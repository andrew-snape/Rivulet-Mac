// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What MusicBrainz knows about an artist or release group.
nonisolated struct MBEntity: Sendable {
    let id: String
    let wikidataID: String?
    let genres: [String]
    let links: [MusicLink]
}

/// MusicBrainz asks for at most one request a second, so every call waits its turn.
actor MusicBrainzClient {
    static let shared = MusicBrainzClient()

    private var nextSlot = ContinuousClock.now

    private func waitTurn() async -> Bool {
        let slot = max(nextSlot, .now)
        nextSlot = slot + .milliseconds(1100)
        do {
            try await Task.sleep(until: slot, clock: .continuous)
            return true
        } catch {
            return false
        }
    }

    private func get<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem], as type: T.Type) async -> MusicLookup<T> {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)") else { return .unavailable }
        components.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url, await waitTurn() else { return .unavailable }
        return await MusicInfoHTTP.get(url, as: type)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Search

    private struct ArtistSearch: Decodable, Sendable {
        struct Hit: Decodable, Sendable {
            let id: String
            let name: String
            let score: Int?
        }
        let artists: [Hit]?
    }

    /// The ID of the one artist named exactly `name`; several hits, or none, is notFound.
    func searchArtist(name: String) async -> MusicLookup<String> {
        let result = await get("artist", [
            URLQueryItem(name: "query", value: "artist:\"\(Self.escaped(name))\""),
            URLQueryItem(name: "limit", value: "5")
        ], as: ArtistSearch.self)
        switch result {
        case .unavailable: return .unavailable
        case .notFound: return .notFound
        case .found(let search):
            let wanted = MusicNameMatch.normalised(name)
            let exact = (search.artists ?? []).filter {
                MusicNameMatch.normalised($0.name) == wanted && ($0.score ?? 0) >= 90
            }
            return exact.count == 1 ? .found(exact[0].id) : .notFound
        }
    }

    private struct ReleaseGroupSearch: Decodable, Sendable {
        struct Credit: Decodable, Sendable {
            let name: String?
            let artist: Named?
        }
        struct Named: Decodable, Sendable { let name: String? }
        struct Hit: Decodable, Sendable {
            let id: String
            let title: String
            let score: Int?
            let artistCredit: [Credit]?
            enum CodingKeys: String, CodingKey {
                case id, title, score
                case artistCredit = "artist-credit"
            }
        }
        let releaseGroups: [Hit]?
        enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
    }

    func searchReleaseGroup(title: String, artist: String) async -> MusicLookup<String> {
        let result = await get("release-group", [
            URLQueryItem(name: "query", value: "releasegroup:\"\(Self.escaped(title))\" AND artist:\"\(Self.escaped(artist))\""),
            URLQueryItem(name: "limit", value: "5")
        ], as: ReleaseGroupSearch.self)
        switch result {
        case .unavailable: return .unavailable
        case .notFound: return .notFound
        case .found(let search):
            let wantedTitle = MusicNameMatch.normalised(title)
            let wantedArtist = MusicNameMatch.normalised(artist)
            let exact = (search.releaseGroups ?? []).filter { hit in
                let credit = hit.artistCredit?.first
                let name = credit?.name ?? credit?.artist?.name ?? ""
                return MusicNameMatch.normalised(hit.title) == wantedTitle
                    && MusicNameMatch.normalised(name) == wantedArtist && (hit.score ?? 0) >= 90
            }
            return exact.count == 1 ? .found(exact[0].id) : .notFound
        }
    }

    // MARK: Lookup

    private struct Entity: Decodable, Sendable {
        struct Relation: Decodable, Sendable {
            struct Resource: Decodable, Sendable { let resource: String? }
            let type: String?
            let url: Resource?
        }
        struct Genre: Decodable, Sendable {
            let name: String
            let count: Int?
        }
        let id: String
        let relations: [Relation]?
        let genres: [Genre]?
    }

    private struct ReleaseLookup: Decodable, Sendable {
        struct Group: Decodable, Sendable { let id: String }
        let releaseGroup: Group?
        enum CodingKeys: String, CodingKey { case releaseGroup = "release-group" }
    }

    private static func entity(_ raw: Entity) -> MBEntity {
        let wikidata = raw.relations?.first { $0.type == "wikidata" }?.url?.resource
            .flatMap { URL(string: $0)?.lastPathComponent }
        let genres = (raw.genres ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(5).map(\.name)
        return MBEntity(id: raw.id, wikidataID: wikidata, genres: genres, links: links(from: raw.relations ?? []))
    }

    private static let linkKinds: [String: MusicLink.Kind] = [
        "official homepage": .officialSite, "bandcamp": .bandcamp, "discogs": .discogs, "allmusic": .allMusic,
        "youtube": .youtube, "social network": .social, "streaming": .streaming, "free streaming": .streaming,
        "wikipedia": .wikipedia
    ]

    /// https links only, one per address, at most eight, in a fixed order.
    private static func links(from relations: [Entity.Relation]) -> [MusicLink] {
        var seen = Set<URL>()
        var found: [MusicLink] = []
        for relation in relations {
            guard let type = relation.type, let kind = linkKinds[type],
                  let text = relation.url?.resource, let url = URL(string: text),
                  url.scheme?.lowercased() == "https", url.host() != nil, seen.insert(url).inserted else { continue }
            found.append(MusicLink(kind: kind, url: url))
        }
        let order: [MusicLink.Kind] = [.officialSite, .bandcamp, .wikipedia, .discogs, .allMusic, .youtube, .social, .streaming]
        let ranked = order.flatMap { kind in found.filter { $0.kind == kind } }
        return Array(ranked.prefix(8))
    }

    func artist(id: String) async -> MusicLookup<MBEntity> {
        switch await get("artist/\(id)", [URLQueryItem(name: "inc", value: "url-rels+genres")], as: Entity.self) {
        case .found(let raw): return .found(Self.entity(raw))
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        }
    }

    /// `id` is a release group's; Plex sometimes carries a release's, which is tried when this one is unknown.
    func releaseGroup(id: String) async -> MusicLookup<MBEntity> {
        switch await get("release-group/\(id)", [URLQueryItem(name: "inc", value: "url-rels+genres")], as: Entity.self) {
        case .found(let raw): return .found(Self.entity(raw))
        case .unavailable: return .unavailable
        case .notFound:
            guard case .found(let release) = await get("release/\(id)", [URLQueryItem(name: "inc", value: "release-groups")],
                                                       as: ReleaseLookup.self),
                  let groupID = release.releaseGroup?.id else { return .notFound }
            switch await get("release-group/\(groupID)", [URLQueryItem(name: "inc", value: "url-rels+genres")], as: Entity.self) {
            case .found(let raw): return .found(Self.entity(raw))
            case .notFound: return .notFound
            case .unavailable: return .unavailable
            }
        }
    }
}
