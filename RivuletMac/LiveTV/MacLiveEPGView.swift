// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Observation
import SwiftUI

/// The programme grid, laid out like the iOS and tvOS guides: the channel
/// column and the time ruler stay put while the programmes scroll beneath
/// them, half-hour columns, a red line at the current time, and more hours
/// loading as you scroll right. It opens at the current half hour.
struct MacLiveEPGView: View {
    let channels: [UnifiedChannel]
    let query: String
    let lineupRevision: Int
    /// Bumped by the toolbar's Now button.
    let jumpToken: Int
    let focus: MacGuideFocus

    private let store = LiveTVDataStore.shared
    /// A debounced copy of the store's guide, so a burst of updates redraws once.
    @State private var epg: [String: [UnifiedProgram]]
    @State private var epgRevision = 0
    @State private var windowStart = MacEPGClock.floorToHalfHour(.now)
    @State private var now = Date.now
    @State private var position = ScrollPosition()
    @State private var scroll = MacEPGScrollState()
    @State private var nearEnd = false
    @State private var cachedSearchQuery = ""
    @State private var cachedProgramMatches = Set<String>()

    init(channels: [UnifiedChannel], query: String, lineupRevision: Int,
         jumpToken: Int, focus: MacGuideFocus) {
        self.channels = channels
        self.query = query
        self.lineupRevision = lineupRevision
        self.jumpToken = jumpToken
        self.focus = focus
        _epg = State(initialValue: LiveTVDataStore.shared.epg)
    }

    var body: some View {
        VStack(spacing: 0) {
            issueBanner
            content
        }
        .background(MacTheme.background)
        .environment(\.colorScheme, .dark)
        // Guide updates arrive in bursts; the wait lets one render cover them all.
        .task {
            for await _ in Observations({ store.epg }) {
                try? await Task.sleep(for: .milliseconds(150))
                epg = store.epg
                epgRevision += 1
            }
        }
        .onChange(of: jumpToken) { jumpToNow() }
        .task(id: searchKey) { await updateProgramMatches() }
        .task { await tickClock() }
        .task(id: MacEPGLoadKey(nearEnd: nearEnd, loadedThrough: store.epgLoadedThrough)) {
            guard nearEnd, let through = store.epgLoadedThrough,
                  through < now.addingTimeInterval(MacEPGMetrics.maxHoursAhead * 3600 - 60) else { return }
            await store.extendEPG(byHours: MacEPGMetrics.hoursPerLoad)
        }
    }

    // MARK: Issues

