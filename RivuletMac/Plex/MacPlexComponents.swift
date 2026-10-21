// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

// MARK: - Artwork

/// Remote image through MacArtworkCache. A cached image is in place on the
/// first frame, so recreated tiles do not flash.
struct MacPlexImage: View {
    let url: URL?
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                if let cached = MacArtworkCache.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                guard let loaded = await MacArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

/// An item's artwork, transcoded to the pixel size the tile draws at. Widths
/// round up to 120px steps so nearby tile sizes share one cache entry.
struct MacPlexArtwork: View {
    let item: PlexMetadata
    let kind: MacPlexSession.ArtworkKind
    /// Display width in points.
    let width: CGFloat
    /// Width over height of the requested image.
    let aspectRatio: CGFloat
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        MacPlexImage(url: Self.url(plex, item: item, kind: kind, width: width, aspectRatio: aspectRatio, scale: displayScale))
    }

    static func url(_ plex: MacPlexSession, item: PlexMetadata, kind: MacPlexSession.ArtworkKind,
                    width: CGFloat, aspectRatio: CGFloat, scale: CGFloat) -> URL? {
        let pixels = max(1, Int((width * scale / 120).rounded(.up))) * 120
        return plex.artworkURL(for: item, kind: kind, width: pixels, height: Int(CGFloat(pixels) / aspectRatio))
    }
}

/// Clear logo with a text fallback. Always drawn over a dark scrim, so white.
struct MacPlexResolvedLogo: View {
    let item: PlexMetadata
    let fallbackTitle: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let fallbackFont: Font
    let alignment: Alignment
    let textAlignment: TextAlignment

    @Environment(MacPlexSession.self) private var plex
    @State private var loaded: (identity: String, image: NSImage)?

    private var sourceIdentity: String {
        let key = item.type == "episode"
            ? item.grandparentRatingKey
            : (item.type == "season" ? item.parentRatingKey : item.ratingKey)
        return "\(key ?? item.id)|\(item.clearLogoPath ?? "")"
    }

    var body: some View {
        let cached = plex.cachedLogoURL(for: item).flatMap(MacArtworkCache.shared.cachedImage(for:))
        let logo = cached ?? (loaded?.identity == sourceIdentity ? loaded?.image : nil)
        ZStack(alignment: alignment) {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.opacity)
            } else {
                Text(fallbackTitle)
                    .font(fallbackFont)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        .animation(.easeInOut(duration: 0.2), value: logo != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallbackTitle)
        .task(id: sourceIdentity) {
            let identity = sourceIdentity
            guard let url = await plex.logoURL(for: item),
                  !Task.isCancelled,
                  let image = await MacArtworkCache.shared.image(for: url),
                  !Task.isCancelled else { return }
            loaded = (identity, image)
        }
    }
}

// MARK: - Watch state

extension View {
    /// Progress bar along the bottom, or the watched check when there is no bar.
    func plexWatchState(_ item: PlexMetadata) -> some View {
        overlay(alignment: .bottom) {
            if let fraction = item.progressBarFraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.progressBarFraction == nil, item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(6)
            }
        }
    }

    func plexPill() -> some View {
        font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
    }
}

extension PlexMetadata {
    /// PlexMetadata's `==` compares only ratingKey, so SwiftUI skips a tile whose
    /// watch state changed. Tiles store this so the change reaches their body.
    var watchStamp: [Int] { [viewOffset ?? 0, viewCount ?? 0, viewedLeafCount ?? 0, lastViewedAt ?? 0] }
}

