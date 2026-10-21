// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Actions

/// What a music tile or row offers.
enum MacMusicAction {
    case play, shuffle, playNext, addToQueue, radio
}

extension MacMusicPlayback {
    /// Plays, queues or starts radio from an artist, album, playlist or track.
    func perform(_ action: MacMusicAction, on item: PlexMetadata) {
        guard let plex else { return }
        if action == .radio, item.type == "track" {
            startRadio(from: item)
            return
        }
        Task {
            guard let tracks = try? await plex.tracks(of: item), !tracks.isEmpty else { return }
            switch action {
            case .play: play(tracks, isAlbum: item.type == "album")
            case .shuffle: play(tracks, shuffled: true)
            case .playNext: playNext(tracks)
            case .addToQueue: addToQueue(tracks)
            case .radio: if let seed = tracks.randomElement() { startRadio(from: seed) }
            }
        }
    }
}

/// Right-click menu for any music item.
struct MacMusicItemMenu: View {
    let item: PlexMetadata
    @Environment(MacMusicPlayback.self) private var music
    @Environment(\.plexActions) private var actions

    var body: some View {
        Button("Play", systemImage: "play.fill") { music.perform(.play, on: item) }
        if item.type != "track" {
            Button("Shuffle", systemImage: "shuffle") { music.perform(.shuffle, on: item) }
        }
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { music.perform(.playNext, on: item) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { music.perform(.addToQueue, on: item) }
        }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { music.perform(.radio, on: item) }
        if item.type == "track" || item.type == "album" {
            Section {
                if let album = item.albumStub {
                    Button("Go to Album", systemImage: "square.stack") { actions.open(album) }
                }
                if let artist = item.artistStub {
                    Button("Go to Artist", systemImage: "music.mic") { actions.open(artist) }
                }
            }
        }
    }
}

// MARK: - Artwork

/// Square music art (round for an artist), at the size it draws.
struct MacMusicArtwork: View {
    let item: PlexMetadata
    let size: CGFloat
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let pixels = max(1, Int((size * displayScale / 120).rounded(.up))) * 120
        MacPlexImage(url: plex.imageURL(path: item.squareArtPath, width: pixels, height: pixels))
            .overlay {
                if item.squareArtPath == nil {
                    Image(systemName: item.type == "artist" ? "music.mic" : "music.note")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(item.type == "artist"
                ? AnyShape(Circle())
                : AnyShape(RoundedRectangle(cornerRadius: size > 100 ? MacTheme.cardCorner : 6, style: .continuous)))
    }
}

// MARK: - Tiles

/// An artist, album or playlist in a grid or row.
struct MacMusicTile: View {
    let item: PlexMetadata
    var width: CGFloat = MacTile.poster

