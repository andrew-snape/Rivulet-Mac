// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Bar

/// The slim player along the bottom of the window while music is queued.
/// The artwork and title open Now Playing.
struct MacMusicBar: View {
    @Environment(MacMusicPlayback.self) private var music

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
                    Button { music.isNowPlayingShown = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .help("Queue")
                }
                .frame(width: 160, alignment: .trailing)
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

/// The whole window for the track playing: big artwork over its own colours,
/// the controls, and the queue beside it.
struct MacMusicNowPlayingView: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions

    var body: some View {
        ZStack {
            if let track = music.track {
                backdrop(for: track)
                HStack(spacing: 40) {
                    VStack(spacing: 22) {
                        Spacer(minLength: 0)
                        MacMusicArtwork(item: track, size: 380)
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                        VStack(spacing: 4) {
                            Text(track.displayTitle).font(.title.bold()).lineLimit(2)
                            Button(track.trackArtist ?? "") {
                                if let artist = track.artistStub { open(artist) }
                            }
                            .buttonStyle(.plain)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            if let album = track.parentTitle {
                                Button([album, (music.current?.track.parentYear).map(String.init)].compactMap { $0 }.joined(separator: " · ")) {
                                    if let stub = track.albumStub { open(stub) }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        MacMusicScrubber().frame(maxWidth: 440)
                        MacMusicTransport(size: .large)
                        MacMusicVolume().frame(width: 220)
                        if let detail = formatDetail {
                            Text(detail).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    MacMusicQueueList()
                        .frame(width: 340)
                }
                .padding(40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { music.isNowPlayingShown = false } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close Now Playing")
            .padding(.leading, 20)
            .padding(.top, 40)
        }
        .environment(\.colorScheme, .dark)
    }

    /// "FLAC · 44.1 kHz" for a file played as it is; "Transcoded" otherwise.
    private var formatDetail: String? {
        guard let source = music.current else { return nil }
        if source.isTranscode { return "AAC 320 kbps (converted by the server)" }
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

    private func backdrop(for track: PlexMetadata) -> some View {
        ZStack {
            MacTheme.background
            MacMusicArtwork(item: track, size: 120)
                .scaleEffect(12)
                .blur(radius: 60)
                .opacity(0.55)
            Color.black.opacity(0.35)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Up Next: drag to reorder, Delete or the menu to remove, click to play.
struct MacMusicQueueList: View {
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        let upNext = music.queue.upNext
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(music.radio == nil ? "Up Next" : "Up Next · Radio").font(.headline)
                Spacer()
                Text(upNext.count == 1 ? "1 song" : "\(upNext.count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if upNext.isEmpty {
                Text("Nothing else is queued.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(upNext) { entry in
                        MacMusicQueueRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { music.jump(to: entry) }
                            .contextMenu {
                                Button("Play Now", systemImage: "play.fill") { music.jump(to: entry) }
                                Button("Remove from Queue", systemImage: "minus.circle") { music.remove(entry) }
                            }
                    }
                    .onMove { music.moveUpNext(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for offset in offsets.sorted(by: >) { music.remove(upNext[offset]) }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: MacTheme.shape)
    }
}

private struct MacMusicQueueRow: View {
    let entry: MusicQueue.Entry

    var body: some View {
        HStack(spacing: 10) {
            MacMusicArtwork(item: entry.track, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.displayTitle).lineLimit(1)
                Text(entry.track.trackArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if entry.isRadio {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Added by radio")
            }
            if let time = entry.track.trackTime {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
