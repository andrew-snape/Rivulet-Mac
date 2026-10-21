// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import CoreText
import SwiftUI

/// The video with its captions and controls. The controls show while the
/// pointer moves over the picture and fade a few seconds after it stops.
struct MacPlayerView: View {
    var playback: MacLivePlayback
    var player: AetherPlayer
    /// A small picture (the guide's corner player): fewer controls, shorter messages.
    var compact = false
    /// The floating window: the full screen button gives way to one that brings the picture back.
    var isPopOut = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if playback.channel != nil {
                    player.surface
                    MacCaptionOverlay(player: player, container: proxy.size)
                        .allowsHitTesting(false)
                }
                status
                if playback.channel != nil {
                    VStack(spacing: 0) {
                        if !compact { topBar }
                        Spacer()
                        MacPlayerControls(playback: playback, player: player, compact: compact, isPopOut: isPopOut)
                            .padding(.horizontal, compact ? 8 : 24)
                            .padding(.bottom, compact ? 8 : 20)
                    }
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: controlsVisible)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
            .onContinuousHover { phase in
                switch phase {
                case .active: showControls()
                case .ended: scheduleHide(after: .seconds(1))
                }
            }
        }
        .onAppear { scheduleHide(after: .seconds(3)) }
        .onChange(of: playback.channel?.id) { showControls() }
        // A slow tune or a resume from the keyboard leaves the pointer still, so fade from here too.
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide(after: .seconds(3)) }
        }
    }

    /// The channel and programme at the top, as the Plex player shows its title.
    @ViewBuilder
    private var topBar: some View {
        if let channel = playback.channel {
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.programme?.displayTitle ?? channel.name)
                    .font(.title3.weight(.semibold))
                if playback.programme != nil {
                    Text(channel.numberAndName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var status: some View {
        if playback.channel == nil {
            if compact {
                VStack(spacing: 6) {
                    Image(systemName: "tv").font(.title)
                    Text("Pick a channel from the guide").font(.callout)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ContentUnavailableView("Pick a Channel", systemImage: "tv",
                                       description: Text("Choose a channel from the list to start watching."))
                    .foregroundStyle(.white)
            }
        } else if let message = failure {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(message)
                    .font(compact ? .callout : .body)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: compact ? 280 : 380)
                if player.canRetry || playback.notice != nil {
                    Button("Try Again", action: playback.retry)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .foregroundStyle(.white)
            .padding(compact ? 12 : 24)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        } else if player.state == .idle || player.state == .loading || player.isBuffering {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var failure: String? {
        if let notice = playback.notice { return notice }
        guard case .failed(let message) = player.state else { return nil }
        return message
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide(after: .seconds(3))
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, player.state == .playing else { return }
            controlsVisible = false
        }
    }
}

// MARK: - Pop-out window

/// The channel's picture alone in a small window that floats above other apps.
struct MacLivePopOutView: View {
    @Environment(MacLivePlayback.self) private var playback
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var popOutWindow: NSWindow?

    var body: some View {
        MacPlayerView(playback: playback, player: playback.player, compact: true, isPopOut: true)
            .background(MacWindowReader { window in
                window.level = .floating
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.contentAspectRatio = NSSize(width: 16, height: 9)
                popOutWindow = window
            })
            .onChange(of: playback.player.videoSize, initial: true) { _, size in
                popOutWindow?.fit(toVideo: size)
            }
            .onDisappear { playback.isPoppedOut = false }
            // Stopping the channel, or starting a Plex title, leaves nothing to float.
            .onChange(of: playback.channel == nil) { _, stopped in
                if stopped { dismissWindow(id: MacLivePlayback.popOutWindowID) }
            }
    }
}

// MARK: - Controls

private struct MacPlayerControls: View {
    var playback: MacLivePlayback
    var player: AetherPlayer
    let compact: Bool
    let isPopOut: Bool
    private let store = LiveTVDataStore.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        // A shrunken window drops the volume slider first, then the fill toggle and Record.
        ViewThatFits(in: .horizontal) {
            row(spacing: 16, wide: true, minimal: false)
            row(spacing: 12, wide: false, minimal: false)
            row(spacing: 10, wide: false, minimal: true)
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, compact ? 6 : 12)
        .background(.regularMaterial, in: compact ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 16)))
        .frame(maxWidth: compact ? .infinity : 980)
        .environment(\.colorScheme, .dark)
    }

    private func row(spacing: CGFloat, wide: Bool, minimal: Bool) -> some View {
        HStack(spacing: spacing) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help(player.state == .playing ? "Pause" : "Play")

            if !compact {
                Button { Task { await player.skip(by: -10) } } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("Back 10 Seconds")
                .disabled(player.liveWindow.seekableRange == nil)

                Button { Task { await player.skip(by: 10) } } label: {
                    Image(systemName: "goforward.10")
                }
                .help("Forward 10 Seconds")
                .disabled(player.liveWindow.seekableRange == nil || player.liveWindow.isAtLiveEdge)
            }

            liveBadge

            Spacer(minLength: 8)

            if let channel = playback.channel {
                let isFavorite = store.isFavorite(channel)
                Button { store.toggleFavorite(channel) } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .help(isFavorite ? "Remove from Favourites" : "Add to Favourites")

                if !compact, !minimal, store.canRecord(channel), let program = playback.programme {
                    MacRecordButton(channel: channel, program: program)
                }
            }

            trackMenus

            Button { player.setMuted(!player.isMuted) } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .help(player.isMuted ? "Unmute" : "Mute")

            if !compact && wide {
                Slider(value: Binding(get: { Double(player.isMuted ? 0 : player.volume) },
                                      set: { player.setVolume(Float($0)) }),
                       in: 0...1)
                    .frame(width: 90)
                    .controlSize(.small)
                    .help("Volume")
            }

            if !compact && !minimal {
                Button { player.fillsWindow.toggle() } label: {
                    Image(systemName: player.fillsWindow
                          ? "arrow.down.right.and.arrow.up.left.rectangle"
                          : "arrow.up.left.and.arrow.down.right.rectangle")
                }
                .help(player.fillsWindow ? "Fit to Window" : "Fill Window")
            }

            if isPopOut {
                Button { dismissWindow(id: MacLivePlayback.popOutWindowID) } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .help("Back to the Main Window")
            } else {
                Button {
                    playback.isPoppedOut = true
                    openWindow(id: MacLivePlayback.popOutWindowID)
                } label: {
                    Image(systemName: "pip.exit")
                }
                .help("Pop Out")

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen")
            }
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if player.liveWindow.isAtLiveEdge {
            Text("LIVE")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
        } else {
            Button("Go Live") { Task { await player.seekToLiveEdge() } }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .help("Jump to Live")
        }
    }

    @ViewBuilder
    private var trackMenus: some View {
        if player.audioTracks.count > 1 {
            Menu {
                ForEach(player.audioTracks) { track in
                    Toggle(isOn: Binding(get: { player.currentAudioTrackId == track.id },
                                         set: { if $0 { player.selectAudioTrack(id: track.id) } })) {
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

        if !player.subtitleTracks.isEmpty {
            Menu {
                Toggle("Off", isOn: Binding(get: { player.currentSubtitleTrackId == nil },
                                            set: { if $0 { player.selectSubtitleTrack(id: nil) } }))
                Divider()
                ForEach(player.subtitleTracks) { track in
                    Toggle(isOn: Binding(get: { player.currentSubtitleTrackId == track.id },
                                         set: { if $0 { player.selectSubtitleTrack(id: track.id) } })) {
                        Text(track.name)
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            } label: {
                Image(systemName: player.currentSubtitleTrackId == nil ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles")
        }
    }
}

// MARK: - Record

/// Records what is airing: the source's own options (this episode, the series),
/// or stops a recording already set for it.
private struct MacRecordButton: View {
    let channel: UnifiedChannel
    let program: UnifiedProgram
    private let store = LiveTVDataStore.shared
    @State private var options: [LiveTVRecordOption] = []
    @State private var failure: String?

    var body: some View {
        let active = store.activeRecording(for: program)
        Menu {
            if let active {
                Button(active.status == .recording ? "Stop Recording" : "Cancel Recording") {
                    run { try await store.cancel(active) }
                }
                if active.ruleIsSeries {
                    Button("Cancel Series Recording") { run { try await store.cancelSeries(of: active) } }
                }
            } else if options.isEmpty {
                Text("No recording options")
            } else {
                ForEach(options) { option in
                    Button(option.title) { run { try await store.record(option, program: program, on: channel) } }
                }
            }
        } label: {
            Image(systemName: active == nil ? "record.circle" : "record.circle.fill")
                .foregroundStyle(active == nil ? Color.primary : Color.red)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(active == nil ? "Record" : "Recording")
        .task(id: program.id) {
            await store.refreshScheduledRecordings()
            options = (try? await store.recordOptions(for: program, on: channel)) ?? []
        }
        .alert("Couldn't Update the Recording", isPresented: Binding(get: { failure != nil },
                                                                     set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { failure = error.localizedDescription }
        }
    }
}

// MARK: - Captions

/// Captions in the system caption style (System Settings > Accessibility >
/// Captions), sized from the picture's height as the tvOS renderer does.
struct MacCaptionOverlay: View {
    var player: AetherPlayer
    let container: CGSize
    @State private var style = CaptionAppearance.current()

    var body: some View {
        let video = videoRect
        let time = player.sourceTime
        let active = player.captions.filter { $0.startTime <= time && $0.endTime >= time } + player.nativeCaptions
        let pointSize = max(14, video.height * 0.05 * style.fontScale)

        ZStack(alignment: .topLeading) {
            ForEach(active) { caption in
                if case .image(let image, let position) = caption.body {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: position.width * video.width, height: position.height * video.height)
                        .offset(x: video.minX + position.minX * video.width,
                                y: video.minY + position.minY * video.height)
                }
            }

            VStack(spacing: pointSize * 0.2) {
                ForEach(active) { caption in
                    if case .text(let runs) = caption.body {
                        line(runs, pointSize: pointSize)
                    }
                }
            }
            .frame(width: video.width * 0.9)
            .position(x: video.midX, y: video.maxY - video.height * 0.12)
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .task {
            for await _ in NotificationCenter.default.notifications(named: CaptionAppearance.changedNotification) {
                style = CaptionAppearance.current()
            }
        }
    }

    private func line(_ runs: [AetherPlayer.Caption.Run], pointSize: CGFloat) -> some View {
        let userColor = Color(cgColor: style.foreground).opacity(style.foregroundOpacity)
        let text = runs.reduce(Text("")) { result, run in
            let color = style.allowsContentColor ? run.color.map { Color(cgColor: $0) } : nil
            var piece = Text(run.text).foregroundColor(color ?? userColor)
            if run.isItalic, style.allowsContentFont { piece = piece.italic() }
            return Text("\(result)\(piece)")
        }
        return text
            .font(Font(style.font(ofSize: pointSize) as CTFont))
            .multilineTextAlignment(.center)
            .padding(.horizontal, pointSize * 0.3)
            .padding(.vertical, pointSize * 0.08)
            .background(
                style.edge == .uniform
                    ? Color.clear
                    : Color(cgColor: style.backgroundColor).opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: pointSize * 0.2)
            )
            .shadow(color: style.edge == .none ? .clear : .black.opacity(0.85), radius: 2, y: 1)
    }

    /// Where the picture sits in the pane: fitted, or filling it when the
    /// viewer chose Fill.
    private var videoRect: CGRect {
        let size = player.videoSize
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = player.fillsWindow
            ? max(container.width / size.width, container.height / size.height)
            : min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2,
                      width: width, height: height)
    }
}
