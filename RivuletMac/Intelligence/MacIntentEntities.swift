// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppIntents
import AppKit
import CryptoKit

// What Siri, Spotlight and Shortcuts can name: Plex titles and music, Live TV
// channels and radio stations. Entities hold plain values; the queries read the
// app's stores through `IntentStore` on the main actor.
//
// Images travel as data, never as a URL: Plex image URLs carry the server
// token, and Spotlight and Shortcuts keep what they are given.

// MARK: - Video

nonisolated struct VideoEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Movie or Show"
    static let defaultQuery = VideoQuery()

    /// The Plex `ratingKey`.
    let id: String
    let title: String
    let subtitle: String?
    let imageData: Data?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: imageData.map { .init(data: $0) }
        )
    }
}

nonisolated struct VideoQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [VideoEntity] {
        try await IntentStore.videos(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [VideoEntity] {
        try await IntentStore.videos(matching: string)
    }

    /// Continue Watching: what Siri offers first, and what it learns names from.
    func suggestedEntities() async throws -> [VideoEntity] {
        try await IntentStore.continueWatching()
    }
}

// MARK: - Channel

nonisolated struct ChannelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Channel"
    static let defaultQuery = ChannelQuery()

    /// `UnifiedChannel.id`.
    let id: String
    let name: String
    let number: Int?
    /// What is on now, from the guide.
    let programme: String?
    let imageData: Data?

    var displayRepresentation: DisplayRepresentation {
        let label = number.map { "\($0) · \(name)" } ?? name
        return DisplayRepresentation(
            title: "\(label)",
            subtitle: programme.map { "\($0)" },
            image: imageData.map { .init(data: $0) }
        )
    }
}

nonisolated struct ChannelQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ChannelEntity] {
        await IntentStore.channels(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        await IntentStore.channels(matching: string)
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        await IntentStore.suggestedChannels()
    }
}

// MARK: - Station

nonisolated struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Radio Station"
    static let defaultQuery = StationQuery()

    /// A hash of the stream address: an address can carry credentials, and
    /// Shortcuts keeps the identifiers it is given.
    let id: String
    let name: String
    let group: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: group.map { "\($0)" })
    }

    static func identifier(for streamURL: URL) -> String {
        SHA256.hash(data: Data(streamURL.absoluteString.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated struct StationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        await IntentStore.stations(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [StationEntity] {
        await IntentStore.stations(matching: string)
    }

    func suggestedEntities() async throws -> [StationEntity] {
        await IntentStore.stations(matching: nil)
    }
}

// MARK: - Music

nonisolated struct MusicEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = MusicQuery()

    /// The Plex `ratingKey` of an artist, album, track or playlist.
    let id: String
    let title: String
    let subtitle: String?
    let imageData: Data?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" },
            image: imageData.map { .init(data: $0) }
        )
    }
}

nonisolated struct MusicQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MusicEntity] {
        try await IntentStore.music(ids: identifiers)
    }

    func entities(matching string: String) async throws -> [MusicEntity] {
        try await IntentStore.music(matching: string)
    }

    /// Playlists: the music most often asked for by name.
    func suggestedEntities() async throws -> [MusicEntity] {
        try await IntentStore.playlists()
    }
}

// MARK: - Store access

/// Reads the app's stores for the queries and intents. Results that show a
/// picker are capped, and only those few carry artwork.
@MainActor
enum IntentStore {
    private static let pickerLimit = 12

    // MARK: Plex

    static func plex() throws -> MacPlexSession {
        guard let plex = MacAppDelegate.vod?.plex, plex.isConfigured else { throw IntentFailure.signedOut }
        return plex
    }