    private var caption: String? {
        switch item.type {
        case "album": [item.parentTitle, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case "playlist": item.leafCount.map { $0 == 1 ? "1 song" : "\($0) songs" }
        case "track": item.trackArtist
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: item.type == "artist" ? .center : .leading, spacing: 6) {
            MacMusicArtwork(item: item, size: width)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            Text(item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: item.type == "artist" ? .center : .leading)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

/// A tile that opens its page, or plays when it is a track.
struct MacMusicTileLink: View {
    let item: PlexMetadata
    var width: CGFloat = MacTile.poster
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        Group {
            if item.type == "track" {
                Button { music.play([item]) } label: { MacMusicTile(item: item, width: width) }
            } else {
                NavigationLink(value: item) { MacMusicTile(item: item, width: width) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { MacMusicItemMenu(item: item) }
    }
}

// MARK: - Library

/// A music library: Plex's own rows, then artists, albums and playlists.
struct MacMusicLibraryView: View {
    let library: PlexLibrary
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacMusicPlayback.self) private var music
    @AppStorage private var sortRaw: String
    @State private var kind: MacMusicKind = .artists
    @State private var hubs: [PlexHub] = []
    @State private var items: [PlexMetadata] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedKey: String?

    private static let pageSize = 120

    init(library: PlexLibrary) {
        self.library = library
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "macLibrarySort.\(library.key)")
    }

    private var sorts: [(LibrarySortOption, String)] {
        kind == .albums
            ? [(.titleAsc, "Title"), (.addedAtDesc, "Date Added"), (.releaseDateDesc, "Release Date")]
            : [(.titleAsc, "Title"), (.addedAtDesc, "Date Added")]
    }

    private var sort: LibrarySortOption {
        let chosen = LibrarySortOption(rawValue: sortRaw) ?? .titleAsc
        return sorts.contains { $0.0 == chosen } ? chosen : .titleAsc
    }

    private var queryKey: String { "\(library.key)|\(kind.rawValue)|\(sort.rawValue)|\(plex.sessionGeneration)" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(hubs) { hub in
                    MacShelfRow(items: hub.items) {
                        Text(hub.displayTitle).font(.title2.bold())
                    } tile: { item in
                        MacMusicTileLink(item: item)
                    }
                }
                Picker("Show", selection: $kind) {
                    ForEach(MacMusicKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, MacTile.margin)

                if items.isEmpty, let error {
                    MacPlexErrorView(title: "Couldn't Load Library", message: error) { await reload() }
                        .frame(maxWidth: .infinity)
                } else if items.isEmpty, !isLoading, loadedKey != nil {
                    ContentUnavailableView("Nothing Here", systemImage: library.icon)
                        .frame(maxWidth: .infinity)
                } else {
                    MacMusicGrid(items: items, loadMore: loadMore)
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle(library.title)
        .toolbar {
            ToolbarItemGroup {
                Button("Library Radio", systemImage: "dot.radiowaves.left.and.right") {
                    music.startLibraryRadio(library)
                }
                .help("Shuffle the whole library, without end")
                if kind != .playlists {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .help("Sort")
                }
            }
        }
        .task(id: library.key) {
            hubs = (try? await plex.musicHubs(library)) ?? []
        }
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            await reload()
        }
    }

    private func reload() async {
        let key = queryKey
        items = []
        total = nil
        isLoading = true
        defer { if key == queryKey { isLoading = false } }
        do {
            if kind == .playlists {
                let playlists = try await plex.audioPlaylists()
                guard key == queryKey else { return }
                items = playlists.uniqued()
                total = items.count
            } else {
                let page = try await plex.musicPage(library, kind: kind, sort: sort, start: 0, size: Self.pageSize)
                guard key == queryKey else { return }
                items = page.items.uniqued()
                total = page.totalSize
            }
            error = nil
            loadedKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            guard key == queryKey else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard kind != .playlists, !isLoading, let total, items.count < total else { return }
        let key = queryKey
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.musicPage(library, kind: kind, sort: sort, start: items.count, size: Self.pageSize),
                  key == queryKey else { return }
            items = (items + page.items).uniqued()
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }
}

/// Square tiles for artists, albums and playlists.
struct MacMusicGrid: View {
    let items: [PlexMetadata]
    var loadMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MacTile.poster, maximum: MacTile.poster + 40),
                                     spacing: MacTile.gap, alignment: .top)],
                  spacing: 22) {
            ForEach(items) { item in
                MacMusicTileLink(item: item, width: MacTile.poster)
                    .onAppear {
                        if item.id == items.last?.id { loadMore?() }
                    }
            }
        }
        .padding(.horizontal, MacTile.margin)
    }
}

// MARK: - Artist

/// An artist: Play, Shuffle and Radio, the popular tracks, then the albums.
struct MacMusicArtistView: View {
    let artist: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @State private var full: PlexMetadata?
    @State private var popular: [PlexMetadata] = []
    @State private var albums: [PlexMetadata] = []
    @State private var error: String?

    private var shown: PlexMetadata { full ?? artist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    MacMusicArtwork(item: shown, size: 180)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shown.displayTitle).font(.largeTitle.bold()).lineLimit(2)
                        if let genres = shown.Genre?.compactMap(\.tag).prefix(3), !genres.isEmpty {
                            Text(genres.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                        MacMusicPlayButtons(item: shown)
                    }
                }
                .padding(.horizontal, MacTile.margin)

                if !popular.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Popular").font(.title2.bold()).padding(.horizontal, MacTile.margin)
                        MacMusicTrackList(tracks: popular, showsArtwork: true)
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Albums").font(.title2.bold()).padding(.horizontal, MacTile.margin)
                        MacMusicGrid(items: albums)
                    }
                } else if let error {
                    MacPlexErrorView(title: "Couldn't Load Artist", message: error) { await load() }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(shown.displayTitle)
        .task(id: artist.ratingKey) { await load() }
    }

