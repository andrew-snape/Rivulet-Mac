// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

@main
struct RivuletMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var playback: MacLivePlayback
    @StateObject private var plex: MacPlexSession
    @StateObject private var vod: MacPlaybackController

    init() {
        // Host values for shared code, set before anything touches the
        // stores (CLAUDE.md, Platform Boundary: host injection).
        PlexAPI.platform = "macOS"
        PlexAPI.deviceName = "Mac"
        LiveTVDataStore.foregroundNotification = NSApplication.didBecomeActiveNotification
        // Start the path monitor now; its first reading arrives after a delay.
        _ = NetworkPathMonitor.shared

        // The session installs the auth manager's content hooks, so it is built
        // before anything signs in.
        let plex = MacPlexSession()
        plex.installProfileHooks()
        _plex = StateObject(wrappedValue: plex)

        let playback = MacLivePlayback()
        let vod = MacPlaybackController()
        vod.plex = plex
        MacAppDelegate.refreshPlex = { [weak plex] in await plex?.refresh() }
        MacAppDelegate.playback = playback
        MacAppDelegate.vod = vod
        _playback = StateObject(wrappedValue: playback)
        _vod = StateObject(wrappedValue: vod)
        // Warms the channel list and guide so the window opens with data.
        LiveTVDataStore.shared.startBackgroundPreload()
    }

    var body: some Scene {
        Window("Rivulet", id: "main") {
            MacRootView()
                .environmentObject(playback)
                .environmentObject(plex)
                .environmentObject(vod)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            MacPlaybackCommands(playback: playback, player: playback.player, vod: vod)
        }

        Settings {
            MacSettingsView()
                .environmentObject(plex)
        }
    }
}

/// The Playback menu. It acts on the Plex player while one is up, else on
/// Live TV. Space and the arrow keys are handled in `MacAppDelegate` instead,
/// so they still type in a text field.
private struct MacPlaybackCommands: Commands {
    @ObservedObject var playback: MacLivePlayback
    @ObservedObject var player: AetherPlayer
    @ObservedObject var vod: MacPlaybackController
    @ObservedObject private var store = LiveTVDataStore.shared

    /// The player in front: the Plex title, else the channel.
    private var active: AetherPlayer? {
        vod.session?.player ?? (playback.channel == nil ? nil : player)
    }

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") { active?.togglePlayPause() }
                .disabled(active == nil)

            Divider()

            Button("Back 10 Seconds") { Task { await active?.skip(by: -10) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(active == nil)
            Button("Forward") { Task { await active?.skip(by: vod.session == nil ? 10 : 30) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(active == nil)
            Button("Mute/Unmute") {
                if let player = active { player.setMuted(!player.isMuted) }
            }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(active == nil)

            Divider()

            Button("Next Channel") { playback.step(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(vod.session != nil || playback.lineup.isEmpty)
            Button("Previous Channel") { playback.step(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(vod.session != nil || playback.lineup.isEmpty)
            Button("Go Live") { Task { await player.seekToLiveEdge() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(vod.session != nil || player.liveWindow.isAtLiveEdge)
            if vod.session == nil, let channel = playback.channel {
                Button(store.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites") {
                    store.toggleFavorite(channel)
                }
                .keyboardShortcut("d")
            }

            Divider()

            Button("Stop") {
                if vod.session != nil { vod.close() } else { playback.stop() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(active == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Refresh") {
                Task {
                    await MacAppDelegate.refreshPlex?()
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
    static weak var vod: MacPlaybackController?
    /// Set by the app: refetches Plex Home and libraries.
    static var refreshPlex: (() async -> Void)?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Space plays and pauses wherever focus is, except while typing. With
        // a Plex title up, the arrows skip and Esc closes it.
        // Local monitors run on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard plain else { return event }
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard !(event.window?.firstResponder is NSText) else { return false }
                if let session = Self.vod?.session {
                    let player = session.player
                    switch keyCode {
                    case 49: player.togglePlayPause()
                    case 123: Task { await player.skip(by: -10) }
                    case 124: Task { await player.skip(by: 30) }
                    case 53: Self.vod?.close()
                    default: return false
                    }
                    return true
                }
                guard keyCode == 49, let playback = Self.playback, playback.channel != nil else { return false }
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
        Self.vod?.close()
        Self.playback?.stop()
    }
}
