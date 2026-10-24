// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
@preconcurrency import AVFoundation
import CoreAudioTypes
@preconcurrency import CoreMedia
import Foundation
import Observation
import os

/// Station names and player states only, never the stream URL.
private let radioLog = Logger(subsystem: "com.rivulet.app", category: "Radio")

/// The radio station playing. Radio is sound only, so it plays through AVPlayer
/// with no picture surface. One station at a time, and it keeps playing when
/// the page changes.
@MainActor
@Observable
final class MacRadioPlayback {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var station: M3UParser.ParsedChannel?
    private(set) var state: State = .idle
    /// What the station says is on, from its stream's metadata (ICY on
    /// Shoutcast and Icecast, ID3 in HLS). Nil when it sends none.
    private(set) var streamTitle: String?
    /// The cover of the song on, when it could be found; the station's logo stands in until then.
    private(set) var cover: NSImage?
    /// Songs the station has named since it was tuned, newest first.
    private(set) var recentSongs: [RadioSong] = []
    /// The song on, unless the station only names itself between songs.
    var song: RadioSong? {
        guard let text = streamTitle, text.caseInsensitiveCompare(station?.name ?? "") != .orderedSame else { return nil }
        return RadioSong(text)
    }
    /// The codec and bitrate the station plays at: the bitrate a Shoutcast or
    /// Icecast server announces, else what the player reports, and the codec
    /// from the decoded track. Nil until either is known.
    var quality: RadioQuality? {
        let track = trackQuality ?? RadioQuality()
        let header = headerQuality ?? RadioQuality()
        let combined = RadioQuality(codec: track.codec ?? header.codec,
                                    kbps: header.kbps ?? track.kbps,
                                    sampleRate: track.sampleRate ?? header.sampleRate)
        return combined == RadioQuality() ? nil : combined
    }
    private var headerQuality: RadioQuality?
    private var trackQuality: RadioQuality?

    @ObservationIgnored private let player = AVPlayer()

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var itemTask: Task<Void, Never>?
    @ObservationIgnored private var metadataReader: RadioMetadataReader?
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var coverTask: Task<Void, Never>?

    init() {
        statusTask = Task { [weak self, player] in
            for await status in Self.changes(of: player, \.timeControlStatus) {
                self?.timeControlChanged(status)
            }
        }
    }

    func play(_ newStation: M3UParser.ParsedChannel) {
        // One stream at a time: a station pauses music.
        MacAppDelegate.music?.pause()
        station = newStation
        state = .loading
        radioLog.notice("Play \(newStation.name, privacy: .public)")
        let item = AVPlayerItem(url: newStation.streamURL)
        streamTitle = nil
        resetSongs()
        let reader = RadioMetadataReader { [weak self, weak item] title in
            // A late title from the station before is dropped.
            guard let self, let item, self.player.currentItem === item else { return }
            self.streamTitle = title
            self.songChanged()
        }
        item.add(reader.output)
        metadataReader = reader
        player.replaceCurrentItem(with: item)
        headerQuality = nil
        trackQuality = nil
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            let found = await RadioHeaderProbe.quality(of: newStation.streamURL)
            guard let self, !Task.isCancelled, self.player.currentItem === item else { return }
            self.headerQuality = found
            self.rememberQuality()
        }
        itemTask?.cancel()
        itemTask = Task { [weak self] in
            for await status in Self.changes(of: item, \.status) {
                let name = Self.name(of: status)
                // Domain and code only: an error's description can carry the URL.
                let error = (item.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "none"
                radioLog.notice("Item \(name, privacy: .public), error: \(error, privacy: .public)")
                if status == .readyToPlay { await self?.readTrackQuality(of: item) }
                guard status == .failed else { continue }
                self?.state = .failed("This station couldn't be played.")
                return
            }
        }
        player.play()
    }

    func togglePlayPause() {
        switch state {
        case .playing, .loading:
            player.pause()
        case .paused:
            state = .loading
            player.play()
        case .failed:
            if let station { play(station) }
        case .idle:
            break
        }
    }

    func stop() {
        itemTask?.cancel()
        qualityTask?.cancel()
        player.replaceCurrentItem(with: nil)
        metadataReader = nil
        station = nil
        streamTitle = nil
        resetSongs()
        headerQuality = nil
        trackQuality = nil
        state = .idle
    }

    private func resetSongs() {
        coverTask?.cancel()
        cover = nil
        recentSongs = []
    }

