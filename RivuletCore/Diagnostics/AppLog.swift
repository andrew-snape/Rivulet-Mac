// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import OSLog

/// One Logger per area, so Console can filter by category.
nonisolated enum AppLog {
    static let plexAuth = Logger(subsystem: "com.rivulet.app", category: "PlexAuth")
    static let plexNetwork = Logger(subsystem: "com.rivulet.app", category: "PlexNetwork")
    static let plexProfile = Logger(subsystem: "com.rivulet.app", category: "PlexProfile")
    static let liveTV = Logger(subsystem: "com.rivulet.app", category: "LiveTV")
}
