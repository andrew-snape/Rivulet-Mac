// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// TheAudioDB's artist photo, backdrop and biography, looked up by MusicBrainz ID.
nonisolated enum TheAudioDBClient {
    /// TheAudioDB's published free key, the same for every app. Not a secret.
    static let apiKey = "123"

    nonisolated struct Result: Sendable {
        let bio: String?
        let thumb: URL?
        let fanart: URL?
    }

    private struct Response: Decodable, Sendable {
        struct Artist: Decodable, Sendable {
            let strBiographyEN: String?
            let strArtistThumb: String?
            let strArtistFanart: String?
        }
        let artists: [Artist]?
    }

    @concurrent
    static func artist(musicBrainzID: String) async -> MusicLookup<Result> {
        var components = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/\(apiKey)/artist-mb.php")
        components?.queryItems = [URLQueryItem(name: "i", value: musicBrainzID)]
        guard let url = components?.url else { return .unavailable }
        switch await MusicInfoHTTP.get(url, as: Response.self) {
        case .unavailable: return .unavailable
        case .notFound: return .notFound
        case .found(let response):
            guard let artist = response.artists?.first else { return .notFound }
            func link(_ text: String?) -> URL? {
                guard let text, !text.isEmpty else { return nil }
                return URL(string: text)
            }
            let bio = artist.strBiographyEN?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .found(Result(
                bio: (bio?.isEmpty ?? true) ? nil : bio,
                thumb: link(artist.strArtistThumb), fanart: link(artist.strArtistFanart)))
        }
    }
}
