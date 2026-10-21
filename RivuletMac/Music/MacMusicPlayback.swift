// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Observation

/// App-level owner of the music playing: the queue, the player, and what
/// Plex hears about it. Music plays under everything else. Starting it stops
/// Live TV (`onStart`); starting a film, an episode or a channel pauses it.
@MainActor
@Observable
final class MacMusicPlayback {
    /// What radio keeps adding to the queue from.
    enum Radio: Equatable {
        /// Tracks like the one playing.
        case similar
        /// Anything from a library.
        case library(String)
    }

    static let loudnessKey = "musicLoudnessLevelling"

    let player = MacMusicPlayer()
    private(set) var queue = MusicQueue()
    private(set) var radio: Radio?
    /// A track that could not be played, shown in the bar until the next one starts.
    private(set) var problem: String?
    /// The full Now Playing view is open.
    var isNowPlayingShown = false

    /// Needed to fetch and report; the app sets it.
    @ObservationIgnored weak var plex: MacPlexSession?
    @ObservationIgnored var onStart: (() -> Void)?

    /// The playing track's source, with its full metadata.
    private(set) var current: MacMusicSource?
    @ObservationIgnored private var next: MacMusicSource?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    @ObservationIgnored private var refillTask: Task<Void, Never>?
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var reportedStopped = true
    @ObservationIgnored private var lastReportBucket = -1

    init() {
        player.onAdvance = { [weak self] in self?.playerAdvanced(to: $0) }
        player.onFailure = { [weak self] in self?.playerFailed($0) }
        observePlayer()
    }

    /// The track playing or paused, nil when nothing is queued.
    var track: PlexMetadata? { current?.track ?? queue.current?.track }
    /// Playing, or about to: the play/pause buttons show Pause.
    var isPlaying: Bool { player.state == .playing || (player.state == .loading && player.wantsToPlay) }
    /// Something is loaded, playing or not.
    var isActive: Bool { queue.current != nil }

    // MARK: - Starting

    /// Plays `tracks` from `index`. An album in order keeps its album gain.
    func play(_ tracks: [PlexMetadata], from index: Int = 0, shuffled: Bool = false, isAlbum: Bool = false) {
        guard !tracks.isEmpty else { return }
        MacAppDelegate.radio?.stop()
        radio = nil
        queue.replace(with: tracks, startIndex: shuffled ? Int.random(in: tracks.indices) : index,
                      shuffled: shuffled, isAlbum: isAlbum)
        loadCurrent()
    }

    /// Plays the track, then keeps going with tracks that sound like it.
    func startRadio(from seed: PlexMetadata) {
        MacAppDelegate.radio?.stop()
        queue.replace(with: [seed], isRadio: true)
        radio = .similar
        loadCurrent()
    }

    /// Shuffles a whole library, endlessly.
    func startLibraryRadio(_ library: PlexLibrary) {
        guard let plex else { return }
        radio = .library(library.key)
        problem = nil
        Task {
            let tracks = await plex.randomTracks(sectionKey: library.key)
            guard radio == .library(library.key), !tracks.isEmpty else { return }
            queue.replace(with: tracks, isRadio: true)
            loadCurrent()
        }
    }

    func playNext(_ tracks: [PlexMetadata]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(tracks)
        wasEmpty ? loadCurrent() : queueChanged()
    }

    func addToQueue(_ tracks: [PlexMetadata]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        wasEmpty ? loadCurrent() : queueChanged()
    }

    // MARK: - Transport

    func togglePlayPause() {
        switch player.state {
        case .ended, .failed, .idle:
            if isActive { loadCurrent() }
        default:
            player.togglePlayPause()
        }
    }

    func resume() {
        guard player.state != .playing else { return }
        togglePlayPause()
    }

    /// Other playback took over; the queue stays for later.
    func pause() {
        if player.state == .playing || player.state == .loading { player.pause() }
    }

    func seek(to time: TimeInterval) {
        player.seek(to: time)
        report(player.state == .playing ? "playing" : "paused")
    }

    func skipToNext() {
        guard queue.skipToNext() != nil else { return }
        loadCurrent()
    }

