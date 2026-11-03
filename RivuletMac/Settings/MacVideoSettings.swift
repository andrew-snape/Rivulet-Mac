// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacVideoSettings: View {
    @AppStorage(StreamingQuality.homeKey) private var homeQuality = StreamingQuality.homeDefault.rawValue
    @AppStorage(StreamingQuality.awayKey) private var awayQuality = StreamingQuality.awayDefault.rawValue
    @AppStorage(MacPlexPlayback.autoPlayNextKey) private var autoPlayNext = true
    @AppStorage(MacSkipInterval.backKey) private var skipBack = MacSkipInterval.backDefault
    @AppStorage(MacSkipInterval.forwardKey) private var skipForward = MacSkipInterval.forwardDefault
    @AppStorage("autoSkipIntro") private var skipIntro = false
    @AppStorage("autoSkipRecap") private var skipRecap = false
    @AppStorage("autoSkipCredits") private var skipCredits = false
    @AppStorage("autoSkipAds") private var skipAds = false
    @AppStorage("useIntroDB") private var useIntroDB = false

    var body: some View {
        Form {
            Section {
                Picker("On Your Network", selection: $homeQuality) { qualityChoices }
                Picker("Away From Home", selection: $awayQuality) { qualityChoices }
            } header: {
                Text("Streaming Quality")
            } footer: {
                Text("Original plays the file as it is. Auto measures the connection and picks a quality that will not stall.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play Next Episode Automatically", isOn: $autoPlayNext)
                Picker("Skip Back", selection: $skipBack) { skipChoices }
                Picker("Skip Forward", selection: $skipForward) { skipChoices }
            } header: {
                Text("Playback")
            } footer: {
                Text("With Play Next off, Up Next waits for you at the end of an episode. The skip lengths apply to the player's buttons, the arrow keys and your keyboard's media keys.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Skip Intros", isOn: $skipIntro)
                Toggle("Skip Recaps", isOn: $skipRecap)
                Toggle("Skip Credits", isOn: $skipCredits)
                Toggle("Skip Commercials", isOn: $skipAds)
                Toggle("Use Community Markers", isOn: $useIntroDB)
            } header: {
                Text("Skipping")
            } footer: {
                Text("Community markers fill in intros and credits Plex has not marked, from IntroDB. Only the show's IMDb ID and the episode number are sent.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var qualityChoices: some View {
        ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0.rawValue) }
    }

    @ViewBuilder
    private var skipChoices: some View {
        ForEach(MacSkipInterval.choices, id: \.self) { Text("\($0) Seconds").tag($0) }
    }
}

/// Skip lengths for a Plex title: the player's buttons, the arrow keys, the
/// Playback menu and the media keys. Live TV keeps 10 seconds each way.
enum MacSkipInterval {
    static let backKey = "skipBackSeconds"
    static let forwardKey = "skipForwardSeconds"
    static let backDefault = 10
    static let forwardDefault = 30
    /// Lengths SF Symbols draws as gobackward.N and goforward.N.
    static let choices = [5, 10, 15, 30, 45, 60]

    static var back: Double { Double(stored(backKey, fallback: backDefault)) }
    static var forward: Double { Double(stored(forwardKey, fallback: forwardDefault)) }

    /// `value` if it is one of the choices, else `fallback`.
    static func checked(_ value: Int, fallback: Int) -> Int {
        choices.contains(value) ? value : fallback
    }

    private static func stored(_ key: String, fallback: Int) -> Int {
        checked(UserDefaults.standard.object(forKey: key) as? Int ?? fallback, fallback: fallback)
    }
}