    /// A broken source would otherwise leave an empty guide that looks like a bug.
    @ViewBuilder
    private var issueBanner: some View {
        if !store.epgIssues.isEmpty {
            Label("Guide data unavailable for \(store.epgIssues.map(\.sourceName).joined(separator: ", "))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .help(store.epgIssues.map { "\($0.sourceName): \($0.reason)" }.joined(separator: "\n"))
                .padding(.horizontal, MacTile.margin)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        let visibleChannels = filteredChannels(programMatches: queryMatches)
        if visibleChannels.isEmpty {
            if !trimmedQuery.isEmpty, cachedSearchQuery != trimmedQuery {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "play.tv")
            } else {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        } else {
            grid(of: visibleChannels)
        }
    }

    @ViewBuilder
    private func grid(of visibleChannels: [UnifiedChannel]) -> some View {
        let end = windowEnd
        let minutes = max(30, end.timeIntervalSince(windowStart) / 60)
        let timelineWidth = CGFloat(minutes) * MacEPGMetrics.pointsPerMinute
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visibleChannels) { channel in
                        MacEPGChannelRow(
                            channel: channel,
                            schedule: epg[channel.id] ?? [],
                            isFavorite: store.isFavorite(channel),
                            toggleFavorite: { store.toggleFavorite(channel) },
                            windowStart: windowStart, windowEnd: end, now: now,
                            timelineWidth: timelineWidth, scroll: scroll, focus: focus
                        )
                    }
                } header: {
                    MacEPGRuler(
                        scroll: scroll, windowStart: windowStart, now: now,
                        columnCount: Int((minutes / 30).rounded(.up)), timelineWidth: timelineWidth
                    )
                }
            }
            .frame(width: MacEPGMetrics.channelWidth + timelineWidth, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { max(0, $0.contentOffset.x) }) { _, x in
            scroll.x = x
        }
        .onScrollGeometryChange(for: Bool.self, of: {
            $0.contentOffset.x + $0.containerSize.width
                > $0.contentSize.width - MacEPGMetrics.loadAheadMinutes * MacEPGMetrics.pointsPerMinute
        }) { _, near in
            nearEnd = near
        }
    }

    private func jumpToNow() {
        let current = MacEPGClock.floorToHalfHour(.now)
        if current != windowStart { windowStart = current }
        withAnimation { position.scrollTo(x: 0) }
    }

    /// The loaded guide, at least six hours from the window start and never past 72 hours out.
    private var windowEnd: Date {
        let minimum = windowStart.addingTimeInterval(Double(MacEPGMetrics.hoursPerLoad) * 3600)
        let ceiling = now.addingTimeInterval(MacEPGMetrics.maxHoursAhead * 3600)
        return max(minimum, min(store.epgLoadedThrough ?? minimum, ceiling))
    }

    private func tickClock() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            now = .now
        }
    }

    // MARK: Search

    private var searchKey: MacEPGSearchKey {
        MacEPGSearchKey(
            query: trimmedQuery, epgRevision: epgRevision,
            windowStart: windowStart, lineupRevision: lineupRevision
        )
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var queryMatches: Set<String> {
        cachedSearchQuery == trimmedQuery ? cachedProgramMatches : []
    }

    private func filteredChannels(programMatches: Set<String>) -> [UnifiedChannel] {
        let text = trimmedQuery
        guard !text.isEmpty else { return channels }
        return channels.filter { channel in
            channel.name.localizedCaseInsensitiveContains(text)
                || channel.channelNumber.map({ String($0).hasPrefix(text) }) == true
                || programMatches.contains(channel.id)
        }
    }

    private func updateProgramMatches() async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            cachedSearchQuery = text
            cachedProgramMatches = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let channels = self.channels
        let schedules = epg
        let start = windowStart
        let end = windowEnd
        let searchTask = Task.detached(priority: .userInitiated) {
            var matches = Set<String>()
            for channel in channels {
                guard !Task.isCancelled else { return matches }
                guard !channel.name.localizedCaseInsensitiveContains(text),
                      channel.channelNumber.map({ !String($0).hasPrefix(text) }) ?? true,
                      let programs = schedules[channel.id],
                      programs.contains(where: {
                          $0.endTime > start && $0.startTime < end
                              && $0.displayTitle.localizedCaseInsensitiveContains(text)
                      }) else { continue }
                matches.insert(channel.id)
            }
            return matches
        }
        let matches = await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
        guard !Task.isCancelled else { return }
        cachedSearchQuery = text
        cachedProgramMatches = matches
    }
}

// MARK: - Ruler

/// The pinned time ruler: half-hour columns, the day at the left edge, and a
/// dot where the now line meets it.
private struct MacEPGRuler: View {
    let scroll: MacEPGScrollState
    let windowStart: Date
    let now: Date
    let columnCount: Int
    let timelineWidth: CGFloat

    var body: some View {
        let columnWidth = 30 * MacEPGMetrics.pointsPerMinute
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { index in
                    Text(windowStart.addingTimeInterval(Double(index) * 30 * 60)
                        .formatted(.dateTime.hour().minute()))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacTheme.textSecondary)
                        .padding(.leading, 14)
                        .frame(width: columnWidth - MacTheme.gap, height: MacTheme.boxHeight,
                               alignment: .leading)
                        .background(MacTheme.columnFill, in: MacTheme.shape)
                        .frame(width: columnWidth, height: MacEPGMetrics.headerHeight, alignment: .leading)
                }
            }
            .padding(.leading, MacEPGMetrics.channelWidth)

            if now >= windowStart {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .offset(x: MacEPGMetrics.nowX(now, from: windowStart) - 5,
                            y: MacEPGMetrics.headerHeight - 10)
                    .accessibilityHidden(true)
            }

            MacEPGCorner(scroll: scroll, windowStart: windowStart)
        }
        .frame(width: MacEPGMetrics.channelWidth + timelineWidth, height: MacEPGMetrics.headerHeight,
               alignment: .topLeading)
        .background(MacTheme.background)
    }
}

/// The day at the left edge of the guide, pinned over the channel column.
private struct MacEPGCorner: View {
    let scroll: MacEPGScrollState
    let windowStart: Date

