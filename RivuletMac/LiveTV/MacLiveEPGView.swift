// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// A scrollable programme grid alongside the Live TV player.
struct MacLiveEPGView: View {
    let channels: [UnifiedChannel]
    let query: String

    @EnvironmentObject private var playback: MacLivePlayback
    @ObservedObject private var store = LiveTVDataStore.shared

    private static let channelWidth: CGFloat = 170
    private static let hourWidth: CGFloat = 240
    private static let headerHeight: CGFloat = 38
    private static let rowHeight: CGFloat = 74

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TV Guide")
                    .font(.headline)
                Spacer()
                if store.isLoadingEPG {
                    ProgressView().controlSize(.small)
                }
                Button("Load 6 More Hours") {
                    Task { await store.extendEPG(byHours: 6) }
                }
                .disabled(store.isExtendingEPG || store.epgLoadedThrough == nil)
            }
            .padding(.horizontal, 10)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                grid(at: context.date)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func grid(at now: Date) -> some View {
        let start = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(-2 * 3600))?.start ?? now
        let end = max(store.epgLoadedThrough ?? now.addingTimeInterval(6 * 3600),
                      now.addingTimeInterval(6 * 3600))
        let duration = max(3600, end.timeIntervalSince(start))
        let timelineWidth = CGFloat(duration / 3600) * Self.hourWidth
        let hourCount = Int(ceil(duration / 3600))
        let visibleChannels = filteredChannels(start: start, end: end, now: now)
        let height = Self.headerHeight + CGFloat(visibleChannels.count) * Self.rowHeight

        if visibleChannels.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        timeHeader(start: start, hourCount: hourCount, timelineWidth: timelineWidth)
                        LazyVStack(spacing: 0) {
                            ForEach(visibleChannels) { channel in
                                channelRow(channel, start: start, end: end, now: now, timelineWidth: timelineWidth)
                            }
                        }
                    }

                    if now >= start, now < end {
                        Rectangle()
                            .fill(.red)
                            .frame(width: 2, height: height)
                            .offset(x: Self.channelWidth + CGFloat(now.timeIntervalSince(start) / 3600) * Self.hourWidth)
                            .accessibilityHidden(true)
                    }
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
                    Text(start.addingTimeInterval(Double(index) * 3600).formatted(.dateTime.hour().minute()))
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

    private func channelRow(
        _ channel: UnifiedChannel,
        start: Date,
        end: Date,
        now: Date,
        timelineWidth: CGFloat
    ) -> some View {
        let programs = store.getPrograms(for: channel, startDate: start, endDate: end)

        return HStack(spacing: 0) {
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
                        if store.isFavorite(channel) {
                            Label("Favourite", systemImage: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .labelStyle(.titleOnly)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: Self.channelWidth, height: Self.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Watch \(channel.name)")
            .contextMenu {
                Button("Play") { playback.play(channel) }
                Button(store.isFavorite(channel) ? "Remove from Favourites" : "Add to Favourites") {
                    store.toggleFavorite(channel)
                }
            }

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                ForEach(0..<Int(ceil(timelineWidth / Self.hourWidth)), id: \.self) { index in
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                        .frame(width: 1)
                        .offset(x: CGFloat(index) * Self.hourWidth)
                }

                if programs.isEmpty {
                    Text("No guide data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .frame(height: Self.rowHeight, alignment: .center)
                } else {
                    ForEach(programs) { program in
                        let clippedStart = max(program.startTime, start)
                        let clippedEnd = min(program.endTime, end)
                        let width = max(36, CGFloat(clippedEnd.timeIntervalSince(clippedStart) / 3600) * Self.hourWidth)
                        Button {
                            playback.play(channel)
                        } label: {
                            MacEPGProgramCell(program: program, now: now)
                                .frame(width: width, height: Self.rowHeight - 8)
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("\(program.displayTitle), \(program.timeRange). Watch \(channel.name)")
                        .contextMenu {
                            Button("Watch \(channel.name)") { playback.play(channel) }
                        }
                        .position(
                            x: CGFloat(clippedStart.timeIntervalSince(start) / 3600) * Self.hourWidth + width / 2,
                            y: Self.rowHeight / 2
                        )
                    }
                }
            }
            .frame(width: timelineWidth, height: Self.rowHeight)
            .overlay(alignment: .bottom) { Divider() }
        }
        .frame(height: Self.rowHeight)
    }

    private func filteredChannels(start: Date, end: Date, now: Date) -> [UnifiedChannel] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return channels }
        return channels.filter { channel in
            channel.name.localizedCaseInsensitiveContains(text)
                || channel.channelNumber.map { String($0).hasPrefix(text) } == true
                || store.getPrograms(for: channel, startDate: start, endDate: end)
                    .contains { $0.displayTitle.localizedCaseInsensitiveContains(text) }
                || store.program(for: channel, at: now)?.displayTitle.localizedCaseInsensitiveContains(text) == true
        }
    }
}

private struct MacEPGProgramCell: View {
    let program: UnifiedProgram
    let now: Date

    private var isCurrent: Bool { program.startTime <= now && program.endTime > now }
    private var isPast: Bool { program.endTime <= now }

    var body: some View {
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
                ProgressView(value: program.progress(at: now))
                    .controlSize(.mini)
                    .tint(.accentColor)
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
