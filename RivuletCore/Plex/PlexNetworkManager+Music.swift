// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexNetworkManager+Music.swift
//  Rivulet
//
//  Plex music: playlists, an artist's popular tracks, sonically similar
//  tracks for radio, random tracks, and the audio transcode URL.
//
//  Music section items use metadata types 8 (artist), 9 (album) and
//  10 (track). Paged calls send X-Plex-Container-Start with the size, since
//  PMS ignores the size on its own.
//

import Foundation

extension PlexNetworkManager {
    /// The account's audio playlists, smart ones included.
    func getAudioPlaylists(serverURL: String, authToken: String) async throws -> [PlexMetadata] {
        try await musicItems(serverURL: serverURL, authToken: authToken, path: "/playlists", query: [
            URLQueryItem(name: "playlistType", value: "audio")
        ])
    }

    /// A playlist's tracks, in playlist order.
    func getPlaylistItems(serverURL: String, authToken: String, ratingKey: String) async throws -> [PlexMetadata] {
        try await musicItems(serverURL: serverURL, authToken: authToken, path: "/playlists/\(ratingKey)/items", query: [])
    }

    /// An artist's tracks, most played across Plex's listeners first.
    func getPopularTracks(
        serverURL: String,
        authToken: String,
        sectionId: String,
        artistKey: String,
        count: Int = 10
    ) async throws -> [PlexMetadata] {
        try await musicItems(serverURL: serverURL, authToken: authToken, path: "/library/sections/\(sectionId)/all", query: [
            URLQueryItem(name: "type", value: "10"),
            URLQueryItem(name: "artist.id", value: artistKey),
            URLQueryItem(name: "sort", value: "ratingCount:desc"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ])
    }

    /// Tracks that sound like `ratingKey`, from the server's sonic analysis.
    /// Empty (or an error) when the library has not been analysed.
    func getSonicallySimilarTracks(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        count: Int = 40
    ) async throws -> [PlexMetadata] {
        try await musicItems(serverURL: serverURL, authToken: authToken, path: "/library/metadata/\(ratingKey)/nearest", query: [
            URLQueryItem(name: "limit", value: "\(count)"),
            URLQueryItem(name: "maxDistance", value: "0.25")
        ])
    }

    /// Random tracks from a music section; `filters` narrows them (an
    /// `artist.id` or `genre`).
    func getRandomTracks(
        serverURL: String,
        authToken: String,
        sectionId: String,
        filters: [URLQueryItem] = [],
        count: Int = 40
    ) async throws -> [PlexMetadata] {
        try await musicItems(serverURL: serverURL, authToken: authToken, path: "/library/sections/\(sectionId)/all", query: [
            URLQueryItem(name: "type", value: "10"),
            URLQueryItem(name: "sort", value: "random"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ] + filters)
    }

    /// One track as AAC over HLS, for files AVFoundation cannot open and for
    /// relay connections. The session id is the caller's, to stop it later.
    func buildMusicTranscodeURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        sessionID: String
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/music/:/transcode/universal/start.m3u8") else {
            return nil
        }
        let items = [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),
            URLQueryItem(
                name: "X-Plex-Client-Profile-Extra",
                value: "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)"
            ),
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "musicBitrate", value: "320"),
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "hasMDE", value: "1")
        ]
        // Encoded here rather than by URLComponents: the profile's own `&` and
        // `=` must not read as query separators.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        return components.url
    }

    private func musicItems(
        serverURL: String,
        authToken: String,
        path: String,
        query: [URLQueryItem]
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)\(path)") else {
            throw PlexAPIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: PlexMediaContainerWrapper = try await request(url, headers: plexHeaders(authToken: authToken))
        return container.MediaContainer.Metadata ?? []
    }
}
