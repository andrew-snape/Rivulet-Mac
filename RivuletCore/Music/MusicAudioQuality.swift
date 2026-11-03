// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Whether a music file is lossless, and whether it goes past CD quality.
nonisolated enum MusicAudioQuality: Sendable, Equatable {
    case lossless, hiResLossless

    /// Nil for a lossy or unknown codec.
    static func classify(codec: String?, bitDepth: Int?, samplingRate: Int?) -> MusicAudioQuality? {
        guard isLossless(codec: codec) else { return nil }
        if (bitDepth ?? 0) >= 24 || (samplingRate ?? 0) > 48_000 { return .hiResLossless }
        return .lossless
    }

    static func isLossless(codec: String?) -> Bool {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return false }
        return ["flac", "alac", "pcm", "aiff", "wav", "ape", "wavpack"].contains(codec) || codec.contains("dsd")
    }

    var label: String {
        switch self {
        case .lossless: "Lossless"
        case .hiResLossless: "Hi-Res Lossless"
        }
    }
}
