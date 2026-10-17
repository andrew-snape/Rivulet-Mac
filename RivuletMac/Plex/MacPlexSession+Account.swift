// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Account plumbing the shell needs: profile hooks, connection health, server list.
extension MacPlexSession {
    /// The Mac side of the profile handoff.
    func installProfileHooks() {
        PlexUserProfileManager.onProfileChanged = { [weak self] in
            guard let self else { return }
            contentSessionChanged()
            // Locked: nothing loads, and the last profile's rows must not stay up.
            if !isConfigured { clearContent() }
            await refresh()
        }
        // The first selection confirms the profile's server token; reload under it.
        PlexUserProfileManager.onInitialProfileSelected = { [weak self] in
            Task { await self?.refresh() }
        }
    }

    /// Re-tests the saved connection, failing over when it died, and reloads content when it moved.
    func verifyConnection() async {
        guard auth.authToken != nil else { return }
        // Content waits on the saved Home profile: enter it first, server reachable
        // or not. The profile hooks reload once it is in.
        if auth.isContentWithheld {
            await PlexUserProfileManager.shared.fetchHomeUsers()
        }
        let before = auth.selectedServerURL
        await auth.verifyAndFixConnection()
        let moved = auth.selectedServerURL != before
        if moved { await refresh() }
    }

    /// Resumes sign-in where it stopped: server choice when a token exists, otherwise a new PIN.
    func retrySignIn() async {
        await PlexAuthManager.shared.retryAfterError()
    }

    /// Every server on the account, for the Account sheet's server picker.
    func accountServers() async throws -> [PlexDevice] {
        guard let token = PlexAuthManager.shared.authToken else { throw MacPlexSessionError.notConfigured }
        return try await PlexNetworkManager.shared.getServers(authToken: token)
    }

    /// Whether `server` is the one in use. `selectedServer` is unset after relaunch, so fall back to URL and name.
    func isCurrentServer(_ server: PlexDevice) -> Bool {
        let auth = PlexAuthManager.shared
        if let current = auth.selectedServer { return current.clientIdentifier == server.clientIdentifier }
        if let url = auth.selectedServerURL, server.connections?.contains(where: { $0.uri == url }) == true {
            return true
        }
        return server.name == auth.savedServerName
    }

    /// Switches servers. Returns false when no connection to it worked.
    func switchServer(to server: PlexDevice) async -> Bool {
        guard await PlexAuthManager.shared.selectServer(server) else {
            // The old server is still selected; reload clears the failed state the attempt left behind.
            await refresh()
            return false
        }
        contentSessionChanged()
        await refresh()
        return true
    }
}
