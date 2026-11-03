// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacPlaylistForm: View {
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

struct MacServerForm: View {
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
struct MacFormButtons: ViewModifier {
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
