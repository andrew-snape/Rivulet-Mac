// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

// MARK: - Bar

/// The slim player along the bottom of the window while music is queued.
/// The artwork and title open Now Playing.
struct MacMusicBar: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let track = music.track {
            HStack(spacing: 16) {
                Button { music.isNowPlayingShown = true } label: {
                    HStack(spacing: 10) {
                        MacMusicArtwork(item: track, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(music.problem ?? track.trackArtist ?? "")
                                .font(.caption)
                                .foregroundStyle(music.problem == nil ? Color.secondary : Color.orange)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 240, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Now Playing")

                VStack(spacing: 4) {
                    MacMusicTransport(size: .small)
                    MacMusicScrubber()
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    MacMusicVolume().frame(width: 110)
                    MacAirPlayButton(player: music.player.routingPlayer, tint: .secondaryLabelColor)
                        .frame(width: 22, height: 22)
                        .help("AirPlay")
                    Button { openWindow(id: MacMiniPlayer.windowID) } label: {
                        Image(systemName: "pip.enter")
                    }
                    .buttonStyle(.borderless)
                    .help("Mini Player")
                    Button { music.isNowPlayingShown = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .help("Queue")
                }
                .frame(width: 240, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .contextMenu {
                Button("Stop", systemImage: "stop.fill") { music.stop() }
            }
        }
    }
}

// MARK: - Controls

/// Shuffle, Previous, Play/Pause, Next and Repeat.
struct MacMusicTransport: View {
    enum Size { case small, large }
    let size: Size
    @Environment(MacMusicPlayback.self) private var music

    private var repeatSymbol: String { music.queue.repeatMode == .one ? "repeat.1" : "repeat" }

    var body: some View {
        let large = size == .large
        HStack(spacing: large ? 34 : 22) {
            Button { music.setShuffled(!music.queue.isShuffled) } label: {
                Image(systemName: "shuffle")
            }
            .foregroundStyle(music.queue.isShuffled ? Color.accentColor : .secondary)
            .help(music.queue.isShuffled ? "Shuffle Off" : "Shuffle")

            Button { music.skipToPrevious() } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous")

            Button { music.togglePlayPause() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(large ? .system(size: 34) : .title2)
                    .frame(width: large ? 44 : 28)
            }
            .help(music.isPlaying ? "Pause" : "Play")

            Button { music.skipToNext() } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!music.queue.hasNext)
            .help("Next")

            Button { music.cycleRepeat() } label: {
                Image(systemName: repeatSymbol)
            }
            .foregroundStyle(music.queue.repeatMode == .off ? .secondary : Color.accentColor)
            .help(music.queue.repeatMode == .off ? "Repeat" : (music.queue.repeatMode == .all ? "Repeat One" : "Repeat Off"))
        }
        .font(large ? .title2 : .body)
        .buttonStyle(.borderless)
    }
}

/// Elapsed and remaining time around a seek bar. Dragging previews the time;
/// letting go seeks.
struct MacMusicScrubber: View {
    var showsTimes = true
    @Environment(MacMusicPlayback.self) private var music
    @State private var dragging: Double?

    var body: some View {
        let player = music.player
        let duration = max(player.duration, 0)
        let time = dragging ?? min(player.currentTime, duration)
        HStack(spacing: 8) {
            Text(Self.format(time)).frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { time }, set: { dragging = $0 }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = dragging {
                        music.seek(to: target)
                        dragging = nil
                    }
                }
            )
            .controlSize(.small)
            .disabled(duration <= 0)
            Text("-" + Self.format(max(duration - time, 0))).frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MacMusicVolume: View {
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let player = music.player
        HStack(spacing: 6) {
            Button { player.setMuted(!player.isMuted) } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(player.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.mini)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Now Playing

/// The whole window for the track playing: its artwork over its own colours,
/// the controls beneath, and the queue beside them. Everything scales with the
/// window, so nothing is cut off in a small one.
struct MacMusicNowPlayingView: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions

    /// Room for the title bar's buttons, which sit over this view.
    private static let topInset: CGFloat = 52
    /// Title, scrubber, transport and volume under the artwork.
    private static let controlsHeight: CGFloat = 250
    private static let queueWidth: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            let showsQueue = proxy.size.width >= 820
            let playerWidth = proxy.size.width - (showsQueue ? Self.queueWidth : 0)
            let artwork = max(140, min(
                proxy.size.height - Self.topInset - Self.controlsHeight - 40,
                playerWidth - 120,
                560
            ))
            ZStack {
                if let track = music.track {
                    MacMusicBackdrop(track: track)
                    HStack(spacing: 0) {
                        player(for: track, artwork: artwork)
                            .frame(width: playerWidth)
                        if showsQueue {
                            MacMusicQueueList()
                                .frame(width: Self.queueWidth)
                                .background(.black.opacity(0.18))
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .topLeading) { closeButton }
        }
        // Under the title bar too: the insets keep clear of its buttons.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var closeButton: some View {
        Button { music.isNowPlayingShown = false } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close Now Playing")
        .padding(.leading, 18)
        .padding(.top, Self.topInset)
    }

    private func player(for track: PlexMetadata, artwork: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: Self.topInset)
            MacMusicArtwork(item: track, size: artwork)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .id(track.ratingKey)
                .transition(.opacity)
            VStack(spacing: 18) {
                VStack(spacing: 3) {
                    Text(track.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Button(track.trackArtist ?? "") {
                            if let artist = track.artistStub { open(artist) }
                        }
                        if let album = track.parentTitle {
                            Text("·").foregroundStyle(.tertiary)
                            Button(album) {
                                if let stub = track.albumStub { open(stub) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                MacMusicScrubber()
                    .tint(.white)
                MacMusicTransport(size: .large)
                HStack {
                    Text(formatDetail ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    MacMusicVolume().frame(width: 150)
                }
            }
            .frame(width: max(artwork, 380))
            .padding(.top, 28)
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.3), value: track.ratingKey)
    }

    /// "FLAC · 24-bit · 96 kHz" for a file played as it is.
    private var formatDetail: String? {
        guard let source = music.current else { return nil }
        if source.isTranscode { return "AAC · 320 kbps" }
        let stream = source.track.audioStream
        let codec = (source.track.Media?.first?.audioCodec ?? stream?.codec)?.uppercased()
        let rate = stream?.samplingRate.map { String(format: "%g kHz", Double($0) / 1000) }
        let depth = stream?.bitDepth.map { "\($0)-bit" }
        let parts = [codec, depth, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func open(_ item: PlexMetadata) {
        music.isNowPlayingShown = false
        actions.open(item)
    }
}

/// The artwork blown up and blurred into a wash of its own colours, darkened
/// enough for white text.
private struct MacMusicBackdrop: View {
    let track: PlexMetadata
    @Environment(MacPlexSession.self) private var plex

    var body: some View {
        ZStack {
            MacTheme.background
            MacPlexImage(url: plex.imageURL(path: track.squareArtPath, width: 240, height: 240))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.4)
                .blur(radius: 90)
                .saturation(1.4)
                .opacity(0.7)
                .id(track.ratingKey)
                .transition(.opacity)
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: track.ratingKey)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Up Next: drag to reorder, double-click to play, the menu to remove.
struct MacMusicQueueList: View {
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let upNext = music.queue.upNext
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").font(.title3.bold())
                if music.radio != nil {
                    Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !upNext.isEmpty {
                    Text(upNext.count == 1 ? "1 song" : "\(upNext.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            if upNext.isEmpty {
                Text("Nothing else is queued.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(upNext) { entry in
                        MacMusicQueueRow(entry: entry)
                            .onTapGesture(count: 2) { music.jump(to: entry) }
                            .contextMenu {
                                Button("Play Now", systemImage: "play.fill") { music.jump(to: entry) }
                                Button("Remove from Queue", systemImage: "minus.circle") { music.remove(entry) }
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                    .onMove { music.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 60)
        .padding(.bottom, 12)
    }
}

private struct MacMusicQueueRow: View {
    let entry: MusicQueue.Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            MacMusicArtwork(item: entry.track, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.displayTitle).lineLimit(1)
                Text(entry.track.trackArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let time = entry.track.trackTime {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
