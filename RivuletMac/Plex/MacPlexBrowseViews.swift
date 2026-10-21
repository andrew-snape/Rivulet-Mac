// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

// MARK: - Home

/// Continue Watching, then each pinned library's promoted rows.
struct MacPlexHomeView: View {
    @Environment(MacPlexSession.self) private var plex
    @AppStorage(MacSidebarLayout.hiddenKey) private var sidebarHidden = ""

    /// Home leaves out what the sidebar hides: shelves from a hidden library,
    /// and Continue Watching entries that belong to one.
    private var hiddenLibraries: Set<String> {
        Set(MacSidebarLayout.ids(sidebarHidden).compactMap { id in
            id.hasPrefix("library.") ? String(id.dropFirst("library.".count)) : nil
        })
    }

    private var visibleShelves: [PlexHub] {
        let hidden = hiddenLibraries
        return zip(plex.shelves, plex.shelfLibraryKeys).filter { !hidden.contains($0.1) }.map(\.0)
    }

    private var visibleContinueWatching: PlexHub? {
        guard var hub = plex.continueWatching else { return nil }
        let hidden = hiddenLibraries
        if !hidden.isEmpty {
            hub.Metadata = hub.Metadata?.filter { item in
                // Plex sends the library as an id, or only as "/library/sections/N".
                let key = item.librarySectionID.map(String.init) ?? item.librarySectionKey?.split(separator: "/").last.map(String.init)
                return key.map { !hidden.contains($0) } ?? true
            }
        }
        return hub.items.isEmpty ? nil : hub
    }

    var body: some View {
        let continueWatching = visibleContinueWatching
        let shelves = visibleShelves
        Group {
            if continueWatching != nil || !shelves.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if let continueWatching {
                            MacPlexShelfView(hub: continueWatching)
                        }
                        ForEach(shelves) { MacPlexShelfView(hub: $0) }
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
/// Sorted by title, a letter bar down the side jumps through it.
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
    /// The page being appended, so a letter jump waits for it rather than racing it.
    @State private var pageTask: Task<Void, Never>?
    @State private var alphabet: LibraryAlphabetIndex?
    @State private var alphabetKey: String?
    /// The item in the top row, kept by the scroll view; setting it scrolls there.
    @State private var topID: String?
    @State private var jumpTask: Task<Void, Never>?

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

    /// The letter the top row sits under.
    private var currentLetter: Int? {
        guard let alphabet, let topID, let index = items.firstIndex(where: { $0.id == topID }) else { return nil }
        return alphabet.entryIndex(containing: index)
    }

    var body: some View {
        Group {
            if items.isEmpty, let error {
                MacPlexErrorView(title: "Couldn't Load Library", message: error) { await reload() }
            } else if items.isEmpty, !isLoading, loadedKey != nil {
                ContentUnavailableView(unwatchedOnly ? "Nothing Unwatched" : "No Items", systemImage: library.icon)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        MacPlexPosterGrid(items: items, loadMore: loadMore)
                        if isLoading || pageTask != nil { ProgressView().padding() }
                    }
                    .scrollPosition(id: $topID, anchor: .top)
                    if let alphabet, alphabet.entries.count > 1, !items.isEmpty {
                        MacAlphabetBar(index: alphabet, current: currentLetter, jump: jump(to:))
                    }
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
        .task(id: queryKey) {
            guard alphabetKey != queryKey else { return }
            let key = queryKey
            let index = try? await plex.libraryAlphabet(library, sort: sort, unwatchedOnly: unwatchedOnly)
            guard !Task.isCancelled, key == queryKey else { return }
            alphabet = index
            alphabetKey = key
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
        guard pageTask == nil else { return }
        Task { await fetchMore() }
    }

    /// Appends the next page, or with `index`, everything up to it and a page
    /// past it in one request. Waits out a page already on its way.
    private func fetchMore(through index: Int? = nil) async {
        if let pending = pageTask { await pending.value }
        guard !isLoading, let total, items.count < total else { return }
        if let index, index < items.count { return }
        let key = queryKey
        let start = items.count
        let size = max(Self.pageSize, (index ?? 0) - start + Self.pageSize)
        let task = Task {
            guard let page = try? await plex.libraryPage(
                library, sort: sort, unwatchedOnly: unwatchedOnly, start: start, size: size
            ), key == queryKey, start == items.count else { return }
            items = (items + page.items).uniqued()
            // An empty page means the server's count overstated; stop paging.
            self.total = page.items.isEmpty ? items.count : page.totalSize
        }
        pageTask = task
        await task.value
        if pageTask == task { pageTask = nil }
    }

    /// Scrolls to the first title under a letter, loading the pages before it first.
    private func jump(to entry: LibraryAlphabetIndex.Entry) {
        jumpTask?.cancel()
        let key = queryKey
        jumpTask = Task {
            if entry.offset >= items.count { await fetchMore(through: entry.offset) }
            guard !Task.isCancelled, key == queryKey, let item = items[safe: entry.offset] else { return }
            topID = item.id
        }
    }
}

/// The letters down the side of a title-sorted library. Click a letter, or
/// drag along the bar, to jump there.
private struct MacAlphabetBar: View {
    let index: LibraryAlphabetIndex
    let current: Int?
    let jump: (LibraryAlphabetIndex.Entry) -> Void
    @State private var dragged: Int?

    var body: some View {
        let entries = index.entries
        GeometryReader { proxy in
            let rowHeight = proxy.size.height / CGFloat(max(entries.count, 1))
            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { i in
                    Text(entries[i].title)
                        .font(.system(size: min(11, rowHeight * 0.8), weight: .semibold))
                        .foregroundStyle(i == (dragged ?? current) ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let i = min(max(Int(value.location.y / rowHeight), 0), entries.count - 1)
                        guard i != dragged else { return }
                        dragged = i
                        jump(entries[i])
                    }
                    .onEnded { _ in dragged = nil }
            )
        }
        // Letters keep a steady spacing in a tall window rather than spreading out.
        .frame(width: 22)
        .frame(maxHeight: CGFloat(entries.count) * 18)
        .padding(.vertical, 12)
        .padding(.trailing, 4)
        .help("Jump to a Letter")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Letters")
        .accessibilityValue(current.map { entries[$0].title } ?? "")
        .accessibilityAdjustableAction { direction in
            let from = current ?? 0
            let to = direction == .increment ? min(from + 1, entries.count - 1) : max(from - 1, 0)
            jump(entries[to])
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
