// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Darwin
import Sparkle
import SwiftUI

/// The App menu's "About Rivulet": the standard panel, with the versions of
/// what plays the media underneath. Every version is read from the running
/// code, never typed in, so none goes stale when a dependency moves. libdovi
/// has no way to report its version, so it is not listed.
struct MacAboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Rivulet") { MacAbout.show() }
        }
    }
}

enum MacAbout {
    static func show() {
        let lines = components.map { "\($0.name) \($0.version)" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var components: [(name: String, version: String)] {
        var list: [(name: String, version: String)] = [("AetherEngine", AetherPlayer.engineVersion)]
        // FFmpeg and dav1d sit in the engine's embedded frameworks; ask them directly.
        if let ffmpeg = cString(from: "av_version_info") {
            list.append(("FFmpeg", ffmpeg.hasPrefix("n") ? String(ffmpeg.dropFirst()) : ffmpeg))
        }
        if let dav1d = cString(from: "dav1d_version") { list.append(("dav1d", dav1d)) }
        if let sparkle = Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            list.append(("Sparkle", sparkle))
        }
        return list
    }

    /// Calls a loaded C function of the form `const char *name(void)`, if the process has it.
    private static func cString(from symbol: String) -> String? {
        // RTLD_DEFAULT: search every image loaded in the process.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) else { return nil }
        typealias VersionFunction = @convention(c) () -> UnsafePointer<CChar>?
        let function = unsafeBitCast(address, to: VersionFunction.self)
        return function().map { String(cString: $0) }
    }
}