    var body: some View {
        let leftEdge = windowStart.addingTimeInterval(Double(scroll.x / MacEPGMetrics.pointsPerMinute) * 60)
        Text(Calendar.current.isDateInToday(leftEdge)
            ? "Today"
            : leftEdge.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            .font(.callout.weight(.semibold))
            .foregroundStyle(MacTheme.textSecondary)
            .frame(width: MacEPGMetrics.channelWidth - MacTheme.gap, height: MacTheme.boxHeight)
            .background(MacTheme.columnFill, in: MacTheme.shape)
            .frame(width: MacEPGMetrics.channelWidth, height: MacEPGMetrics.headerHeight, alignment: .leading)
            .background(MacTheme.background)
            .offset(x: scroll.x)
    }
}

// MARK: - Rows

private struct MacEPGChannelRow: View {
    let channel: UnifiedChannel
    let schedule: [UnifiedProgram]
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let timelineWidth: CGFloat
    let scroll: MacEPGScrollState
    let focus: MacGuideFocus
    @Environment(MacLivePlayback.self) private var playback

    private struct Span: Identifiable {
        let id: String
        let program: UnifiedProgram?
        let minX: CGFloat
        let width: CGFloat
    }

    /// The programmes inside the window, or one block across it when the channel has no guide data.
    private var spans: [Span] {
        let visible = schedule.compactMap { program -> Span? in
            guard program.endTime > windowStart, program.startTime < windowEnd,
                  program.endTime > program.startTime else { return nil }
            let from = max(program.startTime, windowStart)
            let to = min(program.endTime, windowEnd)
            return Span(
                id: program.id, program: program,
                minX: MacEPGMetrics.channelWidth
                    + CGFloat(from.timeIntervalSince(windowStart) / 60) * MacEPGMetrics.pointsPerMinute,
                width: CGFloat(to.timeIntervalSince(from) / 60) * MacEPGMetrics.pointsPerMinute
            )
        }
        guard visible.isEmpty else { return visible }
        return [Span(id: "\(channel.id):empty", program: nil,
                     minX: MacEPGMetrics.channelWidth, width: timelineWidth)]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(spans) { span in
                MacEPGProgramCell(
                    program: span.program, channel: channel, now: now,
                    minX: span.minX + MacTheme.gap / 2, width: span.width - MacTheme.gap,
                    scroll: scroll, focus: focus, play: { playback.play(channel) }
                )
                .frame(width: max(span.width - MacTheme.gap, 2),
                       height: MacEPGMetrics.rowHeight - MacTheme.gap)
                .offset(x: span.minX + MacTheme.gap / 2, y: MacTheme.gap / 2)
            }

            // Drawn per row, under the channel column, so it never crosses it.
            if now >= windowStart, now < windowEnd {
                Rectangle()
                    .fill(.red)
                    .frame(width: 2, height: MacEPGMetrics.rowHeight)
                    .offset(x: MacEPGMetrics.nowX(now, from: windowStart) - 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            MacEPGChannelCell(
                channel: channel, isFavorite: isFavorite,
                toggleFavorite: toggleFavorite, scroll: scroll, focus: focus
            )
        }
        .frame(width: MacEPGMetrics.channelWidth + timelineWidth, height: MacEPGMetrics.rowHeight,
               alignment: .topLeading)
    }
}

/// The channel box, pinned to the left edge while the programmes scroll under it.
private struct MacEPGChannelCell: View {
    let channel: UnifiedChannel
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let scroll: MacEPGScrollState
    let focus: MacGuideFocus
    @Environment(MacLivePlayback.self) private var playback

