// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Settings (⌘,). Live TV sources are added through the shared
/// verify-then-add connector.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacPlexSettings()
                .tabItem { Label("Plex", systemImage: "person.crop.circle") }
            MacSourcesSettings()
                .tabItem { Label("Sources", systemImage: "antenna.radiowaves.left.and.right") }
            MacSidebarSettings()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            MacPlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
        }
        .frame(width: 560)
    }
}

// MARK: - Sources

private struct MacSourcesSettings: View {
    private let store = LiveTVDataStore.shared
    @State private var adding: AddKind?
    @State private var removing: LiveTVDataStore.LiveTVSourceInfo?
    @State private var plexFailure: LiveTVConnectError?

    enum AddKind: String, Identifiable {
        case playlist, server
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                if store.sources.isEmpty {
                    Text("No sources yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.sources) { source in
                    HStack {
                        Image(systemName: source.sourceType.iconName)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            Text(summary(of: source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…", role: .destructive) { removing = source }
                    }
                }
            } header: {
                Text("Live TV Sources")
            } footer: {
                HStack {
                    Menu("Add Source") {
                        Button("M3U Playlist…") { adding = .playlist }
                        Button("Dispatcharr Server…") { adding = .server }
                        Button("Plex Live TV") { addPlex() }
                            .disabled(PlexAuthManager.shared.selectedServerToken == nil)
                    }
                    .fixedSize()
                    Spacer()
                    Button("Refresh Channels") {
                        Task {
                            await store.refreshChannels()
                            await store.loadEPG(startDate: Date(), hours: LiveTVDataStore.refreshWindowHours)
                        }
                    }
                    .disabled(store.sources.isEmpty || store.isLoadingChannels)
                }
                .padding(.top, 8)
            }

            let hidden = store.channels.filter { store.isHidden($0) }
            if !hidden.isEmpty {
                Section {
                    ForEach(hidden) { channel in
                        HStack {
                            Text(channel.numberAndName)
                            Spacer()
                            Button("Unhide") { store.unhide(channel.id) }
                        }
                    }
                } header: {
                    Text("Hidden Channels")
                } footer: {
                    Button("Unhide All") { store.unhideAll() }
                        .padding(.top, 8)
                }
            }

            if let error = store.channelsError {
                Section("Problems") {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.epgIssues.isEmpty {
                Section("Guide") {
                    ForEach(store.epgIssues) { issue in
                        Text("\(issue.sourceName): \(issue.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $adding) { kind in
            switch kind {
            case .playlist: MacPlaylistForm()
            case .server: MacServerForm()
            }
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "this source")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let source = removing else { return }
                Task { await store.removeSource(id: source.id) }
                removing = nil
            }
        } message: {
            Text("Its channels and favourites leave the list. You can add it again later.")
        }
        .alert(plexFailure?.title ?? "", isPresented: Binding(get: { plexFailure != nil }, set: { if !$0 { plexFailure = nil } })) {
            Button("OK", role: .cancel) { plexFailure = nil }
        } message: {
            Text(plexFailure?.message ?? "")
        }
    }

    /// The signed-in Plex server's tuners, when it has any.
    private func addPlex() {
        Task {
            do {
                try await LiveTVSourceConnector().connect(LiveTVSourceConnector.plexRequest())
            } catch {
                plexFailure = error as? LiveTVConnectError ?? .plex(error.localizedDescription)
            }
        }
    }

    private func summary(of source: LiveTVDataStore.LiveTVSourceInfo) -> String {
        var parts = [source.sourceType.displayName]
        if source.channelCount > 0 { parts.append("\(source.channelCount) channels") }
        if let profile = source.channelProfile { parts.append("Profile: \(profile)") }
        return parts.joined(separator: " · ")
    }
}

private struct MacPlaylistForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var m3u = ""
    @State private var epg = ""
    @State private var isWorking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(LiveTVSourceConnector.defaultPlaylistName))
                TextField("Playlist URL", text: $m3u, prompt: Text("http://example.com/playlist.m3u"))
                TextField("Guide (XMLTV) URL", text: $epg, prompt: Text("Optional"))
            } header: {
                Text("Add an M3U Playlist")
            } footer: {
                Text("The guide URL is optional. Without it, channels play but show no programme details.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disableAutocorrection(true)
        .modifier(MacFormButtons(isWorking: isWorking, canAdd: !m3u.isEmpty, add: add, failure: $failure))
    }

    private func add() {
        do {
            let request = try LiveTVSourceConnector.playlistRequest(m3uURL: m3u, epgURL: epg)
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    try await LiveTVSourceConnector().connect(request, name: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                } catch {
                    failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
                }
            }
        } catch {
            failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
        }
    }
}

private struct MacServerForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var profile = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var failure: LiveTVConnectError?

