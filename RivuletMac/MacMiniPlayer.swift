// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

enum MacMiniPlayer {
    /// The setting that puts the player in the menu bar. With it on, closing the
    /// window leaves music and radio playing there; with it off, closing quits.
    static let menuBarKey = "menuBarPlayer"
    /// With the menu bar player on, the Dock icon goes while the window is closed.
    static let hideDockKey = "hideDockIcon"

    static var isInMenuBar: Bool { UserDefaults.standard.bool(forKey: menuBarKey) }

    /// A regular app while its window is open, so it has a Dock icon and menus.
    /// With the menu bar player and Hide Dock Icon on, an accessory app while it is closed.
    @MainActor
    static func applyDockPolicy() {
        let hidden = isInMenuBar && UserDefaults.standard.bool(forKey: hideDockKey)
            && MacAppDelegate.mainWindow?.isVisible != true
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}

/// A card for what is playing: a station if one is loaded, else music. It sits
/// in the menu bar's popover.
struct MacMiniPlayerView: View {
    @Environment(MacMusicPlayback.self) private var music
    @Environment(MacRadioPlayback.self) private var radio
    @Environment(\.openWindow) private var openWindow

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
            HStack {
                Button("Show Rivulet") {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                    if let window = MacAppDelegate.mainWindow {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
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
