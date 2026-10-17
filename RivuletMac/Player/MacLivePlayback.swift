// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// The channel on screen. One for the app's lifetime: picking another
/// channel switches it in place, as the iOS and tvOS players do.
@MainActor
final class MacLivePlayback: ObservableObject {
    let player = AetherPlayer()
    @Published private(set) var channel: UnifiedChannel?
    /// Shown instead of the engine's failure: a refused tune or a busy tuner.
    @Published private(set) var notice: String?

    /// The channels the window lists right now, in order: what Channel Up and
    /// Channel Down step through. Set by the window.
    var lineup: [UnifiedChannel] = []

    private let store = LiveTVDataStore.shared
    private let keepalive = PlexLiveTimelineKeepalive()
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    var programme: UnifiedProgram? { channel.flatMap(store.getCurrentProgram(for:)) }

    func play(_ newChannel: UnifiedChannel) {
        guard newChannel.id != channel?.id || player.state == .idle else { return }
        channel = newChannel
        tune(after: .milliseconds(250))
    }

    /// The next or previous channel in the lineup, wrapping at the ends.
    func step(by offset: Int) {
        guard !lineup.isEmpty else { return }
        guard let current = channel, let index = lineup.firstIndex(where: { $0.id == current.id }) else {
            play(lineup[0])
            return
        }
        let next = (index + offset + lineup.count) % lineup.count
        play(lineup[next])
    }

    func retry() {
        tune(after: .zero)
    }

    /// Arrow keys in the channel list switch channel on every press. The
    /// short wait means only the channel the viewer stops on is tuned, rather
    /// than every one passed on the way (each tune can claim a tuner).
    private func tune(after delay: Duration) {
        loadTask?.cancel()
        loadTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
    }

    /// The task ends once Plex has released a tuned channel's tuner.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        loadTask?.cancel()
        watchTask?.cancel()
        let released = keepalive.stop()
        player.stop()
        channel = nil
        notice = nil
        return released
    }

    private func load() async {
        guard let channel else { return }
        notice = nil
        keepalive.stop()
        watchTask?.cancel()
        watchTask = store.beganWatching(channel)

        let url: URL
        do {
            guard let resolved = try await store.resolveStreamURL(for: channel) else {
                notice = "This channel has no stream."
                return
            }
            url = resolved
        } catch {
            guard !isCancellationError(error) else { return }
            notice = error is PlexLiveTuneError
                ? "Couldn't tune this channel. All tuners may be busy."
                : "Couldn't tune this channel."
            return
        }
        // A tune that finished after a switch still holds the tuner.
        guard !Task.isCancelled else { PlexLiveTimelineKeepalive.release(url); return }

        // A no-op unless the URL is a Plex tuned session.
        keepalive.start(url: url)
        let headers = LiveTVClientIdentity.streamHeaders(for: channel)
        do {
            try await player.loadLive(url: url, headers: headers,
                                      forceEngineDemux: url.path.hasPrefix("/livetv/sessions/"))
        } catch {
            guard !Task.isCancelled, !isCancellationError(error) else { return }
            keepalive.stop()
            if channel.sourceType != .plex, await LiveTunerBusy.sourceIsBusy(url, headers: headers) {
                notice = "All tuners are busy. Stop another stream and try again."
            }
        }
    }
}
