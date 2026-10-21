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
        statusTask = Task { [weak self, player] in
            for await status in player.publisher(for: \.timeControlStatus).values {
                self?.timeControlChanged(status)
            }
        }
    }

    func play(_ newStation: M3UParser.ParsedChannel) {
        station = newStation
        state = .loading
        let item = AVPlayerItem(url: newStation.streamURL)
        player.replaceCurrentItem(with: item)
        itemTask?.cancel()
        itemTask = Task { [weak self] in
            for await status in item.publisher(for: \.status).values where status == .failed {
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