    var body: some View {
        let isPlaying = playback.channel?.id == channel.id
        Button {
            playback.play(channel)
        } label: {
            HStack(spacing: 8) {
                MacChannelLogo(url: channel.logoURL)
                    .frame(width: 40, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        if let number = channel.channelNumber {
                            Text(String(number))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(MacTheme.textSecondary)
                        }
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: MacEPGMetrics.channelWidth - MacTheme.gap,
                   height: MacEPGMetrics.rowHeight - MacTheme.gap, alignment: .leading)
            .background(MacTheme.columnFill, in: MacTheme.shape)
            .overlay {
                if isPlaying {
                    MacTheme.shape.strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(width: MacEPGMetrics.channelWidth, height: MacEPGMetrics.rowHeight)
            .background(MacTheme.background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { focus.set(channel, nil) } }
        .help("Watch \(channel.name)")
        .contextMenu {
            Button("Play") { playback.play(channel) }
            Button(isFavorite ? "Remove from Favourites" : "Add to Favourites", action: toggleFavorite)
        }
        .offset(x: scroll.x)
    }
}

// MARK: - Programme cell

/// One programme. Click plays what is on now; a past or future programme opens its details.
/// The text slides right past the channel column so a long programme's title stays readable.
private struct MacEPGProgramCell: View {
    let program: UnifiedProgram?
    let channel: UnifiedChannel
    let now: Date
    /// The cell's leading edge in the scrolled content, and its width.
    let minX: CGFloat
    let width: CGFloat
    let scroll: MacEPGScrollState
    let focus: MacGuideFocus
    let play: () -> Void
    @State private var showsDetails = false

    private var isCurrent: Bool {
        program.map { $0.startTime <= now && $0.endTime > now } ?? true
    }

    private var isPast: Bool {
        program.map { $0.endTime <= now } ?? false
    }

    var body: some View {
        Button(action: activate) {
            ZStack(alignment: .bottomLeading) {
                MacEPGCellLabel(program: program, detail: detail, minX: minX, width: width, scroll: scroll)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if isCurrent, let program {
                    ProgressView(value: program.progress(at: now))
                        .controlSize(.mini)
                        .tint(.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isCurrent ? MacTheme.surface : MacTheme.columnFill, in: MacTheme.shape)
            .opacity(isPast ? 0.6 : 1)
            .contentShape(MacTheme.shape)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { focus.set(channel, program) } }
        .help(program.map { "\($0.displayTitle), \($0.timeRange)" } ?? channel.name)
        .contextMenu {
            Button("Watch \(channel.name)", action: play)
            if program != nil {
                Button("Details") { showsDetails = true }
            }
        }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            if let program {
                MacEPGProgramDetails(
                    channel: channel, program: program, isCurrent: isCurrent,
                    watch: { showsDetails = false; play() }
                )
            }
        }
    }

    /// The episode title when there is one, else the time.
    private var detail: String? {
        guard let program else { return nil }
        return program.guideSubtitle ?? program.timeRange
    }

    private func activate() {
        if program != nil, !isCurrent {
            showsDetails = true
        } else {
            play()
        }
    }
}

private struct MacEPGProgramDetails: View {
    let channel: UnifiedChannel
    let program: UnifiedProgram
    let isCurrent: Bool
    let watch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(program.displayTitle)
                .font(.headline)
            if let subtitle = program.guideSubtitle {
                Text(subtitle)
                    .font(.subheadline)
            }
            Text(when)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let description = program.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .lineLimit(8)
                    .padding(.top, 2)
            }
            Button(isCurrent ? "Watch" : "Watch \(channel.name)", action: watch)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var when: String {
        "\(channel.numberAndName) · \(program.dayAndTimeRange)"
    }
}

/// A programme's title lines, shifted right of the pinned channel column while
/// the cell scrolls under it. Its own view so the scroll offset invalidates this
/// and not the whole cell.
private struct MacEPGCellLabel: View {
    let program: UnifiedProgram?
    let detail: String?
    let minX: CGFloat
    let width: CGFloat
    let scroll: MacEPGScrollState

    var body: some View {
        let hiddenLeading = min(max(0, scroll.x + MacEPGMetrics.channelWidth - minX), max(0, width - 90))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(program?.displayTitle ?? "No guide data")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let program {
                    if program.isLive {
                        Circle().fill(.red).frame(width: 6, height: 6)
                            .accessibilityLabel("Live")
                    } else if program.isNew {
                        Text("NEW").font(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
                    }
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MacTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, hiddenLeading)
    }
}

// MARK: - Support

/// The guide's horizontal scroll offset. Only the views that pin to the left
/// edge read it, so a scroll redraws those and not the whole grid.
@Observable
private final class MacEPGScrollState {
    var x: CGFloat = 0
}

private struct MacEPGLoadKey: Equatable {
    let nearEnd: Bool
    let loadedThrough: Date?
}

private struct MacEPGSearchKey: Equatable {
    let query: String
    let epgRevision: Int
    let windowStart: Date
    let lineupRevision: Int
}

private enum MacEPGClock {
    static func floorToHalfHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 1800).rounded(.down) * 1800)
    }
}

private enum MacEPGMetrics {
    static let channelWidth: CGFloat = 168
    static let rowHeight: CGFloat = 64
    static let headerHeight: CGFloat = 44
    /// 330 pt an hour: about two and a half hours show beside the player.
    static let pointsPerMinute: CGFloat = 5.5
    static let hoursPerLoad = 6
    static let maxHoursAhead: TimeInterval = 72
    /// Load more once the right edge is this close to the end of the loaded guide.
    static let loadAheadMinutes: CGFloat = 90

    /// Where a time sits in the scrolled content, past the channel column.
    static func nowX(_ date: Date, from start: Date) -> CGFloat {
        channelWidth + CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }
}
