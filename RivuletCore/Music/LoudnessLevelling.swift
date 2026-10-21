// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Evens out loudness from Plex's own analysis of each track.
///
/// Plex stores a gain in dB that would bring the track to its reference
/// loudness, for the track alone and for its whole album. Album gain keeps an
/// album's quiet songs quiet; track gain suits shuffle and radio. The player
/// can only turn down, so a quiet track plays at full volume while loud ones
/// come down to meet it, and no track is lifted past its peak.
nonisolated enum LoudnessLevelling {
    /// The player volume (0...1) for a track's audio stream, or 1 without analysis.
    static func volume(for stream: PlexStream?, preferAlbum: Bool) -> Float {
        guard let stream else { return 1 }
        let track = (gain: stream.gain?.value, peak: stream.peak?.value)
        let album = (gain: stream.albumGain?.value, peak: stream.albumPeak?.value)
        let chosen = preferAlbum && album.gain != nil ? album : track
        return volume(gain: chosen.gain ?? album.gain, peak: chosen.peak)
    }

    static func volume(gain: Double?, peak: Double?) -> Float {
        guard let gain, gain.isFinite else { return 1 }
        var linear = pow(10, gain / 20)
        if let peak, peak.isFinite, peak > 0 { linear = min(linear, 1 / peak) }
        return Float(min(max(linear, 0), 1))
    }
}

extension PlexMetadata {
    /// The audio stream of a track's first file.
    var audioStream: PlexStream? {
        Media?.first?.Part?.first?.Stream?.first(where: \.isAudio)
    }
}
