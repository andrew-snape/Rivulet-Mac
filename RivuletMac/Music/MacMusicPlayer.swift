// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Combine
import Foundation
import Observation

/// Music through AVQueuePlayer: the playing track plus the next one already
/// queued, so an album plays without gaps between tracks. AetherPlayer stays
/// video only; AVFoundation opens every common audio format itself.
///
/// The player knows nothing of the queue. `MacMusicPlayback` loads a track,
/// queues the next, and hears back when playback moved on, ended or failed.
@MainActor
@Observable
final class MacMusicPlayer {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        /// The last queued track finished.
        case ended
        case failed
    }

    private(set) var state: State = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// The queue entry audible now.
    private(set) var currentID: UUID?
    /// Bumped by every seek, so Now Playing can resync its clock.
    private(set) var seekCount = 0
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    /// Play was pressed (or a track started) and not paused since, loaded or not.
    private(set) var wantsToPlay = false

    /// The playing track finished and the queued one took over.
    @ObservationIgnored var onAdvance: ((UUID) -> Void)?
    /// A track could not be opened or stopped partway.
    @ObservationIgnored var onFailure: ((UUID) -> Void)?

    private struct Loaded {
        let item: AVPlayerItem
        let id: UUID
        let gain: Float
        let duration: TimeInterval
        var observations: [AnyCancellable]
    }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var loaded: [ObjectIdentifier: Loaded] = [:]
    @ObservationIgnored private var currentItem: ObjectIdentifier?
    @ObservationIgnored private var playerObservations: [AnyCancellable] = []
    @ObservationIgnored private var clock: Any?

    init() {
        player.actionAtItemEnd = .advance
        playerObservations = [
            Self.onMain(Self.currentItems(of: player)) { [weak self] in
                self?.currentItemChanged($0)
            },
            Self.onMain(Self.timeControlChanges(of: player)) { [weak self] _ in
                self?.updateState()
            },
            Self.onMain(Self.items(posting: AVPlayerItem.didPlayToEndTimeNotification)) { [weak self] in
                self?.itemEnded($0)
            },
            Self.onMain(Self.items(posting: AVPlayerItem.failedToPlayToEndTimeNotification)) { [weak self] in
                self?.itemFailed($0)
            },
        ]
        clock = Self.addClock(to: player) { [weak self] seconds in
            self?.clockTicked(seconds)
        }
    }

    // MARK: - Loading

    /// Replaces everything with `source`, starting at `time`.
    func load(_ source: MacMusicSource, gain: Float, at time: TimeInterval = 0, autoplay: Bool = true) {
        clear()
        let entry = makeItem(for: source, gain: gain)
        currentItem = ObjectIdentifier(entry.item)
        currentID = source.entryID
        duration = entry.duration
        currentTime = time
        player.insert(entry.item, after: nil)
        if time > 0 { seek(to: time) }
        applyVolume()
        wantsToPlay = autoplay
        state = .loading
        if autoplay { player.play() } else { player.pause() }
        updateState()
    }

    /// Shows `id` as loading while its URL is worked out.
    func prepare(_ id: UUID, duration: TimeInterval) {
        clear()
        currentID = id
        currentTime = 0
        self.duration = duration
        wantsToPlay = true
        state = .loading
    }

    /// Queues `source` to follow the current track, replacing what was queued.
    func setNext(_ source: MacMusicSource?, gain: Float) {
        for item in player.items() where ObjectIdentifier(item) != currentItem {
            player.remove(item)
            loaded[ObjectIdentifier(item)] = nil
        }
        guard let source, let current = player.currentItem else { return }
        let entry = makeItem(for: source, gain: gain)
        player.insert(entry.item, after: current)
    }

    /// The queued track's entry, if one is queued.
    var nextID: UUID? {
        player.items().dropFirst().first.flatMap { loaded[ObjectIdentifier($0)]?.id }
    }

    /// Stops and forgets every track.
    func stop() {
        clear()
        currentID = nil
        currentTime = 0
        duration = 0
        state = .idle
    }

    private func clear() {
        wantsToPlay = false
        player.pause()
        player.removeAllItems()
        loaded = [:]
        currentItem = nil
    }

    private func makeItem(for source: MacMusicSource, gain: Float) -> Loaded {
        let asset = AVURLAsset(url: source.url)
        // Same trust as the Plex API session: a raw-IP or private certificate plays.
        asset.resourceLoader.setDelegate(MacMusicTrust.shared, queue: MacMusicTrust.queue)
        let item = AVPlayerItem(asset: asset)
        let id = ObjectIdentifier(item)
        let entry = Loaded(
            item: item,
            id: source.entryID,
            gain: gain,
            duration: source.track.duration.map { TimeInterval($0) / 1000 } ?? 0,
            observations: [
                Self.onMain(Self.failures(of: item)) { [weak self] _ in
                    self?.itemFailed(id)
                },
                Self.onMain(Self.durations(of: item)) { [weak self] seconds in
                    guard let self, seconds.isFinite, seconds > 0, self.currentItem == id else { return }
                    self.duration = seconds
                },
            ]
        )
        loaded[id] = entry
        return entry
    }

    // MARK: - Transport

    func play() {
        wantsToPlay = true
        guard player.currentItem != nil else { return }
        player.play()
        updateState()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        updateState()
    }

    func togglePlayPause() {
        wantsToPlay ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        let target = max(0, duration > 0 ? min(time, duration) : time)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        seekCount += 1
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        applyVolume()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyVolume()
    }

    /// The user's volume times the playing track's levelling gain.
    private func applyVolume() {
        let gain = currentItem.flatMap { loaded[$0]?.gain } ?? 1
        player.volume = volume * gain
        player.isMuted = isMuted
    }

    // MARK: - Events

    private func currentItemChanged(_ id: ObjectIdentifier?) {
        guard let id, id != currentItem, let entry = loaded[id] else { return }
        // The queued track took over. The one just finished stays known until
        // the next change, since its end notice may still be on its way.
        let queued = Set(player.items().map(ObjectIdentifier.init))
        for key in loaded.keys where key != currentItem && !queued.contains(key) { loaded[key] = nil }
        currentItem = id
        currentID = entry.id
        duration = entry.duration
        currentTime = 0
        applyVolume()
        updateState()
        onAdvance?(entry.id)
    }

    /// With a track queued after it, the advance reports the end; without
    /// one, playback has run out.
    private func itemEnded(_ id: ObjectIdentifier) {
        guard id == currentItem, player.items().allSatisfy({ ObjectIdentifier($0) == id }) else { return }
        wantsToPlay = false
        currentTime = duration
        state = .ended
    }

    private func itemFailed(_ id: ObjectIdentifier) {
        guard let entry = loaded[id] else { return }
        if id == currentItem {
            wantsToPlay = false
            state = .failed
        }
        onFailure?(entry.id)
    }

    private func clockTicked(_ seconds: TimeInterval) {
        guard seconds.isFinite, currentItem != nil else { return }
        currentTime = max(0, seconds)
    }

    private func updateState() {
        guard currentItem != nil, state != .ended, state != .failed else { return }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .loading
        case .paused: state = wantsToPlay ? .loading : .paused
        @unknown default: break
        }
    }

    // MARK: - Observation plumbing

    // Nonisolated on purpose: AVFoundation calls these from its own threads,
    // and a closure built in a main-actor method would trap on that isolation check.

    private nonisolated static func onMain<P: Publisher>(
        _ publisher: P,
        _ handle: @escaping @MainActor @Sendable (P.Output) -> Void
    ) -> AnyCancellable where P.Failure == Never, P.Output: Sendable {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { value in MainActor.assumeIsolated { handle(value) } }
    }

    private nonisolated static func items(posting name: Notification.Name) -> AnyPublisher<ObjectIdentifier, Never> {
        NotificationCenter.default.publisher(for: name)
            .compactMap { ($0.object as? AVPlayerItem).map(ObjectIdentifier.init) }
            .eraseToAnyPublisher()
    }

    private nonisolated static func currentItems(of player: AVQueuePlayer) -> AnyPublisher<ObjectIdentifier?, Never> {
        player.publisher(for: \.currentItem).map { $0.map(ObjectIdentifier.init) }.eraseToAnyPublisher()
    }

    private nonisolated static func timeControlChanges(of player: AVPlayer) -> AnyPublisher<Int, Never> {
        player.publisher(for: \.timeControlStatus).map(\.rawValue).eraseToAnyPublisher()
    }

    private nonisolated static func failures(of item: AVPlayerItem) -> AnyPublisher<Int, Never> {
        item.publisher(for: \.status)
            .filter { $0 == .failed }
            .map(\.rawValue)
            .eraseToAnyPublisher()
    }

    private nonisolated static func durations(of item: AVPlayerItem) -> AnyPublisher<TimeInterval, Never> {
        item.publisher(for: \.duration).map(\.seconds).eraseToAnyPublisher()
    }

    private nonisolated static func addClock(
        to player: AVPlayer,
        _ handle: @escaping @MainActor @Sendable (TimeInterval) -> Void
    ) -> Any {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated { handle(seconds) }
        }
    }
}

/// Answers AVFoundation's certificate challenges with the Plex API session's rule.
nonisolated final class MacMusicTrust: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = MacMusicTrust()
    static let queue = DispatchQueue(label: "Rivulet.MusicTrust")

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        let space = authenticationChallenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              PlexCertificateDelegate.trustsUnverifiedCertificate(for: space) else { return false }
        authenticationChallenge.sender?.use(URLCredential(trust: trust), for: authenticationChallenge)
        return true
    }
}