    private func load() async {
        do {
            let loaded = try await plex.metadata(for: artist)
            full = loaded
            albums = try await plex.albums(of: loaded)
            error = nil
            if let section = loaded.librarySectionID {
                popular = Array(((try? await plex.popularTracks(of: loaded, sectionKey: String(section))) ?? []).prefix(5))
            }
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Play, Shuffle and a menu with the rest.
struct MacMusicPlayButtons: View {
    let item: PlexMetadata
    @Environment(MacMusicPlayback.self) private var music

    var body: some View {
        HStack(spacing: 10) {
            Button { music.perform(.play, on: item) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            Button { music.perform(.shuffle, on: item) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            Button { music.perform(.radio, on: item) } label: {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .help("Play tracks like these, without end")
            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { music.perform(.playNext, on: item) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { music.perform(.addToQueue, on: item) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.large)
    }
}

// MARK: - Album and playlist

/// An album or playlist: its art, Play and Shuffle, then the tracks.
struct MacMusicAlbumView: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.plexActions) private var actions
    @State private var full: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []
    @State private var error: String?
    @State private var isLoading = true

    private var shown: PlexMetadata { full ?? item }
    private var isPlaylist: Bool { item.type == "playlist" }

    private var info: String {
        let minutes = tracks.compactMap(\.duration).reduce(0, +) / 60_000
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let length = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
        return [shown.year.map(String.init), tracks.isEmpty ? nil : count, minutes > 0 ? length : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 24) {
                    MacMusicArtwork(item: shown, size: 220)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isPlaylist ? "Playlist" : "Album")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(shown.displayTitle).font(.largeTitle.bold()).lineLimit(2)
                        if !isPlaylist, let artist = shown.artistStub {
                            Button(artist.displayTitle) { actions.open(artist) }
                                .buttonStyle(.plain)
                                .font(.title3)
                                .foregroundStyle(.tint)
                        }
                        Text(info).foregroundStyle(.secondary)
                        MacMusicPlayButtons(item: shown).padding(.top, 6)
                    }
                }
                .padding(.horizontal, MacTile.margin)

                if let error, tracks.isEmpty {
                    MacPlexErrorView(title: "Couldn't Load", message: error) { await load() }
                        .frame(maxWidth: .infinity)
                } else if isLoading, tracks.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    MacMusicTrackList(
                        tracks: tracks,
                        isAlbum: !isPlaylist,
                        showsArtwork: isPlaylist,
                        albumArtist: isPlaylist ? nil : shown.parentTitle
                    )
                }
                if let summary = shown.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(.horizontal, MacTile.margin)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(shown.displayTitle)
        .task(id: item.ratingKey) { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedTracks = plex.tracks(of: item)
            if !isPlaylist { full = try? await plex.metadata(for: item) }
            tracks = try await loadedTracks
            error = nil
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Tracks

/// Numbered tracks; an album with more than one disc gets a heading per disc.
/// Double-click a row, or its number, to play from there.
struct MacMusicTrackList: View {
    let tracks: [PlexMetadata]
    var isAlbum = false
    var showsArtwork = false
    /// Hidden on rows by the same artist.
    var albumArtist: String?
    @Environment(MacMusicPlayback.self) private var music

    private struct Row: Identifiable {
        let offset: Int
        let track: PlexMetadata
        var id: Int { offset }
    }

    private struct Disc: Identifiable {
        let number: Int
        let rows: [Row]
        var id: Int { number }
    }

    private var discs: [Disc] {
        let rows = tracks.enumerated().map { Row(offset: $0.offset, track: $0.element) }
        guard isAlbum else { return [Disc(number: 0, rows: rows)] }
        let grouped = Dictionary(grouping: rows) { $0.track.parentIndex ?? 1 }
        return grouped.keys.sorted().map { Disc(number: $0, rows: grouped[$0] ?? []) }
    }

    var body: some View {
        let discs = discs
        VStack(alignment: .leading, spacing: 0) {
            ForEach(discs) { disc in
                if discs.count > 1 {
                    Label("Disc \(disc.number)", systemImage: "opticaldisc")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .padding(.horizontal, MacTile.margin)
                }
                ForEach(disc.rows) { row in
                    MacMusicTrackRow(
                        track: row.track,
                        number: isAlbum ? row.track.index : row.offset + 1,
                        showsArtwork: showsArtwork,
                        showsArtist: row.track.trackArtist != albumArtist,
                        play: { music.play(tracks, from: row.offset, isAlbum: isAlbum) }
                    )
                }
            }
        }
        .padding(.horizontal, MacTile.margin - 10)
    }
}

struct MacMusicTrackRow: View {
    let track: PlexMetadata
    let number: Int?
    var showsArtwork = false
    var showsArtist = true
    let play: () -> Void
    @Environment(MacMusicPlayback.self) private var music
    @State private var hovering = false

    private var isCurrent: Bool { music.track?.ratingKey != nil && music.track?.ratingKey == track.ratingKey }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if hovering {
                    Button(action: play) { Image(systemName: "play.fill") }
                        .buttonStyle(.plain)
                        .help("Play")
                } else if isCurrent {
                    Image(systemName: music.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.tint)
                } else if let number {
                    Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 26)
            if showsArtwork {
                MacMusicArtwork(item: track, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                if showsArtist, let artist = track.trackArtist {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let time = track.trackTime {
                Text(time).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsArtwork ? 6 : 9)
        .background(hovering ? MacTheme.surface.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { MacMusicItemMenu(item: track) }
    }
}
