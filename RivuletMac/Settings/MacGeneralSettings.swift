// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Sparkle
import SwiftUI

struct MacGeneralSettings: View {
    let updater: SPUUpdater
    @AppStorage(MacMiniPlayer.menuBarKey) private var menuBarPlayer = false
    @AppStorage(MacMiniPlayer.hideDockKey) private var hideDockIcon = false
    @State private var checksAutomatically = true
    @State private var installsAutomatically = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show in Menu Bar", isOn: $menuBarPlayer)
                Toggle("Hide Dock Icon When the Window Is Closed", isOn: $hideDockIcon)
                    .disabled(!menuBarPlayer)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Music and radio in the menu bar, with the cover, song and controls. Closing the window then leaves them playing there instead of quitting Rivulet. A video or channel stops when the window closes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check for Updates Automatically", isOn: $checksAutomatically)
                Toggle("Install Updates When Rivulet Quits", isOn: $installsAutomatically)
                    .disabled(!checksAutomatically)
            } header: {
                Text("Software Update")
            } footer: {
                HStack {
                    Text("Rivulet \(version)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checksAutomatically = updater.automaticallyChecksForUpdates
            installsAutomatically = updater.automaticallyDownloadsUpdates
        }
        .onChange(of: checksAutomatically) { _, on in updater.automaticallyChecksForUpdates = on }
        .onChange(of: installsAutomatically) { _, on in updater.automaticallyDownloadsUpdates = on }
    }
}
