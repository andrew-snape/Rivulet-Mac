// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine
import SwiftUI

/// What the sidebar opens.
enum MacSection: Hashable {
    case home
    case search
    case library(String)
    case liveTV
}

/// The main window: Plex and Live TV in the sidebar, the chosen page beside
/// it, and a Plex title playing over the whole window.
struct MacRootView: View {
    @EnvironmentObject private var plex: MacPlexSession
    @EnvironmentObject private var playback: MacPlaybackController
    @EnvironmentObject private var live: MacLivePlayback
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: MacSection? = .home
    @State private var path = NavigationPath()
    @State private var searchQuery = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var choosingProfile = false
    @State private var showingSignIn = false

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                detail
            }
            if let session = playback.session {
                MacVODPlayerView(session: session, player: session.player, close: playback.close)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.session != nil)
        .onAppear {
            playback.plex = plex
            playback.onStart = { [live] in live.stop() }
        }
        .task { await plex.verifyConnection() }
        .onChange(of: section) { old, new in
            path = NavigationPath()
            // Live TV plays inside its page; leaving the page stops it.
            if old == .liveTV, new != .liveTV { live.stop() }
        }
        .onChange(of: plex.sessionGeneration) { path = NavigationPath() }
        .onChange(of: searchQuery) { _, query in
            if !query.isEmpty, section != .search { section = .search }
        }
        // Content is withheld until a profile is entered: ask who is watching,
        // and nothing of the locked profile's keeps playing.
        .onChange(of: profiles.needsProfileSelection, initial: true) { _, needed in
            if needed { playback.close() }
            choosingProfile = needed && profiles.hasLoadedProfiles
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await plex.refreshIfStale() } }
        }
        // Full screen is for watching: the sidebar steps aside, and comes back on exit.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
            withAnimation { columns = .detailOnly }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            withAnimation { columns = .all }
        }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Plex") {
                Label("Home", systemImage: "house").tag(MacSection.home)
                Label("Search", systemImage: "magnifyingglass").tag(MacSection.search)
                ForEach(videoLibraries) { library in
                    Label(library.title, systemImage: library.icon).tag(MacSection.library(library.key))
                }
            }
            Section("Live TV") {
                Label("Channels", systemImage: "play.tv").tag(MacSection.liveTV)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) { accountButton.padding(10) }
    }

    /// Movie and TV libraries, movies first.
    private var videoLibraries: [PlexLibrary] {
        plex.libraries
            .filter { $0.type == "movie" || $0.type == "show" }
            .sorted { lhs, rhs in
                lhs.type != rhs.type
                    ? lhs.type == "movie"
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    @ViewBuilder
    private var accountButton: some View {
        if plex.isSignedIn {
            Menu {
                if let server = plex.selectedServerName {
                    Text(server)
                }
                if profiles.hasMultipleProfiles {
                    Button("Switch Profile…") { choosingProfile = true }
                }
                Divider()
                Button("Sign Out of Plex", role: .destructive) {
                    playback.close()
                    plex.signOut()
                }
            } label: {
                HStack(spacing: 8) {
                    MacPlexAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 26)
                    Text(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            Button {
                showingSignIn = true
            } label: {
                Label("Sign In to Plex…", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if section == .liveTV {
            MacLiveTVView(isFullScreen: isFullScreen)
        } else {
            NavigationStack(path: $path) {
                plexRoot
                    .navigationDestination(for: PlexMetadata.self) { MacPlexDetailView(item: $0) }
                    .navigationDestination(for: PlexLibrary.self) { MacPlexLibraryView(library: $0) }
                    .navigationDestination(for: MacPlexHubRoute.self) { MacPlexHubGridView(route: $0) }
            }
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Movies, Shows and Episodes")
            .macPlexActionHost(open: { path.append($0) })
        }
    }

    @ViewBuilder
    private var plexRoot: some View {
        if !plex.isConfigured {
            MacPlexConnectView()
        } else {
            switch section ?? .home {
            case .home, .liveTV:
                MacPlexHomeView()
            case .search:
                MacPlexSearchView(query: $searchQuery)
            case .library(let key):
                if let library = plex.libraries.first(where: { $0.key == key }) {
                    MacPlexLibraryView(library: library).id(key)
                } else {
                    ContentUnavailableView("Library Not Found", systemImage: "rectangle.stack")
                }
            }
        }
    }
}
