// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Names a track's file on disk: what it is, never where it came from, so no
/// address or token is ever in a file name.
nonisolated struct MacMusicCacheKey: Hashable, Sendable {
    let ratingKey: String
    let partID: Int
    let size: Int
    let fileExtension: String

    var fileName: String { "\(ratingKey)-\(partID)-\(size).\(fileExtension)" }

    /// Nil unless the first part has an id, a size and a container AVFoundation opens from a file.
    init?(ratingKey: String, media: PlexMedia?) {
        guard let part = media?.Part?.first, let size = part.size, size > 0,
              let ext = Self.fileExtension(container: media?.container ?? part.container) else { return nil }
        self.ratingKey = ratingKey
        partID = part.id
        self.size = size
        fileExtension = ext
    }

    static func fileExtension(container: String?) -> String? {
        switch (container ?? "").lowercased() {
        case "mp3": "mp3"
        case "mp4", "m4a": "m4a"
        case "flac": "flac"
        case "wav": "wav"
        case "aiff", "aif": "aiff"
        case "aac": "aac"
        case "caf": "caf"
        default: nil
        }
    }
}

/// Whole songs kept on disk, so they start at once and survive a slow
/// connection. Least recently used go first when over the limit.
actor MacMusicCache {
    static let shared = MacMusicCache()
    static let limitKey = "musicCacheLimitMB"
    static let limitDefault = 1024
    static let limitChoices = [0, 500, 1024, 2048, 5120, 10240, 20480, 51200, 102400]
    /// A download in flight or just finished, before it is stored.
    nonisolated static let partialExtension = "part"

    /// The limit in bytes; 0 keeps nothing.
    nonisolated static var limitBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: limitKey) as? Int ?? limitDefault
        let mb = limitChoices.contains(stored) ? stored : limitDefault
        return Int64(mb) * 1_048_576
    }

    nonisolated static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MusicFiles", isDirectory: true)
    }

    private var pinned: Set<String> = []

    /// The kept file, marked as just used.
    func file(for key: MacMusicCacheKey) -> URL? {
        guard let url = Self.directory?.appendingPathComponent(key.fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Moves a finished download into place.
    func store(_ downloaded: URL, for key: MacMusicCacheKey) throws -> URL {
        guard let directory = Self.directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: downloaded)
        } else {
            try FileManager.default.moveItem(at: downloaded, to: url)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        trim()
        return url
    }

    func remove(_ key: MacMusicCacheKey) {
        guard let url = Self.directory?.appendingPathComponent(key.fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// File names that must stay: the playing track and the ones about to be.
    func pin(_ names: Set<String>) {
        pinned = names
        trim()
    }

    /// Removes the oldest unpinned files until within the limit.
    func trim() {
        let limit = Self.limitBytes
        var files = kept().filter { !pinned.contains($0.url.lastPathComponent) }
        var total = kept().reduce(Int64(0)) { $0 + $1.size }
        files.sort { $0.date < $1.date }
        for file in files where total > limit {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    func size() -> Int64 {
        kept().reduce(Int64(0)) { $0 + $1.size }
    }

    func clear() {
        for file in kept() where !pinned.contains(file.url.lastPathComponent) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// Downloads that never finished, from a run that quit mid-way.
    func purgeLeftovers() {
        guard let directory = Self.directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == Self.partialExtension {
            try? FileManager.default.removeItem(at: url)
        }
        trim()
    }

    private func kept() -> [(url: URL, size: Int64, date: Date)] {
        guard let directory = Self.directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension != Self.partialExtension,
                  let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey])
            else { return nil }
            return (url, Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
