// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import CoreText
import SwiftUI

extension UnifiedChannel {
    /// "7 · BBC One", or the name alone.
    var numberAndName: String {
        [channelNumber.map(String.init), name].compactMap { $0 }.joined(separator: " · ")
    }
}

extension UnifiedProgram {
    var timeRange: String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        return "\(startTime.formatted(style)) to \(endTime.formatted(style))"
    }

    /// How far through the programme `date` is, 0...1.
    func progress(at date: Date) -> Double {
        let length = endTime.timeIntervalSince(startTime)
        guard length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(startTime) / length, 0), 1)
    }
}

// MARK: - Artwork

/// Memory cache for channel logos. Mirrors the iOS cache, with NSImage.
actor MacArtworkCache {
    static let shared = MacArtworkCache()

    /// NSCache is thread-safe; read synchronously so a reused row shows its
    /// logo on the first frame instead of flashing empty.
    nonisolated(unsafe) private let images = NSCache<NSURL, NSImage>()
    private var downloads: [URL: Task<NSImage?, Never>] = [:]
    /// Trusts the self-signed certificates a raw-IP server presents, as the API client does.
    private static let session = URLSession(configuration: .default, delegate: PlexCertificateDelegate(), delegateQueue: nil)

    private init() {
        images.countLimit = 600
    }

    nonisolated func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        if let existing = downloads[url] { return await existing.value }

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let (data, response) = try? await Self.session.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else {
                return nil
            }
            return NSImage(data: data)
        }
        downloads[url] = task
        let image = await task.value
        downloads[url] = nil

        if let image {
            images.setObject(image, forKey: url as NSURL)
        }
        return image
    }
}

/// A channel logo drawn whole (scaled to fit). On dark backgrounds a faint
/// halo keeps black wordmarks legible, as on iOS.
struct MacChannelLogo: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap(MacArtworkCache.shared.cachedImage(for:)))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "tv")
                    .foregroundStyle(.tertiary)
            }
        }
        .shadow(color: colorScheme == .dark ? .white.opacity(0.45) : .clear, radius: 1)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = MacArtworkCache.shared.cachedImage(for: url) { image = cached; return }
            image = await MacArtworkCache.shared.image(for: url)
        }
    }
}

// MARK: - Window

/// Hands back the window a view sits in, for AppKit code that must tell windows apart.
struct MacWindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}

// MARK: - Captions

extension CaptionStyle {
    /// The system caption font at `size`; the tvOS and iOS renderers build the same.
    func font(ofSize size: CGFloat) -> NSFont {
        if let fontDescriptor {
            return CTFontCreateWithFontDescriptor(fontDescriptor, size, nil) as NSFont
        }
        return .systemFont(ofSize: size, weight: .medium)
    }
}
