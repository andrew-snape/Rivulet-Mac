// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A track ready for the music player: its full metadata (loudness lives on
/// the audio stream) and the URL to open.
nonisolated struct MacMusicSource: Sendable {
    let entryID: UUID
    let track: PlexMetadata
    let url: URL
    let serverURL: String
    let token: String
    /// Set for a transcode, to stop it on the server afterwards.
    let transcodeSessionID: String?
    /// Names the file in the music cache; nil for a transcode.
    var cacheKey: MacMusicCacheKey? = nil

    var isTranscode: Bool { transcodeSessionID != nil }
    /// Plays from a file on this Mac.
    var isCached: Bool { url.isFileURL }

    /// The same track, played from `file`.
    func withURL(_ file: URL) -> MacMusicSource {
        MacMusicSource(entryID: entryID, track: track, url: file, serverURL: serverURL, token: token,
                       transcodeSessionID: nil, cacheKey: cacheKey)
    }
}

/// What a music library page lists.
nonisolated enum MacMusicKind: String, CaseIterable, Identifiable {
    case artists, albums, playlists

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Plex's metadata type number for `/all?type=`.
    var plexType: Int? {
        switch self {
        case .artists: 8
        case .albums: 9
        case .playlists: nil
        }
    }
}

extension MacPlexSession {
    // MARK: - Browsing

    /// One page of artists or albums.
    func musicPage(
        _ library: PlexLibrary,
        kind: MacMusicKind,
        sort: LibrarySortOption,
        start: Int,
        size: Int
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let type = kind.plexType else { return ([], 0) }
        let (serverURL, token) = try configuration()
        let key = "/library/sections/\(library.key)/all?type=\(type)&sort=\(sort.apiParameter)"
        return try await network.getHubItems(serverURL: serverURL, authToken: token, hubKey: key, start: start, count: size)
    }

    /// The library page's rows: Plex's own music hubs (recently played,
    /// mixes, recently added), keeping only kinds the music pages can open.
    func musicHubs(_ library: PlexLibrary) async throws -> [PlexHub] {
        let (serverURL, token) = try configuration()
        let playable: Set<String> = ["artist", "album", "track", "playlist"]
        return try await network.getLibraryHubs(serverURL: serverURL, authToken: token, sectionId: library.key)
            .compactMap { hub in
                var hub = hub
                hub.Metadata = hub.Metadata?.filter { playable.contains($0.type ?? "") }
                return (hub.Metadata ?? []).isEmpty ? nil : hub
            }
    }

    func audioPlaylists() async throws -> [PlexMetadata] {
        let (serverURL, token) = try configuration()
        return try await network.getAudioPlaylists(serverURL: serverURL, authToken: token)
    }

    /// An artist's albums, newest first.
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = artist.ratingKey else { return [] }
        let (serverURL, token) = try configuration()
        return try await network.getChildren(serverURL: serverURL, authToken: token, ratingKey: key)
            .filter { $0.type == "album" }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    /// The tracks of an album (disc, then track number), playlist (its order) or artist (every album).
    func tracks(of item: PlexMetadata) async throws -> [PlexMetadata] {
        guard let key = item.ratingKey else { return [] }
        let (serverURL, token) = try configuration()
        switch item.type {
        case "track":
            return [item]
        case "playlist":
            return try await network.getPlaylistItems(serverURL: serverURL, authToken: token, ratingKey: key)
                .filter { $0.type == "track" }
        case "artist":
            return try await network.getAllLeaves(serverURL: serverURL, authToken: token, ratingKey: key)
        default:
            return try await network.getChildren(serverURL: serverURL, authToken: token, ratingKey: key)
                .sorted { ($0.parentIndex ?? 1, $0.index ?? 0) < ($1.parentIndex ?? 1, $1.index ?? 0) }
        }
    }

    func popularTracks(of artist: PlexMetadata, sectionKey: String) async throws -> [PlexMetadata] {
        guard let key = artist.ratingKey else { return [] }
        let (serverURL, token) = try configuration()
        return try await network.getPopularTracks(serverURL: serverURL, authToken: token, sectionId: sectionKey, artistKey: key)
    }

