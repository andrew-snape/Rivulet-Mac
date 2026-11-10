// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import SwiftUI

/// The "What's new" sheet shown once after an update. The notes come from the CHANGELOG.md bundled
/// with the app, so they work offline and always match the running version.
enum MacWhatsNew {
    struct Notice: Identifiable {
        let version: String
        let items: [String]
        var id: String { version }
    }

    static let seenKey = "macWhatsNewSeenVersion"

    /// The notes to show when this launch runs a different version from the last one seen. Records the
    /// version as seen, so the sheet appears once per update. A version with no changelog section shows nothing.
    static func pending(defaults: UserDefaults = .standard) -> Notice? {
        let now = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard defaults.string(forKey: seenKey) != now else { return nil }
        defaults.set(now, forKey: seenKey)
        let items = bullets(for: now)
        return items.isEmpty ? nil : Notice(version: now, items: items)
    }

    /// The bullet lines under "## <version>" in the bundled CHANGELOG.md, with markdown marks removed.
    static func bullets(for version: String) -> [String] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false
        var items: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == version
            } else if inSection, line.hasPrefix("- ") {
                let plain = line.dropFirst(2).replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                items.append(plain)
            }
        }
        return items
    }
}

struct MacWhatsNewSheet: View {
    let notice: MacWhatsNew.Notice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What’s new in Rivulet \(notice.version)")
                .font(.title2.bold())
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(notice.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(MacTheme.textSecondary)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 360)
    }
}
