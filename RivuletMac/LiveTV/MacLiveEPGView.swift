// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// A scrollable programme grid alongside the Live TV player.
struct MacLiveEPGView: View {
    let channels: [UnifiedChannel]
    let query: String
    let lineupRevision: Int

    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var epgRevision = 0
    @State private var searchWindowHour = 0
    @State private var guideNow = Date.now
    @State private var cachedSearchQuery = ""
    @State private var cachedProgramMatches = Set<String>()
    @State private var scheduleSignatures: [String: Int] = [:]
    @State private var rowScheduleRevisions: [String: Int] = [:]

    fileprivate static let channelWidth: CGFloat = 170
    fileprivate static let hourWidth: CGFloat = 240
    fileprivate static let headerHeight: CGFloat = 38
    fileprivate static let rowHeight: CGFloat = 74
    fileprivate static let secondsPerHour: TimeInterval = 3600
    fileprivate static let secondsPerMinute: TimeInterval = 60
    fileprivate static let guideHoursPerLoad = 6
    fileprivate static let hoursBeforeNow = 2

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TV Guide")
                    .font(.headline)
                Spacer()
                if store.isLoadingEPG {
                    ProgressView().controlSize(.small)
                }
                Button("Load \(Self.guideHoursPerLoad) More Hours") {
                    Task { await store.extendEPG(byHours: Self.guideHoursPerLoad) }
                }
                .disabled(store.isExtendingEPG || store.epgLoadedThrough == nil)
            }
            .padding(.horizontal, 10)

            grid(at: guideNow)
        }
        .padding(.vertical, 8)
        .onReceive(store.$epg.debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { schedules in
            updateScheduleRevisions(schedules)
        }
        .task(id: searchKey) { await updateProgramMatches() }
        .task { await monitorSearchWindowHour() }
    }

    private var searchKey: MacEPGSearchKey {
        MacEPGSearchKey(
            query: trimmedQuery, epgRevision: epgRevision,
            windowHour: searchWindowHour,
            lineupRevision: lineupRevision
        )
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func grid(at now: Date) -> some View {
        let window = guideWindow(at: now)
        let start = window.start
        let end = window.end
        let duration = max(Self.secondsPerHour, end.timeIntervalSince(start))
        let timelineWidth = CGFloat(duration / Self.secondsPerHour) * Self.hourWidth
        let hourCount = Int(ceil(duration / Self.secondsPerHour))
        let result = queryMatches
        let visibleChannels = filteredChannels(programMatches: result)
        let height = Self.headerHeight + CGFloat(visibleChannels.count) * Self.rowHeight

        if visibleChannels.isEmpty {
            if !trimmedQuery.isEmpty, cachedSearchQuery != trimmedQuery {
                ProgressView()
            } else if trimmedQuery.isEmpty {
                ContentUnavailableView("No Channels", systemImage: "play.tv")
            } else {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        timeHeader(start: start, hourCount: hourCount, timelineWidth: timelineWidth)
                        LazyVStack(spacing: 0) {
                            ForEach(visibleChannels) { channel in
                                MacEPGChannelRow(
                                    channel: channel,
                                    schedule: store.epg[channel.id] ?? [],
                                    isFavorite: store.isFavorite(channel),
                                    toggleFavorite: { store.toggleFavorite(channel) },
                                    start: start, end: end, now: now,
                                    timelineWidth: timelineWidth,
                                    scheduleRevision: rowScheduleRevisions[channel.id] ?? 0
                                )
                            }
                        }
                    }

                    MacEPGNowIndicator(
                        start: start, end: end, height: height, timelineWidth: timelineWidth,
                        channelWidth: Self.channelWidth, hourWidth: Self.hourWidth
                    )
                }
                .frame(width: Self.channelWidth + timelineWidth, height: height, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func timeHeader(start: Date, hourCount: Int, timelineWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Channel")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.channelWidth, height: Self.headerHeight, alignment: .leading)
                .padding(.leading, 10)

            HStack(spacing: 0) {
                ForEach(0..<hourCount, id: \.self) { index in
                    let width = min(Self.hourWidth, timelineWidth - CGFloat(index) * Self.hourWidth)
                    Text(start.addingTimeInterval(Double(index) * Self.secondsPerHour)
                        .formatted(.dateTime.hour().minute()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: width, height: Self.headerHeight, alignment: .leading)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1)
                        }
                }
            }
        }
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
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
        let window = guideWindow(at: .now)
        let channels = self.channels
        let schedules = store.epg
        let start = window.start
        let end = window.end
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

    private func updateScheduleRevisions(_ schedules: [String: [UnifiedProgram]]) {
        var signatures = scheduleSignatures
        var revisions = rowScheduleRevisions
        for channelID in Set(signatures.keys).union(schedules.keys) {
            let signature = schedules[channelID]?.hashValue ?? 0
            guard signatures[channelID] != signature else { continue }
            signatures[channelID] = signature
            revisions[channelID, default: 0] += 1
        }
        scheduleSignatures = signatures
        rowScheduleRevisions = revisions
        epgRevision += 1
    }

    private func monitorSearchWindowHour() async {
        while !Task.isCancelled {
            let now = Date.now
            let hour = Int(now.timeIntervalSince1970 / Self.secondsPerHour)
            if searchWindowHour != hour {
                searchWindowHour = hour
                guideNow = now
            }
            let nextHour = Date(timeIntervalSince1970: Double(hour + 1) * Self.secondsPerHour)
            do {
                try await Task.sleep(for: .seconds(max(0.1, nextHour.timeIntervalSince(now))))
            } catch {
                return
            }
        }
    }

    /// Keeps two past hours visible and rounds the six-hour future edge to an hour boundary.
    private func guideWindow(at now: Date) -> (start: Date, end: Date) {
        let start = Calendar.current.dateInterval(
            of: .hour, for: now.addingTimeInterval(-Double(Self.hoursBeforeNow) * Self.secondsPerHour)
        )?.start ?? now
        let initialEnd = now.addingTimeInterval(Double(Self.guideHoursPerLoad) * Self.secondsPerHour)
        let roundedInitialEnd = Calendar.current.dateInterval(of: .hour, for: initialEnd)?.end ?? initialEnd
        let end = max(store.epgLoadedThrough ?? roundedInitialEnd, roundedInitialEnd)
        return (start, end)
    }
}

private struct MacEPGChannelRow: View {
    let channel: UnifiedChannel
    let schedule: [UnifiedProgram]
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let start: Date
    let end: Date
    let now: Date
    let timelineWidth: CGFloat
    let scheduleRevision: Int
    @EnvironmentObject private var playback: MacLivePlayback
    @EnvironmentObject private var playback: MacLivePlayback
    @State private var programs: [UnifiedProgram]?

    private var scheduleKey: MacEPGRowScheduleKey {
        MacEPGRowScheduleKey(
            channelID: channel.id, scheduleRevision: scheduleRevision
        )
    }

    private var visiblePrograms: [UnifiedProgram]? {
        programs?.filter {
            $0.endTime > start && $0.startTime < end && $0.endTime > $0.startTime
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                playback.play(channel)
            } label: {
                HStack(spacing: 8) {
                    MacChannelLogo(url: channel.logoURL)
                        .frame(width: 42, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.numberAndName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: MacLiveEPGView.channelWidth, height: MacLiveEPGView.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Watch \(channel.name)")
            .contextMenu {
                Button("Play") { playback.play(channel) }
                Button(isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                    toggleFavorite()
                }
            }

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                ForEach(0..<Int(ceil(timelineWidth / MacLiveEPGView.hourWidth)), id: \.self) { index in
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                        .frame(width: 1)
                        .offset(x: CGFloat(index) * MacLiveEPGView.hourWidth)
                }

                if let visiblePrograms {
                    if visiblePrograms.isEmpty {
                        Text("No guide data")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 8)
                            .frame(height: MacLiveEPGView.rowHeight, alignment: .center)
                    } else {
                        ForEach(visiblePrograms) { program in
                            let clippedStart = max(program.startTime, start)
                            let clippedEnd = min(program.endTime, end)
                            let width = CGFloat(clippedEnd.timeIntervalSince(clippedStart)
                                                / MacLiveEPGView.secondsPerHour)
                                * MacLiveEPGView.hourWidth
                            Button {
                                playback.play(channel)
                            } label: {
                                MacEPGProgramCell(program: program, now: now)
                                    .frame(width: width, height: MacLiveEPGView.rowHeight - 8)
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("\(program.displayTitle), \(program.timeRange). Watch \(channel.name)")
                            .contextMenu {
                                Button("Watch \(channel.name)") { playback.play(channel) }
                            }
                            .position(
                                x: CGFloat(clippedStart.timeIntervalSince(start) / MacLiveEPGView.secondsPerHour)
                                    * MacLiveEPGView.hourWidth
                                    + width / 2,
                                y: MacLiveEPGView.rowHeight / 2
                            )
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: MacLiveEPGView.rowHeight)
                }
            }
            .frame(width: timelineWidth, height: MacLiveEPGView.rowHeight)
            .overlay(alignment: .bottom) { Divider() }
        }
        .frame(height: MacLiveEPGView.rowHeight)
        .task(id: scheduleKey) {
            programs = schedule
        }
    }
}

private struct MacEPGRowScheduleKey: Equatable {
    let channelID: String
    let scheduleRevision: Int
}

private struct MacEPGSearchKey: Equatable {
    let query: String
    let epgRevision: Int
    let windowHour: Int
    let lineupRevision: Int
}

private struct MacEPGProgramCell: View {
    let program: UnifiedProgram
    let now: Date

    var body: some View {
        let isCurrent = program.startTime <= now && program.endTime > now
        let isPast = program.endTime <= now
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(program.displayTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if program.isLive {
                    Circle().fill(.red).frame(width: 6, height: 6)
                        .accessibilityLabel("Live")
                } else if program.isNew {
                    Text("NEW").font(.system(size: 8, weight: .bold)).foregroundStyle(.tint)
                }
            }
            Text(program.timeRange)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isCurrent {
                TimelineView(.periodic(from: .now, by: MacLiveEPGView.secondsPerMinute)) { context in
                    ProgressView(value: program.progress(at: context.date))
                        .controlSize(.mini)
                        .tint(.accentColor)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            isCurrent ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .opacity(isPast ? 0.62 : 1)
    }
}

private struct MacEPGNowIndicator: View {
    let start: Date
    let end: Date
    let height: CGFloat
    let timelineWidth: CGFloat
    let channelWidth: CGFloat
    let hourWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: MacLiveEPGView.secondsPerMinute)) { context in
            Group {
                if context.date >= start, context.date < end {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 2, height: height)
                        .offset(
                            x: channelWidth
                                + CGFloat(context.date.timeIntervalSince(start) / MacLiveEPGView.secondsPerHour)
                                * hourWidth
                        )
                        .accessibilityHidden(true)
                }
            }
            .frame(width: channelWidth + timelineWidth, height: height, alignment: .topLeading)
        }
    }
}
