// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Sparkle
import SwiftUI

/// The App menu's "Check for Updates…". Sparkle checks on its own once a day
/// and installs quietly when the app quits (Info.plist: SUAutomaticallyUpdate);
/// this is only for asking now.
struct MacUpdateCommands: Commands {
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
    }
}
