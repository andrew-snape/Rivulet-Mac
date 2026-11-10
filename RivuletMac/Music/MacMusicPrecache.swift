// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import OSLog

/// Downloads the songs about to play, one at a time, into the music cache.
/// Nothing is fetched on a metered connection, in Low Data Mode, away from
/// home or over a relay.
@MainActor
final class MacMusicPrecache {
    static let countKey = "musicPrecacheCount"
    static let countDefault = 1
    static let countChoices = [0, 1, 3, 5]

    static var count: Int {
        let stored = UserDefaults.standard.object(forKey: countKey) as? Int ?? countDefault
        return countChoices.contains(stored) ? stored : countDefault
    }

    private static let log = Logger(subsystem: "com.rivulet.app", category: "Music")

    weak var plex: MacPlexSession?
    /// A song finished downloading: its queue entry and the file.
    var onCached: ((UUID, URL) -> Void)?

    private var window: [(id: UUID, track: PlexMetadata)] = []
    private var currentSource: MacMusicSource?
    private var jobs: [(id: UUID, track: PlexMetadata)] = []
    private var keys: [UUID: MacMusicCacheKey] = [:]
    private var done = Set<UUID>()
    private var failed = Set<UUID>()
    private var worker: Task<Void, Never>?
    private var workingOn: UUID?

    /// Bumped for each worker, so a worker that has been replaced or stopped
    /// never clears the reference to its successor when it finally exits.
    private var generation = 0
    private var canDownloadNow = false

    func update(current: MacMusicSource?, upcoming: [MusicQueue.Entry], canDownload: Bool) {
        canDownloadNow = canDownload
        window = upcoming.map { ($0.id, $0.track) }
        currentSource = current
        let ids = Set(window.map(\.id))
        done.formIntersection(ids)
        failed.formIntersection(ids)
        keys = keys.filter { ids.contains($0.key) }

        jobs = []
        if downloadsAllowed {
            jobs = window
            if let current, MacMusicCache.limitBytes > 0, current.cacheKey != nil, !current.isCached,
               StreamingQuality.isHome(serverURL: current.serverURL) {
                jobs.insert((current.entryID, current.track), at: 0)
            }
        }
        pinFiles()

        if let workingOn, !canDownload || !jobs.contains(where: { $0.id == workingOn }) {
            worker?.cancel()
        }
        // A cancelled worker is still non-nil here, so a replacement is started
        // by `run()` itself once it has wound down (see its `defer`).
        if canDownload, worker == nil, nextJob() != nil {
            startWorker()
        }
    }

    private func startWorker() {
        generation += 1
        let mine = generation
        worker = Task { await run(generation: mine) }
    }

    /// Cancels the download and forgets everything; nothing stays pinned.
    func stop() {
        worker?.cancel()
        worker = nil
        workingOn = nil
        generation += 1
        canDownloadNow = false
        window = []
        jobs = []
        currentSource = nil
        keys = [:]
        done = []
        failed = []
        Task { await MacMusicCache.shared.pin([]) }
    }

    private var downloadsAllowed: Bool {
        guard Self.count > 0, MacMusicCache.limitBytes > 0 else { return false }
        if NetworkPathMonitor.shared.isAwayPath { return false }
        guard let server = plex?.auth.selectedServerURL, !PlexRelay.isRelayURL(server) else { return false }
        return true
    }

    private func nextJob() -> (id: UUID, track: PlexMetadata)? {
        jobs.first { !done.contains($0.id) && !failed.contains($0.id) }
    }

    private func pinFiles() {
        var names = Set(keys.values.map(\.fileName))
        if let name = currentSource?.cacheKey?.fileName { names.insert(name) }
        Task { await MacMusicCache.shared.pin(names) }
    }

    private func run(generation mine: Int) async {
        defer {
            // Only the current worker clears the state. If it was cancelled
            // because its job left the window, start the replacement now,
            // since `update` could not while this task was still registered.
            if generation == mine {
                let wasCancelled = Task.isCancelled
                worker = nil
                workingOn = nil
                if wasCancelled, canDownloadNow, nextJob() != nil {
                    startWorker()
                }
            }
        }
        while !Task.isCancelled, let job = nextJob() {
            workingOn = job.id
            do {
                let source: MacMusicSource
                if let currentSource, currentSource.entryID == job.id {
                    source = currentSource
                } else if let plex {
                    source = try await plex.musicSource(for: job.id, track: job.track)
                } else {
                    return
                }
                guard let key = source.cacheKey, !source.isCached else {
                    done.insert(job.id)
                    continue
                }
                keys[job.id] = key
                pinFiles()
                let temp = try await MacMusicDownload.fetch(source.url, expectedSize: key.size)
                let file = try await MacMusicCache.shared.store(temp, for: key)
                done.insert(job.id)
                onCached?(job.id, file)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                failed.insert(job.id)
                Self.log.error("Download failed, code \(Self.code(of: error))")
            }
        }
    }

    private static func code(of error: Error) -> Int {
        if let url = error as? URLError { return url.code.rawValue }
        if let download = error as? MacMusicDownload.Failure, case .status(let status) = download { return status }
        return 0
    }
}

/// One whole file from the Plex server, to disk.
nonisolated enum MacMusicDownload {
    enum Failure: Error {
        case status(Int)
        case size
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: configuration, delegate: PlexCertificateDelegate(), delegateQueue: nil)
    }()

    /// The downloaded file, moved to a `.part` file in the cache folder. Cancelling the task cancels the transfer.
    static func fetch(_ url: URL, expectedSize: Int) async throws -> URL {
        let (temp, response) = try await session.download(for: URLRequest(url: url))
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure.status((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard size == expectedSize, let directory = MacMusicCache.directory else { throw Failure.size }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let part = directory.appendingPathComponent("\(UUID().uuidString).\(MacMusicCache.partialExtension)")
            try FileManager.default.moveItem(at: temp, to: part)
            return part
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
