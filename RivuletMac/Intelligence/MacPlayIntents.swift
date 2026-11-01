// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppIntents
import AppKit
import MediaPlayer

// Siri, Spotlight and Shortcuts actions. Each one starts playback the way the
// app's own buttons do (`IntentActions`), so the one-stream rule holds: video
// and channels need the window and bring it forward; music and radio play
// without it.

// MARK: - Video

nonisolated struct PlayVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Movie or Show"
    static let description = IntentDescription("Plays a movie or an episode. A show plays its next episode.")
    static let openAppWhenRun = true

    @Parameter(title: "Title") var item: VideoEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$item)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await IntentActions.playVideo(id: item.id)
        return .result(dialog: "Playing \(name).")
    }
}

nonisolated struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Plays the first title in Continue Watching.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await IntentActions.resumeWatching()
        return .result(dialog: "Playing \(name).")
    }
}

// MARK: - Live TV

nonisolated struct TuneChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Watch Channel"
    static let description = IntentDescription("Opens Live TV and tunes a channel.")
    static let openAppWhenRun = true

    @Parameter(title: "Channel") var channel: ChannelEntity

    static var parameterSummary: some ParameterSummary { Summary("Watch \(\.$channel)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await IntentActions.tune(channelID: channel.id)
        return .result(dialog: "Tuning \(name).")
    }
}

// MARK: - Radio and music

nonisolated struct PlayStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Radio Station"
    static let description = IntentDescription("Plays an internet radio station.")

    @Parameter(title: "Station") var station: StationEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$station)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try await IntentActions.playStation(id: station.id)
        return .result(dialog: "Playing \(name).")
    }
}

nonisolated struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays an artist, album, song or playlist from Plex.")

    @Parameter(title: "Music") var music: MusicEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$music)") { \.$shuffle }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentActions.playMusic(id: music.id, action: shuffle ? .shuffle : .play)
        return .result(dialog: "Playing \(music.title).")
    }
}

nonisolated struct StartMusicRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Music Radio"
    static let description = IntentDescription("Plays music that sounds like an artist, album, song or playlist.")

    @Parameter(title: "Music") var music: MusicEntity

    static var parameterSummary: some ParameterSummary { Summary("Start radio from \(\.$music)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentActions.playMusic(id: music.id, action: .radio)
        return .result(dialog: "Starting radio from \(music.title).")
    }
}

// MARK: - Transport

/// Pause, resume, next and previous act on what is in front, as the media keys do.
nonisolated struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses whatever Rivulet is playing.")

    func perform() async throws -> some IntentResult {
        try await IntentActions.transport { $0.remotePause() }
        return .result()
    }
}

nonisolated struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Resumes whatever Rivulet was playing.")

    func perform() async throws -> some IntentResult {
        try await IntentActions.transport { $0.remotePlay() }
        return .result()
    }
}

nonisolated struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next"
    static let description = IntentDescription("Skips to the next song or episode.")

    func perform() async throws -> some IntentResult {
        try await IntentActions.transport { $0.remoteNext() }
        return .result()
    }
}

nonisolated struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous"
    static let description = IntentDescription("Goes back to the previous song.")

    func perform() async throws -> some IntentResult {
        try await IntentActions.transport { $0.remotePrevious() }
        return .result()
    }
}

// MARK: - Actions

/// What the intents do, on the main actor, through the same calls as the views.
@MainActor
enum IntentActions {
    /// Returns the name Siri says back.
    static func playVideo(id: String) async throws -> String {
        let item = try await IntentStore.item(id)
        try await play(item)
        return IntentStore.spokenName(of: item)
    }

    static func resumeWatching() async throws -> String {
        guard let item = try await IntentStore.continueWatchingItems().first else {
            throw IntentFailure.nothingToResume
        }
        try await play(item)
        return IntentStore.spokenName(of: item)
    }

    private static func play(_ item: PlexMetadata) async throws {
        guard let vod = MacAppDelegate.vod else { throw IntentFailure.notFound }
        await showWindow()
        do {
            try await vod.play(item: item)
        } catch {
            throw IntentFailure.couldNotPlay(IntentStore.spokenName(of: item))
        }
    }

    /// Live TV plays on its own page, so the window comes forward and opens it first.
    static func tune(channelID: String) async throws -> String {
        guard let channel = await IntentStore.channel(id: channelID), let live = MacAppDelegate.playback else {
            throw IntentFailure.notFound
        }
        MacAppDelegate.vod?.close()
        MacAppDelegate.multiview?.stopAll()
        await showWindow()
        MacAppDelegate.navigate?(.liveTV)
        live.play(channel)
        return channel.name
    }

    static func playStation(id: String) async throws -> String {
        guard let station = await IntentStore.station(id: id), let radio = MacAppDelegate.radio else {
            throw IntentFailure.notFound
        }
        radio.play(station)
        return station.name
    }

    static func playMusic(id: String, action: MacMusicAction) async throws {
        let item = try await IntentStore.item(id)
        guard let music = MacAppDelegate.music else { throw IntentFailure.notFound }
        // A Plex title has the window; music from Siri takes over from it.
        MacAppDelegate.vod?.close()
        music.perform(action, on: item)
    }

    static func transport(_ command: @MainActor (MacPlaybackController) -> MPRemoteCommandHandlerStatus) throws {
        guard let vod = MacAppDelegate.vod, command(vod) == .success else { throw IntentFailure.nothingPlaying }
    }

    /// Brings the main window forward, reopening it if it was closed, and waits
    /// (up to 3 s) until its root view is up to take a page change.
    private static func showWindow() async {
        MacAppDelegate.showMainWindow()
        var waited = 0
        while MacAppDelegate.mainWindow?.isVisible != true || MacAppDelegate.navigate == nil, waited < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }
}
