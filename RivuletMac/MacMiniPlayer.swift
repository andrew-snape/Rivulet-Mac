// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

enum MacMiniPlayer {
    static let windowID = "mini-player"
    /// The setting that puts the mini player in the menu bar.
    static let menuBarKey = "menuBarPlayer"
}

/// The mini player in its own small window, floating above other windows. It
/// closes itself once nothing is left to play.
struct MacMiniPlayerWindow: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacRadioPlayback.self) private var radio
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        MacMiniPlayerView(inMenuBar: false)
            .background(MacWindowReader { window in
                window.level = .floating
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.isMovableByWindowBackground = true
            })
            .onChange(of: radio.station == nil && !music.isActive) { _, idle in
                if idle { dismissWindow(id: MacMiniPlayer.windowID) }
            }
    }
}

/// A card for what is playing: a station if one is loaded, else music. It sits
/// in the mini player window and in the menu bar's popover.
struct MacMiniPlayerView: View {
    let inMenuBar: Bool
    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacRadioPlayback.self) private var radio

    private static let artwork: CGFloat = 88

    var body: some View {
        VStack(spacing: 10) {
            if radio.station != nil {
                radioCard
            } else if let track = music.track {
                musicCard(track)
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.artwork)
            }
            if inMenuBar {
                HStack {
                    Spacer()
                    Button("Show Rivulet") {
                        NSApp.activate()
                        MacAppDelegate.mainWindow?.makeKeyAndOrderFront(nil)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Radio

    private var radioCard: some View {
        HStack(spacing: 12) {
            MacRadioArtwork(radio: radio, size: Self.artwork)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(radio.song?.title ?? radio.station?.name ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(radio.statusText)
                        .font(.caption)
                        .foregroundStyle(radio.isFailed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Button { radio.togglePlayPause() } label: {
                        Image(systemName: radio.state == .playing || radio.state == .loading ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 30)
                    }
                    .help(radio.state == .playing || radio.state == .loading ? "Pause" : "Play")
                    Button { radio.stop() } label: {
                        Image(systemName: "stop.fill").font(.title3)
                    }
                    .help("Stop")
                    Spacer(minLength: 0)
                    if let summary = radio.quality?.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(height: Self.artwork)
    }

    // MARK: Music

    private func musicCard(_ track: PlexMetadata) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                MacMusicArtwork(item: track, size: Self.artwork)
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.displayTitle).font(.headline).lineLimit(1)
                        Text(music.problem ?? track.trackArtist ?? "")
                            .font(.caption)
                            .foregroundStyle(music.problem == nil ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 24) {
                        Button { music.skipToPrevious() } label: {
                            Image(systemName: "backward.fill").font(.title3)
                        }
                        .help("Previous")
                        Button { music.togglePlayPause() } label: {
                            Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .frame(width: 30)
                        }
                        .help(music.isPlaying ? "Pause" : "Play")
                        Button { music.skipToNext() } label: {
                            Image(systemName: "forward.fill").font(.title3)
                        }
                        .disabled(!music.queue.hasNext)
                        .help("Next")
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(height: Self.artwork)
            MacMusicScrubber()
        }
    }
}
