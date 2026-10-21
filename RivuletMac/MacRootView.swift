// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// What the sidebar opens.
enum MacSection: Hashable {
    case home
    case search
    case library(String)
    case liveTV
    case radio
}

/// The main window: Plex, Live TV and Radio in the sidebar, the chosen page
/// beside it, and a Plex title playing over the whole window.
struct MacRootView: View {
    @Environment(MacPlexSession.self) private var plex
    @Environment(MacPlaybackController.self) private var playback
    @Environment(MacLivePlayback.self) private var live
    @Environment(MacMultiview.self) private var multiview
    @Environment(MacRadioPlayback.self) private var radio
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MacSidebarLayout.orderKey) private var sidebarOrder = ""
    @AppStorage(MacSidebarLayout.hiddenKey) private var sidebarHidden = ""
    @State private var section: MacSection? = .home
    @State private var path = NavigationPath()
    @State private var searchQuery = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var choosingProfile = false
    @State private var showingSignIn = false
    @State private var accountHovering = false

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                detail.safeAreaInset(edge: .bottom) { MacRadioBar() }
            }
            // Around the split view, not the detail stack: the split view hosts the
            // stack's pushed pages, which miss environment set inside its detail column.
            .macPlexActionHost(open: { path.append($0) })
            // On the split view, so the field sits in the window toolbar for every page,
            // not only inside the detail column's stack.
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Movies, Shows and Episodes")
            if let session = playback.session {
                MacVODPlayerView(session: session, player: session.player, close: { playback.close() })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playback.session != nil)
        // A Plex title has the window to itself: the sidebar and back buttons step aside.
        .toolbarVisibility(playback.session == nil ? .automatic : .hidden, for: .windowToolbar)
        // The playback keys act only in this window, not in a sheet or Settings.
        .background(MacWindowReader {
            MacAppDelegate.mainWindow = $0
            MacAppDelegate.vod?.applyWindowLevel(to: $0)
        })
        .onAppear {
            playback.plex = plex
            playback.onStart = { [live, multiview, radio] in
                live.stop()
                multiview.stopAll()
                radio.stop()
            }
        }
        .task { await plex.verifyConnection() }
        .onChange(of: section) { old, new in
            path = NavigationPath()
            // Live TV plays inside its page; leaving the page stops it, unless
            // the picture has its own window.
            if old == .liveTV, new != .liveTV {
                multiview.stopAll()
                if !live.isPoppedOut { live.stop() }
            }
        }
        // Closing the floating window off the Live TV page ends the stream.
        .onChange(of: live.isPoppedOut) { was, isNow in
            if was, !isNow, section != .liveTV { live.stop() }
        }
        // One stream at a time: a channel or a multiview tile takes the sound from radio.
        .onChange(of: live.channel?.id) { _, channelID in
            if channelID != nil { radio.stop() }
        }
        .onChange(of: multiview.tiles.count) { _, count in
            if count > 0 { radio.stop() }
        }
        // Hiding the row that is open moves to the first one left.
        .onChange(of: sidebarHidden) {
            let hiddenIDs = MacSidebarLayout.ids(sidebarHidden)
            let visible = MacSidebarLayout.plexItems(libraries: plex.libraries, order: sidebarOrder)
                .filter { !hiddenIDs.contains($0.id) }
                .map(\.section)
            let liveVisible = !hiddenIDs.contains(MacSidebarLayout.liveTVID)
            let radioVisible = !hiddenIDs.contains(MacSidebarLayout.radioID)
            let stillShown = section.map {
                visible.contains($0) || ($0 == .liveTV && liveVisible) || ($0 == .radio && radioVisible)
            } ?? false
            if !stillShown {
                section = visible.first ?? (liveVisible ? .liveTV : radioVisible ? .radio : .home)
            }
        }
        .onChange(of: plex.sessionGeneration) { path = NavigationPath() }
        // Signing out, from the sidebar or from Settings, ends the Plex title playing.
        .onChange(of: plex.isSignedIn) { _, signedIn in
            if !signedIn { playback.close() }
        }
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
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didEnterFullScreenNotification) {
                isFullScreen = true
                withAnimation { columns = .detailOnly }
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification) {
                isFullScreen = false
                withAnimation { columns = .all }
            }
        }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            let hiddenIDs = MacSidebarLayout.ids(sidebarHidden)
            let items = MacSidebarLayout.plexItems(libraries: plex.libraries, order: sidebarOrder)
                .filter { !hiddenIDs.contains($0.id) }
            if !items.isEmpty {
                Section("Plex") {
                    ForEach(items) { item in
                        Label(item.title, systemImage: item.icon).tag(item.section)
                    }
                }
            }
            if !hiddenIDs.contains(MacSidebarLayout.liveTVID) {
                Section("Live TV") {
                    Label("Channels", systemImage: "play.tv").tag(MacSection.liveTV)
                }
            }
            if !hiddenIDs.contains(MacSidebarLayout.radioID) {
                Section("Radio") {
                    Label("Stations", systemImage: "radio").tag(MacSection.radio)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) { accountButton.padding(10) }
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
                Button("Sign Out of Plex", role: .destructive) { plex.signOut() }
            } label: {
                HStack(spacing: 10) {
                    MacPlexAvatar(url: profiles.selectedUser?.avatarURL ?? plex.profileImageURL, size: 30)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let server = plex.selectedServerName {
                            Text(server)
                                .font(.caption)
                                .foregroundStyle(MacTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(MacTheme.surface.opacity(accountHovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onHover { accountHovering = $0 }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
        } else if section == .radio {
            MacRadioView()
        } else {
            NavigationStack(path: $path) {
                plexRoot
                    .navigationDestination(for: PlexMetadata.self) { MacPlexDetailView(item: $0) }
                    .navigationDestination(for: PlexLibrary.self) { MacPlexLibraryView(library: $0) }
                    .navigationDestination(for: MacPlexHubRoute.self) { MacPlexHubGridView(route: $0) }
            }
            .macScreen()
        }
    }

    @ViewBuilder
    private var plexRoot: some View {
        if !plex.isConfigured {
            MacPlexConnectView()
        } else {
            switch section ?? .home {
            case .home, .liveTV, .radio:
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