    /// The station named a new song: note it, and look for its cover.
    private func songChanged() {
        coverTask?.cancel()
        cover = nil
        guard let song else { return }
        recentSongs.removeAll { $0 == song }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 20 { recentSongs.removeLast() }
        coverTask = Task { [weak self] in
            guard let url = await RadioCoverLookup.coverURL(for: song),
                  let image = await MacArtworkCache.shared.image(for: url),
                  !Task.isCancelled, let self, self.song == song else { return }
            self.cover = image
        }
    }

    /// A key-value-observed property as an async sequence, starting with its current value.
    /// Read off the object: KVO's `newValue` is nil for enum properties such as
    /// `timeControlStatus`, so the station never left "Connecting".
    private nonisolated static func changes<Root: NSObject, Value: Sendable>(
        of object: Root, _ keyPath: KeyPath<Root, Value> & Sendable
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let observation = object.observe(keyPath, options: [.initial, .new]) { object, _ in
                continuation.yield(object[keyPath: keyPath])
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
    }

    private static func name(of status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    private static func name(of status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        let name = Self.name(of: status)
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        let rate = player.rate
        radioLog.notice("Player \(name, privacy: .public), waiting: \(reason, privacy: .public), rate: \(rate, privacy: .public)")
        // A failed station stays failed until it is played again.
        if case .failed = state { return }
        switch status {
        case .playing:
            state = .playing
            // An HLS station has no tracks yet when it is first ready.
            if trackQuality == nil, let item = player.currentItem {
                Task { await readTrackQuality(of: item) }
            }
        case .waitingToPlayAtSpecifiedRate:
            state = .loading
        case .paused:
            state = station == nil ? .idle : .paused
        @unknown default:
            break
        }
    }

    /// The codec and sample rate of the decoded sound, and the bitrate the
    /// track or HLS variant reports.
    private func readTrackQuality(of item: AVPlayerItem) async {
        var found = RadioQuality()
        for track in item.tracks {
            guard let assetTrack = track.assetTrack,
                  let format = try? await assetTrack.load(.formatDescriptions).first,
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            found.codec = Self.codecName(basic.mFormatID)
            found.sampleRate = basic.mSampleRate > 0 ? basic.mSampleRate : nil
            if let rate = try? await assetTrack.load(.estimatedDataRate), rate > 0 {
                found.kbps = Int((rate / 1000).rounded())
            }
            break
        }
        if found.kbps == nil {
            let bitrate = await withCheckedContinuation { continuation in
                item.fetchAccessLog { log in
                    continuation.resume(returning: log?.events.last?.indicatedBitrate)
                }
            }
            if let bitrate, bitrate > 0 {
                found.kbps = Int((bitrate / 1000).rounded())
            }
        }
        guard player.currentItem === item, found != RadioQuality() else { return }
        trackQuality = found
        rememberQuality()
    }

    /// Saved by station, so the lists can show it before the station plays again.
    private func rememberQuality() {
        guard let station, let summary = quality?.summary else { return }
        RadioStore.shared.setQuality(summary, of: station.streamURL)
    }

    private static func codecName(_ format: AudioFormatID) -> String? {
        switch format {
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEGLayer2: "MP2"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "HE-AAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        case kAudioFormatLinearPCM: "PCM"
        default: nil
        }
    }
}

/// How a station sounds: codec, bitrate and sample rate, each when known.
nonisolated struct RadioQuality: Equatable, Sendable {
    var codec: String?
    var kbps: Int?
    var sampleRate: Double?

    /// "AAC · 128 kbps". Nil when neither is known.
    var summary: String? {
        let parts = [codec, kbps.map { "\($0) kbps" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "44.1 kHz", for the bar's tooltip.
    var sampleRateText: String? {
        sampleRate.map { ($0 / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz" }
    }
}

/// A song a station names. Shoutcast and Icecast send "Artist - Title" as one
/// string; with no " - " in it, the whole text is the title.
nonisolated struct RadioSong: Equatable, Sendable {
    let text: String
    let artist: String?
    let title: String

    init(_ text: String) {
        self.text = text
        if let split = text.range(of: " - ") {
            let artist = text[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = text[split.upperBound...].trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty {
                self.artist = artist
                self.title = title
                return
            }
        }
        artist = nil
        title = text
    }
}

/// Finds a song's cover in the iTunes Search API. Only a hit that names both the
/// artist and the title counts, so a wrong cover is rarer than a missing one.
/// The song's text goes to Apple; nothing else does.
nonisolated enum RadioCoverLookup {
    private nonisolated struct Response: Decodable, Sendable {
        let results: [Hit]
    }

    private nonisolated struct Hit: Decodable, Sendable {
        let artistName: String?
        let trackName: String?
        let artworkUrl100: String?
    }

    @concurrent
    static func coverURL(for song: RadioSong) async -> URL? {
        guard let artist = song.artist else { return nil }
        var parts = URLComponents(string: "https://itunes.apple.com/search")
        parts?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(song.title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let found = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let wantedArtist = normalised(artist)
        let wantedTitle = normalised(song.title)
        guard !wantedArtist.isEmpty, !wantedTitle.isEmpty else { return nil }
        let hit = found.results.first { hit in
            let hitArtist = normalised(hit.artistName ?? "")
            let hitTitle = normalised(hit.trackName ?? "")
            return !hitArtist.isEmpty && !hitTitle.isEmpty
                && (hitArtist.contains(wantedArtist) || wantedArtist.contains(hitArtist))
                && (hitTitle.contains(wantedTitle) || wantedTitle.contains(hitTitle))
        }
        // The API hands back 100 pixel art; the same path serves larger.
        return hit?.artworkUrl100
            .map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }
            .flatMap(URL.init(string:))
    }

    /// Letters and digits only, without case or accents.
    private static func normalised(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// What a Shoutcast or Icecast server announces in its response headers:
/// `icy-br` or `ice-audio-info` for the bitrate and sample rate, the content
/// type for the codec, `icy-name` for the station. Only the headers are read;
/// the request is cancelled before the sound arrives. Nil when the server
/// announces nothing, as an HLS stream never does.
nonisolated enum RadioHeaderProbe {
    @concurrent
    static func name(of url: URL) async -> String? {
        guard let http = await response(for: url),
              let name = http.value(forHTTPHeaderField: "icy-name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              // Icecast's default when the source sets none.
              !name.isEmpty, name.lowercased() != "unspecified name" else { return nil }
        return name
    }

    @concurrent
    static func quality(of url: URL) async -> RadioQuality? {
        guard let http = await response(for: url) else { return nil }

        var info: [String: String] = [:]
        for pair in (http.value(forHTTPHeaderField: "ice-audio-info") ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            info[key.hasPrefix("ice-") ? String(key.dropFirst(4)) : key] = parts[1]
        }
        // "128" or "128, 128": the first number.
        let bitrate = (http.value(forHTTPHeaderField: "icy-br") ?? info["bitrate"])?
            .split(separator: ",").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        var found = RadioQuality()
        found.kbps = bitrate.flatMap { $0 > 0 ? $0 : nil }
        found.sampleRate = info["samplerate"].flatMap(Double.init)
        switch http.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": found.codec = "MP3"
        case "audio/aac", "audio/aacp", "audio/x-aac": found.codec = "AAC"
        case "audio/flac": found.codec = "FLAC"
        case "audio/ogg", "application/ogg": found.codec = "Ogg"
        case "audio/opus": found.codec = "Opus"
        default: break
        }
        return found == RadioQuality() ? nil : found
    }

    private static func response(for url: URL) async -> HTTPURLResponse? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let result = try? await URLSession.shared.bytes(for: request) else { return nil }
        result.0.task.cancel()
        guard let http = result.1 as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return http
    }
}

/// Hands on the song title a station sends with its sound. Shoutcast and
/// Icecast send "Artist - Title" as one ICY StreamTitle; HLS sends ID3 title
/// and artist apart, joined here the same way. Blank titles are ignored.
private final class RadioMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    let output = AVPlayerItemMetadataOutput(identifiers: nil)
    private let onTitle: @MainActor (String) -> Void

    init(onTitle: @escaping @MainActor (String) -> Void) {
        self.onTitle = onTitle
        super.init()
        output.setDelegate(self, queue: .main)
    }

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                                    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        // Delivered on the main queue (see init), so the items never leave it.
        nonisolated(unsafe) let items = groups.flatMap(\.items)
        Task { @MainActor in await self.read(items) }
    }

    private func read(_ items: [AVMetadataItem]) async {
        var streamTitle: String?
        var title: String?
        var artist: String?
        for item in items {
            guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            if item.identifier == .icyMetadataStreamTitle {
                streamTitle = value
            } else if item.commonKey == .commonKeyTitle {
                title = value
            } else if item.commonKey == .commonKeyArtist {
                artist = value
            }
        }
        let joined = title.map { title in artist.map { "\($0) - \(title)" } ?? title }
        guard let text = streamTitle ?? joined else { return }
        await onTitle(text)
    }
}
