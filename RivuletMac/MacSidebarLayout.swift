// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One row of the Plex section of the sidebar.
struct MacSidebarItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let section: MacSection
}

/// The sidebar's order and hidden rows, kept as comma-separated ids in
/// `sidebarOrder` and `sidebarHidden`. Only the Plex section reorders; Live TV
/// can be hidden but stays in its own section.
enum MacSidebarLayout {
    static let orderKey = "sidebarOrder"
    static let hiddenKey = "sidebarHidden"
    static let liveTVID = "liveTV"

    static func ids(_ stored: String) -> [String] {
        stored.split(separator: ",").map(String.init)
    }

    /// Home, Search and the movie and TV libraries (movies first), in the saved
    /// order. Rows the saved order doesn't know yet follow in default order.
    static func plexItems(libraries: [PlexLibrary], order: String) -> [MacSidebarItem] {
        let videoLibraries = libraries
            .filter { $0.type == "movie" || $0.type == "show" }
            .sorted { lhs, rhs in
                lhs.type != rhs.type
                    ? lhs.type == "movie"
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        let defaults = [
            MacSidebarItem(id: "home", title: "Home", icon: "house", section: .home),
            MacSidebarItem(id: "search", title: "Search", icon: "magnifyingglass", section: .search),
        ] + videoLibraries.map {
            MacSidebarItem(id: "library.\($0.key)", title: $0.title, icon: $0.icon, section: .library($0.key))
        }
        let position = Dictionary(ids(order).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Sorted is not stable, so the default index breaks ties.
        return defaults.enumerated()
            .sorted { lhs, rhs in
                let l = position[lhs.element.id] ?? Int.max
                let r = position[rhs.element.id] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Settings > Sidebar: drag to reorder, switch off to hide.
struct MacSidebarSettings: View {
    @Environment(MacPlexSession.self) private var plex
    @AppStorage(MacSidebarLayout.orderKey) private var order = ""
    @AppStorage(MacSidebarLayout.hiddenKey) private var hidden = ""

    var body: some View {
        let items = MacSidebarLayout.plexItems(libraries: plex.libraries, order: order)
        // A top-level List: drag-to-reorder does not work in a List nested in a Form.
        List {
            Section("Plex") {
                ForEach(items) { item in
                    Toggle(isOn: visibility(of: item.id)) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
                .onMove { source, destination in
                    var ids = items.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    order = ids.joined(separator: ",")
                }
            }
            Section("Live TV") {
                Toggle(isOn: visibility(of: MacSidebarLayout.liveTVID)) {
                    Label("Channels", systemImage: "play.tv")
                }
            }
        }
        .frame(height: 380)
    }

    private func visibility(of id: String) -> Binding<Bool> {
        Binding {
            !MacSidebarLayout.ids(hidden).contains(id)
        } set: { shown in
            var ids = MacSidebarLayout.ids(hidden).filter { $0 != id }
            if !shown { ids.append(id) }
            hidden = ids.joined(separator: ",")
        }
    }
}
