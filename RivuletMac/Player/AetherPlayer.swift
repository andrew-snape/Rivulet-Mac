// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherPlayer.swift
//  Rivulet Mac
//
//  Host for AetherEngine on the Mac, for Live TV and Plex video on demand. A
//  sibling of the iOS adapter of the same name: the engine calls and the
//  source predicates are the iOS ones, minus the parts macOS has no
//  counterpart for (the audio session, Picture in Picture, and the background
//  teardown the engine only performs on iOS and tvOS). This is the only Mac
//  file that names engine types; views draw video through `surface`.
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
import Observation
import SwiftUI
import AetherEngine

@MainActor
@Observable
final class AetherPlayer {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case ended
        case failed(String)
    }

    nonisolated struct Track: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let codec: String
        let language: String?
        let channels: Int
        let isForced: Bool
        let isHearingImpaired: Bool

        var detail: String {
            var parts: [String] = []
            if let language, !language.isEmpty {
                parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
            if !codec.isEmpty { parts.append(codec.uppercased()) }
            if channels > 0 { parts.append(channels == 2 ? "Stereo" : "\(channels) ch") }
            if isHearingImpaired { parts.append("SDH") }
            if isForced { parts.append("Forced") }
            return parts.joined(separator: " · ")
        }
    }

    /// A caption the overlay draws. Text cues keep their colour runs so the
    /// system "Video Override" setting can decide whether colour shows.
    struct Caption: Identifiable {
        struct Run: Hashable {
            let text: String
            let color: CGColor?
            let isItalic: Bool
        }

        enum Body {
            case text([Run])
            /// A bitmap (DVB, PGS) and where it sits, in [0, 1] of the video frame.
            case image(CGImage, CGRect)
        }

        let id: Int
        let startTime: Double
        let endTime: Double
        let body: Body
    }

    /// A sidecar subtitle file registered at load (Plex external streams).
    struct SidecarSubtitle {
        let url: URL
        let name: String?
        let language: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
        /// "srt", "ass", "vtt": Plex stream keys carry no extension.
        let formatHint: String?
    }

    /// The live rewind window on the session axis, the one `skip` uses live.
    struct LiveWindow: Equatable {
        var seekableRange: ClosedRange<Double>?
        var edgeTime: Double
        var playhead: Double
        var isAtLiveEdge: Bool

        static let idle = LiveWindow(seekableRange: nil, edgeTime: 0, playhead: 0, isAtLiveEdge: true)
    }

    private static let nativeAudioTrackIDBase = 300_000

    @ObservationIgnored private let engine: AetherEngine
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var nativeItemObservation: AnyCancellable?
    @ObservationIgnored private var nativeVideoSizeObservation: AnyCancellable?
    @ObservationIgnored private var timeControlObservation: AnyCancellable?
    @ObservationIgnored private weak var nativeMediaItem: AVPlayerItem?
    @ObservationIgnored private var nativeAudioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var nativeAudioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var nativeLegibleOutput: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var nativeLegibleBridge: NativeLegibleBridge?
    @ObservationIgnored private var nativeLegibleClearWorkItem: DispatchWorkItem?

    private(set) var state: State = .idle
    private(set) var isBuffering = false
    private(set) var audioTracks: [Track] = []
    private(set) var subtitleTracks: [Track] = []
    private(set) var currentAudioTrackId: Int?
    private(set) var currentSubtitleTrackId: Int?
    /// Cues from the engine, on the `sourceTime` axis.
    private(set) var captions: [Caption] = []
    /// Lines AVPlayer is showing right now (remote HLS WebVTT / CEA-608).
    private(set) var nativeCaptions: [Caption] = []
    private(set) var sourceTime: Double = 0
    /// Media timeline position (VOD scrubber, markers, Plex reports).
    private(set) var currentTime: Double = 0
    private(set) var duration: TimeInterval = 0
    /// Where an in-flight seek is headed, so repeated skips stack and the
    /// scrubber does not snap back while the engine lands.
    private(set) var pendingSeekTarget: Double?
    /// A VOD load whose clock has not moved yet.
    private(set) var isStarting = false
    /// Playback starving for data; never a seek or the startup load.
    private(set) var isStalled = false
    private(set) var rate: Float = 1
    private(set) var videoSize: CGSize = .zero
    private(set) var liveWindow: LiveWindow = .idle
    private(set) var isMuted = false
    private(set) var volume: Float = 1
    private(set) var canRetry = true
    var fillsWindow = false {
        didSet { engine.videoGravity = fillsWindow ? .resizeAspectFill : .resizeAspect }
    }

    private(set) var isLive = false
    /// Whether the viewer wants playback running, so a reload keeps a pause.
    @ObservationIgnored private var userIntendsToPlay = false
    @ObservationIgnored private var lastLoad: LoadRequest?

    private enum LoadRequest {
        case vod(url: URL, headers: [String: String], subtitles: [SidecarSubtitle])
        case live(url: URL, headers: [String: String], forceEngineDemux: Bool)
    }

    /// A channel rather than a Plex title, so a failure names the right thing.
    private var isLiveLoad: Bool {
        if case .live? = lastLoad { return true }
        return false
    }

    /// AVPlayerLayer does not paint remote HLS captions when the host draws
    /// its own controls, so forward native legible output to the overlay.
    /// The delegate is Sendable, so it passes on the plain text only.
    private final class NativeLegibleBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        let onStrings: @Sendable ([String]) -> Void

        init(onStrings: @escaping @Sendable ([String]) -> Void) {
            self.onStrings = onStrings
        }

        func legibleOutput(
            _ output: AVPlayerItemLegibleOutput,
            didOutputAttributedStrings strings: [NSAttributedString],
            nativeSampleBuffers nativeSamples: [Any],
            forItemTime itemTime: CMTime
        ) {
            onStrings(strings.map(\.string))
        }
    }

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            fatalError("Unable to create AetherEngine: \(error)")
        }
        // The engine otherwise uses system trust alone, so a server the API
        // session accepts would list channels and never play (#337).
        EngineTLS.serverTrustEvaluator = { PlexCertificateDelegate.trustsUnverifiedCertificate(for: $0) }
        wirePublishers()
    }

    /// The video. Hosts never name the engine's view.
    var surface: some View {
        AetherPlayerSurface(engine: engine)
    }

    private func wirePublishers() {
        engine.$state
            // errorInfo is assigned right before state, so read it on this turn.
            .map { [engine] state in (state, engine.errorInfo) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, errorInfo in
                guard let self else { return }
                self.state = Self.translate(state, errorInfo: errorInfo, isLive: self.isLiveLoad)
                if case .error = state { self.canRetry = errorInfo?.kind != .dolbyVisionRequiresHardware }
                self.recomputeBuffering()
            }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeBuffering() }
            .store(in: &cancellables)

        engine.$isLive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isLive = $0 }
            .store(in: &cancellables)

        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                let starving = switch phase {
                case .rebuffering, .stalled: true
                default: false
                }
                let stalled = starving && !self.isStarting && self.pendingSeekTarget == nil
                if stalled != self.isStalled { self.isStalled = stalled }
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &cancellables)

        engine.seekEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, event.isTerminal, let pending = self.pendingSeekTarget,
                      abs(pending - event.target) < 0.5 else { return }
                self.pendingSeekTarget = nil
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                if tracks.isEmpty || !self.engineAudioTracksAreSelectable {
                    if self.nativeAudioOptions.isEmpty { self.audioTracks = [] }
                } else {
                    self.nativeAudioGroup = nil
                    self.nativeAudioOptions = []
                    self.audioTracks = tracks.map(Self.translate)
                }
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.subtitleTracks = tracks.map(Self.translate)
            }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, self.nativeAudioGroup == nil else { return }
                self.currentAudioTrackId = id
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentSubtitleTrackId = $0 }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.clockTicked(time) }
            .store(in: &cancellables)

        engine.clock.$sourceTime
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sourceTime = $0 }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                // The engine's cue type cannot be named here (module and class share a name).
                self.captions = cues.map { cue in
                    let body: Caption.Body
                    switch cue.body {
                    case .text(let text):
                        body = .text([Caption.Run(text: text, color: nil, isItalic: false)])
                    case .richText(let runs):
                        body = .text(runs.map {
                            Caption.Run(
                                text: $0.text,
                                color: $0.color.map {
                                    CGColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255,
                                            blue: CGFloat($0.b) / 255, alpha: 1)
                                },
                                isItalic: $0.isItalic
                            )
                        })
                    case .image(let image):
                        body = .image(image.cgImage, image.position)
                    }
                    return Caption(id: cue.id, startTime: cue.startTime, endTime: cue.endTime, body: body)
                }
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                self.nativeItemObservation = nil
                self.observeTimeControlStatus(of: avPlayer)
                guard let avPlayer else {
                    self.observeVideoSize(of: nil)
                    self.clearNativeMediaSelection()
                    return
                }
                self.nativeItemObservation = avPlayer.publisher(for: \.currentItem)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] item in
                        self?.observeVideoSize(of: item)
                        self?.prepareNativeMediaSelection(for: item)
                    }
            }
            .store(in: &cancellables)

        // The software path's picture size under its pixel aspect ratio
        // (anamorphic SD broadcast); nil on the native path.
        engine.$softwareDisplaySize
            .compactMap { $0 }
            .filter { $0.width > 0 && $0.height > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.videoSize = $0 }
            .store(in: &cancellables)
    }

    private func clockTicked(_ time: Double) {
        currentTime = time
        if isStarting, time > 0 {
            isStarting = false
            pendingSeekTarget = nil
        }
        guard isLive else { return }
        let clock = engine.clock
        let window = LiveWindow(
            seekableRange: clock.seekableLiveRange,
            edgeTime: clock.liveEdgeTime,
            playhead: time,
            isAtLiveEdge: clock.isAtLiveEdge
        )
        if window != liveWindow { liveWindow = window }
    }

    // MARK: - Loading

    /// HLS goes to AVPlayer natively; everything else (raw MPEG-TS) through
    /// the engine's demux. `forceEngineDemux` is for Plex `/livetv/sessions/`
    /// grants, whose broadcast mp2 and teletext AVPlayer cannot decode.
    func loadLive(url: URL, headers: [String: String]? = nil, forceEngineDemux: Bool = false) async throws {
        lastLoad = .live(url: url, headers: headers ?? [:], forceEngineDemux: forceEngineDemux)
        try await performLiveLoad(url: url, headers: headers ?? [:], forceEngineDemux: forceEngineDemux)
    }

    private func performLiveLoad(url: URL, headers: [String: String], forceEngineDemux: Bool) async throws {
        beginLoad()
        let isNativeHLS = Self.isHLSURL(url) && !forceEngineDemux
        // Forced onto the engine demuxer AND a playlist: the Plex direct-play grant.
        let usesHLSIngest = !isNativeHLS && Self.isHLSURL(url)

        func makeOptions(nativeRemoteHLS: Bool) -> LoadOptions {
            LoadOptions(
                suppressDisplayCriteria: false,
                httpHeaders: headers,
                matchContentEnabled: true,
                panelIsInHDRMode: false,
                audioBridgeMode: .lossless,
                isLive: true,
                dvrWindowSeconds: 1800,
                nativeRemoteHLS: nativeRemoteHLS,
                // No libass on the Mac: ASS arrives as clean text.
                preserveASSMarkup: false,
                probesize: 5 * 1024 * 1024,
                maxAnalyzeDuration: 5_000_000,
                preferredAudioLanguages: [],
                preferredSubtitleLanguages: [],
                teletextPage: Self.regionTeletextPage(),
                // Software only where the source says it is interlaced; the
                // engine's own SPS check catches mis-signalled H.264 (#150).
                preferredDecodePath: (!nativeRemoteHLS && Self.needsDeinterlacing(url)) ? .software : .automatic
            )
        }

        do {
            if usesHLSIngest {
                // LoadOptions.httpHeaders never reaches a custom reader (AE#119).
                let reader = HLSLiveIngestReader(playlistURL: url, httpHeaders: headers)
                do {
                    try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: makeOptions(nativeRemoteHLS: false))
                } catch {
                    // Encrypted or fMP4 playlist: retry natively on the same grant.
                    guard reader.terminalError != nil, !Self.isCancellation(error) else { throw error }
                    try await engine.load(url: url, startPosition: nil, options: makeOptions(nativeRemoteHLS: true))
                }
            } else {
                try await engine.load(url: url, startPosition: nil, options: makeOptions(nativeRemoteHLS: isNativeHLS))
            }
            // The engine resets its output level per session.
            engine.volume = isMuted ? 0 : volume
            seedVideoSize()
        } catch {
            failLoad(error)
            throw error
        }
    }

    /// Plex video on demand. Sidecars are registered at load so they appear
    /// as ordinary subtitle tracks. `keepingTransport` (a quality reload) keeps
    /// the speed and a paused session paused.
    func load(
        url: URL,
        headers: [String: String]? = nil,
        startTime: TimeInterval? = nil,
        externalSubtitles: [SidecarSubtitle] = [],
        keepingTransport: Bool = false
    ) async throws {
        lastLoad = .vod(url: url, headers: headers ?? [:], subtitles: externalSubtitles)
        try await performVODLoad(
            url: url, headers: headers ?? [:], startTime: startTime, subtitles: externalSubtitles,
            keepingTransport: keepingTransport
        )
    }

    private func performVODLoad(
        url: URL,
        headers: [String: String],
        startTime: TimeInterval?,
        subtitles: [SidecarSubtitle],
        keepingTransport: Bool = false
    ) async throws {
        beginLoad(keepingTransport: keepingTransport)
        pendingSeekTarget = startTime
        isStarting = true
        var options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers,
            matchContentEnabled: true,
            panelIsInHDRMode: false,
            audioBridgeMode: .lossless,
            isLive: false,
            dvrWindowSeconds: 0,
            nativeRemoteHLS: Self.isHLSURL(url),
            preserveASSMarkup: false,
            probesize: 8 * 1024 * 1024,
            maxAnalyzeDuration: 8_000_000,
            preferredAudioLanguages: [],
            preferredSubtitleLanguages: [],
            externalSubtitles: subtitles.map {
                ExternalSubtitleTrack(
                    url: $0.url,
                    name: $0.name,
                    language: $0.language,
                    isForced: $0.isForced,
                    isHearingImpaired: $0.isHearingImpaired,
                    isDefault: $0.isDefault,
                    httpHeaders: nil,
                    formatHint: $0.formatHint
                )
            },
            teletextPage: Self.regionTeletextPage()
        )
        options.autoplay = userIntendsToPlay

        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
            engine.volume = isMuted ? 0 : volume
            if userIntendsToPlay, rate != 1 { engine.setRate(rate) }
            seedVideoSize()
        } catch {
            failLoad(error)
            throw error
        }
    }

    /// Reloads the last source: VOD at the last position, live at the edge.
    func retry() async {
        guard let lastLoad else { return }
        let position = currentTime
        switch lastLoad {
        case .vod(let url, let headers, let subtitles):
            try? await performVODLoad(url: url, headers: headers, startTime: position > 1 ? position : nil,
                                      subtitles: subtitles)
        case .live(let url, let headers, let forceEngineDemux):
            try? await performLiveLoad(url: url, headers: headers, forceEngineDemux: forceEngineDemux)
        }
    }

    private func beginLoad(keepingTransport: Bool = false) {
        state = .loading
        canRetry = true
        videoSize = .zero
        liveWindow = .idle
        pendingSeekTarget = nil
        isStarting = false
        isStalled = false
        captions = []
        clearNativeSubtitleText()
        // The engine forgets the speed when the source changes; a reload reapplies it.
        if !keepingTransport {
            rate = 1
            userIntendsToPlay = true
        }
    }

    private func failLoad(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        isStarting = false
        canRetry = engine.errorInfo?.kind != .dolbyVisionRequiresHardware
        state = .failed(Self.userFacingFailure(engine.errorInfo, isLive: isLiveLoad))
    }

    /// The engine's coded dimensions until the item reports its own size.
    private func seedVideoSize() {
        guard videoSize == .zero else { return }
        let size = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
        if size.width > 0, size.height > 0 { videoSize = size }
    }

    // MARK: - Transport

    func play() {
        userIntendsToPlay = true
        engine.play()
        // A rate set while paused is applied on resume; setRate would start playback.
        if rate != 1 { engine.setRate(rate) }
    }

    func pause() {
        userIntendsToPlay = false
        engine.pause()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if state == .playing { engine.setRate(newRate) }
    }

    func togglePlayPause() {
        state == .playing ? pause() : play()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.volume = muted ? 0 : volume
    }

    func setVolume(_ level: Float) {
        volume = min(max(level, 0), 1)
        if isMuted, volume > 0 { isMuted = false }
        engine.volume = isMuted ? 0 : volume
    }

    /// VOD seek on the media timeline.
    func seek(to time: TimeInterval) async {
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        await performSeek(to: min(max(0, time), upper))
    }

    /// Skip relative to where the last skip was headed, so rapid presses stack.
    /// Live, within the rewind window; landing within a second of the edge snaps to live.
    func skip(by seconds: Double) async {
        guard isLive else {
            await seek(to: (pendingSeekTarget ?? currentTime) + seconds)
            return
        }
        let window = liveWindow
        guard let range = window.seekableRange else { return }
        let target = min(max((pendingSeekTarget ?? window.playhead) + seconds, range.lowerBound), window.edgeTime)
        if window.edgeTime - target < 1 {
            await seekToLiveEdge()
        } else {
            await performSeek(to: target)
        }
    }

    /// Seek events clear the pending target; the timeout covers a seek the
    /// engine drops without one (no session yet).
    private func performSeek(to target: Double) async {
        isStarting = false
        pendingSeekTarget = target
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.pendingSeekTarget == target { self?.pendingSeekTarget = nil }
        }
        await engine.seek(to: target)
    }

    func seekToLiveEdge() async {
        pendingSeekTarget = nil
        await engine.seekToLiveEdge()
    }

    func selectAudioTrack(id: Int) {
        if id >= Self.nativeAudioTrackIDBase,
           let item = nativeMediaItem,
           let group = nativeAudioGroup {
            let index = id - Self.nativeAudioTrackIDBase
            guard nativeAudioOptions.indices.contains(index) else { return }
            item.select(nativeAudioOptions[index], in: group)
            currentAudioTrackId = id
            return
        }
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        if let id {
            if let item = nativeMediaItem {
                ensureNativeLegibleOutput(on: item)
            }
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
            captions = []
            clearNativeSubtitleText()
        }
    }

    func stop() {
        lastLoad = nil
        userIntendsToPlay = false
        pendingSeekTarget = nil
        isStarting = false
        rate = 1
        clearNativeMediaSelection()
        nativeVideoSizeObservation = nil
        videoSize = .zero
        liveWindow = .idle
        captions = []
        engine.stop()
        state = .idle
    }

    // MARK: - Buffering

    /// The engine's flag goes stale after a far seek that lands while AVPlayer
    /// is still waiting, so fold in timeControlStatus (tvOS AetherPlayer).
    private var hostPlayerWaiting = false

    private func observeTimeControlStatus(of player: AVPlayer?) {
        timeControlObservation = player?
            .publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.hostPlayerWaiting = status == .waitingToPlayAtSpecifiedRate
                self?.recomputeBuffering()
            }
        if player == nil {
            hostPlayerWaiting = false
            recomputeBuffering()
        }
    }

    private func recomputeBuffering() {
        let buffering = engine.isBuffering || (engine.state == .playing && hostPlayerWaiting)
        if buffering != isBuffering { isBuffering = buffering }
    }

    // MARK: - Translation

    private static func translate(_ state: PlaybackState, errorInfo: PlaybackErrorInfo?, isLive: Bool) -> State {
        switch state {
        case .idle: return .idle
        case .loading, .seeking: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .error: return .failed(userFacingFailure(errorInfo, isLive: isLive))
        }
    }

    /// Only kinds that change what the viewer should do get their own sentence.
    private static func userFacingFailure(_ info: PlaybackErrorInfo?, isLive: Bool) -> String {
        let generic = isLive
            ? "This channel couldn't be played. Check your connection and try again."
            : "This video couldn't be played. Check your connection and try again."
        guard let kind = info?.kind else { return generic }
        switch kind {
        case .sourceRateLimited:
            return "The server is refusing new streams right now. Wait a moment and try again."
        case .sourceRefused:
            return "The server refused this stream. It may have moved, or your access to it may have changed."
        case .sourceCertificateRejected:
            return "The server's security certificate was not accepted."
        case .liveSourceUnavailable:
            return "This channel is not responding right now."
        default:
            return generic
        }
    }

    private static func translate(_ track: TrackInfo) -> Track {
        Track(
            id: track.id,
            name: track.name.isEmpty ? fallbackTrackName(track) : track.name,
            codec: track.codec,
            language: track.language,
            channels: track.channels,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired
        )
    }

    private static func fallbackTrackName(_ track: TrackInfo) -> String {
        if let language = track.language, !language.isEmpty {
            return Locale.current.localizedString(forLanguageCode: language) ?? language
        }
        return track.codec.isEmpty ? "Track \(track.id)" : track.codec.uppercased()
    }

    // MARK: - Source predicates (shared with tvOS and iOS AetherPlayer)

    private static func isHLSURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        let text = url.absoluteString.lowercased()
        return text.contains(".m3u8") || text.contains("format=hls")
    }

    /// Plex reports the scan type on the tune; absence means progressive,
    /// because forcing software decode on every playlist channel dropped
    /// frames (tvOS AetherPlayer).
    private static func needsDeinterlacing(_ url: URL) -> Bool {
        guard let scan = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "rivuletLiveScanType" })?.value?
            .lowercased() else { return false }
        return scan != "progressive"
    }

    /// AU free-to-air carries captions on 801 without flagging it; a stored
    /// `liveTeletextPage` overrides (0 means auto-detect).
    private static func regionTeletextPage() -> Int? {
        if let stored = UserDefaults.standard.object(forKey: "liveTeletextPage") as? Int {
            return stored == 0 ? nil : stored
        }
        return Locale.current.region?.identifier == "AU" ? 801 : nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // MARK: - Native remote-HLS media selection and captions

    private func prepareNativeMediaSelection(for item: AVPlayerItem?) {
        guard nativeMediaItem !== item else { return }
        clearNativeMediaSelection()
        guard let item, Self.isRemoteItem(item) else { return }
        nativeMediaItem = item
        ensureNativeLegibleOutput(on: item)

        Task { @MainActor [weak self, weak item] in
            guard let item else { return }
            if item.status == .unknown {
                for await status in item.publisher(for: \.status).values where status != .unknown {
                    guard status == .readyToPlay else { return }
                    break
                }
            }
            guard let self, self.nativeMediaItem === item else { return }
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !group.options.isEmpty,
                  self.engine.audioTracks.isEmpty || !self.engineAudioTracksAreSelectable else { return }

            self.nativeAudioGroup = group
            self.nativeAudioOptions = group.options
            self.audioTracks = group.options.enumerated().map { index, option in
                Track(
                    id: Self.nativeAudioTrackIDBase + index,
                    name: option.displayName.isEmpty ? "Audio \(index + 1)" : option.displayName,
                    codec: "",
                    language: option.extendedLanguageTag,
                    channels: 0,
                    isForced: false,
                    isHearingImpaired: false
                )
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                self.currentAudioTrackId = Self.nativeAudioTrackIDBase + index
            }
        }
    }

    /// Since 7.22.0 the remote-HLS bypass publishes AVPlayer's audio tracks for
    /// information only and ignores `selectAudioTrack`; AVMediaSelection owns them.
    private var engineAudioTracksAreSelectable: Bool { engine.videoRoute != .remoteBypass }

    private static func isRemoteItem(_ item: AVPlayerItem) -> Bool {
        guard let asset = item.asset as? AVURLAsset else { return false }
        switch asset.url.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1", nil: return false
        default: return true
        }
    }

    private func observeVideoSize(of item: AVPlayerItem?) {
        nativeVideoSizeObservation = nil
        guard let item else { return }
        nativeVideoSizeObservation = item
            .publisher(for: \.presentationSize)
            .filter { $0.width > 0 && $0.height > 0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.videoSize = size }
    }

    private func ensureNativeLegibleOutput(on item: AVPlayerItem) {
        guard nativeLegibleOutput == nil || nativeMediaItem !== item else { return }
        if let oldItem = nativeMediaItem, let output = nativeLegibleOutput {
            oldItem.remove(output)
        }

        // The output delivers on the main queue (below).
        let bridge = NativeLegibleBridge { [weak self] strings in
            MainActor.assumeIsolated { self?.handleNativeLegible(strings) }
        }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.textStylingResolution = .sourceAndRulesOnly
        output.setDelegate(bridge, queue: .main)
        item.add(output)
        nativeLegibleBridge = bridge
        nativeLegibleOutput = output
    }

    /// Native captions arrive as "what is showing now", so they are drawn
    /// as-is; an empty update clears them after a beat to ride out flicker.
    private func handleNativeLegible(_ strings: [String]) {
        let lines = strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            guard nativeLegibleClearWorkItem == nil, !nativeCaptions.isEmpty else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.nativeLegibleClearWorkItem = nil
                self?.nativeCaptions = []
            }
            nativeLegibleClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        } else {
            nativeLegibleClearWorkItem?.cancel()
            nativeLegibleClearWorkItem = nil
            nativeCaptions = lines.enumerated().map { index, line in
                Caption(
                    id: 1_000_000 + index,
                    startTime: 0,
                    endTime: .greatestFiniteMagnitude,
                    body: .text([Caption.Run(text: line, color: nil, isItalic: false)])
                )
            }
        }
    }

    private func clearNativeSubtitleText() {
        nativeLegibleClearWorkItem?.cancel()
        nativeLegibleClearWorkItem = nil
        nativeCaptions = []
    }

    private func clearNativeMediaSelection() {
        let hadNativeAudio = !nativeAudioOptions.isEmpty
        if let item = nativeMediaItem, let output = nativeLegibleOutput {
            item.remove(output)
        }
        nativeMediaItem = nil
        nativeAudioGroup = nil
        nativeAudioOptions = []
        nativeLegibleOutput = nil
        nativeLegibleBridge = nil
        if hadNativeAudio {
            audioTracks = []
            currentAudioTrackId = nil
        }
        clearNativeSubtitleText()
    }
}
