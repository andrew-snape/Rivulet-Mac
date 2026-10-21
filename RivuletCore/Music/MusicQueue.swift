// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The music play queue: what has played, what is playing, and what is next.
///
/// A plain value with no player in it. Shuffle reorders only what is still to
/// come and remembers the order it replaced, so switching it off puts the
/// rest back. Repeat One holds the current track only for automatic advances;
/// a press of Next always moves on.
nonisolated struct MusicQueue: Sendable {
    nonisolated enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
    }

    nonisolated struct Entry: Identifiable, Hashable, Sendable {
        let id: UUID
        let track: PlexMetadata
        /// Added by radio rather than chosen.
        let isRadio: Bool

        init(track: PlexMetadata, isRadio: Bool = false) {
            id = UUID()
            self.track = track
            self.isRadio = isRadio
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var currentIndex: Int?
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off
    /// The queue is one album in its own order, so album gain applies.
    private(set) var isAlbum = false
    /// The order shuffle replaced, for everything after the current entry.
    private var unshuffledUpNext: [UUID]?

    init() {}

    var current: Entry? { currentIndex.map { entries[$0] } }
    var isEmpty: Bool { entries.isEmpty }

    /// Entries after the current one.
    var upNext: [Entry] {
        guard let currentIndex else { return entries }
        return Array(entries[(currentIndex + 1)...])
    }

    /// Entries before the current one.
    var history: [Entry] {
        guard let currentIndex else { return [] }
        return Array(entries[..<currentIndex])
    }

    /// How many radio entries are still to play.
    var radioRemaining: Int { upNext.filter(\.isRadio).count }

    /// Album gain suits an album played straight through.
    var prefersAlbumGain: Bool { isAlbum && !isShuffled }

    // MARK: - Replacing

    /// Starts over with `tracks`, playing from `startIndex`. Shuffled, the
    /// chosen track still plays first and the rest follow in random order.
    mutating func replace(with tracks: [PlexMetadata], startIndex: Int = 0, shuffled: Bool = false,
                          isAlbum: Bool = false, isRadio: Bool = false) {
        entries = tracks.map { Entry(track: $0, isRadio: isRadio) }
        currentIndex = entries.isEmpty ? nil : min(max(startIndex, 0), entries.count - 1)
        self.isAlbum = isAlbum
        isShuffled = false
        unshuffledUpNext = nil
        if shuffled { setShuffled(true) }
    }

    mutating func clear() {
        self = MusicQueue()
    }

    // MARK: - Moving

    /// The entry an automatic advance would play after the current one, for preloading.
    var entryAfterCurrent: Entry? {
        guard let currentIndex else { return nil }
        if repeatMode == .one { return entries[currentIndex] }
        if currentIndex + 1 < entries.count { return entries[currentIndex + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    /// The current track ended on its own.
    @discardableResult
    mutating func advance() -> Entry? {
        guard let currentIndex else { return nil }
        if repeatMode == .one { return entries[currentIndex] }
        return skipToNext()
    }

    /// Next was pressed. At the end, Repeat All wraps; otherwise the queue stops.
    @discardableResult
    mutating func skipToNext() -> Entry? {
        guard let index = currentIndex else { return nil }
        if index + 1 < entries.count {
            currentIndex = index + 1
        } else if repeatMode == .all, !entries.isEmpty {
            currentIndex = 0
        } else {
            return nil
        }
        return current
    }

    /// The entry before the current one, wrapping under Repeat All.
    @discardableResult
    mutating func skipToPrevious() -> Entry? {
        guard let index = currentIndex else { return nil }
        if index > 0 {
            currentIndex = index - 1
        } else if repeatMode == .all, !entries.isEmpty {
            currentIndex = entries.count - 1
        } else {
            return nil
        }
        return current
    }

    var hasPrevious: Bool { (currentIndex ?? 0) > 0 || (repeatMode == .all && !entries.isEmpty) }
    var hasNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < entries.count || repeatMode == .all
    }

    /// Plays `id` now, from anywhere in the queue.
    @discardableResult
    mutating func jump(to id: UUID) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        currentIndex = index
        return current
    }

    // MARK: - Editing

    /// Puts `tracks` straight after the current entry.
    mutating func playNext(_ tracks: [PlexMetadata]) {
        let new = tracks.map { Entry(track: $0) }
        let position = currentIndex.map { $0 + 1 } ?? 0
        entries.insert(contentsOf: new, at: position)
        if currentIndex == nil, !entries.isEmpty { currentIndex = 0 }
        unshuffledUpNext?.insert(contentsOf: new.map(\.id), at: 0)
        isAlbum = false
    }

    /// Adds `tracks` after everything chosen, ahead of any radio entries.
    mutating func append(_ tracks: [PlexMetadata], isRadio: Bool = false) {
        let new = tracks.map { Entry(track: $0, isRadio: isRadio) }
        let after = (currentIndex ?? -1) + 1
        let position = isRadio
            ? entries.count
            : entries[after...].firstIndex(where: \.isRadio) ?? entries.count
        entries.insert(contentsOf: new, at: max(position, after))
        if currentIndex == nil, !entries.isEmpty { currentIndex = 0 }
        unshuffledUpNext?.append(contentsOf: new.map(\.id))
        if !isRadio { isAlbum = false }
    }

    /// Removes an upcoming or past entry; the current one stays.
    mutating func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index != currentIndex else { return }
        entries.remove(at: index)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        unshuffledUpNext?.removeAll { $0 == id }
    }

    /// Reorders Up Next. Offsets are positions within `upNext`.
    mutating func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = (currentIndex ?? -1) + 1
        var rest = Array(entries[base...])
        let moving = source.sorted().map { rest[$0] }
        for offset in source.sorted(by: >) { rest.remove(at: offset) }
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(insertAt, 0), rest.count))
        entries.replaceSubrange(base..., with: rest)
        isAlbum = false
    }

    /// Drops every radio entry still to come, when the queue leaves radio.
    mutating func removeUpcomingRadio() {
        let ids = Set(upNext.filter(\.isRadio).map(\.id))
        for id in ids { remove(id) }
    }

    // MARK: - Shuffle

    mutating func setShuffled(_ on: Bool) {
        guard on != isShuffled else { return }
        let base = (currentIndex ?? -1) + 1
        guard base <= entries.count else { return }
        var rest = Array(entries[base...])
        if on {
            unshuffledUpNext = rest.map(\.id)
            rest.shuffle()
        } else if let order = unshuffledUpNext {
            let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            rest.sort { (position[$0.id] ?? Int.max) < (position[$1.id] ?? Int.max) }
            unshuffledUpNext = nil
        }
        entries.replaceSubrange(base..., with: rest)
        isShuffled = on
    }
}
