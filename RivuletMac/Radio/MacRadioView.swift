// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Internet radio: one list of stations per saved playlist. Picking a station
/// plays it, and it keeps playing when another page opens.
struct MacRadioView: View {
    @Environment(MacRadioPlayback.self) private var radio
    @Environment(MacLivePlayback.self) private var live
    @Environment(MacMultiview.self) private var multiview
    @Environment(MacPlaybackController.self) private var vod
    private let store = RadioStore.shared
    @State private var adding = false
    @State private var removing: RadioStore.Playlist?

    var body: some View {
        Group {
            if store.playlists.isEmpty {
                ContentUnavailableView {
                    Label("No Radio Playlists", systemImage: "radio")
                } description: {
                    Text("Add an M3U playlist of internet radio stations.")
                } actions: {
                    Button("Add Playlist…") { adding = true }
                }
            } else {
                List {
                    ForEach(store.playlists) { playlist in
                        playlistSection(playlist)
                    }
                }
            }
        }
        .macScreen()
        .navigationTitle("Radio")
        .toolbar {
            if !store.playlists.isEmpty {
                Button("Add Playlist", systemImage: "plus") { adding = true }
            }
        }
        .task { await store.refreshMissing() }
        .sheet(isPresented: $adding) { MacRadioPlaylistForm() }
        .confirmationDialog("Remove \(removing?.name ?? "this playlist")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { store.remove(removing.id) }
                removing = nil
            }
        } message: {
            Text("Its stations leave the list. You can add it again later.")
        }
    }

    private func playlistSection(_ playlist: RadioStore.Playlist) -> some View {
        let stations = store.stations[playlist.id]
        let failure = store.failures[playlist.id]
        return Section {
            if let stations {
                ForEach(stations, id: \.streamURL) { station in
                    stationRow(station)
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.secondary)
            }
            if stations == nil, failure == nil {
                ProgressView()
            }
        } header: {
            HStack {
                Text(playlist.name)
                Spacer()
                Menu {
                    Button("Refresh") { Task { await store.refresh(playlist.id) } }
                    Divider()
                    Button("Remove…", role: .destructive) { removing = playlist }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func stationRow(_ station: M3UParser.ParsedChannel) -> some View {
        Button {
            play(station)
        } label: {
            HStack(spacing: 12) {
                MacChannelLogo(url: station.tvgLogo.flatMap(URL.init(string:)), placeholder: "radio")
                    .frame(width: 36, height: 24)
                Text(station.name)
                Spacer()
                if radio.station?.streamURL == station.streamURL {
                    indicator
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var indicator: some View {
        switch radio.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .playing, .paused, .idle:
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
        }
    }

    /// Radio takes the sound from Live TV and a Plex title, as Live TV does from them.
    private func play(_ station: M3UParser.ParsedChannel) {
        live.stop()
        multiview.stopAll()
        vod.close()
        radio.play(station)
    }
}

/// What is playing, shown over the bottom of the window. Only while a station plays.
struct MacRadioBar: View {
    @Environment(MacRadioPlayback.self) private var radio

    var body: some View {
        if let station = radio.station {
            HStack(spacing: 12) {
                MacChannelLogo(url: station.tvgLogo.flatMap(URL.init(string:)), placeholder: "radio")
                    .frame(width: 36, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(station.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(MacTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    radio.togglePlayPause()
                } label: {
                    Image(systemName: radio.state == .playing || radio.state == .loading ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(radio.state == .playing || radio.state == .loading ? "Pause" : "Play")
                Button {
                    radio.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
            .padding(12)
            .background(MacTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
    }

    private var statusText: String {
        switch radio.state {
        case .idle: ""
        case .loading: "Connecting…"
        case .playing: "Playing"
        case .paused: "Paused"
        case .failed(let message): message
        }
    }
}

/// Add a playlist by its address. The playlist must list at least one station.
private struct MacRadioPlaylistForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Radio Stations"))
                    TextField("Playlist URL", text: $address, prompt: Text("https://example.com/radio.m3u8"))
                } header: {
                    Text("Add a Radio Playlist")
                } footer: {
                    Text(failure ?? "An M3U playlist of internet radio stations.")
                        .foregroundStyle(failure == nil ? .secondary : .primary)
                }
            }
            .formStyle(.grouped)
            .disableAutocorrection(true)

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private func add() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await RadioStore.shared.add(name: name, address: address)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
