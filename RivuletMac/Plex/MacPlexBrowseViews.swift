// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Home

/// Continue Watching, then each pinned library's promoted rows.
struct MacPlexHomeView: View {
    @Environment(MacPlexSession.self) private var plex

    var body: some View {
        Group {
            if plex.continueWatching != nil || !plex.shelves.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if let continueWatching = plex.continueWatching {
                            MacPlexShelfView(hub: continueWatching)
                        }
                        ForEach(plex.shelves) { MacPlexShelfView(hub: $0) }
                    }
                    .padding(.vertical, 20)
                }
            } else if plex.isLoadingContent {
                ProgressView()
            } else if let error = plex.contentError {
                MacPlexErrorView(title: "Couldn't Load Home", message: error) { await plex.refresh() }
            } else {
                ContentUnavailableView(
                    "Nothing on Home Yet",
                    systemImage: "rectangle.stack",
                    description: Text("Pin a library to Home in Plex, then refresh with ⌘R.")
                )
            }
        }
        .navigationTitle("Home")
    }
}

// MARK: - Library

/// One library as a paged poster grid with Sort and Filter in the toolbar.
struct MacPlexLibraryView: View {
    let library: PlexLibrary
    @Environment(MacPlexSession.self) private var plex
    @AppStorage private var sortRaw: String
    @State private var unwatchedOnly = false
    @State private var items: [PlexMetadata] = []
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedKey: String?

    private static let pageSize = 120
    private static let sorts: [(LibrarySortOption, String)] = [
        (.titleAsc, "Title"),
        (.addedAtDesc, "Date Added"),
        (.releaseDateDesc, "Release Date"),
        (.ratingDesc, "Rating")
    ]

    init(library: PlexLibrary) {
        self.library = library
        _sortRaw = AppStorage(wrappedValue: LibrarySortOption.titleAsc.rawValue, "macLibrarySort.\(library.key)")
    }

    private var sort: LibrarySortOption { LibrarySortOption(rawValue: sortRaw) ?? .titleAsc }
    private var queryKey: String { "\(library.key)|\(sortRaw)|\(unwatchedOnly)|\(plex.watchStateRevision)" }

    var body: some View {
        Group {
            if items.isEmpty, let error {
                MacPlexErrorView(title: "Couldn't Load Library", message: error) { await reload() }
            } else if items.isEmpty, !isLoading, loadedKey != nil {
                ContentUnavailableView(unwatchedOnly ? "Nothing Unwatched" : "No Items", systemImage: library.icon)
            } else {
                ScrollView {
                    MacPlexPosterGrid(items: items, loadMore: loadMore)
                    if isLoading { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(library.title)
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(Self.sorts, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                }
                .pickerStyle(.menu)
                .help("Sort")
                Picker("Show", selection: $unwatchedOnly) {
                    Text("All").tag(false)
                    Text("Unwatched").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Filter")
            }
        }
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            await reload()
        }
    }

    /// Refetches from the top. A watch-state change refetches every loaded
    /// page in one request so the grid repaints in place.
    private func reload() async {
        let key = queryKey
        let sameQuery = loadedKey.map { $0.hasPrefix("\(library.key)|\(sortRaw)|\(unwatchedOnly)|") } ?? false
        let keepCount = sameQuery ? items.count : 0
        if keepCount == 0 { items = [] }
        isLoading = true
        defer { if key == queryKey { isLoading = false } }
        do {
            let page = try await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly,
                start: 0, size: max(Self.pageSize, keepCount)
            )
            guard key == queryKey else { return }
            items = page.items.uniqued()
            total = page.totalSize
            error = nil
            loadedKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            guard key == queryKey else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard !isLoading, let total, items.count < total else { return }
        let key = queryKey
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly, start: items.count, size: Self.pageSize
            ), key == queryKey else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }
}

// MARK: - See All

/// See All for one Home or detail row, paged through the hub's own key.
struct MacPlexHubGridView: View {
    let route: MacPlexHubRoute
    @Environment(MacPlexSession.self) private var plex
    @State private var items: [PlexMetadata]
    @State private var total: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadedRevision: Int?

    private static let pageSize = 90

    init(route: MacPlexHubRoute) {
        self.route = route
        _items = State(initialValue: route.hub.Metadata ?? [])
    }

    /// Continue Watching follows the session's own cache-busted copy.
    private var shown: [PlexMetadata] {
        route.hub.isContinueWatching ? (plex.continueWatching?.Metadata ?? items) : items
    }

    var body: some View {
        Group {
            if shown.isEmpty, let error {
                MacPlexErrorView(title: "Couldn't Load", message: error) { await reload() }
            } else {
                ScrollView {
                    MacPlexPosterGrid(items: shown, loadMore: loadMore)
                    if isLoading { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(route.hub.displayTitle)
        .task(id: plex.watchStateRevision) {
            guard route.pages, loadedRevision != plex.watchStateRevision else { return }
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await plex.hubPage(route.hub, start: 0, size: max(Self.pageSize, items.count))
            items = page.items.uniqued()
            total = page.totalSize
            error = nil
            loadedRevision = plex.watchStateRevision
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard route.pages, !isLoading, let total, items.count < total else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let page = try? await plex.hubPage(route.hub, start: items.count, size: Self.pageSize) else { return }
            items = (items + page.items).uniqued()
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
    }
}

// MARK: - Search

/// Movies, shows and episodes across the server's video libraries.
struct MacPlexSearchView: View {
    @Binding var query: String
    @Environment(MacPlexSession.self) private var plex
    @State private var results: [PlexMetadata] = []
    @State private var isSearching = false
    @State private var error: String?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [(title: String, items: [PlexMetadata])] {
        let sections: [(String, Set<String>)] = [
            ("Movies", ["movie"]),
            ("TV Shows", ["show", "season"]),
            ("Episodes", ["episode"]),
        ]
        return sections.compactMap { title, types in
            let items = results.filter { types.contains($0.type ?? "") }
            return items.isEmpty ? nil : (title, items)
        }
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                ContentUnavailableView(
                    "Search Your Plex Libraries",
                    systemImage: "magnifyingglass",
                    description: Text("Type in the search field to find movies, TV shows and episodes.")
                )
            } else if let error {
                ContentUnavailableView("Couldn't Search", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if groups.isEmpty {
                if isSearching { ProgressView() } else { ContentUnavailableView.search(text: trimmedQuery) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(groups, id: \.title) { group in
                            MacPlexRail(title: group.title, items: group.items) { item in
                                if item.type == "episode" {
                                    MacPlexContinueCard(item: item, width: 260)
                                } else {
                                    MacPlexPosterCard(item: item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Search")
        .task(id: query) { await search() }
    }

    private func search() async {
        let value = trimmedQuery
        error = nil
        guard !value.isEmpty, plex.isConfigured else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await plex.search(value)
        } catch {
            // A newer keystroke cancelled this request; the next task owns the state.
            if Task.isCancelled || isCancellationError(error) { return }
            self.error = error.localizedDescription
        }
        isSearching = false
    }
}
