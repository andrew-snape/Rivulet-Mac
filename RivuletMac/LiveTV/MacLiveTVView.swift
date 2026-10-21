// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Observation
import SwiftUI

/// What the channel list shows.
enum MacChannelFilter: Hashable {
    case favorites
    case recent
    case all
    case group(String)
}

/// Live TV: the channel list on the left, the player on the right. Picking a
/// channel plays it in place; the arrow keys in the list change channel.
/// In full screen the list steps aside.
struct MacLiveTVView: View {
    let isFullScreen: Bool
    /// The window's search field: channel names and numbers, and the guide.
    let query: String
    @Environment(MacLivePlayback.self) private var playback
    @Environment(MacMultiview.self) private var multiview
    private let store = LiveTVDataStore.shared
    @AppStorage("macChannelFilter") private var filterRaw = "all"
    @AppStorage("macChannelSort") private var sortRaw = "provider"
    @State private var groups: [String] = []
    @AppStorage("macLiveTVLayout") private var layoutRaw = MacLiveTVLayout.channels.rawValue
    @State private var lineupRevision = 0
    @AppStorage("macLiveTVShowsList") private var showsList = true

    @State private var guideFocus = MacGuideFocus()
    @State private var jumpToken = 0

    /// The mini player's height in the guide layout; its width follows at 16:9.
    private static let bandHeight: CGFloat = 200

    /// The tvOS arrangement: details and the player across the top, the guide below.
    private var showsGuideLayout: Bool {
        layout == .guide && !isFullScreen && showsList
    }

    private var layout: MacLiveTVLayout {
        MacLiveTVLayout(rawValue: layoutRaw) ?? .channels
    }

