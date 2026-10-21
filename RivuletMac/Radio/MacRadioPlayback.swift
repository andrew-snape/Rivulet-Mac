// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

@preconcurrency import AVFoundation
import Foundation
import Observation
import os

/// Station names and player states only, never the stream URL.
private let radioLog = Logger(subsystem: "com.rivulet.app", category: "Radio")

/// The radio station playing. Radio is sound only, so it plays through AVPlayer
/// with no picture surface. One station at a time, and it keeps playing when
/// the page changes.
@MainActor
@Observable
final class MacRadioPlayback {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var station: M3UParser.ParsedChannel?
    private(set) var state: State = .idle
    /// What the station says is on, from its stream's metadata (ICY on
    /// Shoutcast and Icecast, ID3 in HLS). Nil when it sends none.
    private(set) var streamTitle: String?

    @ObservationIgnored private let player = AVPlayer()

    /// For the AirPlay button, which sends the station to a speaker or Apple TV.
    var routingPlayer: AVPlayer { player }
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var itemTask: Task<Void, Never>?
    @ObservationIgnored private var metadataReader: RadioMetadataReader?

    init() {
        statusTask = Task { [weak self, player] in
            for await status in Self.changes(of: player, \.timeControlStatus) {
                self?.timeControlChanged(status)
            }
        }
    }

    func play(_ newStation: M3UParser.ParsedChannel) {
        // One stream at a time: a station pauses music.
        MacAppDelegate.music?.pause()
        station = newStation
        state = .loading
        radioLog.notice("Play \(newStation.name, privacy: .public)")
        let item = AVPlayerItem(url: newStation.streamURL)
        streamTitle = nil
        let reader = RadioMetadataReader { [weak self, weak item] title in
            // A late title from the station before is dropped.
            guard let self, let item, self.player.currentItem === item else { return }
            self.streamTitle = title
        }
        item.add(reader.output)
        metadataReader = reader
        player.replaceCurrentItem(with: item)
        itemTask?.cancel()
        itemTask = Task { [weak self] in
            for await status in Self.changes(of: item, \.status) {
                let name = Self.name(of: status)
                // Domain and code only: an error's description can carry the URL.
                let error = (item.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "none"
                radioLog.notice("Item \(name, privacy: .public), error: \(error, privacy: .public)")
                guard status == .failed else { continue }
                self?.state = .failed("This station couldn't be played.")
                return
            }
        }
        player.play()
    }

    func togglePlayPause() {
        switch state {
        case .playing, .loading:
            player.pause()
        case .paused:
            state = .loading
            player.play()
        case .failed:
            if let station { play(station) }
        case .idle:
            break
        }
    }

    func stop() {
        itemTask?.cancel()
        player.replaceCurrentItem(with: nil)
        metadataReader = nil
        station = nil
        streamTitle = nil
        state = .idle
    }

    /// A key-value-observed property as an async sequence, starting with its current value.
    /// Read off the object: KVO's `newValue` is nil for enum properties such as
    /// `timeControlStatus`, so the station never left "Connecting".
    private nonisolated static func changes<Root: NSObject, Value: Sendable>(
        of object: Root, _ keyPath: KeyPath<Root, Value> & Sendable
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let observation = object.observe(keyPath, options: [.initial, .new]) { object, _ in
                continuation.yield(object[keyPath: keyPath])
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
    }

    private static func name(of status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    private static func name(of status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        let name = Self.name(of: status)
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        let rate = player.rate
        radioLog.notice("Player \(name, privacy: .public), waiting: \(reason, privacy: .public), rate: \(rate, privacy: .public)")
        // A failed station stays failed until it is played again.
        if case .failed = state { return }
        switch status {
        case .playing:
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            state = .loading
        case .paused:
            state = station == nil ? .idle : .paused
        @unknown default:
            break
        }
    }
}

/// Hands on the song title a station sends with its sound. Shoutcast and
/// Icecast send "Artist - Title" as one ICY StreamTitle; HLS sends ID3 title
/// and artist apart, joined here the same way. Blank titles are ignored.
private final class RadioMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    let output = AVPlayerItemMetadataOutput(identifiers: nil)
    private let onTitle: (String) -> Void

    init(onTitle: @escaping (String) -> Void) {
        self.onTitle = onTitle
        super.init()
        output.setDelegate(self, queue: .main)
    }

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                                    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        let items = groups.flatMap(\.items)
        // The delegate queue is the main queue.
        MainActor.assumeIsolated {
            Task { await self.read(items) }
        }
    }

    private func read(_ items: [AVMetadataItem]) async {
        var streamTitle: String?
        var title: String?
        var artist: String?
        for item in items {
            guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            if item.identifier == .icyMetadataStreamTitle {
                streamTitle = value
            } else if item.commonKey == .commonKeyTitle {
                title = value
            } else if item.commonKey == .commonKeyArtist {
                artist = value
            }
        }
        let joined = title.map { title in artist.map { "\($0) - \(title)" } ?? title }
        guard let text = streamTitle ?? joined else { return }
        onTitle(text)
    }
}
