// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Fills what Plex lacks about an artist or album from MusicBrainz, Wikipedia
/// and TheAudioDB. Off unless the user turns it on; sends only the names or
/// MusicBrainz IDs; caches on disk; fails silently.
actor MusicInfoStore {
    static let shared = MusicInfoStore()

    nonisolated static let enabledKey = "musicOnlineInfo"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var artistTasks: [String: Task<MusicArtistInfo?, Never>] = [:]
    private var albumTasks: [String: Task<MusicAlbumInfo?, Never>] = [:]

    private static var language: String { Locale.current.language.languageCode?.identifier ?? "en" }

    func artistInfo(name: String, musicBrainzID: String?) async -> MusicArtistInfo? {
        guard Self.isEnabled, !name.isEmpty else { return nil }
        let key = "artist|" + (musicBrainzID ?? "name:" + MusicNameMatch.normalised(name)) + "|" + Self.language
        if let existing = artistTasks[key] { return await existing.value }
        let task = Task { await Self.fetchArtist(key: key, name: name, musicBrainzID: musicBrainzID) }
        artistTasks[key] = task
        let info = await task.value
        artistTasks[key] = nil
        return Self.isEnabled ? info : nil
    }

    func albumInfo(title: String, artist: String, musicBrainzID: String?) async -> MusicAlbumInfo? {
        guard Self.isEnabled, !title.isEmpty else { return nil }
        let key = "album|" + (musicBrainzID ?? "name:" + MusicNameMatch.normalised(artist) + ":" + MusicNameMatch.normalised(title))
            + "|" + Self.language
        if let existing = albumTasks[key] { return await existing.value }
        let task = Task { await Self.fetchAlbum(key: key, title: title, artist: artist, musicBrainzID: musicBrainzID) }
        albumTasks[key] = task
        let info = await task.value
        albumTasks[key] = nil
        return Self.isEnabled ? info : nil
    }

    func clear() async {
        for task in artistTasks.values { task.cancel() }
        for task in albumTasks.values { task.cancel() }
        await MusicInfoCache.shared.clear()
    }

    // MARK: Pipelines

    private static func fetchArtist(key: String, name: String, musicBrainzID: String?) async -> MusicArtistInfo? {
        let cache = MusicInfoCache.shared
        if let cached = await cache.get(key, as: MusicArtistInfo.self) { return cached }

        var id = musicBrainzID
        if id == nil {
            switch await MusicBrainzClient.shared.searchArtist(name: name) {
            case .found(let found): id = found
            case .notFound:
                await cache.set(key, value: nil as MusicArtistInfo?)
                return nil
            case .unavailable: return nil
            }
        }
        guard let id else { return nil }

        var complete = true
        var info = MusicArtistInfo(musicBrainzID: id)
        var wikidata: String?
        switch await MusicBrainzClient.shared.artist(id: id) {
        case .found(let entity):
            info.genres = entity.genres
            info.links = entity.links
            wikidata = entity.wikidataID
        case .notFound: break
        case .unavailable: complete = false
        }
        if let wikidata {
            switch await WikipediaClient.summary(wikidataID: wikidata) {
            case .found(let text): info.biography = text
            case .notFound: break
            case .unavailable: complete = false
            }
        }
        switch await TheAudioDBClient.artist(musicBrainzID: id) {
        case .found(let audioDB):
            info.imageURL = audioDB.thumb
            info.backdropURL = audioDB.fanart
            if info.biography == nil, let bio = audioDB.bio {
                info.biography = MusicInfoText(text: bio, source: .theAudioDB, url: URL(string: "https://www.theaudiodb.com"))
            }
        case .notFound: break
        case .unavailable: complete = false
        }
        guard !Task.isCancelled else { return nil }
        let empty = info.biography == nil && info.imageURL == nil && info.backdropURL == nil && info.genres.isEmpty
            && info.links.isEmpty
        if complete { await cache.set(key, value: empty ? nil : info) }
        return empty ? nil : info
    }

    private static func fetchAlbum(key: String, title: String, artist: String, musicBrainzID: String?) async -> MusicAlbumInfo? {
        let cache = MusicInfoCache.shared
        if let cached = await cache.get(key, as: MusicAlbumInfo.self) { return cached }

        var id = musicBrainzID
        if id == nil {
            guard !artist.isEmpty else { return nil }
            switch await MusicBrainzClient.shared.searchReleaseGroup(title: title, artist: artist) {
            case .found(let found): id = found
            case .notFound:
                await cache.set(key, value: nil as MusicAlbumInfo?)
                return nil
            case .unavailable: return nil
            }
        }
        guard let id else { return nil }

        var complete = true
        var info = MusicAlbumInfo()
        var wikidata: String?
        switch await MusicBrainzClient.shared.releaseGroup(id: id) {
        case .found(let entity):
            info.releaseGroupID = entity.id
            info.coverURL = URL(string: "https://coverartarchive.org/release-group/\(entity.id)/front-500")
            info.genres = entity.genres
            info.links = entity.links
            wikidata = entity.wikidataID
        case .notFound: break
        case .unavailable: complete = false
        }
        if let wikidata {
            switch await WikipediaClient.summary(wikidataID: wikidata) {
            case .found(let text): info.summary = text
            case .notFound: break
            case .unavailable: complete = false
            }
        }
        guard !Task.isCancelled else { return nil }
        let empty = info.releaseGroupID == nil
        if complete { await cache.set(key, value: empty ? nil : info) }
        return empty ? nil : info
    }
}
