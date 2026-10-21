// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

@preconcurrency import AVFoundation
import Foundation
import Observation

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

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var itemTask: Task<Void, Never>?

    init() {
        // A live stream that waits to fill a buffer sits in "connecting" while the
        // sound already plays. Radio starts at once and stalls instead.
        player.automaticallyWaitsToMinimizeStalling = false
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
        let item = AVPlayerItem(url: newStation.streamURL)
        player.replaceCurrentItem(with: item)
        itemTask?.cancel()
        itemTask = Task { [weak self] in
            for await status in Self.changes(of: item, \.status) where status == .failed {
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
        station = nil
        state = .idle
    }

    /// A key-value-observed property as an async sequence, starting with its current value.
    private nonisolated static func changes<Root: NSObject, Value: Sendable>(
        of object: Root, _ keyPath: KeyPath<Root, Value>
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let observation = object.observe(keyPath, options: [.initial, .new]) { _, change in
                if let value = change.newValue { continuation.yield(value) }
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
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
