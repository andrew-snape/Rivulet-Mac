// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreGraphics
import CoreText
import MediaAccessibility

// MARK: - CaptionStyle

/// Snapshot of the system caption appearance preferences.
///
/// Colours are `CGColor` and the font is a descriptor so every app can read
/// this; each app turns them into its own `UIColor` / `NSColor` and builds the
/// font in its caption renderer (`font(ofSize:)`).
// CTFontDescriptor is a CF type with no Sendable conformance; this struct is
// only ever read/written on MainActor so the unchecked conformance is safe.
struct CaptionStyle: Equatable, @unchecked Sendable {

    /// Text/foreground color.
    var foreground: CGColor

    /// True when the system lets the CONTENT's own colour win — the "Video
    /// Override" state in tvOS caption settings, reported as
    /// `MACaptionAppearanceBehavior.useContentIfAvailable` on the foreground
    /// colour read. False means the user forced their colour and any
    /// content-specified colour must be ignored.
    var allowsContentColor: Bool

    /// Opacity of the text itself (0...1). Some system presets (and user
    /// overrides) express "translucent text"; ignoring it renders captions
    /// more opaque than the user asked for.
    var foregroundOpacity: Double

    /// Character-cell background color.
    var backgroundColor: CGColor

    /// Opacity of the character-cell background (0...1).
    var backgroundOpacity: Double

    /// Font size multiplier derived from the system relative-character-size preference.
    /// Applied on top of the size Apple bases on the presentation (view) height.
    var fontScale: CGFloat

    /// Video Override state for the character size — gates a cue's own
    /// `fontSize` (ASS `\fs`, SRT `<font size=>`).
    var allowsContentFontSize: Bool

    /// System caption font descriptor. `nil` falls back to the system sans font.
    var fontDescriptor: CTFontDescriptor?

    /// Video Override state for the font — gates a cue's own `fontName` and
    /// its bold / italic / underline / strikethrough.
    var allowsContentFont: Bool

    /// Text edge (shadow/raised/etc.) style.
    var edge: Edge

    enum Edge: Equatable {
        case none
        case dropShadow
        case raised
        case depressed
        case uniform
    }

    static let `default` = CaptionStyle(
        foreground: CGColor(gray: 1, alpha: 1),
        allowsContentColor: true,
        foregroundOpacity: 1.0,
        backgroundColor: CGColor(gray: 0, alpha: 1),
        backgroundOpacity: 0.75,
        fontScale: 1.0,
        allowsContentFontSize: true,
        fontDescriptor: nil,
        allowsContentFont: true,
        edge: .dropShadow
    )

    static func == (lhs: CaptionStyle, rhs: CaptionStyle) -> Bool {
        lhs.foreground == rhs.foreground
            && lhs.allowsContentColor == rhs.allowsContentColor
            && lhs.foregroundOpacity == rhs.foregroundOpacity
            && lhs.backgroundColor == rhs.backgroundColor
            && lhs.backgroundOpacity == rhs.backgroundOpacity
            && lhs.fontScale == rhs.fontScale
            && lhs.allowsContentFontSize == rhs.allowsContentFontSize
            && lhs.allowsContentFont == rhs.allowsContentFont
            && lhs.edge == rhs.edge
            && descriptorsEqual(lhs.fontDescriptor, rhs.fontDescriptor)
    }

    private static func descriptorsEqual(_ a: CTFontDescriptor?, _ b: CTFontDescriptor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return CFEqual(l, r)
        default: return false
        }
    }
}

// MARK: - CaptionAppearance

enum CaptionAppearance {

