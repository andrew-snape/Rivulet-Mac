// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

struct MacLiveTVSettings: View {
    /// Same key and meaning as tvOS and iOS: 0 lets the engine find the page.
    @AppStorage("liveTeletextPage") private var teletextPage = Locale.current.region?.identifier == "AU" ? 801 : 0
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

            Section {
                TextField("Teletext Caption Page", value: $teletextPage, format: .number.grouping(.never))
            } header: {
                Text("Captions")
            } footer: {
                Text("Broadcasts that carry captions as teletext use this page. Use 0 to find it automatically. It applies from the next channel you tune. Caption size, colour and font follow System Settings > Accessibility > Captions.")
                    .foregroundStyle(.secondary)
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