    static func item(_ ratingKey: String) async throws -> PlexMetadata {
        let plex = try plex()
        let (serverURL, token) = try plex.configuration()
        return try await plex.network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: ratingKey)
    }

    static func videos(ids: [String]) async throws -> [VideoEntity] {
        var found: [VideoEntity] = []
        for id in ids {
            if let item = try? await item(id), let entity = await videoEntity(item, withImage: true) {
                found.append(entity)
            }
        }
        return found
    }

    static func videos(matching text: String) async throws -> [VideoEntity] {
        let results = try await plex().search(text)
        var found: [VideoEntity] = []
        for item in results.prefix(pickerLimit) {
            if let entity = await videoEntity(item, withImage: true) { found.append(entity) }
        }
        return found
    }

    static func continueWatching() async throws -> [VideoEntity] {
        var found: [VideoEntity] = []
        for item in try await continueWatchingItems() {
            if let entity = await videoEntity(item, withImage: false) { found.append(entity) }
        }
        return found
    }

    static func continueWatchingItems() async throws -> [PlexMetadata] {
        let plex = try plex()
        if plex.continueWatching == nil { await plex.refreshIfStale() }
        return plex.continueWatching?.Metadata ?? []
    }

    static func videoEntity(_ item: PlexMetadata, withImage: Bool) async -> VideoEntity? {
        guard let key = item.ratingKey, let plex = try? plex() else { return nil }
        let image = withImage
            ? await imageData(plex.artworkURL(for: item, kind: .poster, width: 200, height: 300))
            : nil
        return VideoEntity(id: key, title: item.title ?? "Untitled", subtitle: subtitle(of: item), imageData: image)
    }

    /// "Slow Horses, S4 E2" for an episode, the title otherwise: what Siri says back.
    static func spokenName(of item: PlexMetadata) -> String {
        guard item.type == "episode", let show = item.grandparentTitle else { return item.title ?? "it" }
        guard let season = item.parentIndex, let episode = item.index else { return show }
        return "\(show), S\(season) E\(episode)"
    }

    private static func subtitle(of item: PlexMetadata) -> String? {
        switch item.type {
        case "episode":
            let number = item.parentIndex.flatMap { season in item.index.map { "S\(season) E\($0)" } }
            return [item.grandparentTitle, number].compactMap { $0 }.joined(separator: " · ")
        case "season":
            return item.parentTitle
        case "show":
            return item.year.map { "TV show · \($0)" } ?? "TV show"
        default:
            return item.year.map(String.init)
        }
    }

    // MARK: Music

    static func music(ids: [String]) async throws -> [MusicEntity] {
        var found: [MusicEntity] = []
        for id in ids {
            if let item = try? await item(id), let entity = await musicEntity(item, withImage: true) {
                found.append(entity)
            }
        }
        return found
    }

    static func music(matching text: String) async throws -> [MusicEntity] {
        let results = try await plex().searchMusic(text)
        var found: [MusicEntity] = []
        for item in results.prefix(pickerLimit) {
            if let entity = await musicEntity(item, withImage: true) { found.append(entity) }
        }
        return found
    }

    static func playlists() async throws -> [MusicEntity] {
        var found: [MusicEntity] = []
        for item in try await plex().audioPlaylists() {
            if let entity = await musicEntity(item, withImage: false) { found.append(entity) }
        }
        return found
    }

    private static func musicEntity(_ item: PlexMetadata, withImage: Bool) async -> MusicEntity? {
        guard let key = item.ratingKey, let plex = try? plex() else { return nil }
        let subtitle: String? = switch item.type {
        case "artist": "Artist"
        case "album": ["Album", item.parentTitle].compactMap { $0 }.joined(separator: " · ")
        case "track": ["Song", item.grandparentTitle].compactMap { $0 }.joined(separator: " · ")
        case "playlist": "Playlist"
        default: nil
        }
        let image = withImage ? await imageData(plex.artworkURL(for: item, width: 200, height: 200)) : nil
        return MusicEntity(id: key, title: item.title ?? "Untitled", subtitle: subtitle, imageData: image)
    }

    // MARK: Live TV

    /// The channels the Live TV page can list, without hidden ones. Loads them
    /// if Siri asks before the page has.
    static func visibleChannels() async -> [UnifiedChannel] {
        let store = LiveTVDataStore.shared
        if store.channels.isEmpty { await store.loadChannels() }
        return store.channels.filter { !store.isHidden($0) }
    }

    static func channels(ids: [String]) async -> [ChannelEntity] {
        let wanted = Set(ids)
        var found: [ChannelEntity] = []
        for channel in await visibleChannels() where wanted.contains(channel.id) {
            found.append(await channelEntity(channel, withImage: true))
        }
        return found
    }

    /// By name, call sign or number, as the Live TV page filters.
    static func channels(matching text: String) async -> [ChannelEntity] {
        let text = text.trimmingCharacters(in: .whitespaces)
        let matches = await visibleChannels().filter {
            $0.name.localizedCaseInsensitiveContains(text)
                || $0.callSign?.localizedCaseInsensitiveContains(text) == true
                || $0.channelNumber.map(String.init) == text
        }
        var found: [ChannelEntity] = []
        for channel in matches.prefix(pickerLimit) { found.append(await channelEntity(channel, withImage: true)) }
        return found
    }

    /// Favourites when there are any, else the lineup: the names Siri learns.
    static func suggestedChannels() async -> [ChannelEntity] {
        let store = LiveTVDataStore.shared
        let visible = await visibleChannels()
        let favourites = visible.filter { $0.isFavourite || store.isFavorite($0) }
        var found: [ChannelEntity] = []
        for channel in (favourites.isEmpty ? visible : favourites).prefix(200) {
            found.append(await channelEntity(channel, withImage: false))
        }
        return found
    }

    static func channel(id: String) async -> UnifiedChannel? {
        await visibleChannels().first { $0.id == id }
    }

    private static func channelEntity(_ channel: UnifiedChannel, withImage: Bool) async -> ChannelEntity {
        let image = withImage ? await imageData(channel.logoURL) : nil
        return ChannelEntity(
            id: channel.id, name: channel.name, number: channel.channelNumber,
            programme: LiveTVDataStore.shared.getCurrentProgram(for: channel)?.title,
            imageData: image
        )
    }

    // MARK: Radio

    /// My Stations and every playlist's stations, without hidden ones or repeats.
    static func allStations() async -> [M3UParser.ParsedChannel] {
        let store = RadioStore.shared
        await store.refreshMissing()
        let all = store.ownStationChannels + store.playlists.flatMap { store.stations[$0.id] ?? [] }
        var seen = Set<URL>()
        return all.filter { !store.isHidden($0) && seen.insert($0.streamURL).inserted }
    }

    static func stations(ids: [String]) async -> [StationEntity] {
        let wanted = Set(ids)
        return await allStations().map(stationEntity).filter { wanted.contains($0.id) }
    }

    /// By name and group, as the Radio page filters. Nil lists them all.
    static func stations(matching text: String?) async -> [StationEntity] {
        let text = text?.trimmingCharacters(in: .whitespaces) ?? ""
        let stations = await allStations()
        let matches = text.isEmpty ? stations : stations.filter {
            $0.name.localizedCaseInsensitiveContains(text)
                || $0.groupTitle?.localizedCaseInsensitiveContains(text) == true
        }
        return matches.map(stationEntity)
    }

    static func station(id: String) async -> M3UParser.ParsedChannel? {
        await allStations().first { StationEntity.identifier(for: $0.streamURL) == id }
    }

    private static func stationEntity(_ station: M3UParser.ParsedChannel) -> StationEntity {
        StationEntity(id: StationEntity.identifier(for: station.streamURL), name: station.name,
                      group: station.groupTitle)
    }

    // MARK: Images

    /// A small PNG of the image at `url`, through the artwork cache (which
    /// trusts Plex certificates).
    static func imageData(_ url: URL?) async -> Data? {
        guard let url, let image = await MacArtworkCache.shared.image(for: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// What an intent says when it can't do what was asked.
nonisolated enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case notFound
    case nothingToResume
    case nothingPlaying
    case couldNotPlay(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Plex in Rivulet first."
        case .notFound: "Rivulet couldn't find that."
        case .nothingToResume: "There's nothing in Continue Watching."
        case .nothingPlaying: "Nothing is playing in Rivulet."
        case .couldNotPlay(let name): "Rivulet couldn't play \(name)."
        }
    }
}
