// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Movie, show, season or episode page: backdrop and actions, episodes, then
/// cast, extras and related rows. Ported from the iOS app's detail page.
struct MacPlexDetailView: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    @State private var full: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var seasonKey: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var episodesSeasonKey: String?
    @State private var related: [PlexMetadata] = []
    @State private var error: String?
    @State private var loadedRevision: Int?
    /// PlexMetadata's == compares only ratingKey, so SwiftUI keeps children built from the
    /// stub item; a new identity per load makes them read the loaded one.
    @State private var loadCount = 0

    private var shown: PlexMetadata { full ?? item }
    private var isSeries: Bool { shown.type == "show" || shown.type == "season" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                MacPlexDetailHeader(item: shown, playTarget: playTarget, isLoading: full == nil && error == nil)
                if full == nil, let error {
                    MacPlexErrorView(title: "Couldn't Load", message: error) { await load() }
                } else {
                    sections
                }
            }
            .id(loadCount)
            .padding(.bottom, 32)
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .navigationTitle(shown.showTitle)
        .task(id: plex.watchStateRevision) {
            guard loadedRevision != plex.watchStateRevision else { return }
            await load()
        }
        .task(id: seasonKey) { await loadEpisodes() }
    }

    @ViewBuilder
    private var sections: some View {
        if let summary = shown.summary, !summary.isEmpty {
            Text(summary)
                .font(.body)
                .frame(maxWidth: 760, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, MacTile.margin)
        }
        if isSeries {
            episodesSection
        }
        MacPlexCastRow(item: shown)
        if !related.isEmpty {
            MacPlexRail(title: "More Like This", items: related) { MacPlexPosterCard(item: $0) }
        }
        MacPlexExtrasRow(item: shown)
        MacPlexInformationSection(item: shown).padding(.horizontal, MacTile.margin)
    }

    // MARK: - Episodes

    private var currentSeason: PlexMetadata? { seasons.first { $0.ratingKey == seasonKey } }

    /// Highlighted only when there is something left to watch in this season.
    private var nextUpID: String? {
        if let onDeck = full?.OnDeck?.Metadata?.first, episodes.contains(where: { $0.id == onDeck.id }) {
            return onDeck.id
        }
        return (episodes.first(where: \.isInProgress) ?? episodes.first(where: { !$0.isWatched }))?.id
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if seasons.count > 1 {
                    Picker("Season", selection: $seasonKey) {
                        ForEach(seasons) { Text(seasonLabel($0)).tag($0.ratingKey) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .font(.title2.bold())
                } else {
                    Text(currentSeason.map(seasonLabel) ?? "Episodes").font(.title2.bold())
                }
                Spacer()
            }
            .padding(.horizontal, MacTile.margin)

            if episodesSeasonKey != seasonKey {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else {
                MacShelfRow(items: episodes) {
                    EmptyView()
                } tile: { episode in
                    MacPlexEpisodeCard(episode: episode, isNextUp: episode.id == nextUpID)
                }
            }
        }
    }

    private func seasonLabel(_ season: PlexMetadata) -> String {
        guard let index = season.index else { return season.displayTitle }
        return index == 0 ? "Specials" : "Season \(index)"
    }

    // MARK: - Play target

    /// Movies and episodes play themselves; a show plays On Deck, then the
    /// next episode of the loaded season.
    private var playTarget: PlexMetadata? {
        if shown.isPlayable { return shown }
        if shown.type == "show", let onDeck = full?.OnDeck?.Metadata?.first { return onDeck }
        guard episodesSeasonKey != nil else { return nil }
        return MacPlexSession.nextUp(in: episodes)
    }

    // MARK: - Loading

    private func load() async {
        do {
            let loaded = try await plex.metadata(for: item)
            full = loaded
            error = nil
            switch loaded.type {
            case "show":
                seasons = try await plex.children(of: loaded)
                let keep = seasons.contains { $0.ratingKey == seasonKey }
                await selectSeason(keep ? seasonKey : initialSeasonKey(show: loaded))
            case "season":
                seasons = [loaded]
                await selectSeason(loaded.ratingKey)
            default:
                break
            }
            loadedRevision = plex.watchStateRevision
            loadCount += 1
        } catch let error where isCancellationError(error) {
            return
        } catch {
            self.error = error.localizedDescription
        }
        if related.isEmpty, shown.type == "movie" || shown.type == "show" {
            related = (try? await plex.related(to: shown)) ?? []
        }
    }

    /// Selecting a new season loads it through `.task(id: seasonKey)`; the
    /// same season reloads here so watch state repaints.
    private func selectSeason(_ key: String?) async {
        if key == seasonKey {
            await loadEpisodes(force: true)
        } else {
            seasonKey = key
        }
    }

    /// The On Deck episode's season, else the first season with unwatched
    /// episodes, else the first real season.
    private func initialSeasonKey(show: PlexMetadata) -> String? {
        if let key = show.OnDeck?.Metadata?.first?.parentRatingKey,
           seasons.contains(where: { $0.ratingKey == key }) {
            return key
        }
        let real = seasons.filter { ($0.index ?? 0) > 0 }
        return (real.first { !$0.isWatched } ?? real.first ?? seasons.first)?.ratingKey
    }

    private func loadEpisodes(force: Bool = false) async {
        guard let key = seasonKey, force || episodesSeasonKey != key,
              let season = seasons.first(where: { $0.ratingKey == key }) else { return }
        do {
            let loaded = try await plex.children(of: season)
            guard seasonKey == key else { return }
            episodes = loaded
            episodesSeasonKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Header

private struct MacPlexDetailHeader: View {
    let item: PlexMetadata
    let playTarget: PlexMetadata?
    let isLoading: Bool
    @Environment(\.plexActions) private var actions
    @Environment(MacPlexSession.self) private var plex

    private var metadataItems: [String] {
        let date: String? = item.type == "episode"
            ? item.originallyAvailableAt.flatMap(MacPlexInformationSection.formattedDate)
            : item.year.map(String.init)
        return [date, item.runtimeText, item.Genre?.prefix(2).compactMap(\.tag).joined(separator: ", ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                MacPlexArtwork(item: item, kind: .backdrop, width: proxy.size.width, aspectRatio: 16 / 9)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.75), location: 0.75),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
                titleBlock
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, MacTile.margin)
                    .padding(.bottom, 24)
            }
        }
        .frame(height: 460)
        .clipped()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: 380,
                maxHeight: 120,
                fallbackFont: .largeTitle.bold(),
                alignment: .bottomLeading,
                textAlignment: .leading
            )
            if item.type == "episode" || item.type == "season" {
                Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            HStack(spacing: 8) {
                Text(metadataItems.joined(separator: " · "))
                if let rating = item.contentRating, !rating.isEmpty {
                    Text(rating).plexPill()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)

            actionRow.padding(.top, 6)

            if let target = playTarget, target.id != item.id, let code = target.episodeCode {
                Text([code, target.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                if let playTarget { actions.play(playTarget) }
            } label: {
                HStack(spacing: 8) {
                    if actions.preparingID == playTarget?.id, playTarget != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(playTarget?.isInProgress == true ? "Resume" : "Play")
                    if let left = playTarget?.timeLeftText {
                        Text("· \(left)").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(playTarget == nil)
            .opacity(playTarget == nil && isLoading ? 0.6 : 1)

            if PlexAuthManager.shared.accountContentToken != nil,
               ["movie", "show", "season", "episode"].contains(item.type ?? "") {
                let onList = plex.isOnWatchlist(item)
                Button { actions.setWatchlisted(item, !onList) } label: {
                    Image(systemName: onList ? "checkmark" : "plus")
                }
                .help(onList ? "Remove from Watchlist" : "Add to Watchlist")
            }

            Menu {
                MacPlexItemMenu(item: item, showsPlay: false, showsWatchlist: false)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .controlSize(.large)
    }
}

// MARK: - Sections

/// One episode as a card: still, title, time left, summary. Clicking plays.
private struct MacPlexEpisodeCard: View {
    let episode: PlexMetadata
    let isNextUp: Bool
    private let watchStamp: [Int]
    @Environment(\.plexActions) private var actions

    init(episode: PlexMetadata, isNextUp: Bool) {
        self.episode = episode
        self.isNextUp = isNextUp
        watchStamp = episode.watchStamp
    }

    private let width: CGFloat = 280

    var body: some View {
        Button { actions.play(episode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                MacPlexArtwork(item: episode, kind: .thumb, width: width, aspectRatio: 16 / 9)
                    .frame(width: width, height: width * 9 / 16)
                    .plexWatchState(episode)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if actions.preparingID == episode.id { ProgressView().tint(.white) }
                    }
                if isNextUp {
                    Text("Up Next").font(.caption.bold()).foregroundStyle(.tint)
                }
                Text(episode.index.map { "\($0). \(episode.displayTitle)" } ?? episode.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let detail = episode.timeLeftText ?? episode.runtimeText {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plexContextMenu(episode)
        .help("Play")
    }
}

/// Cast & Crew: actors, then directors.
private struct MacPlexCastRow: View {
    let item: PlexMetadata
    @Environment(MacPlexSession.self) private var plex
    @Environment(\.displayScale) private var displayScale

    private struct Person: Identifiable {
        let id: Int
        let name: String
        let role: String?
        let thumb: String?
    }

    private var people: [Person] {
        let cast = (item.Role ?? []).prefix(20).compactMap { role in
            role.tag.map { (name: $0, role: role.role, thumb: role.thumb) }
        }
        let directors = (item.Director ?? []).compactMap { member in
            member.tag.map { (name: $0, role: Optional("Director"), thumb: member.thumb) }
        }
        return (cast + directors).enumerated().map {
            Person(id: $0.offset, name: $0.element.name, role: $0.element.role, thumb: $0.element.thumb)
        }
    }

    var body: some View {
        let people = self.people
        if !people.isEmpty {
            MacShelfRow(items: people) {
                Text("Cast & Crew").font(.title2.bold())
            } tile: { person in
                let width = MacTile.person
                let pixels = Int((width * displayScale).rounded(.up))
                VStack(spacing: 6) {
                    MacPlexImage(url: plex.imageURL(path: person.thumb, width: pixels, height: pixels))
                        .overlay {
                            if person.thumb == nil {
                                Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: width, height: width)
                        .clipShape(Circle())
                    Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                    if let role = person.role {
                        Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: width + 20)
            }
        }
    }
}

/// Extras and trailers from the full metadata; clicking one plays it.
private struct MacPlexExtrasRow: View {
    let item: PlexMetadata
    @Environment(\.plexActions) private var actions

    private var extras: [PlexMetadata] {
        item.allExtras
            .sorted { ExtraSubtype.from(subtype: $0.subtype, extraType: $0.extraType)
                < ExtraSubtype.from(subtype: $1.subtype, extraType: $1.extraType) }
            .compactMap { extra in
                extra.ratingKey.map {
                    PlexMetadata(ratingKey: $0, type: "clip", title: extra.title, thumb: extra.thumb, duration: extra.duration)
                }
            }
    }

    var body: some View {
        let extras = self.extras
        if !extras.isEmpty {
            MacShelfRow(items: extras) {
                Text("Extras").font(.title2.bold())
            } tile: { extra in
                let width: CGFloat = 260
                Button { actions.play(extra) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MacPlexArtwork(item: extra, kind: .thumb, width: width, aspectRatio: 16 / 9)
                            .frame(width: width, height: width * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                if actions.preparingID == extra.id { ProgressView().tint(.white) }
                            }
                        Text(extra.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                        if let runtime = extra.runtimeText {
                            Text(runtime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Studio, genres, rating, release date, languages: whatever the item has.
struct MacPlexInformationSection: View {
    let item: PlexMetadata

    nonisolated static func formattedDate(_ isoDay: String) -> String? {
        guard let date = try? Date(isoDay, strategy: .iso8601.year().month().day().dateSeparator(.dash)) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    private func languages(streamType: Int) -> String? {
        let streams = item.Media?.first?.Part?.first?.Stream ?? []
        var seen = Set<String>()
        let names = streams
            .filter { $0.streamType == streamType }
            .compactMap { $0.language ?? $0.languageTag }
            .filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var rows: [(String, String)] {
        [
            ("Studio", item.studio),
            ("Genre", item.Genre?.compactMap(\.tag).joined(separator: ", ")),
            ("Rated", item.contentRating),
            ("Released", item.originallyAvailableAt.flatMap(Self.formattedDate)),
            ("Runtime", item.runtimeText),
            ("Audio", languages(streamType: 2)),
            ("Subtitles", languages(streamType: 3))
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Information").font(.title2.bold())
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3),
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(rows, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.subheadline.weight(.semibold))
                            Text(value).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
