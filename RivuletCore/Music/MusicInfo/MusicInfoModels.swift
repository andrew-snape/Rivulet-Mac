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

/// A page about an artist or album elsewhere on the web, from MusicBrainz's URL relations.
nonisolated struct MusicLink: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case officialSite, bandcamp, discogs, allMusic, youtube, social, streaming, wikipedia

        var title: String {
            switch self {
            case .officialSite: "Official Site"
            case .bandcamp: "Bandcamp"
            case .discogs: "Discogs"
            case .allMusic: "AllMusic"
            case .youtube: "YouTube"
            case .social: "Social"
            case .streaming: "Streaming"
            case .wikipedia: "Wikipedia"
            }
        }
    }

    var kind: Kind
    var url: URL

    /// Social and streaming links are named for their site when it is a known one.
    var title: String {
        guard kind == .social || kind == .streaming, var host = url.host()?.lowercased() else { return kind.title }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let names: [String: String] = [
            "instagram.com": "Instagram", "facebook.com": "Facebook", "twitter.com": "X", "x.com": "X",
            "tiktok.com": "TikTok", "soundcloud.com": "SoundCloud", "bsky.app": "Bluesky",
            "threads.net": "Threads", "mastodon.social": "Mastodon", "patreon.com": "Patreon",
            "open.spotify.com": "Spotify", "music.apple.com": "Apple Music", "deezer.com": "Deezer",
            "tidal.com": "Tidal", "music.youtube.com": "YouTube Music", "music.amazon.com": "Amazon Music",
            "pandora.com": "Pandora", "napster.com": "Napster", "qobuz.com": "Qobuz"
        ]
        return names[host] ?? kind.title
    }
}

nonisolated struct MusicArtistInfo: Codable, Sendable, Equatable {
    var musicBrainzID: String?
    var biography: MusicInfoText?
    var imageURL: URL?
    var backdropURL: URL?
    var genres: [String] = []
    var links: [MusicLink] = []

    init(musicBrainzID: String? = nil) { self.musicBrainzID = musicBrainzID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        musicBrainzID = try c.decodeIfPresent(String.self, forKey: .musicBrainzID)
        biography = try c.decodeIfPresent(MusicInfoText.self, forKey: .biography)
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        backdropURL = try c.decodeIfPresent(URL.self, forKey: .backdropURL)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        links = try c.decodeIfPresent([MusicLink].self, forKey: .links) ?? []
    }
}

nonisolated struct MusicAlbumInfo: Codable, Sendable, Equatable {
    var releaseGroupID: String?
    var summary: MusicInfoText?
    /// Cover Art Archive's front cover for the release group.
    var coverURL: URL?
    var genres: [String] = []
    var links: [MusicLink] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        releaseGroupID = try c.decodeIfPresent(String.self, forKey: .releaseGroupID)
        summary = try c.decodeIfPresent(MusicInfoText.self, forKey: .summary)
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        links = try c.decodeIfPresent([MusicLink].self, forKey: .links) ?? []
    }
}

/// The outcome of one online request. `notFound` is an answer worth caching;
/// `unavailable` (offline, rate limited, a server error) is not.
nonisolated enum MusicLookup<T: Sendable>: Sendable {
    case found(T)
    case notFound
    case unavailable
}
