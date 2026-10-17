// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine
import CoreText
import SwiftUI

/// The video with its captions and controls. The controls show while the
/// pointer moves over the picture and fade a few seconds after it stops.
struct MacPlayerView: View {
    @ObservedObject var playback: MacLivePlayback
    @ObservedObject var player: AetherPlayer
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
                    VStack {
                        Spacer()
                        MacPlayerControls(playback: playback, player: player)
                            .padding(16)
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
    }

    @ViewBuilder
    private var status: some View {
        if playback.channel == nil {
            ContentUnavailableView("Pick a Channel", systemImage: "tv",
                                   description: Text("Choose a channel from the list to start watching."))
                .foregroundStyle(.white)
        } else if let message = failure {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if player.canRetry || playback.notice != nil {
                    Button("Try Again", action: playback.retry)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .foregroundStyle(.white)
            .padding(24)
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

// MARK: - Controls

private struct MacPlayerControls: View {
    @ObservedObject var playback: MacLivePlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject private var store = LiveTVDataStore.shared

    var body: some View {
        HStack(spacing: 14) {
            Button(action: player.togglePlayPause) {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help(player.state == .playing ? "Pause" : "Play")

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

            liveBadge

            if let channel = playback.channel {
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.programme?.displayTitle ?? channel.name)
                        .font(.callout.weight(.semibold))
                    if playback.programme != nil {
                        Text(channel.numberAndName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let channel = playback.channel {
                let isFavorite = store.isFavorite(channel)
                Button { store.toggleFavorite(channel) } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .help(isFavorite ? "Remove from Favourites" : "Add to Favourites")
            }

            trackMenus

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
                .help("Volume")

            Button { player.fillsWindow.toggle() } label: {
                Image(systemName: player.fillsWindow
                      ? "arrow.down.right.and.arrow.up.left.rectangle"
                      : "arrow.up.left.and.arrow.down.right.rectangle")
            }
            .help(player.fillsWindow ? "Fit to Window" : "Fill Window")

            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full Screen")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
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

// MARK: - Captions

/// Captions in the system caption style (System Settings > Accessibility >
/// Captions), sized from the picture's height as the tvOS renderer does.
struct MacCaptionOverlay: View {
    @ObservedObject var player: AetherPlayer
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
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.changedNotification)) { _ in
            style = CaptionAppearance.current()
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