extension Array where Element == PlexMetadata {
    /// Drops repeats by id, keeping the first; ForEach needs unique ids.
    func uniqued() -> [PlexMetadata] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Tiles

enum MacTile {
    static let poster: CGFloat = 160
    static let landscape: CGFloat = 300
    static let person: CGFloat = 96
    static let gap: CGFloat = 16
    static let margin: CGFloat = 28
}

struct MacPlexPosterCard: View {
    let item: PlexMetadata
    var width: CGFloat? = MacTile.poster
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat? = MacTile.poster) {
        self.item = item
        self.width = width
        watchStamp = item.watchStamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacPlexArtwork(item: item, kind: .poster, width: width ?? MacTile.poster, aspectRatio: 2 / 3)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: width)
                .plexWatchState(item)
                .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)

            Text(item.type == "episode" ? item.showTitle : item.displayTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let caption = item.type == "episode" ? item.episodeCode : item.subtitle {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

/// Continue Watching, the tvOS card: backdrop art, the logo centred, and
/// progress and "S2, E5 · 12 min left" along the bottom.
struct MacPlexContinueCard: View {
    static let aspectRatio: CGFloat = 16 / 9

    let item: PlexMetadata
    var width: CGFloat = MacTile.landscape
    private let watchStamp: [Int]

    init(item: PlexMetadata, width: CGFloat = MacTile.landscape) {
        self.item = item
        self.width = width
        watchStamp = item.watchStamp
    }

    private var height: CGFloat { width / Self.aspectRatio }

    private var info: String {
        [item.episodeCode, item.timeLeftText ?? item.runtimeText ?? item.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            MacPlexArtwork(item: item, kind: .backdrop, width: width, aspectRatio: Self.aspectRatio)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            MacPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: width * 0.6,
                maxHeight: height * 0.35,
                fallbackFont: .title3.bold(),
                alignment: .center,
                textAlignment: .center
            )
            HStack(spacing: 6) {
                if let fraction = item.progressBarFraction {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 40, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: 40 * fraction)
                        }
                }
                Text(info)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        .contentShape(Rectangle())
        .macCardHover()
    }
}

// MARK: - Rows

/// A See All destination: one hub, paged through its own key.
struct MacPlexHubRoute: Hashable {
    let hub: PlexHub

    /// Continue Watching is the cache-busted fetch, and a literal id list is a
    /// fixed set, so neither pages.
    var pages: Bool {
        guard !hub.isContinueWatching, let key = hub.key ?? hub.hubKey else { return false }
        return !key.hasPrefix("/library/metadata/")
    }
}

/// "Title ›" heading that opens the full grid.
struct MacPlexShelfHeader: View {
    let title: String
    var route: MacPlexHubRoute?

    var body: some View {
        if let route {
            NavigationLink(value: route) {
                HStack(spacing: 4) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(title).font(.title2.bold())
        }
    }
}

/// A titled horizontal row. Scroll sideways with a trackpad, or Shift and the wheel.
struct MacShelfRow<Items: RandomAccessCollection, Header: View, Tile: View>: View where Items.Element: Identifiable {
    let items: Items
    @ViewBuilder let header: () -> Header
    @ViewBuilder let tile: (Items.Element) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header().padding(.horizontal, MacTile.margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MacTile.gap) {
                    ForEach(items) { tile($0) }
                }
                .padding(.horizontal, MacTile.margin)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// One Home hub as a titled row.
struct MacPlexShelfView: View {
    let hub: PlexHub

    var body: some View {
        MacPlexRail(title: hub.displayTitle, route: MacPlexHubRoute(hub: hub), items: hub.items) { item in
            if hub.isContinueWatching {
                MacPlexContinueCard(item: item)
            } else {
                MacPlexPosterCard(item: item)
            }
        }
    }
}

/// Titled row of Plex items; each tile opens its detail and has the item menu.
struct MacPlexRail<Tile: View>: View {
    let title: String
    var route: MacPlexHubRoute?
    let items: [PlexMetadata]
    @ViewBuilder let tile: (PlexMetadata) -> Tile

    var body: some View {
        MacShelfRow(items: items) {
            MacPlexShelfHeader(title: title, route: route)
        } tile: { item in
            NavigationLink(value: item) { tile(item) }
                .buttonStyle(.plain)
                .plexContextMenu(item)
        }
    }
}

/// Adaptive poster grid for libraries and See All. Calls `loadMore` when the
/// last tile appears.
struct MacPlexPosterGrid: View {
    let items: [PlexMetadata]
    var loadMore: (() -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: MacTile.poster, maximum: MacTile.poster + 40),
                                     spacing: MacTile.gap, alignment: .top)],
                  spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: item) { MacPlexPosterCard(item: item, width: nil) }
                    .buttonStyle(.plain)
                    .plexContextMenu(item)
                    .onAppear {
                        if item.id == items.last?.id { loadMore?() }
                    }
            }
        }
        // Lets a scroll view report and set its top tile (the library's letter bar).
        .scrollTargetLayout()
        .padding(.horizontal, MacTile.margin)
        .padding(.vertical, 16)
    }
}

/// Error state with Retry, used by every content surface.
struct MacPlexErrorView: View {
    let title: String
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
        }
    }
}
