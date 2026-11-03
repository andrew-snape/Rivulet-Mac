// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Layout

/// Left to right, wrapping to a new row when one is full.
struct MacFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Small parts

struct MacMusicChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.1), in: Capsule())
    }
}

/// Chips for each text, repeats (any case) dropped.
struct MacMusicChips: View {
    let texts: [String]

    private var unique: [String] {
        var seen = Set<String>()
        return texts.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        let texts = unique
        if !texts.isEmpty {
            MacFlowLayout(spacing: 6) {
                ForEach(texts, id: \.self) { MacMusicChip(text: $0) }
            }
        }
    }
}

/// The listener's stars and the critic's rating, whichever exist.
struct MacMusicRatingBadge: View {
    let item: PlexMetadata

    var body: some View {
        let stars = PlexUserRating.stars(item.userRating)
        let critic = (item.rating ?? 0) > 0 ? item.rating : nil
        if stars != nil || critic != nil {
            HStack(spacing: 12) {
                if let stars {
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { index in
                            Image(systemName: stars >= Double(index) + 1 ? "star.fill"
                                  : (stars >= Double(index) + 0.5 ? "star.leadinghalf.filled" : "star"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Your Rating")
                }
                if let critic {
                    Text("★ " + (critic / 2).formatted(.number.precision(.fractionLength(1))))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .help("Critic Rating")
                }
            }
        } else {
            EmptyView()
        }
    }
}

struct MacMusicQualityBadge: View {
    let quality: MusicAudioQuality

    var body: some View {
        Label(quality.label, systemImage: "waveform")
            .plexPill()
            .foregroundStyle(.secondary)
    }
}

/// A biography or review, cut to a few lines with More to open it.
struct MacMusicBio: View {
    let text: String
    var sourceName: String?
    var sourceURL: URL?
    var collapsedLines = 4
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > limitedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : collapsedLines)
                .background {
                    // Hidden copies measure whether the limit cuts anything.
                    ZStack {
                        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { Color.clear.preference(key: MacBioHeight.self, value: [0: $0.size.height]) })
                        Text(text).font(.callout).lineLimit(collapsedLines).fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { Color.clear.preference(key: MacBioHeight.self, value: [1: $0.size.height]) })
                    }
                    .hidden()
                }
                .onPreferenceChange(MacBioHeight.self) { heights in
                    fullHeight = heights[0] ?? 0
                    limitedHeight = heights[1] ?? 0
                }
            if isTruncated {
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
            if let sourceName {
                if let sourceURL {
                    Link("From \(sourceName)", destination: sourceURL)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("From \(sourceName)").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }
}

private struct MacBioHeight: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// How often Plex's listeners play a track against the artist's most played.
struct MacMusicPopularityBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 36, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(.secondary).frame(width: 36 * min(max(fraction, 0), 1), height: 4)
            }
            .help("Popularity")
    }
}

// MARK: - Hero

/// The top of an artist or album page: a wash of the cover's colour, and the
/// artist's backdrop behind it when there is one.
struct MacMusicHero<Content: View>: View {
    let tint: Color?
    var backdrop: URL?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.top, 24)
            .padding(.horizontal, MacTile.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: [(tint ?? .clear).opacity(0.9), MacTheme.background],
                                   startPoint: .top, endPoint: .bottom)
                    if let backdrop {
                        MacPlexImage(url: backdrop)
                            .opacity(0.5)
                            .overlay {
                                LinearGradient(colors: [.clear, MacTheme.background], startPoint: .top, endPoint: .bottom)
                            }
                            .frame(minHeight: 320)
                    }
                }
                .padding(.top, -200)
            }
            .animation(.easeInOut(duration: 0.4), value: tint)
    }
}

// MARK: - Elsewhere

/// Pages about the artist or album on other sites; nothing when there are none.
struct MacMusicLinksMenu: View {
    let links: [MusicLink]

    var body: some View {
        if !links.isEmpty {
            Menu("Elsewhere", systemImage: "link") {
                ForEach(links, id: \.self) { link in
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Open this on another site")
        }
    }
}

// MARK: - Online gaps

extension PlexMetadata {
    /// Plex has no genre or style of its own.
    var hasNoMusicStyles: Bool {
        (Genre ?? []).isEmpty && (Style ?? []).isEmpty
    }
}
