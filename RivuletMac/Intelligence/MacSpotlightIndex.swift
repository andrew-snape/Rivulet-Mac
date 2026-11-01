// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppIntents
import CoreSpotlight
import Observation

// Spotlight lists two things from Rivulet: Continue Watching and the favourite
// Live TV channels. Choosing one opens Rivulet and plays it.
//
// Continue Watching is mirrored, not added to: the index is replaced whenever
// the list changes, and the list empties on sign-out and on a server or profile
// switch (`MacPlexSession.clearContent` / `refresh`), so one profile's titles
// never show for another.

extension VideoEntity: IndexedEntity {}
extension ChannelEntity: IndexedEntity {}

@MainActor
enum MacSpotlightIndex {
    static func start(plex: MacPlexSession) {
        Task {
            var indexed: [String]?
            for await items in Observations({ plex.continueWatching?.Metadata ?? [] }) {
                let ids = items.compactMap(\.ratingKey)
                guard ids != indexed else { continue }
                indexed = ids
                var entities: [VideoEntity] = []
                for item in items {
                    if let entity = await IntentStore.videoEntity(item, withImage: true) { entities.append(entity) }
                }
                await replace(with: entities)
            }
        }
        Task {
            let store = LiveTVDataStore.shared
            var indexed: [String]?
            let favourites = Observations {
                store.channels.filter { ($0.isFavourite || store.isFavorite($0)) && !store.isHidden($0) }
            }
            for await channels in favourites {
                let ids = channels.map(\.id)
                guard ids != indexed else { continue }
                indexed = ids
                var entities: [ChannelEntity] = []
                for channel in channels {
                    entities.append(await IntentStore.channelEntity(channel, withImage: true))
                }
                await replace(with: entities)
            }
        }
    }

    /// Everything of this type comes out, then the current set goes in.
    private static func replace<Entity: IndexedEntity>(with entities: [Entity]) async {
        let index = CSSearchableIndex.default()
        try? await index.deleteAppEntities(ofType: Entity.self)
        guard !entities.isEmpty else { return }
        try? await index.indexAppEntities(entities)
    }
}

// MARK: - Opening from Spotlight

/// Choosing a title in Spotlight plays it: these are Continue Watching, so it resumes.
struct OpenVideoIntent: OpenIntent {
    static let title: LocalizedStringResource = "Resume Title"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Title") var target: VideoEntity

    func perform() async throws -> some IntentResult {
        _ = try await IntentActions.playVideo(id: target.id)
        return .result()
    }
}

/// Choosing a channel in Spotlight tunes it on the Live TV page.
struct OpenChannelIntent: OpenIntent {
    static let title: LocalizedStringResource = "Watch Channel"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Channel") var target: ChannelEntity

    func perform() async throws -> some IntentResult {
        _ = try await IntentActions.tune(channelID: target.id)
        return .result()
    }
}
