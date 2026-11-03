// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacMusicSettings: View {
    @AppStorage(MacMusicPlayback.loudnessKey) private var loudnessLevelling = true
    @AppStorage(MusicInfoStore.enabledKey) private var onlineInfo = false

    var body: some View {
        Form {
            Section {
                Toggle("Loudness Levelling", isOn: $loudnessLevelling)
            } footer: {
                Text("Evens out volume between tracks, using the loudness analysis on your Plex server. An album played in order keeps its own quiet and loud songs. It applies from the next track.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Look Up Missing Artist and Album Details", isOn: $onlineInfo)
                    .onChange(of: onlineInfo) { _, on in
                        if !on { Task { await MusicInfoStore.shared.clear() } }
                    }
            } header: {
                Text("Music Details")
            } footer: {
                Text("When Plex has no biography, photo or cover, Rivulet looks for one on MusicBrainz, Wikipedia and TheAudioDB. The artist and album names, or their MusicBrainz IDs, are sent to them; nothing else is. Radio covers come from Apple's iTunes search, which is sent the song's name. Turning this off forgets what was found.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
