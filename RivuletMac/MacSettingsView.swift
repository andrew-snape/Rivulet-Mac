// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Settings (⌘,). Sources are added through the same verify-then-add
/// connector the tvOS and iOS forms use.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacSourcesSettings()
                .tabItem { Label("Sources", systemImage: "antenna.radiowaves.left.and.right") }
            MacPlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
        }
        .frame(width: 560)
    }
}

// MARK: - Sources

private struct MacSourcesSettings: View {
    @ObservedObject private var store = LiveTVDataStore.shared
    @State private var adding: AddKind?
    @State private var removing: LiveTVDataStore.LiveTVSourceInfo?

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
                    Button("Add Playlist…") { adding = .playlist }
                    Button("Add Dispatcharr Server…") { adding = .server }
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