    /// An artist or album with its guids, styles, moods and reviews.
    func musicDetail(for item: PlexMetadata) async throws -> PlexMetadata {
        guard let key = item.ratingKey else { return item }
        let (serverURL, token) = try configuration()
        return try await network.getMusicMetadata(serverURL: serverURL, authToken: token, ratingKey: key)
    }

    /// Plex's related rows for an artist or album, keeping those that hold
    /// only `kind` (so "artist" or "album"), at most two.
    func musicRelated(to item: PlexMetadata, kind: String) async -> [PlexHub] {
        guard let key = item.ratingKey, let (serverURL, token) = try? configuration(),
              let hubs = try? await network.getRelatedItems(serverURL: serverURL, authToken: token, ratingKey: key)
        else { return [] }
        var kept: [PlexHub] = []
        for var hub in hubs {
            let items = (hub.Metadata ?? []).filter { $0.ratingKey != key }
            guard !items.isEmpty, items.allSatisfy({ $0.type == kind }) else { continue }
            hub.Metadata = items
            kept.append(hub)
            if kept.count == 2 { break }
        }
        return kept
    }

    /// Library artists with these names, in order; a name with no exact match is skipped.
    func libraryArtists(named names: [String], sectionKey: String) async -> [PlexMetadata] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        let wanted = Array(names.prefix(8))
        let network = self.network
        let candidates = await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, name) in wanted.enumerated() {
                group.addTask {
                    (index, (try? await network.getLibraryArtists(
                        serverURL: serverURL, authToken: token, sectionId: sectionKey, title: name)) ?? [])
                }
            }
            var results: [Int: [PlexMetadata]] = [:]
            for await (index, matches) in group { results[index] = matches }
            return results
        }
        return wanted.enumerated().compactMap { index, name in
            let target = MusicNameMatch.normalised(name)
            return candidates[index]?.first { MusicNameMatch.normalised($0.displayTitle) == target }
        }.uniqued()
    }

    /// Lossless or Hi-Res Lossless when every track is lossless; the first
    /// track's stream decides Hi-Res.
    func albumQuality(of tracks: [PlexMetadata]) async -> MusicAudioQuality? {
        guard !tracks.isEmpty,
              tracks.allSatisfy({ MusicAudioQuality.isLossless(codec: $0.Media?.first?.audioCodec) }),
              let first = tracks.first, let key = first.ratingKey else { return nil }
        guard let (serverURL, token) = try? configuration(),
              let full = try? await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: key) else {
            return .lossless
        }
        let stream = full.audioStream
        return MusicAudioQuality.classify(
            codec: full.Media?.first?.audioCodec ?? stream?.codec,
            bitDepth: stream?.bitDepth, samplingRate: stream?.samplingRate) ?? .lossless
    }

    /// Radio's next tracks after `seed`: sonically similar when the server has
    /// analysed the library, otherwise random tracks from the seed's library.
    func radioTracks(after seed: PlexMetadata, sectionKey: String?) async -> [PlexMetadata] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        if let key = seed.ratingKey,
           let similar = try? await network.getSonicallySimilarTracks(serverURL: serverURL, authToken: token, ratingKey: key),
           !similar.isEmpty {
            return similar
        }
        guard let section = sectionKey ?? seed.librarySectionID.map(String.init) else { return [] }
        return await randomTracks(sectionKey: section)
    }

    func randomTracks(sectionKey: String, filters: [URLQueryItem] = []) async -> [PlexMetadata] {
        guard let (serverURL, token) = try? configuration() else { return [] }
        return (try? await network.getRandomTracks(serverURL: serverURL, authToken: token, sectionId: sectionKey, filters: filters)) ?? []
    }

    // MARK: - Playing

    /// Full metadata for `track` and the URL to play it: the file itself when
    /// AVFoundation can open it, else an AAC transcode. Relay connections always transcode.
    func musicSource(for entryID: UUID, track: PlexMetadata, forceTranscode: Bool = false) async throws -> MacMusicSource {
        let (serverURL, token) = try configuration()
        guard let ratingKey = track.ratingKey else { throw MacPlexSessionError.noPlayableURL }
        let full = try await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)

        let media = full.Media?.first
        let key = Self.avFoundationPlays(media) ? MacMusicCacheKey(ratingKey: ratingKey, media: media) : nil
        // A kept file plays even on a relay connection.
        if !forceTranscode, let key, let file = await MacMusicCache.shared.file(for: key) {
            return MacMusicSource(entryID: entryID, track: full, url: file, serverURL: serverURL, token: token,
                                  transcodeSessionID: nil, cacheKey: key)
        }
        if !forceTranscode, !PlexRelay.isRelayURL(serverURL), Self.avFoundationPlays(media),
           let partKey = media?.Part?.first?.key,
           let url = Self.directPlayURL(serverURL: serverURL, token: token, partKey: partKey) {
            return MacMusicSource(entryID: entryID, track: full, url: url, serverURL: serverURL, token: token,
                                  transcodeSessionID: nil, cacheKey: key)
        }
        let session = UUID().uuidString
        guard let url = network.buildMusicTranscodeURL(
            serverURL: serverURL, authToken: token, ratingKey: ratingKey, sessionID: session
        ) else { throw MacPlexSessionError.noPlayableURL }
        return MacMusicSource(entryID: entryID, track: full, url: url, serverURL: serverURL, token: token, transcodeSessionID: session)
    }

    /// Codecs and containers AVFoundation opens on its own.
    private static func avFoundationPlays(_ media: PlexMedia?) -> Bool {
        guard let media else { return false }
        let codecs: Set<String> = ["mp3", "aac", "alac", "flac", "pcm", "ac3", "eac3"]
        let containers: Set<String> = ["mp3", "mp4", "m4a", "flac", "wav", "aiff", "aif", "aac", "caf"]
        return codecs.contains((media.audioCodec ?? "").lowercased())
            && containers.contains((media.container ?? "").lowercased())
    }

    func reportMusic(_ source: MacMusicSource, time: TimeInterval, state: String) async {
        guard let key = source.track.ratingKey else { return }
        _ = try? await network.reportProgress(
            serverURL: source.serverURL,
            authToken: source.token,
            ratingKey: key,
            timeMs: Int(time * 1000),
            state: state,
            duration: source.track.duration
        )
    }

    /// Counts a play and frees a transcode.
    func finishMusic(_ source: MacMusicSource, played: Bool) async {
        if played, let key = source.track.ratingKey {
            try? await network.markWatched(serverURL: source.serverURL, authToken: source.token, ratingKey: key)
        }
        if let session = source.transcodeSessionID {
            await network.stopTranscodeSession(serverURL: source.serverURL, authToken: source.token, sessionId: session)
        }
    }
}

