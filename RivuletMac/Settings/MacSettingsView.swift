// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Sparkle
import SwiftUI

/// The panes of Settings (⌘,), listed in the sidebar in this order.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case plex, video, liveTV, music, sidebar, general

    static let storageKey = "settingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plex: "Plex"
        case .video: "Video"
        case .liveTV: "Live TV"
        case .music: "Music"
        case .sidebar: "Sidebar"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .plex: "person.crop.circle"
        case .video: "play.rectangle.fill"
        case .liveTV: "play.tv.fill"
        case .music: "music.note"
        case .sidebar: "sidebar.left"
        case .general: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .plex: .orange
        case .video: .blue
        case .liveTV: .orange
        case .music: .pink
        case .sidebar: .indigo
        case .general: .gray
        }
    }
}

struct MacSettingsView: View {
    let updater: SPUUpdater
    @AppStorage(MacSettingsPane.storageKey) private var pane: MacSettingsPane = .plex

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<MacSettingsPane?>(get: { pane }, set: { if let new = $0 { pane = new } })) {
                Section {
                    MacPlexAccountRow().tag(MacSettingsPane.plex)
                }
                Section {
                    ForEach([MacSettingsPane.video, .liveTV, .music]) { MacSettingsSidebarLabel(pane: $0) }
                }
                Section {
                    ForEach([MacSettingsPane.sidebar, .general]) { MacSettingsSidebarLabel(pane: $0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .plex: MacPlexSettings()
                case .video: MacVideoSettings()
                case .liveTV: MacLiveTVSettings()
                case .music: MacMusicSettings()
                case .sidebar: MacSidebarSettings()
                case .general: MacGeneralSettings(updater: updater)
                }
            }
            .navigationTitle(pane.title)
            .id(pane)
        }
        .frame(width: 720, height: 520)
    }
}

private struct MacSettingsSidebarLabel: View {
    let pane: MacSettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            MacSettingsTile(symbol: pane.symbol, tint: pane.tint)
        }
        .tag(pane)
    }
}

/// A white glyph on a rounded, tinted square, as in System Settings.
private struct MacSettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The Plex row at the top of the sidebar: the profile's picture, name and server.
private struct MacPlexAccountRow: View {
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var profiles = PlexUserProfileManager.shared

    var body: some View {
        HStack(spacing: 8) {
            MacPlexAvatar(url: plex.isSignedIn ? (profiles.selectedUser?.avatarURL ?? plex.profileImageURL) : nil, size: 30)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(plex.isSignedIn ? (profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex") : "Sign In to Plex")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(plex.isSignedIn ? (plex.selectedServerName ?? "Plex") : "Plex account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
