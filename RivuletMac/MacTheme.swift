// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The one look for Plex and Live TV, after Apple's TV app: a dark canvas,
/// artwork-led cards, one continuous corner, no chrome of its own.
enum MacTheme {
    static let background = Color(red: 0.10, green: 0.10, blue: 0.115)
    static let surface = Color(red: 0.21, green: 0.21, blue: 0.23)
    static let columnFill = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let textSecondary = Color.white.opacity(0.55)

    /// Guide boxes, panels and the mini player.
    static let corner: CGFloat = 14
    /// Posters and Continue Watching cards.
    static let cardCorner: CGFloat = 12
    static let gap: CGFloat = 4
    static let boxHeight: CGFloat = 34
    static let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
}

extension View {
    /// A full page: the theme's canvas, always dark.
    func macScreen() -> some View {
        background(MacTheme.background)
            .environment(\.colorScheme, .dark)
    }

    /// A tile that lifts slightly under the pointer, as focus does on tvOS.
    func macCardHover() -> some View {
        modifier(MacCardHover())
    }
}

private struct MacCardHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: 10, y: 6)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
