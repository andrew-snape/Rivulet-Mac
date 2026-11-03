// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Where a piece of online text came from.
nonisolated enum MusicInfoSource: String, Codable, Sendable {
    case wikipedia, theAudioDB

    var displayName: String {
        switch self {
        case .wikipedia: "Wikipedia"
        case .theAudioDB: "TheAudioDB"
        }
    }
}

nonisolated struct MusicInfoText: Codable, Sendable, Equatable {
    var text: String
    var source: MusicInfoSource
    var url: URL?
}

nonisolated struct MusicArtistInfo: Codable, Sendable, Equatable {
    var musicBrainzID: String?
    var biography: MusicInfoText?
    var imageURL: URL?
    var backdropURL: URL?
    var genres: [String] = []
}

nonisolated struct MusicAlbumInfo: Codable, Sendable, Equatable {
    var releaseGroupID: String?
    var summary: MusicInfoText?
    /// Cover Art Archive's front cover for the release group.
    var coverURL: URL?
    var genres: [String] = []
}

/// The outcome of one online request. `notFound` is an answer worth caching;
/// `unavailable` (offline, rate limited, a server error) is not.
nonisolated enum MusicLookup<T: Sendable>: Sendable {
    case found(T)
    case notFound
    case unavailable
}
