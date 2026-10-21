// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Observation

/// The internet radio playlists the user has added, and the stations each one
/// lists. The playlists are saved; the stations are fetched again each launch.
/// Single stations added by their own stream address, the stations hidden and
/// the quality last heard on each station are saved too.
@MainActor
@Observable
final class RadioStore {
    static let shared = RadioStore()

    struct Playlist: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let url: URL
    }

    /// One station added by its stream address rather than from a playlist.
    struct Station: Codable, Equatable {
        var name: String
        let url: URL
    }

    enum RadioError: LocalizedError {
        case invalidAddress
        case noStations
        case noStream
        case alreadyAdded

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return "Enter a web address that starts with http:// or https://."
            case .noStations:
                return "No stations were found in that playlist."
            case .noStream:
                return "No stream address was found in that file."
            case .alreadyAdded:
                return "That station is already in My Stations."
            }
        }
    }

    private static let defaultsKey = "radioPlaylists"
    private static let stationsKey = "radioStations"
    private static let hiddenKey = "radioHiddenStations"
    private static let qualityKey = "radioStationQuality"

    private(set) var playlists: [Playlist]
    private(set) var ownStations: [Station]
    /// Hidden stations by stream address, so a station stays hidden in every playlist that lists it.
    private(set) var hidden: Set<String>
    /// The quality each station was last heard at ("AAC · 128 kbps"), by stream address.
    private(set) var qualities: [String: String]
    private(set) var stations: [UUID: [M3UParser.ParsedChannel]] = [:]
    private(set) var failures: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.defaultsKey)
        playlists = saved.flatMap { try? JSONDecoder().decode([Playlist].self, from: $0) } ?? []
        let savedStations = defaults.data(forKey: Self.stationsKey)
        ownStations = savedStations.flatMap { try? JSONDecoder().decode([Station].self, from: $0) } ?? []
        hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        qualities = defaults.dictionary(forKey: Self.qualityKey) as? [String: String] ?? [:]
    }

    /// The single stations, in the form the player and the lists take.
    var ownStationChannels: [M3UParser.ParsedChannel] {
        ownStations.map {
            M3UParser.ParsedChannel(tvgId: nil, tvgName: nil, tvgLogo: nil, groupTitle: nil,
                                    channelNumber: nil, name: $0.name, streamURL: $0.url)
        }
    }

    func isOwnStation(_ station: M3UParser.ParsedChannel) -> Bool {
        ownStations.contains { $0.url == station.streamURL }
    }

    /// Checks the playlist has stations, then saves it. Nothing is saved on failure.
    func add(name: String, address: String) async throws {
        let url = try Self.webAddress(address)
        let found = try await M3UParser().parse(from: url)
        guard !found.isEmpty else { throw RadioError.noStations }

        let typedName = name.trimmingCharacters(in: .whitespaces)
        let playlist = Playlist(id: UUID(), name: typedName.isEmpty ? (url.host() ?? "Radio") : typedName, url: url)
        playlists.append(playlist)
        stations[playlist.id] = found
        save()
    }

    /// Saves one station by its stream address. A .pls or plain .m3u file, as
    /// many stations link to, is read for the stream address inside it.
    func addStation(name: String, address: String) async throws {
        let url = try await Self.streamAddress(Self.webAddress(address))
        guard !ownStations.contains(where: { $0.url == url }) else { throw RadioError.alreadyAdded }
        let typedName = name.trimmingCharacters(in: .whitespaces)
        ownStations.append(Station(name: typedName.isEmpty ? (url.host() ?? "Station") : typedName, url: url))
        saveStations()
    }

    /// The name the station's server announces, for the add form to fill in.
    /// Nil for an HLS stream, which announces none.
    static func announcedName(of address: String) async -> String? {
        guard let url = try? await streamAddress(webAddress(address)) else { return nil }
        return await RadioHeaderProbe.name(of: url)
    }

    func removeStation(_ station: M3UParser.ParsedChannel) {
        ownStations.removeAll { $0.url == station.streamURL }
        saveStations()
    }

    func isHidden(_ station: M3UParser.ParsedChannel) -> Bool {
        hidden.contains(station.streamURL.absoluteString)
    }

    func setHidden(_ isHidden: Bool, _ station: M3UParser.ParsedChannel) {
        setHidden(isHidden, streams: [station.streamURL])
    }

    func setHidden(_ isHidden: Bool, streams: Set<URL>) {
        let keys = Set(streams.map(\.absoluteString))
        if isHidden { hidden.formUnion(keys) } else { hidden.subtract(keys) }
        defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
    }

    func quality(of station: M3UParser.ParsedChannel) -> String? {
        qualities[station.streamURL.absoluteString]
    }

    func setQuality(_ quality: String, of url: URL) {
        let key = url.absoluteString
        guard qualities[key] != quality else { return }
        qualities[key] = quality
        defaults.set(qualities, forKey: Self.qualityKey)
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

    private static func webAddress(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else {
            throw RadioError.invalidAddress
        }
        return url
    }

    /// The first stream address in a .pls (`File1=`) or plain .m3u file. Any
    /// other address is the stream itself; it is not fetched, as a live
    /// stream never finishes downloading.
    private static func streamAddress(_ url: URL) async throws -> URL {
        guard ["pls", "m3u"].contains(url.pathExtension.lowercased()) else { return url }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw M3UParseError.httpError(http.statusCode)
        }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("file"), let equals = value.firstIndex(of: "=") {
                value = String(value[value.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            }
            if let stream = try? webAddress(value) { return stream }
        }
        throw RadioError.noStream
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func saveStations() {
        guard let data = try? JSONEncoder().encode(ownStations) else { return }
        defaults.set(data, forKey: Self.stationsKey)
    }
}
