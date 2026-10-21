// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The panes that open above the player's controls, after tvOS's info pills.
enum MacPlayerPane: String, CaseIterable, Identifiable {
    case info = "Info"
    case chapters = "Chapters"
    case details = "Details"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .info: "info.circle"
        case .chapters: "list.bullet.rectangle"
        case .details: "chart.bar.doc.horizontal"
        }
    }
}

// MARK: - Card

/// A glass card holding the open pane, with tabs for the others.
struct MacPlayerPaneCard: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    /// The item with its chapters and cast, once fetched.
    let detail: PlexMetadata?
    let chapters: [MacChapter]
    @Binding var pane: MacPlayerPane?
    @State private var tab: MacPlayerPane = .info

    private var tabs: [MacPlayerPane] {
        MacPlayerPane.allCases.filter { $0 != .chapters || !chapters.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Pane", selection: $tab) {
                    ForEach(tabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { pane = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
            }
            switch tab {
            case .info: MacInfoPane(session: session, player: player, detail: detail)
            case .chapters: MacChaptersPane(player: player, chapters: chapters)
            case .details: MacDetailsPane(session: session, player: player, detail: detail)
            }
        }
        .padding(16)
        .frame(maxWidth: 980, minHeight: 190, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { tab = pane ?? .info }
        .onChange(of: pane) { _, new in if let new { tab = new } }
        .onChange(of: chapters.isEmpty) { _, empty in if empty, tab == .chapters { tab = .info } }
    }
}

// MARK: - Info

private struct MacInfoPane: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    let detail: PlexMetadata?
    @Environment(MacPlexSession.self) private var plex

    private var item: PlexMetadata { detail ?? session.request.item }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MacPlexArtwork(item: item, kind: .poster, width: 110, aspectRatio: 2.0 / 3.0)
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if item.type == "episode" {
                    Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(metaLine).foregroundStyle(.secondary)
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                    }
                }
                .font(.caption)
                if let summary = item.summary, !summary.isEmpty {
                    ScrollView {
                        Text(summary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 64)
                }
                if player.currentTime > 30 {
                    Button { Task { await player.seek(to: 0) } } label: {
                        Label("From Beginning", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cast
        }
    }

    /// "Genre · 2h 4m · 2019".
    private var metaLine: String {
        let parts: [String?] = [
            item.Genre?.prefix(2).compactMap(\.tag).joined(separator: ", "),
            item.durationFormatted,
            item.year.map(String.init)
        ]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var badges: [String] {
        var result: [String] = []
        if let rating = item.contentRating { result.append(rating) }
        let media = session.request.item.Media?[safe: session.request.mediaIndex]
        if let resolution = media?.videoResolution?.uppercased() {
            result.append(resolution == "4K" ? "4K" : resolution.hasSuffix("P") ? resolution : "\(resolution)P")
        }
        if media?.Part?.first?.Stream?.contains(where: { $0.DOVIPresent == true }) == true {
            result.append("DV")
        }
        if !session.subtitleTracks.isEmpty { result.append("CC") }
        return result
    }

    /// The cast and director, from Plex.
    @ViewBuilder
    private var cast: some View {
        let people = (item.Role ?? []).prefix(6).compactMap { role in
            role.tag.map { (name: $0, role: role.role, thumb: role.thumb) }
        }
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("CAST").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    HStack(spacing: 8) {
                        MacPlexImage(url: plex.imageURL(path: person.thumb, width: 80, height: 80))
                            .overlay {
                                if person.thumb == nil { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let role = person.role {
                                Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .personLinks(name: person.name)
                }
            }
            .frame(width: 190, alignment: .leading)
        }
    }
}

// MARK: - Chapters

/// A chapter of the playing title, in seconds.
struct MacChapter: Identifiable, Equatable {
    let id: Int
    let title: String
    let start: TimeInterval
    let end: TimeInterval?
    let thumb: String?

    init?(_ chapter: PlexChapter, position: Int) {
        guard let start = chapter.startTimeOffset else { return nil }
        id = chapter.id ?? position
        title = chapter.tag.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(chapter.index ?? position + 1)"
        self.start = Double(start) / 1000
        end = chapter.endTimeOffset.map { Double($0) / 1000 }
        thumb = chapter.thumb
    }

    static func list(from item: PlexMetadata?) -> [MacChapter] {
        (item?.Chapter ?? []).enumerated().compactMap { MacChapter($1, position: $0) }
    }
}

private struct MacChaptersPane: View {
    var player: AetherPlayer
    let chapters: [MacChapter]
    @Environment(MacPlexSession.self) private var plex

    /// The last chapter that has started.
    private var currentID: Int? {
        let time = player.pendingSeekTarget ?? player.currentTime
        return chapters.last(where: { $0.start <= time })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(chapters) { chapter in
                        let isCurrent = chapter.id == currentID
                        Button { Task { await player.seek(to: chapter.start) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                MacPlexImage(url: plex.imageURL(path: chapter.thumb, width: 400, height: 225))
                                    .frame(width: 200, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.accentColor, lineWidth: isCurrent ? 3 : 0)
                                    }
                                Text(chapter.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(MacVODPlayerView.format(chapter.start))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .frame(width: 200, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
        }
    }
}

// MARK: - Details

private struct MacDetailsPane: View {
    var session: MacPlexPlayback
    var player: AetherPlayer
    let detail: PlexMetadata?

    private struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private struct DetailSection: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    var body: some View {
        ScrollView(.horizontal) {
            // Live figures refresh once a second; the file's facts don't change.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(alignment: .top, spacing: 28) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(section.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(row.label).foregroundStyle(.secondary)
                                    Text(row.value).monospacedDigit()
                                }
                                .font(.caption)
                                .lineLimit(1)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Sections

    private var item: PlexMetadata { detail ?? session.request.item }
    private var media: PlexMedia? { item.Media?[safe: session.request.mediaIndex] }
    private var streams: [PlexStream] { media?.Part?.first?.Stream ?? [] }

    private var sections: [DetailSection] {
        [playbackSection, videoSection, audioSection, liveSection, fileSection].compactMap { $0 }
    }

    private var playbackSection: DetailSection {
        let request = session.request
        var rows = [Row(label: "Mode", value: request.plan == .original ? "Direct Play" : "Transcode")]
        rows.append(Row(label: "Quality", value: session.qualityLabel))
        if let kbps = request.sourceKbps { rows.append(Row(label: "Source", value: Self.mbps(Double(kbps) / 1000))) }
        return DetailSection(title: "PLAYBACK", rows: rows)
    }

    private var videoSection: DetailSection? {
        guard let video = streams.first(where: { $0.streamType == 1 }) else { return nil }
        var rows: [Row] = []
        if let codec = video.codec { rows.append(Row(label: "Codec", value: codec.uppercased() + (video.profile.map { " \($0)" } ?? ""))) }
        if let width = video.width ?? media?.width, let height = video.height ?? media?.height {
            rows.append(Row(label: "Size", value: "\(width)×\(height)"))
        }
        if let fps = video.frameRate { rows.append(Row(label: "Frame rate", value: String(format: "%g fps", fps))) }
        if let depth = video.bitDepth { rows.append(Row(label: "Bit depth", value: "\(depth)-bit")) }
        if let range = Self.dynamicRange(video) { rows.append(Row(label: "Range", value: range)) }
        if let decoder = player.stats().videoDecoder { rows.append(Row(label: "Decoder", value: decoder)) }
        return DetailSection(title: "VIDEO", rows: rows)
    }

    private var audioSection: DetailSection? {
        let audio = streams.first { $0.isAudio && $0.id == session.selectedAudioID }
            ?? streams.first { $0.isAudio && $0.selected == true }
            ?? streams.first(where: \.isAudio)
        guard let audio else { return nil }
        var rows: [Row] = []
        if let codec = audio.codec { rows.append(Row(label: "Codec", value: codec.uppercased())) }
        if let layout = audio.audioChannelLayout ?? audio.channels.map({ "\($0) ch" }) {
            rows.append(Row(label: "Channels", value: layout))
        }
        if let rate = audio.samplingRate { rows.append(Row(label: "Sample rate", value: String(format: "%g kHz", Double(rate) / 1000))) }
        if let bitrate = audio.bitrate { rows.append(Row(label: "Bitrate", value: "\(bitrate) kbps")) }
        if let language = audio.language { rows.append(Row(label: "Language", value: language)) }
        if let decoder = player.stats().audioDecoder { rows.append(Row(label: "Decoder", value: decoder)) }
        return DetailSection(title: "AUDIO", rows: rows)
    }

    /// The engine's live figures; nil when it measures none on this path.
    private var liveSection: DetailSection? {
        let stats = player.stats()
        var rows: [Row] = []
        if let value = stats.instantBitrateMbps { rows.append(Row(label: "Bitrate", value: Self.mbps(value))) }
        if let value = stats.averageBitrateMbps { rows.append(Row(label: "Average", value: Self.mbps(value))) }
        if let value = stats.framesPerSecond { rows.append(Row(label: "Frame rate", value: String(format: "%.1f fps", value))) }
        if let value = stats.droppedFrames { rows.append(Row(label: "Dropped", value: "\(value) frames")) }
        if let value = stats.bufferSeconds { rows.append(Row(label: "Buffer", value: String(format: "%.1f s", value))) }
        return rows.isEmpty ? nil : DetailSection(title: "LIVE", rows: rows)
    }

    private var fileSection: DetailSection? {
        guard let part = media?.Part?.first else { return nil }
        var rows: [Row] = []
        if let name = part.file?.split(separator: "/").last { rows.append(Row(label: "File", value: String(name))) }
        if let container = part.container ?? media?.container { rows.append(Row(label: "Container", value: container.uppercased())) }
        if let size = part.size { rows.append(Row(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let bitrate = media?.bitrate { rows.append(Row(label: "Bitrate", value: Self.mbps(Double(bitrate) / 1000))) }
        return rows.isEmpty ? nil : DetailSection(title: "FILE", rows: rows)
    }

    private static func mbps(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }

    private static func dynamicRange(_ video: PlexStream) -> String? {
        if video.DOVIPresent == true {
            return "Dolby Vision" + (video.DOVIProfile.map { " P\($0)" } ?? "")
        }
        switch video.colorTrc {
        case "smpte2084": return "HDR10"
        case "arib-std-b67": return "HLG"
        case nil: return nil
        default: return "SDR"
        }
    }
}

// MARK: - Up Next

/// The end-of-episode card, as on tvOS: the next episode's picture and summary,
/// Play Next (Play Now once the countdown runs) and Dismiss.
struct MacUpNextCard: View {
    var session: MacPlexPlayback
    let next: PlexMetadata
    @Environment(MacPlexSession.self) private var plex

    var body: some View {
        let countdown = session.upNextCountdown
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                MacPlexArtwork(item: next, kind: .thumb, width: 160, aspectRatio: 16.0 / 9.0)
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text([next.episodeCode, next.displayTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let summary = next.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { session.playNext() } label: {
                    Label(countdown == nil ? "Play Next" : "Play Now · \(countdown ?? 0)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss", action: session.cancelUpNext)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension Collection {
    /// The element at `index`, or nil when it is out of range.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