    var body: some View {
        Group {
            if store.sources.isEmpty {
                MacNoSourcesView()
            } else if layout == .multiview {
                MacMultiviewView(lineup: lineup, open: openFromMultiview)
            } else if showsGuideLayout {
                guideLayout
            } else {
                HStack(spacing: 0) {
                    if !isFullScreen && showsList {
                        VStack(spacing: 0) {
                            filterBar
                            MacChannelList(channels: lineup, query: query, emptyText: emptyText)
                        }
                        .frame(width: 340)
                        Divider()
                    }
                    MacNowPlayingPane(showsDetails: !isFullScreen && showsList)
                }
            }
        }
        .macScreen()
        .navigationTitle("Live TV")
        .toolbar { if !store.sources.isEmpty && !isFullScreen { toolbarControls } }
        .task {
            await store.elevatePreloadPriority()
            await store.refreshIfStale()
        }
        .task {
            for await channels in Observations({ store.channels }) {
                groups = Array(Set(channels.compactMap(\.groupTitle).filter { !$0.isEmpty }))
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
        }
        .onChange(of: lineup.map(\.id), initial: true) {
            playback.lineup = lineup
            lineupRevision += 1
        }
        // Back to what is playing once a channel is picked.
        .onChange(of: playback.channel?.id) { guideFocus.clear() }
        .onChange(of: layoutRaw) { old, new in
            if new == MacLiveTVLayout.multiview.rawValue { enterMultiview() }
            if old == MacLiveTVLayout.multiview.rawValue { multiview.stopAll() }
        }
    }

    /// The channel playing becomes the first tile. The single player lets its
    /// tuner go first, so the same channel does not take two.
    private func enterMultiview() {
        guard let channel = playback.channel else { return }
        let released = playback.stop()
        Task {
            await released?.value
            multiview.add(channel)
        }
    }

    /// A tile taken to the single player, once the tiles' tuners are released.
    private func openFromMultiview(_ channel: UnifiedChannel) {
        let released = multiview.stopAll()
        layoutRaw = MacLiveTVLayout.channels.rawValue
        Task {
            for task in released { await task.value }
            playback.play(channel)
        }
    }

    private var guideLayout: some View {
        VStack(spacing: 0) {
            filterBar
            HStack(alignment: .top, spacing: 24) {
                MacGuideInfoBar(focus: guideFocus)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                MacLivePlayerPane(compact: true)
                    .frame(width: Self.bandHeight * 16 / 9, height: Self.bandHeight)
                    .clipShape(MacTheme.shape)
            }
            .padding(.horizontal, MacTile.margin)
            .padding(.bottom, 14)
            MacLiveEPGView(channels: lineup, query: query, lineupRevision: lineupRevision,
                           jumpToken: jumpToken, focus: guideFocus)
        }
        .macScreen()
    }

    /// Loading progress above the list; the search is the window's field.
    @ViewBuilder
    private var filterBar: some View {
        if store.isLoadingChannels || store.isLoadingEPG {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(store.isLoadingChannels ? "Loading channels" : "Loading guide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }

    @ToolbarContentBuilder
    private var toolbarControls: some ToolbarContent {
        ToolbarItem {
            Button {
                showsList.toggle()
            } label: {
                Label(showsList ? "Hide Channels" : "Show Channels", systemImage: "sidebar.squares.left")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .help(showsList ? "Hide the channel list" : "Show the channel list")
        }
        ToolbarItem {
            Picker("View", selection: $layoutRaw) {
                Text("Channels").tag(MacLiveTVLayout.channels.rawValue)
                Text("Guide").tag(MacLiveTVLayout.guide.rawValue)
                Text("Multiview").tag(MacLiveTVLayout.multiview.rawValue)
            }
            .pickerStyle(.segmented)
        }
        if layout == .guide {
            ToolbarItem {
                Button("Now") { jumpToken += 1 }
                    .help("Scroll the guide to the current time")
            }
        }
        ToolbarItem {
            Picker("Sort", selection: $sortRaw) {
                Text("Channel Number").tag("provider")
                Text("Name").tag("name")
            }
        }
        ToolbarItem {
            Picker("Show", selection: $filterRaw) {
                Text("Favourites").tag("favorites")
                Text("Recently Watched").tag("recent")
                Text("All Channels").tag("all")
                if !groups.isEmpty {
                    Divider()
                    ForEach(groups, id: \.self) { Text($0).tag("group:" + $0) }
                }
            }
        }
    }

    private var filter: MacChannelFilter {
        switch filterRaw {
        case "favorites": return .favorites
        case "recent": return .recent
        case let raw where raw.hasPrefix("group:"): return .group(String(raw.dropFirst(6)))
        default: return .all
        }
    }

    /// The channels the current filter lists, less the hidden ones, in the chosen order.
    private var lineup: [UnifiedChannel] {
        let listed: [UnifiedChannel]
        switch filter {
        case .favorites:
            listed = store.favorites(in: store.channels)
        case .recent:
            let byId = Dictionary(store.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            listed = store.recentChannelIds.compactMap { byId[$0] }
        case .all:
            listed = store.channels
        case .group(let group):
            listed = store.channels.filter { $0.groupTitle == group }
        }
        let visible = listed.filter { !store.isHidden($0) }
        // Favourites and Recently Watched keep their own order.
        guard sortRaw == "name", filter != .favorites, filter != .recent else { return visible }
        return visible.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var emptyText: String {
        switch filter {
        case .favorites: return "Channels you favourite appear here. Use the star in the player or the channel's menu."
        case .recent: return "Channels you watch appear here."
        case .all, .group: return store.isLoadingChannels ? "Loading channels…" : "No channels."
        }
    }
}

private enum MacLiveTVLayout: String {
    case channels
    case guide
    case multiview
}

// MARK: - Channel list

private struct MacChannelList: View {
    let channels: [UnifiedChannel]
    let query: String
    let emptyText: String
    @Environment(MacLivePlayback.self) private var playback
    private let store = LiveTVDataStore.shared

    var body: some View {
        // Once a minute is enough to move "now" along and redraw the progress bars.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let shown = filtered(at: context.date)
            List(selection: Binding(
                get: { playback.channel?.id },
                set: { id in
                    if let id, let channel = shown.first(where: { $0.id == id }) { playback.play(channel) }
                }
            )) {
                ForEach(shown) { channel in
                    MacChannelRow(channel: channel,
                                  programme: store.program(for: channel, at: context.date),
                                  now: context.date)
                        .tag(channel.id)
                        .contextMenu { menu(for: channel) }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Nothing Here", systemImage: "tv", description: Text(emptyText))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
    }

    private func filtered(at date: Date) -> [UnifiedChannel] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return channels }
        // Anything in the guide from now on, not only what is on now.
        return channels.filter { channel in
            channel.name.localizedCaseInsensitiveContains(text)
                || channel.channelNumber.map { String($0).hasPrefix(text) } == true
                || store.epg[channel.id]?.contains {
                    $0.endTime > date && $0.displayTitle.localizedCaseInsensitiveContains(text)
                } == true
        }
    }

    @ViewBuilder
    private func menu(for channel: UnifiedChannel) -> some View {
        Button("Play") { playback.play(channel) }
        let isFavorite = store.isFavorite(channel)
        Button(isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            store.toggleFavorite(channel)
        }
        Divider()
        Button("Hide Channel") { store.hide(channel) }
    }
}

private struct MacChannelRow: View {
    let channel: UnifiedChannel
    let programme: UnifiedProgram?
    let now: Date
    private let store = LiveTVDataStore.shared

    var body: some View {
        HStack(spacing: 10) {
            MacChannelLogo(url: channel.logoURL)
                .frame(width: 46, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(channel.numberAndName)
                        .font(.body.weight(.medium))
                    if store.isFavorite(channel) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                if let programme {
                    Text(programme.displayTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ProgressView(value: programme.progress(at: now))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Now playing

private struct MacNowPlayingPane: View {
    let showsDetails: Bool
    @Environment(MacLivePlayback.self) private var playback
    private let store = LiveTVDataStore.shared

    var body: some View {
        VStack(spacing: 0) {
            MacLivePlayerPane(compact: false)
            if showsDetails, let channel = playback.channel {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    MacProgrammeDetails(channel: channel, programme: store.program(for: channel, at: context.date))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MacTheme.columnFill)
                }
            }
        }
    }
}

/// The player, or a stand-in while the picture floats in its own window.
private struct MacLivePlayerPane: View {
    let compact: Bool
    @Environment(MacLivePlayback.self) private var playback
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if playback.isPoppedOut {
            ZStack {
                Color.black
                VStack(spacing: compact ? 6 : 12) {
                    Image(systemName: "pip").font(compact ? .title : .largeTitle)
                    Text("Playing in a separate window").font(compact ? .callout : .body)
                    Button("Bring Back") { dismissWindow(id: MacLivePlayback.popOutWindowID) }
                        .controlSize(compact ? .small : .regular)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        } else {
            MacPlayerView(playback: playback, player: playback.player, compact: compact)
        }
    }
}

/// What a programme is: the channel's logo, the title, channel and time, the
/// description, and what follows.
private struct MacProgrammeDetails: View {
    let channel: UnifiedChannel
    let programme: UnifiedProgram?
    private let store = LiveTVDataStore.shared

    var body: some View {
        let next = programme.flatMap { current in
            store.getPrograms(for: channel, startDate: current.endTime, endDate: current.endTime.addingTimeInterval(6 * 3600))
                .first { $0.startTime >= current.endTime }
        }
        HStack(alignment: .top, spacing: 16) {
            MacChannelLogo(url: channel.logoURL)
                .frame(width: 72, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(programme?.displayTitle ?? channel.name)
                    .font(.title2.weight(.semibold))
                if let programme {
                    HStack(spacing: 8) {
                        Text(channel.numberAndName)
                        Text(programme.dayAndTimeRange)
                        if let episode = programme.guideSubtitle ?? programme.episodeNumber {
                            Text(episode)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let description = programme.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
                if let next {
                    Text("Next: \(next.displayTitle) at \(next.startTime.formatted(.dateTime.hour().minute()))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Guide info bar

/// The programme the pointer last rested on in the guide. The guide only
/// writes it and the info bar only reads it, so hovering redraws the bar and
/// not the grid.
@Observable
final class MacGuideFocus {
    private(set) var channel: UnifiedChannel?
    private(set) var program: UnifiedProgram?

    func set(_ channel: UnifiedChannel, _ program: UnifiedProgram?) {
        guard self.channel?.id != channel.id || self.program?.id != program?.id else { return }
        self.channel = channel
        self.program = program
    }

    func clear() {
        channel = nil
        program = nil
    }
}

/// Top left of the guide layout, as on tvOS: details of the programme under
/// the pointer, else of what is playing.
private struct MacGuideInfoBar: View {
    let focus: MacGuideFocus
    @Environment(MacLivePlayback.self) private var playback
    private let store = LiveTVDataStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let channel = focus.channel ?? playback.channel {
                MacProgrammeDetails(
                    channel: channel,
                    programme: focus.program ?? store.program(for: channel, at: context.date)
                )
            } else {
                Text("Point at a programme for details. Click to watch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Empty state

private struct MacNoSourcesView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Live TV Sources", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Add an M3U playlist, a Dispatcharr server or your Plex server's tuners to start watching.")
        } actions: {
            SettingsLink {
                Text("Add a Source…")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
