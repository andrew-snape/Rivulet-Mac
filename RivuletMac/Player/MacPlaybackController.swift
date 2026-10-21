// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
@preconcurrency import MediaPlayer
import Observation
import SwiftUI

/// App-level owner of the Plex item playing, shown over the whole window.
/// Starting one stops Live TV (`onStart`), so only one stream plays at a time.
@MainActor
@Observable
final class MacPlaybackController {
    private static let nowPlayingUpdateInterval: TimeInterval = 5
    private static let remoteSkipBackwardInterval: TimeInterval = 10
    private static let remoteSkipForwardInterval: TimeInterval = 30

    private(set) var session: MacPlexPlayback?
    private(set) var isAlwaysOnTop = false

    /// Needed to build sessions; the root view sets it.
    @ObservationIgnored weak var plex: MacPlexSession?
    @ObservationIgnored var onStart: (() -> Void)?

    @ObservationIgnored private var stateObservation: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingObservations: [Task<Void, Never>] = []
    @ObservationIgnored private let sleepGuard = MacSleepGuard()
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var liveObservation: Task<Void, Never>?
    @ObservationIgnored private var videoShapeObservation: Task<Void, Never>?
    @ObservationIgnored private var hasConfiguredRemoteCommands = false
    /// The last title's volume and mute; the next title starts on them.
    @ObservationIgnored private var volume: Float = 1
    @ObservationIgnored private var isMuted = false

    func play(_ request: MacPlexPlaybackRequest) {
        guard let plex else { return }
        end()
        let newSession = MacPlexPlayback(request: request, plex: plex)
        newSession.player.setVolume(volume)
        newSession.player.setMuted(isMuted)
        session = newSession
        lockAspectRatio(true)
        onStart?()
        // Keep the display awake while something plays, as a video player should.
        let player = newSession.player
        stateObservation = Task { [weak self] in
            for await playing in Observations({ player.state == .playing }) {
                self?.sleepGuard.setAwake(playing)
            }
        }
        videoShapeObservation = Task { [weak self] in
            for await size in Observations({ player.videoSize }) {
                self?.fitWindow(toVideo: size)
            }
        }
        observeNowPlaying(for: newSession)
        updateRemoteCommandAvailability(for: newSession)
        Task { await newSession.begin() }
    }

    /// Once the picture's shape is known the window takes it, so a scope film
    /// has no black bars to shrink past. Width stays; the height follows.
    private func fitWindow(toVideo size: CGSize) {
        guard size.width > 0, size.height > 0,
              let window = MacAppDelegate.mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = size
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let height = (content.width * size.height / size.width).rounded()
        frame.origin.y += content.height - height
        frame.size.height += height - content.height
        window.setFrame(frame, display: true, animate: true)
    }

    /// Ends playback and leaves the player. The task ends once Plex has the final report.
    @discardableResult
    func close() -> Task<Void, Never>? {
        end()
    }

    @discardableResult
    private func end() -> Task<Void, Never>? {
        guard let session else { return nil }
        volume = session.player.volume
        isMuted = session.player.isMuted
        let reported = session.end()
        session.player.stop()
        stateObservation?.cancel()
        stateObservation = nil
        cancelNowPlayingObservations()
        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .stopped
        setAlwaysOnTop(false)
        lockAspectRatio(false)
        updateRemoteCommandAvailability(for: nil)
        sleepGuard.setAwake(false)
        nowPlayingArtwork = nil
        self.session = nil
        return reported
    }

    /// Pinning is a per-session choice and resets when playback ends.
    func setAlwaysOnTop(_ enabled: Bool) {
        isAlwaysOnTop = enabled
        MacAppDelegate.mainWindow?.level = windowLevel
    }

