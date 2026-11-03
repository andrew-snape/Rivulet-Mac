// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CryptoKit
import Foundation

/// Found details on disk, so a page does not ask again: 30 days for a hit,
/// 7 for a miss. A nil value is a remembered miss.
actor MusicInfoCache {
    static let shared = MusicInfoCache()

    private struct Entry<T: Codable & Sendable>: Codable, Sendable {
        var version = 2
        var fetchedAt: Date
        var value: T?
    }

    private var memory: [String: Data] = [:]

    private var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MusicInfo", isDirectory: true)
    }

    private func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("\(digest).json")
    }

    /// `.some(nil)` is a cached miss; `nil` is nothing usable cached.
    func get<T: Codable & Sendable>(_ key: String, as type: T.Type) -> T?? {
        let data: Data
        if let cached = memory[key] {
            data = cached
        } else if let url = file(for: key), let read = try? Data(contentsOf: url) {
            data = read
        } else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let entry = try? decoder.decode(Entry<T>.self, from: data), entry.version == 2 else { return nil }
        let lifetime: TimeInterval = (entry.value == nil ? 7 : 30) * 86_400
        guard Date().timeIntervalSince(entry.fetchedAt) < lifetime else { return nil }
        memory[key] = data
        return .some(entry.value)
    }

    func set<T: Codable & Sendable>(_ key: String, value: T?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Entry(fetchedAt: Date(), value: value)) else { return }
        memory[key] = data
        guard let directory, let url = file(for: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        memory = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
