// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A Wikipedia summary, found through the entity's Wikidata ID.
nonisolated enum WikipediaClient {
    private struct Entities: Decodable, Sendable {
        struct Entity: Decodable, Sendable {
            struct Link: Decodable, Sendable { let title: String? }
            let sitelinks: [String: Link]?
        }
        let entities: [String: Entity]?
    }

    private struct Summary: Decodable, Sendable {
        struct Pages: Decodable, Sendable {
            struct Page: Decodable, Sendable { let page: String? }
            let desktop: Page?
        }
        let type: String?
        let extract: String?
        let contentURLs: Pages?
        enum CodingKeys: String, CodingKey {
            case type, extract
            case contentURLs = "content_urls"
        }
    }

    @concurrent
    static func summary(wikidataID: String) async -> MusicLookup<MusicInfoText> {
        var languages: [String] = []
        for code in [Locale.current.language.languageCode?.identifier ?? "en", "en"] where !languages.contains(code) {
            languages.append(code)
        }
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: wikidataID),
            URLQueryItem(name: "props", value: "sitelinks"),
            URLQueryItem(name: "sitefilter", value: languages.map { "\($0)wiki" }.joined(separator: "|")),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return .unavailable }
        switch await MusicInfoHTTP.get(url, as: Entities.self) {
        case .unavailable: return .unavailable
        case .notFound: return .notFound
        case .found(let found):
            let links = found.entities?[wikidataID]?.sitelinks ?? [:]
            for language in languages {
                guard let title = links["\(language)wiki"]?.title else { continue }
                let encoded = title.replacingOccurrences(of: " ", with: "_")
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
                guard let encoded, let page = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)")
                else { continue }
                switch await MusicInfoHTTP.get(page, as: Summary.self) {
                case .unavailable: return .unavailable
                case .notFound: continue
                case .found(let summary):
                    let extract = (summary.extract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if summary.type == "disambiguation" || extract.isEmpty { continue }
                    return .found(MusicInfoText(
                        text: extract, source: .wikipedia,
                        url: summary.contentURLs?.desktop?.page.flatMap(URL.init(string:))))
                }
            }
            return .notFound
        }
    }
}