    /// The window keeps the picture's 16:9 shape while a title plays. Setting
    /// resize increments back to 1 is how AppKit clears an aspect ratio.
    private func lockAspectRatio(_ locked: Bool) {
        guard let window = MacAppDelegate.mainWindow else { return }
        if locked {
            window.contentAspectRatio = NSSize(width: 16, height: 9)
        } else {
            videoShapeObservation?.cancel()
            videoShapeObservation = nil
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    func applyWindowLevel(to window: NSWindow) {
        window.level = windowLevel
    }

    private var windowLevel: NSWindow.Level {
        isAlwaysOnTop ? .floating : .normal
    }

    func configureRemoteCommands() {
        guard !hasConfiguredRemoteCommands else { return }
        hasConfiguredRemoteCommands = true
        // This controller is an app-lifetime State, so the shared command
        // center receives one set of handlers for the lifetime of the app.
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Self.dispatchRemoteCommand { self?.remotePlay() ?? .commandFailed }
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Self.dispatchRemoteCommand { self?.remotePause() ?? .commandFailed }
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.dispatchRemoteCommand { self?.remoteToggle() ?? .commandFailed }
        }
        commands.stopCommand.addTarget { [weak self] _ in
            Self.dispatchRemoteCommand { self?.remoteStop() ?? .commandFailed }
        }

        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.remoteSkipBackwardInterval)]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite else {
                return .commandFailed
            }
            let interval = abs(event.interval)
            return Self.dispatchRemoteCommand {
                self?.remoteSkip(by: -interval) ?? .commandFailed
            }
        }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.remoteSkipForwardInterval)]
        commands.skipForwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite else {
                return .commandFailed
            }
            let interval = abs(event.interval)
            return Self.dispatchRemoteCommand {
                self?.remoteSkip(by: interval) ?? .commandFailed
            }
        }

        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent,
                  position.positionTime.isFinite else { return .commandFailed }
            let positionTime = position.positionTime
            return Self.dispatchRemoteCommand {
                guard let self,
                      let player = self.session?.player else { return .commandFailed }
                let target = player.duration > 0
                    ? min(max(positionTime, 0), player.duration)
                    : max(positionTime, 0)
                Task { await player.seek(to: target) }
                return .success
            }
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Self.dispatchRemoteCommand { self?.remoteNext() ?? .commandFailed }
        }
        updateRemoteCommandAvailability(for: nil)
        observeLive()
    }

    /// The channel on screen: Now Playing and the media keys follow it while no Plex title is up.
    private var live: MacLivePlayback? {
        MacAppDelegate.playback.flatMap { $0.channel == nil ? nil : $0 }
    }

    /// The player in front: the Plex title, else the channel.
    private var activePlayer: AetherPlayer? {
        session?.player ?? live?.player
    }

    private func observeLive() {
        guard let playback = MacAppDelegate.playback else { return }
        liveObservation = Task { [weak self] in
            for await _ in Observations({
                _ = (playback.channel?.id, playback.player.state, playback.programme?.title)
            }) {
                guard let self, self.session == nil else { continue }
                self.updateLiveNowPlaying()
                self.updateRemoteCommandAvailability(for: nil)
            }
        }
    }

    private func updateLiveNowPlaying() {
        let nowPlaying = MPNowPlayingInfoCenter.default()
        guard let playback = live else {
            nowPlaying.nowPlayingInfo = nil
            nowPlaying.playbackState = .stopped
            return
        }
        let channel = playback.channel
        nowPlaying.nowPlayingInfo = [
            MPMediaItemPropertyTitle: playback.programme?.displayTitle ?? channel?.name ?? "",
            MPMediaItemPropertyArtist: channel?.numberAndName ?? "",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playback.player.state == .playing ? 1.0 : 0.0
        ]
        switch playback.player.state {
        case .playing: nowPlaying.playbackState = .playing
        case .ended, .failed, .idle: nowPlaying.playbackState = .stopped
        case .loading, .paused: nowPlaying.playbackState = .paused
        }
    }

    private nonisolated static func dispatchRemoteCommand(
        _ action: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
    ) -> MPRemoteCommandHandlerStatus {
        // Preserve the handler result on the main-thread path; queue unexpected off-main callbacks.
        if Thread.isMainThread {
            return MainActor.assumeIsolated(action)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = action()
            }
        }
        return .success
    }

    private func cancelNowPlayingObservations() {
        nowPlayingObservations.forEach { $0.cancel() }
        nowPlayingObservations.removeAll()
    }

    private func observeNowPlaying(for session: MacPlexPlayback) {
        cancelNowPlayingObservations()
        let player = session.player
        // Anything but the clock: transport, seek, length, speed, and the item itself.
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({
                _ = (player.state, player.pendingSeekTarget, player.duration, player.rate, session.request.item.ratingKey)
            }) {
                self?.updateNowPlaying()
            }
        })
        // Now Playing interpolates elapsed time from the playback rate between updates.
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({ _ = player.currentTime }) {
                self?.updateNowPlaying()
                try? await Task.sleep(for: .seconds(Self.nowPlayingUpdateInterval))
            }
        })
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({ session.nextEpisode?.ratingKey }) {
                guard let self else { return }
                self.updateRemoteCommandAvailability(for: self.session)
            }
        })
        // The poster follows the item, so Up Next swaps it too.
        nowPlayingObservations.append(Task { [weak self] in
            for await _ in Observations({ session.request.item.ratingKey }) {
                guard let self else { return }
                self.nowPlayingArtwork = nil
                self.updateNowPlaying()
                self.nowPlayingArtwork = await self.loadArtwork(for: session.request.item)
                self.updateNowPlaying()
            }
        })
        updateNowPlaying()
    }

    private func loadArtwork(for item: PlexMetadata) async -> MPMediaItemArtwork? {
        guard let url = plex?.artworkURL(for: item, kind: .poster, width: 600, height: 900),
              let image = await MacArtworkCache.shared.image(for: url),
              !Task.isCancelled else { return nil }
        return Self.artwork(from: image)
    }

    /// Nonisolated on purpose: MediaPlayer calls the handler on its own queue, and a
    /// closure built in a main-actor method would trap on that isolation check.
    private nonisolated static func artwork(from image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard let session else { return }
        let item = session.request.item
        let player = session.player
        let nowPlaying = MPNowPlayingInfoCenter.default()
        let elapsed = player.pendingSeekTarget ?? player.currentTime
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: item.displayTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? player.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: player.rate
        ]
        let duration = player.duration > 0 ? player.duration : item.durationSeconds
        if duration.isFinite, duration > 0 {
            information[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if item.type == "episode" {
            information[MPMediaItemPropertyAlbumTitle] = item.showTitle
        }
        if let nowPlayingArtwork {
            information[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        nowPlaying.nowPlayingInfo = information
        switch player.state {
        case .playing:
            nowPlaying.playbackState = .playing
        case .ended, .failed, .idle:
            nowPlaying.playbackState = .stopped
        case .loading, .paused:
            nowPlaying.playbackState = .paused
        }
    }

    private func updateRemoteCommandAvailability(for session: MacPlexPlayback?) {
        let commands = MPRemoteCommandCenter.shared()
        // A channel can pause and stop but has no length to skip or seek in.
        let available = session != nil
        let playing = available || live != nil
        commands.playCommand.isEnabled = playing
        commands.pauseCommand.isEnabled = playing
        commands.togglePlayPauseCommand.isEnabled = playing
        commands.stopCommand.isEnabled = playing
        commands.skipBackwardCommand.isEnabled = available
        commands.skipForwardCommand.isEnabled = available
        commands.changePlaybackPositionCommand.isEnabled = available
        commands.nextTrackCommand.isEnabled = session?.nextEpisode != nil
    }

    private func remotePlay() -> MPRemoteCommandHandlerStatus {
        guard let player = activePlayer else { return .commandFailed }
        switch player.state {
        case .playing:
            return .success
        case .paused:
            player.togglePlayPause()
            return .success
        default:
            return .commandFailed
        }
    }

    private func remotePause() -> MPRemoteCommandHandlerStatus {
        guard let player = activePlayer else { return .commandFailed }
        if player.state == .playing { player.togglePlayPause() }
        return .success
    }

    private func remoteToggle() -> MPRemoteCommandHandlerStatus {
        guard let player = activePlayer else { return .commandFailed }
        player.togglePlayPause()
        return .success
    }

    private func remoteStop() -> MPRemoteCommandHandlerStatus {
        if session != nil {
            close()
        } else if let live {
            live.stop()
        } else {
            return .commandFailed
        }
        return .success
    }

    private func remoteSkip(by seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard let player = session?.player else { return .commandFailed }
        Task { await player.skip(by: seconds) }
        return .success
    }

    private func remoteNext() -> MPRemoteCommandHandlerStatus {
        guard let session, session.nextEpisode != nil else { return .commandFailed }
        session.playNext()
        return .success
    }
}

// MARK: - Player

/// A Plex title over the whole window: the video, captions, and controls that
/// show while the pointer moves.
struct MacVODPlayerView: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    let close: () -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?

    var body: some View {
        ZStack {
            // The picture fills the window, title bar included.
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    player.surface
                    MacCaptionOverlay(player: player, container: proxy.size)
                        .allowsHitTesting(false)
                    // Clicks on the picture, under the controls: double for full screen, single for play/pause.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
                        .onTapGesture { player.togglePlayPause() }
                }
            }
            .ignoresSafeArea()
            // The rest keeps below the title bar, whose window buttons would take the close
            // button's clicks, and above the click layer, so the failure's buttons take clicks.
            status
            VStack(spacing: 0) {
                topBar
                    .opacity(chromeVisible ? 1 : 0)
                Spacer()
                // Skip and Up Next stay up with the controls hidden, so they can be clicked at once.
                HStack(alignment: .bottom) {
                    Spacer()
                    contextualButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                if session.pane != nil {
                    MacPlayerPaneCard(
                        session: session, player: player, detail: session.detail,
                        chapters: session.chapters,
                        pane: Binding(get: { session.pane }, set: { session.pane = $0 })
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .opacity(chromeVisible ? 1 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .opacity(chromeVisible ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.25), value: controlsVisible)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls()
            case .ended: scheduleHide(after: .seconds(1))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { scheduleHide(after: .seconds(3)) }
        .task(id: session.request.item.ratingKey) { await session.loadDetail() }
        .animation(.easeOut(duration: 0.2), value: session.pane)
        // A slow start or a resume from the keyboard leaves the pointer still, so fade from here too.
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide(after: .seconds(3)) }
        }
    }

    private var chromeVisible: Bool { controlsVisible || player.state != .playing || session.pane != nil }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if case .failed(let message) = player.state {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    if player.canRetry { Button("Try Again", action: session.retry) }
                    Button("Close", action: close)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        } else if player.state == .idle || player.state == .loading || player.isBuffering
                    || (player.isStarting && player.state == .playing) {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        let item = session.request.item
        return HStack(alignment: .top, spacing: 14) {
            Button(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                    .font(.title3.weight(.semibold))
                if item.type == "episode" {
                    Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
            Spacer()
        }
        .padding(20)
        .foregroundStyle(.white)
    }

    // MARK: Contextual action

    @ViewBuilder
    private var contextualButton: some View {
        if let next = session.nextEpisode,
           session.upNextCountdown != nil || (!session.upNextDismissed && session.isNearEnd) {
            MacUpNextCard(session: session, next: next)
        } else if let marker = session.activeMarker {
            Button { session.skip(marker) } label: {
                Label("Skip \(marker.displayName)", systemImage: marker.isCommunity ? "person.3.fill" : "forward.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Controls

    private var duration: Double {
        player.duration > 0 ? player.duration : session.request.item.durationSeconds
    }

    private var position: Double { player.pendingSeekTarget ?? player.currentTime }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(Self.format(scrubbing ?? position))
                    .monospacedDigit()
                Slider(
                    value: Binding(get: { min(scrubbing ?? position, max(duration, 1)) },
                                   set: { scrubbing = $0 }),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubbing else { return }
                        scrubbing = nil
                        Task { await player.seek(to: target) }
                    }
                )
                .controlSize(.small)
                Text("-" + Self.format(max(0, duration - (scrubbing ?? position))))
                    .monospacedDigit()
            }
            .font(.caption)

            // A shrunken window drops the volume slider first, then folds the panes into one menu.
            ViewThatFits(in: .horizontal) {
                buttonRow(spacing: 16, volumeSlider: true, foldPanes: false)
                buttonRow(spacing: 12, volumeSlider: false, foldPanes: false)
                buttonRow(spacing: 10, volumeSlider: false, foldPanes: true)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 980)
    }

    private var visiblePanes: [MacPlayerPane] {
        MacPlayerPane.allCases.filter { $0 != .chapters || !session.chapters.isEmpty }
    }

    private func buttonRow(spacing: CGFloat, volumeSlider: Bool, foldPanes: Bool) -> some View {
        HStack(spacing: spacing) {
                Button { Task { await player.skip(by: -10) } } label: { Image(systemName: "gobackward.10") }
                    .help("Back 10 Seconds (←)")
                Button(action: player.togglePlayPause) {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 26)
                }
                .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
                Button { Task { await player.skip(by: 30) } } label: { Image(systemName: "goforward.30") }
                    .help("Forward 30 Seconds (→)")
                if session.nextEpisode != nil {
                    Button { session.playNext() } label: { Image(systemName: "forward.end.fill") }
                        .help("Next Episode")
                }

                Spacer()

                trackMenus
                qualityMenu
                speedMenu

                if foldPanes {
                    Menu {
                        ForEach(visiblePanes) { pane in
                            Toggle(pane.rawValue, isOn: Binding(get: { session.pane == pane },
                                                                set: { session.pane = $0 ? pane : nil }))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Info")
                } else {
                    ForEach(visiblePanes) { pane in
                        Button { session.pane = session.pane == pane ? nil : pane } label: {
                            Image(systemName: pane.icon)
                                .foregroundStyle(session.pane == pane ? Color.accentColor : .primary)
                        }
                        .help(pane.rawValue)
                    }
                }

                Button { player.setMuted(!player.isMuted) } label: {
                    Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .help(player.isMuted ? "Unmute" : "Mute")
                if volumeSlider {
                    Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                          set: { player.setVolume(Float($0)) }),
                           in: 0...1)
                        .frame(width: 90)
                        .controlSize(.small)
                }

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen")
        }
        .font(.title3)
    }

    @ViewBuilder
    private var trackMenus: some View {
        if session.audioTracks.count > 1 {
            Menu {
                ForEach(session.audioTracks) { track in
                    Toggle(isOn: Binding(get: { session.selectedAudioID == track.id },
                                         set: { if $0 { session.selectAudio(track.id) } })) {
                        Text(track.name)
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            } label: {
                Image(systemName: "speaker.wave.2.bubble")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio")
        }

        if !session.subtitleTracks.isEmpty {
            Menu {
                Toggle("Off", isOn: Binding(get: { session.selectedSubtitleID == nil },
                                            set: { if $0 { session.selectSubtitle(nil) } }))
                Divider()
                ForEach(session.subtitleTracks) { track in
                    Toggle(isOn: Binding(get: { session.selectedSubtitleID == track.id },
                                         set: { if $0 { session.selectSubtitle(track.id) } })) {
                        Text(track.name)
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            } label: {
                Image(systemName: session.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles")
        }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(StreamingQuality.allChoices, id: \.self) { quality in
                Toggle(quality.label, isOn: Binding(get: { session.request.quality == quality },
                                                    set: { if $0 { session.switchQuality(quality) } }))
            }
        } label: {
            Text(session.qualityLabel).font(.caption.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quality")
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                Toggle(Self.speedLabel(speed), isOn: Binding(get: { player.rate == speed },
                                                             set: { if $0 { player.setRate(speed) } }))
            }
        } label: {
            Text(Self.speedLabel(player.rate)).font(.caption.weight(.semibold))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Speed")
    }

    // MARK: Helpers

    private static func speedLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide(after: .seconds(3))
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, player.state == .playing, scrubbing == nil else { return }
            controlsVisible = false
        }
    }
}