    /// Clamps a MediaAccessibility relative-character-size value to a usable font scale.
    ///
    /// `MACaptionAppearanceGetRelativeCharacterSize` already returns the size as a
    /// multiplicative scale factor (1.0 at the default), NOT an offset — so it is
    /// used directly. A non-positive value means "unset"; treat that as 1.0.
    ///
    /// The API does not return a continuous value. Measured on tvOS 26.5 by
    /// writing `MACaptionCharScale` into caption profiles and reading it back,
    /// it QUANTISES to five buckets — 0.35, 0.6, 1.0, 1.5, 2.0 — and reports
    /// 1.0 for anything outside that range. So the bounds below are only a
    /// sanity net; they can never actually bind. 0.35 is the smallest bucket,
    /// not "the smallest caption size", and reading it as the latter is what
    /// mis-calibrated `CaptionOverlayView.Metrics.fontHeightFraction` (#299).
    ///
    /// The quantised value is the RIGHT one to render from, despite being lossy:
    /// AVKit quantises too. "Large Text" (stored 1.75) and "Outline Text"
    /// (stored 1.5) both report 1.5 and both render at exactly the same size,
    /// measured identically to the pixel. So no raw-pref reading is needed, and
    /// none should be added.
    ///
    /// What this value is NOT is a multiplier. AVKit's size is not linear in it
    /// — see `CaptionOverlayView.Metrics.sizeLadder`, which maps each reported
    /// value to a measured fraction of presentation height. Multiplying by this
    /// number directly is ~11% short everywhere except the default.
    static func fontScale(forRelativeSize relative: CGFloat) -> CGFloat {
        guard relative > 0 else { return 1.0 }
        return min(max(relative, 0.25), 4.0)
    }

    /// Reads the current system caption style from MediaAccessibility.
    ///
    /// Uses the `.user` domain so that user-configured overrides take effect.
    /// Each value is fetched with `.useValue` so the system value is authoritative.
    static func current() -> CaptionStyle {
        var behavior = MACaptionAppearanceBehavior.useValue

        // Foreground color + opacity. `behavior` is an OUT param: each call
        // overwrites it to report whether the returned value is forced by the
        // user (.useValue) or may yield to the content (.useContentIfAvailable).
        // Read it straight after the COLOUR call — that read is the "Video
        // Override" state for text colour, and the opacity call below
        // immediately clobbers it.
        // Each `allowsContent*` below is captured IMMEDIATELY after its own
        // call, because every MediaAccessibility read overwrites `behavior`.
        // They gate the content styling the engine now delivers (5.26.0:
        // bold / italic / underline / strikethrough / font / size on
        // SubtitleTextRun) the same way `allowsContentColor` has always gated
        // colour: content wins only where the user allows it to.
        func contentMayOverride() -> Bool { behavior == .useContentIfAvailable }

        let fgUnmanaged = MACaptionAppearanceCopyForegroundColor(.user, &behavior)
        let foreground = fgUnmanaged.takeRetainedValue()
        let allowsContentColor = contentMayOverride()
        let rawFgOpacity = Double(MACaptionAppearanceGetForegroundOpacity(.user, &behavior))
        let foregroundOpacity = rawFgOpacity > 0 ? min(rawFgOpacity, 1.0) : 1.0

        // Background color + opacity — the box drawn directly behind the glyphs.
        let bgCG = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        let bgOpacity = Double(MACaptionAppearanceGetBackgroundOpacity(.user, &behavior))

        // Window color + opacity — the larger region box. Several built-in styles
        // express their "background" via the window rather than the character
        // background, so fall back to it when the character background is clear.
        let windowCG = MACaptionAppearanceCopyWindowColor(.user, &behavior).takeRetainedValue()
        let windowOpacity = Double(MACaptionAppearanceGetWindowOpacity(.user, &behavior))

        let useWindow = bgOpacity <= 0.01 && windowOpacity > 0.01
        let backgroundColor = useWindow ? windowCG : bgCG
        let backgroundOpacity = useWindow ? windowOpacity : bgOpacity

        // Font scale
        let relative = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let allowsContentFontSize = contentMayOverride()
        let scale = fontScale(forRelativeSize: relative)

        // Font (system caption font descriptor)
        let fontDescriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default)
            .takeRetainedValue()
        let allowsContentFont = contentMayOverride()

        // Edge style
        let maEdge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        let edge: CaptionStyle.Edge
        switch maEdge {
        case .dropShadow: edge = .dropShadow
        case .raised:     edge = .raised
        case .depressed:  edge = .depressed
        case .uniform:    edge = .uniform
        default:          edge = .none
        }

        return CaptionStyle(
            foreground: foreground,
            allowsContentColor: allowsContentColor,
            foregroundOpacity: foregroundOpacity,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            fontScale: scale,
            allowsContentFontSize: allowsContentFontSize,
            fontDescriptor: fontDescriptor,
            allowsContentFont: allowsContentFont,
            edge: edge
        )
    }

    /// Posted by the system whenever the user changes caption appearance settings.
    ///
    /// Bridged from `kMACaptionAppearanceSettingsChangedNotification`.
    static let changedNotification = Notification.Name(
        kMACaptionAppearanceSettingsChangedNotification as String
    )
}