    var body: some View {
        let host = LiveTVSourceConnector.suggestedHost
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(LiveTVSourceConnector.defaultServerName))
                TextField("Server Address", text: $address, prompt: Text("http://\(host):9191"))
                TextField("Channel Profile", text: $profile, prompt: Text("Optional"))
            } header: {
                Text("Add a Dispatcharr Server")
            }
            Section {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            } footer: {
                Text("Optional. Signing in lets Rivulet read recordings; watching works without it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disableAutocorrection(true)
        .modifier(MacFormButtons(isWorking: isWorking, canAdd: !address.isEmpty, add: add, failure: $failure))
    }

    private func add() {
        let connector = LiveTVSourceConnector()
        do {
            let request = try connector.serverRequest(address: address, username: username, password: password,
                                                      channelProfile: profile)
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    try await connector.connect(request, name: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                } catch {
                    failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
                }
            }
        } catch {
            failure = error as? LiveTVConnectError ?? .source(error.localizedDescription)
        }
    }
}

/// Cancel and Add under a sheet's form, a busy state while the source is
/// checked, and the connector's own words when it fails.
private struct MacFormButtons: ViewModifier {
    let isWorking: Bool
    let canAdd: Bool
    let add: () -> Void
    @Binding var failure: LiveTVConnectError?
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || isWorking)
            }
            .padding(16)
        }
        .frame(width: 480)
        .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
    }
}

// MARK: - Plex

private struct MacPlexSettings: View {
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @AppStorage(StreamingQuality.homeKey) private var homeQuality = StreamingQuality.homeDefault.rawValue
    @AppStorage(StreamingQuality.awayKey) private var awayQuality = StreamingQuality.awayDefault.rawValue
    @AppStorage("autoSkipIntro") private var skipIntro = false
    @AppStorage("autoSkipRecap") private var skipRecap = false
    @AppStorage("autoSkipCredits") private var skipCredits = false
    @AppStorage("autoSkipAds") private var skipAds = false
    @AppStorage("useIntroDB") private var useIntroDB = false
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

            Section {
                Picker("On Your Network", selection: $homeQuality) { qualityChoices }
                Picker("Away From Home", selection: $awayQuality) { qualityChoices }
            } header: {
                Text("Streaming Quality")
            } footer: {
                Text("Original plays the file as it is. Auto measures the connection and picks a quality that will not stall.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Skip Intros", isOn: $skipIntro)
                Toggle("Skip Recaps", isOn: $skipRecap)
                Toggle("Skip Credits", isOn: $skipCredits)
                Toggle("Skip Commercials", isOn: $skipAds)
                Toggle("Use Community Markers", isOn: $useIntroDB)
            } header: {
                Text("Skipping")
            } footer: {
                Text("Community markers fill in intros and credits Plex has not marked, from IntroDB. Only the show's IMDb ID and the episode number are sent.")
                    .foregroundStyle(.secondary)
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

// MARK: - Playback

private struct MacPlaybackSettings: View {
    /// Same key and meaning as tvOS and iOS: 0 lets the engine find the page.
    @AppStorage("liveTeletextPage") private var teletextPage = Locale.current.region?.identifier == "AU" ? 801 : 0

    var body: some View {
        Form {
            Section {
                TextField("Teletext Caption Page", value: $teletextPage, format: .number.grouping(.never))
            } footer: {
                Text("Broadcasts that carry captions as teletext use this page. Use 0 to find it automatically. It applies from the next channel you tune. Caption size, colour and font follow System Settings > Accessibility > Captions.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
