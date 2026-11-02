// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One genre of a library, from `/library/sections/{id}/genre`. `key` is the
/// genre's ID within that library (the `genre=` filter value); the same name
/// has a different ID in each library.
nonisolated struct PlexGenre: Decodable, Sendable, Equatable {
    let key: String
    let title: String
}

nonisolated struct PlexGenreContainer: Decodable, Sendable {
    let MediaContainer: PlexGenreMediaContainer
}

nonisolated struct PlexGenreMediaContainer: Decodable, Sendable {
    let Directory: [PlexGenre]?
}
