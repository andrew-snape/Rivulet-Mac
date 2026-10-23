// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// Internet radio: the single stations the user added, then one list of
/// stations per saved playlist, as a list or a grid. Picking a station plays
/// it, and it keeps playing when another page opens. Hidden stations step out
/// of the lists until Show Hidden is on. Select picks several stations to hide
/// or unhide at once; a click then selects rather than plays.
struct MacRadioView: View {
    /// The window's search field, which filters the stations by name.
    let query: String
    @Environment(MacRadioPlayback.self) private var radio
    @Environment(MacLivePlayback.self) private var live
    @Environment(MacMultiview.self) private var multiview
    @Environment(MacPlaybackController.self) private var vod
    private let store = RadioStore.shared
    @AppStorage("radioLayout") private var layoutRaw = "list"
    @AppStorage("radioSort") private var sortRaw = "playlist"
    @State private var showsHidden = false
    @State private var selecting = false
    @State private var selection: Set<URL> = []
    @State private var adding: MacRadioAddKind?
    @State private var removing: RadioStore.Playlist?

    private var isEmpty: Bool { store.playlists.isEmpty && store.ownStations.isEmpty }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView {
                    Label("No Radio Stations", systemImage: "radio")
                } description: {
                    Text("Add an M3U playlist of internet radio stations, or a single station's stream.")
                } actions: {
                    Button("Add Playlist…") { adding = .playlist }
                    Button("Add Station…") { adding = .station }
                }
            } else {
                let shown = sections
                Group {
                    if layoutRaw == "grid" {
                        grid(shown)
                    } else {
                        list(shown)
                    }
                }
                .overlay {
                    if !trimmedQuery.isEmpty, shown.isEmpty {
                        ContentUnavailableView.search(text: trimmedQuery)
                    }
                }
            }
        }
        .macScreen()
        .navigationTitle("Radio")
        .toolbar { if !isEmpty { toolbarControls } }
        .task { await store.refreshMissing() }
        .sheet(item: $adding) { MacRadioAddForm(kind: $0) }
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

    @ToolbarContentBuilder
    private var toolbarControls: some ToolbarContent {
        if selecting {
            ToolbarItem {
                Button("Select All") {
                    selection = Set(sections.flatMap { $0.stations ?? [] }.map(\.streamURL))
                }
            }
            ToolbarItem {
                Button("Hide") { hideSelection(true) }
                    .disabled(selection.isEmpty)
                    .help("Hide the selected stations")
            }
            if showsHidden {
                ToolbarItem {
                    Button("Unhide") { hideSelection(false) }
                        .disabled(selection.isEmpty)
                        .help("Unhide the selected stations")
                }
            }
        }
        ToolbarItem {
            Button(selecting ? "Done" : "Select") {
                selecting.toggle()
                selection = []
            }
            .help(selecting ? "Stop selecting stations" : "Select stations to hide or unhide")
        }
        ToolbarItem {
            Picker("View", selection: $layoutRaw) {
                Text("List").tag("list")
                Text("Grid").tag("grid")
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Picker("Sort", selection: $sortRaw) {
                Text("Playlist Order").tag("playlist")
                Text("Name").tag("name")
            }
        }
        if !store.hidden.isEmpty {
            ToolbarItem {
                Toggle(isOn: $showsHidden) {
                    Label("Show Hidden", systemImage: "eye")
                }
                .help(showsHidden ? "Leave out hidden stations" : "Show hidden stations")
            }
        }
        ToolbarItem {
            Menu {
                Button("Add Playlist…") { adding = .playlist }
                Button("Add Station…") { adding = .station }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private func hideSelection(_ isHidden: Bool) {
        store.setHidden(isHidden, streams: selection)
        selection = []
    }

    // MARK: - Sections

    /// The user's own stations first, then each playlist, with the search,
    /// hidden stations and the sort applied.
    private var sections: [MacRadioSection] {
        var all: [MacRadioSection] = []
        if !store.ownStations.isEmpty {
            all.append(section(id: "own", title: "My Stations", playlist: nil,
                               stations: store.ownStationChannels, failure: nil))
        }
        for playlist in store.playlists {
            all.append(section(id: playlist.id.uuidString, title: playlist.name, playlist: playlist,
                               stations: store.stations[playlist.id], failure: store.failures[playlist.id]))
        }
        // While searching, a section with no match steps out of the list.
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter { $0.stations?.isEmpty == false }
    }

    private func section(id: String, title: String, playlist: RadioStore.Playlist?,
                         stations: [M3UParser.ParsedChannel]?, failure: String?) -> MacRadioSection {
        guard let stations else {
            return MacRadioSection(id: id, title: title, playlist: playlist, stations: nil,
                                   failure: failure, allHidden: false)
        }
        let visible = showsHidden ? stations : stations.filter { !store.isHidden($0) }
        var shown = visible
        let text = trimmedQuery
        if !text.isEmpty {
            shown = shown.filter {
                $0.name.localizedCaseInsensitiveContains(text)
                    || $0.groupTitle?.localizedCaseInsensitiveContains(text) == true
            }
        }
        if sortRaw == "name" {
            shown.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return MacRadioSection(id: id, title: title, playlist: playlist, stations: shown,
                               failure: failure, allHidden: !stations.isEmpty && visible.isEmpty)
    }

    private func header(_ section: MacRadioSection) -> some View {
        HStack {
            Text(section.title)
            Spacer()
            if let playlist = section.playlist {
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

    /// The lines a section shows besides its stations: a failed fetch, the
    /// fetch under way, or every station hidden.
    @ViewBuilder
    private func notes(_ section: MacRadioSection) -> some View {
        if let failure = section.failure {
            Text(failure).foregroundStyle(.secondary)
        }
        if section.stations == nil, section.failure == nil {
            ProgressView()
        }
        if section.allHidden, trimmedQuery.isEmpty {
            Text("Every station here is hidden.").foregroundStyle(.secondary)
        }
    }

    // MARK: - List

    private func list(_ sections: [MacRadioSection]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.stations ?? [], id: \.streamURL) { station in
                        stationRow(station)
                            .opacity(store.isHidden(station) ? 0.45 : 1)
                            .contextMenu { menu(for: station) }
                    }
                    notes(section)
                } header: {
                    header(section)
                }
            }
        }
    }

    private func stationRow(_ station: M3UParser.ParsedChannel) -> some View {
        Button {
            tap(station)
        } label: {
            HStack(spacing: 12) {
                if selecting {
                    checkmark(station)
                }
                MacChannelLogo(url: station.tvgLogo.flatMap(URL.init(string:)), placeholder: "radio")
                    .frame(width: 36, height: 24)
                Text(station.name)
                Spacer()
                if let quality = quality(of: station) {
                    Text(quality)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if isCurrent(station) {
                    indicator
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private func grid(_ sections: [MacRadioSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        header(section).font(.title3.weight(.semibold))
                        notes(section)
                        if let stations = section.stations, !stations.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: MacTile.gap)],
                                      alignment: .leading, spacing: 20) {
                                ForEach(stations, id: \.streamURL) { station in
                                    stationTile(station)
                                        .opacity(store.isHidden(station) ? 0.45 : 1)
                                        .contextMenu { menu(for: station) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(MacTile.margin)
        }
    }

    private func stationTile(_ station: M3UParser.ParsedChannel) -> some View {
        let shape = RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous)
        return Button {
            tap(station)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                MacChannelLogo(url: station.tvgLogo.flatMap(URL.init(string:)), placeholder: "radio")
                    .font(.title)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
                    .background(MacTheme.surface, in: shape)
                    .overlay {
                        if isCurrent(station) { shape.strokeBorder(.tint, lineWidth: 2) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent(station) { indicator.padding(8) }
                    }
                    .overlay(alignment: .topLeading) {
                        if selecting { checkmark(station).padding(8) }
                    }
                Text(station.name)
                    .font(.callout)
                    .lineLimit(2)
                if let quality = quality(of: station) {
                    Text(quality)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stations

    @ViewBuilder
    private func menu(for station: M3UParser.ParsedChannel) -> some View {
        Button("Play") { play(station) }
        if store.isHidden(station) {
            Button("Unhide Station") { store.setHidden(false, station) }
        } else {
            Button("Hide Station") { store.setHidden(true, station) }
        }
        if store.isOwnStation(station) {
            Divider()
            Button("Edit Station…") { adding = .edit(station.streamURL) }
            Button("Remove Station", role: .destructive) { store.removeStation(station) }
        }
    }

    /// Plays the station, or while selecting, adds it to the selection or takes it out.
    private func tap(_ station: M3UParser.ParsedChannel) {
        guard selecting else { play(station); return }
        if selection.contains(station.streamURL) {
            selection.remove(station.streamURL)
        } else {
            selection.insert(station.streamURL)
        }
    }

    private func checkmark(_ station: M3UParser.ParsedChannel) -> some View {
        let isSelected = selection.contains(station.streamURL)
        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }

    private func isCurrent(_ station: M3UParser.ParsedChannel) -> Bool {
        radio.station?.streamURL == station.streamURL
    }

    /// What the station is playing at now, else what it was last heard at.
    private func quality(of station: M3UParser.ParsedChannel) -> String? {
        if isCurrent(station), let summary = radio.quality?.summary { return summary }
        return store.quality(of: station)
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

/// One heading on the Radio page: My Stations or a playlist.
private struct MacRadioSection: Identifiable {
    let id: String
    let title: String
    /// Nil for My Stations.
    let playlist: RadioStore.Playlist?
    /// Nil until the playlist is fetched.
    let stations: [M3UParser.ParsedChannel]?
    let failure: String?
    /// It lists stations, but every one is hidden.
    let allHidden: Bool
}

private enum MacRadioAddKind: Hashable, Identifiable {
    case playlist
    case station
    /// One of My Stations, by its stream address.
    case edit(URL)

    var id: Self { self }
}

/// The station along the bottom of the window, in the music bar's place and
/// laid out like it. Only while a station is loaded.
struct MacRadioBar: View {
    @Environment(MacRadioPlayback.self) private var radio
    @Environment(\.openWindow) private var openWindow
    @State private var showsDetails = false

    var body: some View {
        if let station = radio.station {
            HStack(spacing: 16) {
                Button { showsDetails.toggle() } label: {
                    HStack(spacing: 10) {
                        MacRadioArtwork(radio: radio, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(radio.song?.title ?? station.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(radio.statusText)
                                .font(.caption)
                                .foregroundStyle(radio.isFailed ? Color.orange : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 240, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Recent Songs")
                .popover(isPresented: $showsDetails, arrowEdge: .top) { MacRadioDetails() }

                Button { radio.togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .help(isPlaying ? "Pause" : "Play")
                .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    if let quality = radio.quality, let summary = quality.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(quality.sampleRateText.map { summary + " · " + $0 } ?? summary)
                    }
                    MacAirPlayButton(player: radio.routingPlayer, tint: .secondaryLabelColor)
                        .frame(width: 22, height: 22)
                        .help("AirPlay")
                    Button { openWindow(id: MacMiniPlayer.windowID) } label: {
                        Image(systemName: "pip.enter")
                    }
                    .buttonStyle(.borderless)
                    .help("Mini Player")
                    Button { radio.stop() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                }
                .frame(width: 240, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var isPlaying: Bool { radio.state == .playing || radio.state == .loading }
}

extension MacRadioPlayback {
    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Under the title: the artist and station while a song is on, else how the station is doing.
    var statusText: String {
        switch state {
        case .idle: ""
        case .loading: "Connecting…"
        case .playing:
            if let song {
                [song.artist, station?.name].compactMap { $0 }.joined(separator: " · ")
            } else {
                "Playing"
            }
        case .paused: "Paused"
        case .failed(let message): message
        }
    }
}

/// The song's cover when it has been found, else the station's logo.
struct MacRadioArtwork: View {
    let radio: MacRadioPlayback
    let size: CGFloat

    var body: some View {
        ZStack {
            if let cover = radio.cover {
                Image(nsImage: cover).resizable().scaledToFill()
            } else {
                MacChannelLogo(url: radio.station?.tvgLogo.flatMap(URL.init(string:)), placeholder: "radio")
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? MacTheme.cardCorner : 6, style: .continuous))
    }
}

/// From the radio bar: the station and song on, and the songs before it.
private struct MacRadioDetails: View {
    @Environment(MacRadioPlayback.self) private var radio

    var body: some View {
        VStack(spacing: 14) {
            MacRadioArtwork(radio: radio, size: 200)
            VStack(spacing: 3) {
                Text(radio.song?.title ?? radio.station?.name ?? "").font(.headline).lineLimit(2)
                if let artist = radio.song?.artist {
                    Text(artist).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(radio.song == nil ? "" : radio.station?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let quality = radio.quality, let summary = quality.summary {
                    Text(quality.sampleRateText.map { summary + " · " + $0 } ?? summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .multilineTextAlignment(.center)

            let earlier = Array(radio.recentSongs.dropFirst())
            if !earlier.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Earlier").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(earlier, id: \.text) { song in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(song.title).lineLimit(1)
                                    if let artist = song.artist {
                                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }
        }
        .padding(18)
        .frame(width: 260)
    }
}

/// Add a playlist or a single station by its address. A playlist must list
/// at least one station.
private struct MacRadioAddForm: View {
    let kind: MacRadioAddKind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var logo = ""
    @State private var isWorking = false
    @State private var isLookingUp = false
    /// The name last filled in from the stream, so a new address can replace it.
    @State private var filledName: String?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    switch kind {
                    case .playlist:
                        TextField("Name", text: $name, prompt: Text("Radio Stations"))
                        TextField("Playlist URL", text: $address, prompt: Text("https://example.com/radio.m3u8"))
                    case .station, .edit:
                        TextField("Name", text: $name, prompt: Text("Station Name"))
                        TextField("Stream URL", text: $address, prompt: Text("https://example.com/stream.mp3"))
                            .disabled(isEditing)
                        TextField("Logo URL", text: $logo, prompt: Text("Optional"))
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text(failure ?? footer)
                        .foregroundStyle(failure == nil ? .secondary : .primary)
                }
            }
            .formStyle(.grouped)
            .disableAutocorrection(true)

            HStack {
                if isWorking || isLookingUp {
                    ProgressView().controlSize(.small)
                    Text(isWorking ? "Checking…" : "Looking up the name…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
            .padding(16)
        }
        .frame(width: 480)
        .task(id: address) { await lookUpName() }
        .onAppear {
            guard case .edit(let url) = kind, let station = RadioStore.shared.ownStation(url) else { return }
            name = station.name
            address = url.absoluteString
            logo = station.logo?.absoluteString ?? ""
        }
    }

    private var isEditing: Bool {
        if case .edit = kind { return true }
        return false
    }

    private var title: String {
        switch kind {
        case .playlist: "Add a Radio Playlist"
        case .station: "Add a Radio Station"
        case .edit: "Edit Station"
        }
    }

    private var footer: String {
        switch kind {
        case .playlist: "An M3U playlist of internet radio stations."
        case .station: "One station's stream, such as a Shoutcast or Icecast address, or a .pls or .m3u link to it. "
            + "A stream carries no picture, so paste the address of the station's logo if you'd like one."
        case .edit: "A stream carries no picture, so paste the address of the station's logo if you'd like one."
        }
    }

    /// Fills in the name a station's server announces, once the address has
    /// stopped changing. Only into an empty field, or over a name filled in before.
    private func lookUpName() async {
        guard kind == .station, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        guard let found = await RadioStore.announcedName(of: address), !Task.isCancelled else { return }
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard typed.isEmpty || typed == filledName else { return }
        name = found
        filledName = found
    }

    private func add() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch kind {
                case .playlist: try await RadioStore.shared.add(name: name, address: address)
                case .station: try await RadioStore.shared.addStation(name: name, address: address, logo: logo)
                case .edit(let url): try RadioStore.shared.updateStation(url, name: name, logo: logo)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
