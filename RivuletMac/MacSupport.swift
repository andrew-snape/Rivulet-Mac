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

    /// `timeRange`, led by the day when the programme is not today.
    var dayAndTimeRange: String {
        guard !Calendar.current.isDateInToday(startTime) else { return timeRange }
        return "\(startTime.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(timeRange)"
    }

    /// The episode title, unless it adds nothing: it repeats the title, or it is
    /// only a date (the news is listed as "Sunday 18 October 2026").
    var guideSubtitle: String? {
        guard let text = subtitle?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              text != title, text != displayTitle else { return nil }
        let calendar = Calendar.current
        let looksLikeDate = text.count <= 40
            && text.contains(String(calendar.component(.year, from: startTime)))
            && calendar.monthSymbols.contains { text.localizedCaseInsensitiveContains($0) }
        return looksLikeDate ? nil : text
    }

    /// How far through the programme `date` is, 0...1.
    func progress(at date: Date) -> Double {
        let length = endTime.timeIntervalSince(startTime)
        guard length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(startTime) / length, 0), 1)
    }
}

// MARK: - Artwork

/// Memory cache for artwork. Images are decoded once, off the main thread, so
/// drawing a row never pays for a decode; the memory cache is bounded by bytes
/// and responses persist on disk across launches.
actor MacArtworkCache {
    static let shared = MacArtworkCache()

    /// NSCache is thread-safe; read synchronously so a reused row shows its
    /// logo on the first frame instead of flashing empty.
    nonisolated(unsafe) private let images = NSCache<NSURL, NSImage>()
    private var downloads: [URL: Task<NSImage?, Never>] = [:]
    /// Trusts the self-signed certificates a raw-IP server presents, as the API client does.
    /// Responses land in a disk cache, so relaunching does not download every poster again.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration, delegate: PlexCertificateDelegate(), delegateQueue: nil)
    }()

    private init() {
        images.totalCostLimit = 256 * 1024 * 1024
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
            return Self.decode(data)
        }
        downloads[url] = task
        let image = await task.value
        downloads[url] = nil

        if let image, let cost = image.representations.first.map({ $0.pixelsWide * $0.pixelsHigh * 4 }) {
            images.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Decodes now, on the calling thread: NSImage(data:) defers it to the first draw.
    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

// MARK: - Display sleep

/// Keeps the display awake while something plays, as a video player should.
@MainActor
final class MacSleepGuard {
    private var activity: NSObjectProtocol?

    func setAwake(_ awake: Bool) {
        if awake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !awake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
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

extension NSWindow {
    /// Once the picture's shape is known the window takes it, so a scope film
    /// has no black bars to shrink past. Width stays; the height follows.
    func fit(toVideo size: CGSize) {
        guard size.width > 0, size.height > 0, !styleMask.contains(.fullScreen) else { return }
        contentAspectRatio = size
        var frame = frame
        let content = contentRect(forFrameRect: frame)
        let height = (content.width * size.height / size.width).rounded()
        frame.origin.y += content.height - height
        frame.size.height += height - content.height
        setFrame(frame, display: true, animate: true)
    }
}

/// A cast or crew name opens its Wikipedia page; the context menu offers IMDb.
/// Plex carries no outside ids for people, so both go through the sites' own search.
private struct PersonLinks: ViewModifier {
    let name: String

    private func url(_ base: String, _ items: [URLQueryItem]) -> URL? {
        var parts = URLComponents(string: base)
        parts?.queryItems = items
        return parts?.url
    }

    func body(content: Content) -> some View {
        let wikipedia = url("https://en.wikipedia.org/wiki/Special:Search",
                            [.init(name: "search", value: name), .init(name: "go", value: "Go")])
        let imdb = url("https://www.imdb.com/find/",
                       [.init(name: "q", value: name), .init(name: "s", value: "nm")])
        content
            .contentShape(Rectangle())
            .onTapGesture { if let wikipedia { NSWorkspace.shared.open(wikipedia) } }
            .contextMenu {
                if let wikipedia { Link("Wikipedia", destination: wikipedia) }
                if let imdb { Link("IMDb", destination: imdb) }
            }
            .help("Open \(name) on Wikipedia")
    }
}

extension View {
    func personLinks(name: String) -> some View {
        modifier(PersonLinks(name: name))
    }
}
