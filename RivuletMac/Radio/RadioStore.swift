// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Observation

/// The internet radio playlists the user has added, and the stations each one
/// lists. The playlists are saved; the stations are fetched again each launch.
@MainActor
@Observable
final class RadioStore {
    static let shared = RadioStore()

    struct Playlist: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let url: URL
    }

    enum RadioError: LocalizedError {
        case invalidAddress
        case noStations

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return "Enter a web address that starts with http:// or https://."
            case .noStations:
                return "No stations were found in that playlist."
            }
        }
    }

    private static let defaultsKey = "radioPlaylists"

    private(set) var playlists: [Playlist]
    private(set) var stations: [UUID: [M3UParser.ParsedChannel]] = [:]
    private(set) var failures: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.defaultsKey)
        playlists = saved.flatMap { try? JSONDecoder().decode([Playlist].self, from: $0) } ?? []
    }

    /// Checks the playlist has stations, then saves it. Nothing is saved on failure.
    func add(name: String, address: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else {
            throw RadioError.invalidAddress
        }
        let found = try await M3UParser().parse(from: url)
        guard !found.isEmpty else { throw RadioError.noStations }

        let typedName = name.trimmingCharacters(in: .whitespaces)
        let playlist = Playlist(id: UUID(), name: typedName.isEmpty ? (url.host() ?? "Radio") : typedName, url: url)
        playlists.append(playlist)
        stations[playlist.id] = found
        save()
    }

    func remove(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        stations[id] = nil
        failures[id] = nil
        save()
    }

    /// Fetches any playlist whose stations are not in memory yet.
    func refreshMissing() async {
        for playlist in playlists where stations[playlist.id] == nil {
            await refresh(playlist.id)
        }
    }

    /// Fetches a playlist again. A failed fetch keeps the stations already shown.
    func refresh(_ id: UUID) async {
        guard let playlist = playlists.first(where: { $0.id == id }), !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        do {
            let found = try await M3UParser().parse(from: playlist.url)
            guard !found.isEmpty else { throw RadioError.noStations }
            stations[id] = found
            failures[id] = nil
        } catch {
            failures[id] = error.localizedDescription
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
