// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacPlexSettings: View {
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var servers: [PlexDevice] = []
    @State private var switchingID: String?
    @State private var showingSignIn = false
    @State private var switchFailed = false

    var body: some View {
        Form {
            Section("Account") {
                if plex.isSignedIn {
                    LabeledContent("Signed In As", value: profiles.selectedUser?.displayName ?? plex.profileDisplayName ?? "Plex")
                    Button("Sign Out of Plex", role: .destructive) { plex.signOut() }
                } else {
                    Button("Sign In to Plex…") { showingSignIn = true }
                }
            }

            if plex.isSignedIn {
                Section("Server") {
                    if servers.isEmpty {
                        LabeledContent("Current", value: plex.selectedServerName ?? "None")
                    }
                    ForEach(servers) { server in
                        Button {
                            switchingID = server.id
                            Task {
                                let connected = await plex.switchServer(to: server)
                                switchFailed = !connected
                                switchingID = nil
                            }
                        } label: {
                            MacServerRow(server: server, isCurrent: plex.isCurrentServer(server),
                                         isConnecting: switchingID == server.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(switchingID != nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: plex.isSignedIn) {
            servers = plex.isSignedIn ? ((try? await plex.accountServers()) ?? []) : []
        }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
        .alert("Couldn't Connect", isPresented: $switchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That server didn't answer. Rivulet is still using the previous one.")
        }
    }

    @ViewBuilder
    private var qualityChoices: some View {
        ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0.rawValue) }
    }
}
