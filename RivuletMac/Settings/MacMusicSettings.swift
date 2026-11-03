// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacMusicSettings: View {
    @AppStorage(MacMusicPlayback.loudnessKey) private var loudnessLevelling = true
    @AppStorage(MusicInfoStore.enabledKey) private var onlineInfo = false
    @AppStorage(MacMusicCache.limitKey) private var cacheLimit = MacMusicCache.limitDefault
    @AppStorage(MacMusicPrecache.countKey) private var precacheCount = MacMusicPrecache.countDefault
    @AppStorage(MusicOutputRate.key) private var outputRate = MusicOutputRate.dontChange
    @State private var cacheSize: Int64 = 0
    @State private var deviceRates: [Int] = []

    var body: some View {
        Form {
            Section {
                Toggle("Loudness Levelling", isOn: $loudnessLevelling)
            } footer: {
                Text("Evens out volume between tracks, using the loudness analysis on your Plex server. An album played in order keeps its own quiet and loud songs. It applies from the next track.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sample Rate", selection: $outputRate) {
                    Text("Don't Change").tag(MusicOutputRate.dontChange)
                    Text("Match Each Track").tag(MusicOutputRate.matchTrack)
                    Divider()
                    ForEach(rateChoices, id: \.self) { Text(MusicOutputRate.label($0)).tag($0) }
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Match Each Track sets your Mac's sound output to each song's own sample rate, so it plays without conversion. It applies to every app, and the earlier rate comes back when music stops. Bluetooth and AirPlay keep their own rate, and songs at different rates have a short gap between them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep Downloaded Music", selection: $cacheLimit) {
                    Text("Off").tag(0)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("10 GB").tag(10240)
                    Text("20 GB").tag(20480)
                    Text("50 GB").tag(51200)
                    Text("100 GB").tag(102400)
                }
                .onChange(of: cacheLimit) {
                    Task {
                        await MacMusicCache.shared.trim()
                        await reloadCacheSize()
                    }
                }
                Picker("Download Ahead", selection: $precacheCount) {
                    Text("Off").tag(0)
                    Text("1 Song").tag(1)
                    Text("3 Songs").tag(3)
                    Text("5 Songs").tag(5)
                }
                LabeledContent("Downloaded Music") {
                    HStack {
                        Text(cacheSize, format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                await MacMusicCache.shared.clear()
                                await reloadCacheSize()
                            }
                        }
                    }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Songs you play and the ones coming up are kept on this Mac, so they start at once and survive a slow connection. Download Ahead fetches whole songs before they play, except on a metered connection or in Low Data Mode. Songs Plex converts are never kept.")
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
                Text("When Plex has no biography, photo, cover or links, Rivulet looks for them on MusicBrainz, Wikipedia and TheAudioDB. The artist and album names, or their MusicBrainz IDs, are sent to them; nothing else is. Radio covers come from Apple's iTunes search, which is sent the song's name. Turning this off forgets what was found.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            deviceRates = MacAudioOutput.supportedRates()
            await reloadCacheSize()
        }
    }

    /// The rates the output offers, plus a stored one it lacks, so the picker always shows its selection.
    private var rateChoices: [Int] {
        var rates = deviceRates
        if MusicOutputRate.fixedChoices.contains(outputRate), !rates.contains(outputRate) { rates.append(outputRate) }
        return rates.sorted()
    }

    private func reloadCacheSize() async {
        cacheSize = await MacMusicCache.shared.size()
    }
}
