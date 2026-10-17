// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// What the sidebar can list.
enum MacChannelFilter: Hashable {
    case favorites
    case recent
    case all
    case group(String)
}

/// The main window: filters in the sidebar, channels in the middle, the
/// player on the right. Picking a channel plays it in place; the arrow keys
/// in the list change channel.
struct MacRootView: View {
    @EnvironmentObject private var playback: MacLivePlayback
    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var filter: MacChannelFilter? = .all
    @State private var query = ""
    @State private var groups: [String] = []
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if store.sources.isEmpty {
                MacNoSourcesView()
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } content: {
                    MacChannelList(channels: lineup, query: query, emptyText: emptyText)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
                        .searchable(text: $query, placement: .sidebar, prompt: "Channels and Programmes")
                } detail: {
                    MacNowPlayingPane(showsDetails: columns != .detailOnly)
                }
            }
        }
        .task {
            await store.elevatePreloadPriority()
            await store.refreshIfStale()
        }
        .onReceive(store.$channels) { channels in
            groups = Array(Set(channels.compactMap(\.groupTitle).filter { !$0.isEmpty }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        .onChange(of: lineup.map(\.id), initial: true) { playback.lineup = lineup }
        // Full screen is for watching: the lists step aside, and come back on exit.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            withAnimation { columns = .detailOnly }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation { columns = .all }
        }
    }

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                Label("Favourites", systemImage: "star").tag(MacChannelFilter.favorites)
                Label("Recently Watched", systemImage: "clock").tag(MacChannelFilter.recent)
                Label("All Channels", systemImage: "square.grid.2x2").tag(MacChannelFilter.all)
            }
            if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups, id: \.self) { group in
                        Label(group, systemImage: "folder").tag(MacChannelFilter.group(group))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        .overlay(alignment: .bottom) {
            if store.isLoadingChannels || store.isLoadingEPG {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(store.isLoadingChannels ? "Loading channels" : "Loading guide")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
        }
    }

    /// The channels the current filter lists, in guide order.
    private var lineup: [UnifiedChannel] {
        switch filter ?? .all {
        case .favorites:
            return store.favorites(in: store.channels)
        case .recent:
            let byId = Dictionary(store.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return store.recentChannelIds.compactMap { byId[$0] }
        case .all:
            return store.channels
        case .group(let group):
            return store.channels.filter { $0.groupTitle == group }
        }
    }

    private var emptyText: String {
        switch filter ?? .all {
        case .favorites: return "Channels you favourite appear here. Use the star in the player or the channel's menu."
        case .recent: return "Channels you watch appear here."
        case .all, .group: return store.isLoadingChannels ? "Loading channels…" : "No channels."
        }
    }
}

// MARK: - Channel list

private struct MacChannelList: View {
    let channels: [UnifiedChannel]
    let query: String
    let emptyText: String
    @EnvironmentObject private var playback: MacLivePlayback
    @ObservedObject private var store = LiveTVDataStore.shared

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
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(text)
                || $0.channelNumber.map { String($0).hasPrefix(text) } == true
                || store.program(for: $0, at: date)?.title.localizedCaseInsensitiveContains(text) == true
        }
    }

    @ViewBuilder
    private func menu(for channel: UnifiedChannel) -> some View {
        Button("Play") { playback.play(channel) }
        let isFavorite = store.isFavorite(channel)
        Button(isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            store.toggleFavorite(channel)
        }
    }
}

private struct MacChannelRow: View {
    let channel: UnifiedChannel
    let programme: UnifiedProgram?
    let now: Date
    @ObservedObject private var store = LiveTVDataStore.shared

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
    @EnvironmentObject private var playback: MacLivePlayback
    @ObservedObject private var store = LiveTVDataStore.shared

    var body: some View {
        VStack(spacing: 0) {
            MacPlayerView(playback: playback, player: playback.player)
            if showsDetails, let channel = playback.channel {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    details(for: channel, at: context.date)
                }
            }
        }
        .navigationTitle(playback.channel?.name ?? "Rivulet")
    }

    private func details(for channel: UnifiedChannel, at date: Date) -> some View {
        let programme = store.program(for: channel, at: date)
        let next = programme.flatMap { current in
            store.getPrograms(for: channel, startDate: current.endTime, endDate: current.endTime.addingTimeInterval(6 * 3600))
                .first { $0.startTime >= current.endTime }
        }
        return HStack(alignment: .top, spacing: 16) {
            MacChannelLogo(url: channel.logoURL)
                .frame(width: 72, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(programme?.displayTitle ?? channel.name)
                    .font(.title2.weight(.semibold))
                if let programme {
                    HStack(spacing: 8) {
                        Text(channel.numberAndName)
                        Text(programme.timeRange)
                        if let episode = programme.subtitle ?? programme.episodeNumber {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }
}

// MARK: - Empty state

private struct MacNoSourcesView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Live TV Sources", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Add an M3U playlist or a Dispatcharr server to start watching.")
        } actions: {
            SettingsLink {
                Text("Add a Source…")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