    /// A few seconds in, Previous restarts the track; otherwise it goes back one.
    func skipToPrevious() {
        if player.currentTime > 3 || !queue.hasPrevious {
            seek(to: 0)
            return
        }
        queue.skipToPrevious()
        loadCurrent()
    }

    func jump(to entry: MusicQueue.Entry) {
        guard queue.jump(to: entry.id) != nil else { return }
        loadCurrent()
    }

    func remove(_ entry: MusicQueue.Entry) {
        queue.remove(entry.id)
        queueChanged()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.moveUpNext(fromOffsets: source, toOffset: destination)
        queueChanged()
    }

    func setShuffled(_ on: Bool) {
        queue.setShuffled(on)
        queueChanged()
    }

    func cycleRepeat() {
        let modes = MusicQueue.RepeatMode.allCases
        queue.repeatMode = modes[(modes.firstIndex(of: queue.repeatMode)! + 1) % modes.count]
        queueChanged()
    }

    /// Stops and empties the queue. The task ends once Plex has the final report.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        let reported = finishCurrent()
        generation += 1
        loadTask?.cancel()
        nextTask?.cancel()
        refillTask?.cancel()
        player.stop()
        queue.clear()
        radio = nil
        current = nil
        next = nil
        problem = nil
        isNowPlayingShown = false
        return reported
    }

    // MARK: - Loading

    /// Opens the queue's current entry. A direct-play file that fails gets
    /// one more try as a transcode.
    private func loadCurrent(forceTranscode: Bool = false, at time: TimeInterval = 0) {
        guard let plex, let entry = queue.current else { return }
        finishCurrent()
        generation += 1
        let generation = generation
        loadTask?.cancel()
        nextTask?.cancel()
        current = nil
        next = nil
        problem = nil
        player.prepare(entry.id, duration: entry.track.durationSeconds)
        onStart?()
        loadTask = Task {
            do {
                let source = try await plex.musicSource(for: entry.id, track: entry.track, forceTranscode: forceTranscode)
                guard generation == self.generation else { return }
                current = source
                reportedStopped = false
                lastReportBucket = -1
                // A pause while the track was being fetched holds.
                player.load(source, gain: gain(for: source), at: time, autoplay: player.wantsToPlay)
                queueChanged()
            } catch {
                guard generation == self.generation, !isCancellationError(error) else { return }
                skipUnplayable(entry)
            }
        }
    }

    /// The queued follow-on no longer matches the queue: queue the right one.
    private func queueChanged() {
        refillRadioIfNeeded()
        guard let current else { return }
        let wanted = queue.entryAfterCurrent
        if let next, next.entryID == wanted?.id, player.nextID == next.entryID {
            return
        }
        nextTask?.cancel()
        next = nil
        player.setNext(nil, gain: 1)
        guard let wanted, let plex else { return }
        let generation = generation
        // Repeat One queues the same file again.
        if wanted.id == current.entryID {
            next = current
            player.setNext(current, gain: gain(for: current))
            return
        }
        nextTask = Task {
            guard let source = try? await plex.musicSource(for: wanted.id, track: wanted.track),
                  generation == self.generation, queue.entryAfterCurrent?.id == wanted.id else { return }
            next = source
            player.setNext(source, gain: gain(for: source))
        }
    }

    private func gain(for source: MacMusicSource) -> Float {
        let levelling = UserDefaults.standard.object(forKey: Self.loudnessKey) as? Bool ?? true
        guard levelling else { return 1 }
        return LoudnessLevelling.volume(for: source.track.audioStream, preferAlbum: queue.prefersAlbumGain)
    }

    /// Moves past a track the server would not hand over.
    private func skipUnplayable(_ entry: MusicQueue.Entry) {
        problem = "Couldn't play \(entry.track.displayTitle)."
        guard queue.current?.id == entry.id, queue.skipToNext() != nil else {
            player.stop()
            return
        }
        loadCurrent()
    }

    // MARK: - Player events

    private func playerAdvanced(to id: UUID) {
        finishCurrent(completed: true)
        // The follow-on is the queue's next entry (or the same one, under Repeat One).
        if queue.entryAfterCurrent?.id == id {
            queue.advance()
        } else {
            queue.jump(to: id)
        }
        if let next, next.entryID == id {
            current = next
        }
        next = nil
        reportedStopped = false
        lastReportBucket = -1
        problem = nil
        report("playing")
        queueChanged()
    }

    /// Nothing was queued behind the track that finished: the queue ran
    /// out, or its next track was not ready in time.
    private func playerRanOut() {
        finishCurrent(completed: true)
        guard queue.entryAfterCurrent != nil else { return }
        queue.advance()
        loadCurrent()
    }

    private func playerFailed(_ id: UUID) {
        if let current, current.entryID == id {
            guard let entry = queue.current, entry.id == id else { return }
            if current.isTranscode {
                skipUnplayable(entry)
            } else {
                loadCurrent(forceTranscode: true, at: player.currentTime)
            }
        } else if let next, next.entryID == id {
            self.next = nil
            player.setNext(nil, gain: 1)
            guard !next.isTranscode, let plex, let wanted = queue.entryAfterCurrent, wanted.id == id else { return }
            let generation = generation
            nextTask = Task {
                guard let source = try? await plex.musicSource(for: wanted.id, track: wanted.track, forceTranscode: true),
                      generation == self.generation, queue.entryAfterCurrent?.id == wanted.id else { return }
                self.next = source
                player.setNext(source, gain: gain(for: source))
            }
        }
    }

    // MARK: - Radio

    private func refillRadioIfNeeded() {
        guard let radio, let plex, refillTask == nil, queue.radioRemaining < 5, let seed = track else { return }
        let played = Set(queue.entries.compactMap(\.track.ratingKey))
        refillTask = Task {
            defer { refillTask = nil }
            let candidates: [PlexMetadata]
            switch radio {
            case .similar:
                candidates = await plex.radioTracks(after: seed, sectionKey: current?.track.librarySectionID.map(String.init))
            case .library(let key):
                candidates = await plex.randomTracks(sectionKey: key)
            }
            guard self.radio == radio else { return }
            var seen = played
            let fresh = candidates.shuffled().filter { $0.ratingKey.map { seen.insert($0).inserted } ?? false }
            guard !fresh.isEmpty else { return }
            queue.append(Array(fresh.prefix(15)), isRadio: true)
            queueChanged()
        }
    }

    // MARK: - Plex reporting

    private func observePlayer() {
        let player = player
        observationTasks.append(Task { [weak self] in
            var last: MacMusicPlayer.State?
            for await state in Observations({ player.state }) {
                if state == last { continue }
                last = state
                self?.stateChanged(state)
            }
        })
        observationTasks.append(Task { [weak self] in
            for await time in Observations({ player.currentTime }) {
                self?.tick(time)
            }
        })
    }

    private func stateChanged(_ state: MacMusicPlayer.State) {
        switch state {
        case .playing: report("playing")
        case .paused: report("paused")
        case .ended: playerRanOut()
        default: break
        }
    }

    private func tick(_ time: TimeInterval) {
        guard player.state == .playing else { return }
        let bucket = Int(time) / 10
        if bucket != lastReportBucket {
            lastReportBucket = bucket
            report("playing")
        }
    }

    private func report(_ state: String) {
        guard !reportedStopped, let current, let plex else { return }
        let time = player.currentTime
        Task { await plex.reportMusic(current, time: time, state: state) }
    }

    /// Stopped, then a play counted when the track got past the watched
    /// ceiling. `completed` is a track that played to its end.
    @discardableResult
    private func finishCurrent(completed: Bool = false) -> Task<Void, Never>? {
        guard !reportedStopped, let current, let plex else { return nil }
        reportedStopped = true
        let runtime = current.track.durationSeconds > 0 ? current.track.durationSeconds : player.duration
        let time = completed ? runtime : player.currentTime
        let played = completed || (WatchProgressPolicy.progress(offsetSeconds: time, runtimeSeconds: runtime) ?? 0)
            >= WatchProgressPolicy.completionThreshold
        return Task {
            await plex.reportMusic(current, time: time, state: "stopped")
            await plex.finishMusic(current, played: played)
        }
    }
}
