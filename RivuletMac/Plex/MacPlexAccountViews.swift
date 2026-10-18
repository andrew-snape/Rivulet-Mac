// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import SwiftUI

/// Shown in place of Plex content: sign in, or, when signed in with content
/// waiting on a Home profile, choose who is watching.
struct MacPlexConnectView: View {
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var showingSignIn = false
    @State private var choosingProfile = false

    var body: some View {
        Group {
            if plex.isSignedIn, !profiles.needsProfileSelection {
                // plex.tv is still being asked to let the saved profile in.
                ProgressView()
            } else if plex.isSignedIn {
                ContentUnavailableView {
                    Label("Who’s Watching?", systemImage: "person.2")
                } description: {
                    Text("Choose a profile to load your Plex libraries.")
                } actions: {
                    Button("Choose Profile") { choosingProfile = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("Sign In to Plex", systemImage: "person.crop.circle")
                } description: {
                    Text("Sign in to watch your Plex movies and TV shows.")
                } actions: {
                    Button("Sign In") { showingSignIn = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $choosingProfile) { MacProfilePickerSheet() }
        .sheet(isPresented: $showingSignIn) { MacPlexSignInSheet() }
    }
}

// MARK: - Sign in

/// PIN sign-in, then server choice, then the profile picker when the Plex Home has several users.
struct MacPlexSignInSheet: View {
    @Environment(MacPlexSession.self) private var plex
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var choosingProfile = false
    @State private var lastError: String?
    @State private var connectingID: String?
    @State private var copied = false

    private static let linkURL = URL(string: "https://plex.tv/link")!

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2.bold())
                .padding(.top, 20)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            Divider()
            HStack {
                Spacer()
                Button(plex.isSignedIn ? "Done" : "Cancel") {
                    if !plex.isSignedIn { plex.cancelSignIn() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .task {
            if plex.state == .signedOut { await plex.retrySignIn() }
        }
        .onChange(of: plex.state) { _, state in
            switch state {
            case .failed(let message):
                lastError = message
            case .requestingPIN, .waitingForPIN, .findingServers, .selectingServer:
                lastError = nil
            case .connected:
                if profiles.hasMultipleProfiles { choosingProfile = true } else { dismiss() }
            case .signedOut:
                break
            }
        }
    }

    private var title: String {
        if choosingProfile { return "Who’s Watching?" }
        return plex.state == .selectingServer ? "Choose a Server" : "Sign In to Plex"
    }

    @ViewBuilder
    private var content: some View {
        if choosingProfile {
            MacProfilePicker(onDone: { dismiss() })
        } else {
            switch plex.state {
            case .waitingForPIN:
                pinStep
            case .selectingServer:
                List(plex.availableServers) { server in
                    Button {
                        connectingID = server.id
                        Task {
                            await plex.selectServer(server)
                            connectingID = nil
                        }
                    } label: {
                        MacServerRow(server: server, isConnecting: connectingID == server.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(connectingID != nil)
                }
            case .failed(let message):
                failure(message)
            case .signedOut where lastError != nil:
                failure(lastError ?? "")
            case .connected:
                ContentUnavailableView("Signed In", systemImage: "checkmark.circle.fill")
            default:
                ProgressView()
            }
        }
    }

    private var pinStep: some View {
        VStack(spacing: 22) {
            Text("Open plex.tv/link and sign in. If it asks for a code, enter this one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let code = plex.pinCode {
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    // The PIN is the short kind plex.tv/link takes, so the link page, not app.plex.tv/auth.
                    Button { openURL(Self.linkURL) } label: {
                        Label("Open plex.tv/link", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to sign in").foregroundStyle(.secondary)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Sign In", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await plex.retrySignIn() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// A Plex server with a checkmark when current and a spinner while connecting.
struct MacServerRow: View {
    let server: PlexDevice
    var isCurrent = false
    var isConnecting = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    if server.owned == false, let owner = server.sourceTitle {
                        Text("Shared by \(owner)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: server.owned == false ? "person.2" : "server.rack")
            }
            Spacer()
            if isConnecting {
                ProgressView().controlSize(.small)
            } else if isCurrent {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Profiles

extension PlexHomeUser {
    /// plex.tv serves Home avatars as absolute URLs.
    var avatarURL: URL? { thumb.flatMap(URL.init(string:)) }
}

struct MacPlexAvatar: View {
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        MacPlexImage(url: url)
            .overlay {
                if url == nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

/// The profile picker in its own sheet, for when content is waiting on a profile.
struct MacProfilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Who’s Watching?").font(.title2.bold()).padding(.top, 20)
            MacProfilePicker(onDone: { dismiss() })
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 400)
    }
}

/// Plex Home profile grid. Calls `onDone` once a profile is in.
struct MacProfilePicker: View {
    let onDone: () -> Void
    @ObservedObject private var profiles = PlexUserProfileManager.shared
    @State private var switchingID: Int?
    @State private var pinUser: PlexHomeUser?
    @State private var pinError: String?
    @State private var switchFailed = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 20)], spacing: 24) {
                ForEach(profiles.homeUsers) { user in
                    Button { select(user) } label: { tile(user) }
                        .buttonStyle(.plain)
                        .disabled(switchingID != nil)
                }
            }
            .padding(20)
        }
        .overlay {
            if profiles.homeUsers.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Profiles", systemImage: "person.2.slash")
                } actions: {
                    Button("Try Again") { Task { await profiles.fetchHomeUsers() } }
                        .disabled(profiles.isLoadingUsers)
                }
            }
        }
        .sheet(item: $pinUser) { user in
            MacProfilePINEntry(user: user, initialError: pinError) { pin, remember in
                await verify(user, pin: pin, remember: remember)
            }
        }
        .alert("Couldn’t Switch Profile", isPresented: $switchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    private func tile(_ user: PlexHomeUser) -> some View {
        let isSelected = profiles.selectedUser?.id == user.id
        return VStack(spacing: 8) {
            MacPlexAvatar(url: user.avatarURL, size: 72)
                .overlay {
                    if switchingID == user.id {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor)
                    } else if user.requiresPin {
                        Image(systemName: "lock.circle.fill").foregroundStyle(.white, .gray)
                    }
                }
                .symbolRenderingMode(.palette)
                .font(.title2)
            Text(user.displayName).font(.callout).lineLimit(1)
        }
    }

    private func select(_ user: PlexHomeUser) {
        if profiles.selectedUser?.id == user.id {
            onDone()
            return
        }
        guard user.requiresPin else {
            Task {
                switchingID = user.id
                let ok = await profiles.selectUser(user)
                switchingID = nil
                if ok { onDone() } else { switchFailed = true }
            }
            return
        }
        guard profiles.hasRememberedPin(for: user) else {
            pinError = nil
            pinUser = user
            return
        }
        Task {
            switchingID = user.id
            let result = await profiles.selectUserWithRememberedPin(user)
            switchingID = nil
            if result.success {
                onDone()
            } else {
                pinError = result.pinWasInvalid ? "Your saved PIN no longer works. Enter it again." : nil
                pinUser = user
            }
        }
    }

    private func verify(_ user: PlexHomeUser, pin: String, remember: Bool) async -> Bool {
        switchingID = user.id
        defer { switchingID = nil }
        guard await profiles.selectUser(user, pin: pin) else { return false }
        if remember { profiles.rememberPin(pin, for: user) }
        onDone()
        return true
    }
}

/// PIN entry for a protected profile. Plex PINs are four digits, so the fourth submits.
private struct MacProfilePINEntry: View {
    let user: PlexHomeUser
    let initialError: String?
    let submit: (String, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var remember = false
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PIN for \(user.displayName)").font(.headline)
            SecureField("PIN", text: $pin)
                .focused($focused)
                .disabled(isWorking)
                .onChange(of: pin) { _, value in
                    if value.count == 4 { send() }
                }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Toggle("Remember PIN on this Mac", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            error = initialError
            focused = true
        }
    }

    private func send() {
        guard !isWorking, !pin.isEmpty else { return }
        isWorking = true
        Task {
            let ok = await submit(pin, remember)
            isWorking = false
            if ok {
                dismiss()
            } else {
                error = "Incorrect PIN. Try again."
                pin = ""
                focused = true
            }
        }
    }
}
