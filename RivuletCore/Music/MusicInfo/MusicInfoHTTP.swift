// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The one HTTP path for online music lookups. Prints nothing.
nonisolated enum MusicInfoHTTP {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Rivulet/\(version) ( https://github.com/andrew-snape/Rivulet-Mac )"
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    @concurrent
    static func get<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async -> MusicLookup<T> {
        do {
            let (data, response) = try await session.data(from: url)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
            switch status {
            case 200:
                guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .notFound }
                return .found(value)
            case 404:
                return .notFound
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}