extension PlexMetadata {
    /// A track's artist: the track artist where it differs from the album's.
    var trackArtist: String? { originalTitle ?? grandparentTitle }

    /// "3:41" for a track, "1:02:10" past an hour.
    var trackTime: String? {
        guard let duration, duration > 0 else { return nil }
        return Duration.milliseconds(duration).formatted(.time(pattern: duration >= 3_600_000 ? .hourMinuteSecond : .minuteSecond))
    }

    /// Square art: an album's own, a track's album, a playlist's tiles.
    var squareArtPath: String? {
        switch type {
        case "track": parentThumb ?? thumb ?? grandparentThumb
        case "playlist": composite ?? thumb
        default: thumb ?? parentThumb
        }
    }

    /// The album a track belongs to, enough for its page to load the rest.
    var albumStub: PlexMetadata? {
        guard type == "track", let parentRatingKey else { return nil }
        return PlexMetadata(ratingKey: parentRatingKey, type: "album", title: parentTitle, thumb: parentThumb,
                            parentRatingKey: grandparentRatingKey, parentTitle: grandparentTitle)
    }

    /// The artist of an album or track.
    var artistStub: PlexMetadata? {
        let key = type == "track" ? grandparentRatingKey : (type == "album" ? parentRatingKey : nil)
        guard let key else { return nil }
        return PlexMetadata(ratingKey: key, type: "artist",
                            title: type == "track" ? grandparentTitle : parentTitle,
                            thumb: type == "track" ? grandparentThumb : parentThumb)
    }
}
