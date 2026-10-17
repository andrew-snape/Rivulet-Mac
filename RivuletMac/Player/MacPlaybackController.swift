// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// App-level owner of the Plex item playing, shown over the whole window.
/// Starting one stops Live TV (`onStart`), so only one stream plays at a time.
@MainActor
final class MacPlaybackController: ObservableObject {
    @Published private(set) var session: MacPlexPlayback?

    /// Needed to build sessions; the root view sets it.
    weak var plex: MacPlexSession?
    var onStart: (() -> Void)?

    private var stateObservation: AnyCancellable?
    private var sleepActivity: NSObjectProtocol?

    func play(_ request: MacPlexPlaybackRequest) {
        guard let plex else { return }
        end()
        let newSession = MacPlexPlayback(request: request, plex: plex)
        session = newSession
        onStart?()
        // Keep the display awake while something plays, as a video player should.
        stateObservation = newSession.player.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.keepAwake(state == .playing) }
        Task { await newSession.begin() }
    }

    /// Ends playback and leaves the player.
    func close() {
        end()
    }

    private func end() {
        guard let session else { return }
        session.end()
        session.player.stop()
        stateObservation = nil
        keepAwake(false)
        self.session = nil
    }

    private func keepAwake(_ awake: Bool) {
        if awake, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !awake, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}

// MARK: - Player

/// A Plex title over the whole window: the video, captions, and controls that
/// show while the pointer moves.
struct MacVODPlayerView: View {
    @ObservedObject var session: MacPlexPlayback
    @ObservedObject var player: AetherPlayer
    let close: () -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?

    var body: some View {
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
                // Above the click layer, so the failure's buttons take clicks.
                status
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    HStack {
                        Spacer()
                        contextualButton
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    controls
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                .opacity(controlsVisible || player.state != .playing ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: controlsVisible)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: showControls()
                case .ended: scheduleHide(after: .seconds(1))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { scheduleHide(after: .seconds(3)) }
        // A slow start or a resume from the keyboard leaves the pointer still, so fade from here too.
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide(after: .seconds(3)) }
        }
    }

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
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")

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
        if let countdown = session.upNextCountdown {
            HStack(spacing: 8) {
                Button { session.playNext() } label: {
                    Label("Next Episode in \(countdown)", systemImage: "forward.end.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel", action: session.cancelUpNext)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        } else if session.nextEpisode != nil, !session.upNextDismissed, session.isNearEnd {
            Button { session.playNext() } label: {
                Label("Next Episode", systemImage: "forward.end.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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

            HStack(spacing: 16) {
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

                Spacer()

                trackMenus
                qualityMenu
                speedMenu

                Button { player.setMuted(!player.isMuted) } label: {
                    Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .help(player.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                      set: { player.setVolume(Float($0)) }),
                       in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen")
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 980)
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
