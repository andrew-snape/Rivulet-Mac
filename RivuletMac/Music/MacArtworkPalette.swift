// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// The colour an album cover leans toward, darkened to sit behind white text.
nonisolated enum MacArtworkPalette {
    static func tint(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Twelve hue bins and one grey bin: weight, and the weighted RGB sum.
        var weights = [Double](repeating: 0, count: 13)
        var sums = [[Double]](repeating: [0, 0, 0], count: 13)
        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha >= 0.5 else { continue }
            // Premultiplied: divide the alpha back out.
            let red = min(Double(pixels[index * 4]) / 255 / alpha, 1)
            let green = min(Double(pixels[index * 4 + 1]) / 255 / alpha, 1)
            let blue = min(Double(pixels[index * 4 + 2]) / 255 / alpha, 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, unused: CGFloat = 0
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &unused)
            let bin: Int
            let weight: Double
            if saturation < 0.15 || brightness < 0.15 || brightness > 0.95 {
                bin = 12
                weight = 0.02
            } else {
                bin = Int(hue * 12) % 12
                weight = pow(Double(saturation), 1.5) * (0.3 + Double(brightness))
            }
            weights[bin] += weight
            sums[bin][0] += red * weight
            sums[bin][1] += green * weight
            sums[bin][2] += blue * weight
        }
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0 else { return nil }
        let mean = NSColor(
            srgbRed: sums[best][0] / weights[best], green: sums[best][1] / weights[best],
            blue: sums[best][2] / weights[best], alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, unused: CGFloat = 0
        mean.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &unused)
        return NSColor(hue: hue, saturation: min(saturation, 0.75), brightness: min(max(brightness, 0.28), 0.5), alpha: 1)
    }
}

/// Finds and remembers the tint of a cover. Held in memory only, keyed by the
/// item and its art path, never by a URL (those carry the server token).
actor MacArtworkTint {
    static let shared = MacArtworkTint()

    private var cache: [String: Color] = [:]
    private var misses: Set<String> = []

    func tint(key: String, url: URL?) async -> Color? {
        if let cached = cache[key] { return cached }
        guard let url, !misses.contains(key) else { return nil }
        guard let image = await MacArtworkCache.shared.image(for: url),
              let color = MacArtworkPalette.tint(of: image) else {
            misses.insert(key)
            return nil
        }
        let tint = Color(nsColor: color)
        cache[key] = tint
        return tint
    }
}

extension MacPlexSession {
    /// The tint of an item's square art, or nil when it has none.
    func artworkTint(of item: PlexMetadata) async -> Color? {
        guard let path = item.squareArtPath, let key = item.ratingKey else { return nil }
        return await MacArtworkTint.shared.tint(key: "\(key)|\(path)", url: imageURL(path: path, width: 120, height: 120))
    }
}
