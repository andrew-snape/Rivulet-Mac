// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import FoundationModels

// Smart search: a request like "funny movie under 90 minutes I haven't seen"
// becomes a Plex library filter. The on-device model only reads the request;
// Plex finds the titles. It runs when Apple Intelligence is on and the query
// has three words or more, beside the keyword search, never instead of it.

/// What the model reads out of a request.
@Generable
nonisolated struct MediaRequest {
    @Guide(description: "movie for films, show for TV series, either if the request doesn't say")
    var kind: MediaKind

    @Guide(description: "Genres asked for or clearly implied, using only names from the genre list. Empty if none.")
    var genres: [String]

    @Guide(description: "Longest running time in minutes, only if a length is mentioned")
    var maxMinutes: Int?

    @Guide(description: "Earliest release year, only if a year, decade or era is mentioned")
    var fromYear: Int?

    @Guide(description: "Latest release year, only if a year, decade or era is mentioned")
    var toYear: Int?

    @Guide(description: "True only if they ask for something they haven't watched or seen")
    var unwatchedOnly: Bool

    @Guide(description: "newest for new or recent, highestRated for the best or acclaimed, random for a surprise, otherwise relevance")
    var order: MediaOrder

    @Guide(description: "Words of a title they named, otherwise nil")
    var titleWords: String?
}

@Generable
nonisolated enum MediaKind {
    case movie, show, either
}

@Generable
nonisolated enum MediaOrder {
    case relevance, newest, highestRated, random
}

@MainActor
enum MacSmartSearch {
    /// A row of titles headed by how the request was read
    /// ("Comedy · Movies · Under 90 min · Unwatched").
    struct Result: Equatable {
        let label: String
        let items: [PlexMetadata]
    }

    private static let limit = 40

    /// Library genres, by library key, for one server and session.
    private static var genreCache: (generation: Int, serverURL: String, genres: [String: [PlexGenre]])?

