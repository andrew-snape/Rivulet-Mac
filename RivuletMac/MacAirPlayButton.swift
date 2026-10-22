// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// The system AirPlay button. With a player it sends that player to an Apple
/// TV or AirPlay speaker, picture included for video; without one it picks the
/// Mac's sound output, so the sound goes and the picture stays here. Music and
/// radio use it without one: bound to an audio player, the picker never leaves
/// its pulsing "connecting" state even once the speaker is playing.
struct MacAirPlayButton: NSViewRepresentable {
    var player: AVPlayer?
    var tint: NSColor = .labelColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
        view.setRoutePickerButtonColor(tint, for: .normal)
    }
}
