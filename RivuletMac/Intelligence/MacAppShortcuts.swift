// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppIntents
import Observation

/// Siri phrases. Every one names Rivulet, so none competes with the Music or
/// TV apps, and no two share a pattern Siri would have to guess between.
struct MacAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Resume watching in \(.applicationName)",
                "Continue watching in \(.applicationName)",
            ],
            shortTitle: "Resume Watching",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayVideoIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Watch \(\.$item) in \(.applicationName)",
            ],
            shortTitle: "Play Movie or Show",
            systemImageName: "film"
        )
        AppShortcut(
            intent: TuneChannelIntent(),
            phrases: [
                "Tune \(.applicationName) to \(\.$channel)",
                "Watch \(\.$channel) live on \(.applicationName)",
            ],
            shortTitle: "Watch Channel",
            systemImageName: "tv"
        )
        AppShortcut(
            intent: PlayStationIntent(),
            phrases: [
                "Play \(\.$station) radio on \(.applicationName)",
                "Tune in to \(\.$station) on \(.applicationName)",
            ],
            shortTitle: "Play Radio Station",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Listen to \(\.$music) in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play"
        )
    }

    /// Siri learns channel and station names from the queries' suggestions, so
    /// it is told again whenever the lineup or the station lists change.
    @MainActor
    static func refreshParametersOnChange() {
        Task {
            let live = LiveTVDataStore.shared
            let radio = RadioStore.shared
            for await _ in Observations({ live.channels.count + radio.ownStations.count + radio.stations.count }) {
                updateAppShortcutParameters()
            }
        }
    }
}
