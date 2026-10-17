// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

@main
struct RivuletMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var playback: MacLivePlayback

    init() {
        // Host values for shared code, set before anything touches the
        // stores (CLAUDE.md, Platform Boundary: host injection).
        PlexAPI.platform = "macOS"
        PlexAPI.deviceName = "Mac"
        LiveTVDataStore.foregroundNotification = NSApplication.didBecomeActiveNotification
        // Start the path monitor now; its first reading arrives after a delay.
        _ = NetworkPathMonitor.shared

        let playback = MacLivePlayback()
        MacAppDelegate.playback = playback
        _playback = StateObject(wrappedValue: playback)
        // Warms the channel list and guide so the window opens with data.
        LiveTVDataStore.shared.startBackgroundPreload()
    }

    var body: some Scene {
        Window("Rivulet", id: "main") {
            MacRootView()
                .environmentObject(playback)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            MacPlaybackCommands(playback: playback, player: playback.player)
        }

        Settings {
            MacSettingsView()
        }
    }
}

/// The Playback menu. Space is handled in `MacAppDelegate` instead, so it
/// still types a space in a text field.
private struct MacPlaybackCommands: Commands {
    @ObservedObject var playback: MacLivePlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject private var store = LiveTVDataStore.shared

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.state == .playing ? "Pause" : "Play", action: player.togglePlayPause)
                .disabled(playback.channel == nil)

            Divider()

            Button("Next Channel") { playback.step(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Channel") { playback.step(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Divider()

            Button("Back 10 Seconds") { Task { await player.skip(by: -10) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(player.liveWindow.seekableRange == nil)
            Button("Forward 10 Seconds") { Task { await player.skip(by: 10) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(player.liveWindow.seekableRange == nil || player.liveWindow.isAtLiveEdge)
            Button("Go Live") { Task { await player.seekToLiveEdge() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(player.liveWindow.isAtLiveEdge)

            Divider()

            Button(player.isMuted ? "Unmute" : "Mute") { player.setMuted(!player.isMuted) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(playback.channel == nil)

            if let channel = playback.channel {
                Button(store.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites") {
                    store.toggleFavorite(channel)
                }
                .keyboardShortcut("d")
            }

            Divider()

            Button("Stop") { playback.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(playback.channel == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Refresh Guide") {
                Task {
                    await store.loadChannels()
                    await store.loadEPG(startDate: Date(), hours: LiveTVDataStore.refreshWindowHours)
                }
            }
            .keyboardShortcut("r")
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static weak var playback: MacLivePlayback?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Space plays and pauses wherever focus is, except while typing.
        // Local monitors run on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard !(event.window?.firstResponder is NSText),
                      let playback = Self.playback, playback.channel != nil else { return false }
                playback.player.togglePlayPause()
                return true
            }
            return handled ? nil : event
        }
    }

    /// One window: closing it stops the stream and quits, as a player should.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.playback?.stop()
    }
}