    /// Apple Intelligence is on, the model is ready, and it reads this language.
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale()
    }

    /// Three words or more reads as a request; fewer is a title, which the
    /// keyword search already finds.
    static func readsAsRequest(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// Nil when the model is unavailable or declines, the request names nothing
    /// to filter on, or nothing matches: the keyword results then stand alone.
    static func results(for query: String, plex: MacPlexSession) async throws -> Result? {
        guard isAvailable, readsAsRequest(query) else { return nil }
        let libraries = plex.libraries.filter(\.isVideoLibrary)
        guard !libraries.isEmpty else { return nil }
        let (serverURL, token) = try plex.configuration()

        let genres = await genres(of: libraries, plex: plex, serverURL: serverURL, token: token)
        let known = Dictionary(
            genres.values.joined().map { ($0.title.lowercased(), $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        let session = LanguageModelSession(instructions: instructions(genres: known.values.sorted()))
        guard let request = try? await session.respond(to: query, generating: MediaRequest.self).content else {
            return nil
        }

        // Genres the model made up are dropped, so the filter stays honest.
        let wanted = request.genres.compactMap { known[$0.lowercased()] }
        let filter = SmartFilter(request: request, genres: wanted)
        guard filter.narrows else { return nil }

        var items: [PlexMetadata] = []
        for library in libraries where filter.includes(library) {
            let ids = (genres[library.key] ?? [])
                .filter { genre in wanted.contains { $0.caseInsensitiveCompare(genre.title) == .orderedSame } }
                .map(\.key)
            // A library without any of the genres asked for has nothing to offer.
            if !wanted.isEmpty, ids.isEmpty { continue }
            let page = try await plex.network.getHubItems(
                serverURL: serverURL, authToken: token,
                hubKey: filter.key(for: library, genreIDs: ids), start: 0, count: limit
            )
            items += page.items
        }
        if request.order == .random { items.shuffle() }
        guard !items.isEmpty else { return nil }
        return Result(label: filter.label, items: Array(items.prefix(limit)))
    }

    private static func instructions(genres: [String]) -> String {
        let year = Calendar.current.component(.year, from: .now)
        return """
            You read a request for something to watch from a home media library and fill in a search filter. \
            Fill in only what the request asks for; leave everything else empty, nil or false. \
            Genres must come from this list: \(genres.joined(separator: ", ")). \
            The current year is \(year).
            """
    }

    private static func genres(
        of libraries: [PlexLibrary], plex: MacPlexSession, serverURL: String, token: String
    ) async -> [String: [PlexGenre]] {
        if let cache = genreCache, cache.generation == plex.sessionGeneration, cache.serverURL == serverURL {
            return cache.genres
        }
        var found: [String: [PlexGenre]] = [:]
        for library in libraries {
            found[library.key] = (try? await plex.network.getGenres(
                serverURL: serverURL, authToken: token, sectionId: library.key
            )) ?? []
        }
        genreCache = (plex.sessionGeneration, serverURL, found)
        return found
    }
}

/// A request as a Plex library filter.
private struct SmartFilter {
    let request: MediaRequest
    /// The library's own spelling of each genre asked for.
    let genres: [String]

    private var titleWords: String? {
        guard let words = request.titleWords?.trimmingCharacters(in: .whitespaces), !words.isEmpty else { return nil }
        return words
    }

    /// Something to filter on beyond the kind of title.
    var narrows: Bool {
        !genres.isEmpty || request.maxMinutes != nil || request.fromYear != nil || request.toYear != nil
            || request.unwatchedOnly || titleWords != nil || request.order != .relevance
    }

    /// A length limit means movies: a show has no single running time.
    func includes(_ library: PlexLibrary) -> Bool {
        switch request.kind {
        case .movie: library.type == "movie"
        case .show: library.type == "show"
        case .either: request.maxMinutes == nil || library.type == "movie"
        }
    }

    /// `/library/sections/{key}/all` with Plex filter operators: `>>=` is
    /// "greater than" and `<<=` "less than", sent pre-encoded (`%3E`, `%3C`)
    /// because the hub URL builder parses the key as a URL. Duration is in ms.
    func key(for library: PlexLibrary, genreIDs: [String]) -> String {
        var params: [String] = []
        if !genreIDs.isEmpty { params.append("genre=\(genreIDs.joined(separator: ","))") }
        if let minutes = request.maxMinutes, library.type == "movie" {
            params.append("duration%3C%3C=\(minutes * 60_000 + 1)")
        }
        if let from = request.fromYear { params.append("year%3E%3E=\(from - 1)") }
        if let to = request.toYear { params.append("year%3C%3C=\(to + 1)") }
        if request.unwatchedOnly { params.append("unwatched=1") }
        if let words = titleWords?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            params.append("title=\(words)")
        }
        params.append("sort=\(sort)")
        return "/library/sections/\(library.key)/all?" + params.joined(separator: "&")
    }

    private var sort: String {
        switch request.order {
        case .relevance, .highestRated: "audienceRating:desc"
        case .newest: "originallyAvailableAt:desc"
        case .random: "random"
        }
    }

    /// How the request was read, so it's never a mystery why something matched.
    var label: String {
        var parts = genres
        switch request.kind {
        case .movie: parts.append("Movies")
        case .show: parts.append("TV Shows")
        case .either: break
        }
        if let minutes = request.maxMinutes { parts.append("Under \(minutes) min") }
        switch (request.fromYear, request.toYear) {
        case let (from?, to?): parts.append(from == to ? "\(from)" : "\(from)–\(to)")
        case let (from?, nil): parts.append("From \(from)")
        case let (nil, to?): parts.append("Up to \(to)")
        case (nil, nil): break
        }
        if request.unwatchedOnly { parts.append("Unwatched") }
        if let words = titleWords { parts.append("“\(words)”") }
        switch request.order {
        case .newest: parts.append("Newest first")
        case .highestRated: parts.append("Highest rated")
        case .random: parts.append("Random")
        case .relevance: break
        }
        return parts.joined(separator: " · ")
    }
}
