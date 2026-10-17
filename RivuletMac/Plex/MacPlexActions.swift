// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// What a tile, detail page or menu can do with an item. Provided by
/// `MacPlexActionHost`; the default does nothing. Ported from the iOS app.
struct MacPlexActions {
    var play: (PlexMetadata) -> Void = { _ in }
    /// Opens the item's detail page in the current column.
    var open: (PlexMetadata) -> Void = { _ in }
    var setWatched: (PlexMetadata, Bool) -> Void = { _, _ in }
    var setWatchlisted: (PlexMetadata, Bool) -> Void = { _, _ in }
    /// Item whose playback is being prepared, for a spinner.
    var preparingID: String?
}

extension EnvironmentValues {
    @Entry var plexActions = MacPlexActions()
}

extension View {
    /// The one place Plex playback starts. Applied once, around the content
    /// column; `open` pushes a detail page onto that column's stack.
    func macPlexActionHost(open: @escaping (PlexMetadata) -> Void) -> some View {
        modifier(MacPlexActionHost(open: open))
    }
}

private struct MacPlexActionHost: ViewModifier {
    let open: (PlexMetadata) -> Void
    @EnvironmentObject private var plex: MacPlexSession
    @EnvironmentObject private var playback: MacPlaybackController
    @State private var preparingID: String?
    @State private var failure: (title: String, message: String)?

    func body(content: Content) -> some View {
        content
            .environment(\.plexActions, MacPlexActions(
                play: play,
                open: open,
                setWatched: { item, watched in
                    run("Couldn't Update") { try await plex.setWatched(watched, for: item) }
                },
                setWatchlisted: { item, on in
                    run("Couldn't Update Watchlist") { try await plex.setWatchlisted(on, item: item) }
                },
                preparingID: preparingID
            ))
            .alert(
                failure?.title ?? "",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                actions: { Button("OK") {} },
                message: { Text(failure?.message ?? "") }
            )
    }

    private func play(_ item: PlexMetadata) {
        guard preparingID == nil else { return }
        preparingID = item.id
        Task {
            defer { preparingID = nil }
            do {
                let target = try await plex.playableTarget(for: item)
                playback.play(try await plex.playback(for: target))
            } catch let error where isCancellationError(error) {
            } catch {
                failure = ("Couldn't Play", error.localizedDescription)
            }
        }
    }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch let error where isCancellationError(error) {} catch {
                failure = (title, error.localizedDescription)
            }
        }
    }
}

// MARK: - Item menu

extension View {
    /// Right-click menu shared by every poster, card and row.
    func plexContextMenu(_ item: PlexMetadata) -> some View {
        contextMenu { MacPlexItemMenu(item: item) }
    }
}

/// Menu items for one item: Play, Watched, Watchlist, Go to Show.
struct MacPlexItemMenu: View {
    let item: PlexMetadata
    var showsPlay = true
    var showsWatchlist = true
    @Environment(\.plexActions) private var actions
    @EnvironmentObject private var plex: MacPlexSession
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    var body: some View {
        if showsPlay {
            Button(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") { actions.play(item) }
        }
        Section {
            Button(
                item.isWatched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: item.isWatched ? "circle" : "checkmark.circle"
            ) { actions.setWatched(item, !item.isWatched) }
            if showsWatchlist, PlexAuthManager.shared.accountContentToken != nil,
               ["movie", "show", "season", "episode"].contains(item.type ?? "") {
                let onList = plex.isOnWatchlist(item)
                let standsForShow = item.type == "episode" || item.type == "season"
                Button(
                    onList ? "Remove from Watchlist" : (standsForShow ? "Add Show to Watchlist" : "Add to Watchlist"),
                    systemImage: onList ? "minus.circle" : "plus.circle"
                ) { actions.setWatchlisted(item, !onList) }
            }
        }
        if item.type == "episode" || item.type == "season" {
            Section {
                if let show = item.showStub {
                    Button("Go to Show", systemImage: "tv") { actions.open(show) }
                }
                if let season = item.seasonStub {
                    Button("Go to Season", systemImage: "square.stack") { actions.open(season) }
                }
            }
        }
    }
}

extension PlexMetadata {
    /// Enough of the parent show for a detail page to load the rest.
    var showStub: PlexMetadata? {
        let key = type == "episode" ? grandparentRatingKey : (type == "season" ? parentRatingKey : nil)
        guard let key else { return nil }
        return PlexMetadata(
            ratingKey: key,
            guid: type == "episode" ? grandparentGuid : parentGuid,
            type: "show",
            title: type == "episode" ? grandparentTitle : parentTitle,
            thumb: type == "episode" ? grandparentThumb : parentThumb,
            art: grandparentArt ?? art
        )
    }

    /// An episode's season.
    var seasonStub: PlexMetadata? {
        guard type == "episode", let parentRatingKey else { return nil }
        return PlexMetadata(
            ratingKey: parentRatingKey,
            guid: parentGuid,
            type: "season",
            title: parentIndex.map { "Season \($0)" } ?? parentTitle,
            thumb: parentThumb,
            art: grandparentArt,
            parentRatingKey: grandparentRatingKey,
            parentGuid: grandparentGuid,
            parentTitle: grandparentTitle,
            index: parentIndex
        )
    }
}
