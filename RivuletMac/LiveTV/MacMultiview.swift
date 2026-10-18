// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Observation
import SwiftUI

/// Up to four channels playing at once, with the sound on one. Each tile is a
/// `MacLivePlayback`, so tuning, the tuner keepalive and its release work as
/// for a single channel. One for the app's lifetime, like `MacLivePlayback`.
@MainActor
@Observable
final class MacMultiview {
    static let maxTiles = 4

    struct Tile: Identifiable {
        let id = UUID()
        let playback = MacLivePlayback()
    }

    private(set) var tiles: [Tile] = []
    private(set) var soundID: Tile.ID?

    var canAdd: Bool { tiles.count < Self.maxTiles }

    func add(_ channel: UnifiedChannel) {
        guard canAdd, !tiles.contains(where: { $0.playback.channel?.id == channel.id }) else { return }
        let tile = Tile()
        tiles.append(tile)
        tile.playback.play(channel)
        // The first channel has the sound; later ones join muted.
        if soundID == nil { soundID = tile.id }
        applySound()
    }

    func remove(_ id: Tile.ID) {
        guard let tile = tiles.first(where: { $0.id == id }) else { return }
        tile.playback.stop()
        tiles.removeAll { $0.id == id }
        if soundID == id { soundID = tiles.first?.id }
        applySound()
    }

    func setSound(_ id: Tile.ID) {
        soundID = id
        applySound()
    }

    /// Stops every tile. The tasks end once Plex has released each tuner.
    @discardableResult
    func stopAll() -> [Task<Void, Never>] {
        let released = tiles.compactMap { $0.playback.stop() }
        tiles = []
        soundID = nil
        return released
    }

    private func applySound() {
        for tile in tiles { tile.playback.player.setMuted(tile.id != soundID) }
    }
}

// MARK: - View

/// The Live TV page's Multiview layout.
struct MacMultiviewView: View {
    /// The channels the picker offers: the page's current list.
    let lineup: [UnifiedChannel]
    /// A tile taken to the single-channel player.
    let open: (UnifiedChannel) -> Void
    @Environment(MacMultiview.self) private var multiview
    @State private var choosing = false

    var body: some View {
        let tiles = multiview.tiles
        ZStack {
            Color.black
            if tiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x2").font(.largeTitle)
                    Text("Watch up to four channels at once")
                    addButton
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                grid(of: tiles)
            }
        }
        .toolbar {
            ToolbarItem {
                addButton.disabled(!multiview.canAdd)
            }
        }
    }

    private var addButton: some View {
        Button { choosing = true } label: {
            Label("Add Channel", systemImage: "plus")
        }
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            MacMultiviewPicker(lineup: lineup) { channel in
                choosing = false
                multiview.add(channel)
            }
        }
    }

    private func grid(of tiles: [MacMultiview.Tile]) -> some View {
        let columns = tiles.count == 1 ? 1 : 2
        return GeometryReader { proxy in
            let rows = Int((Double(tiles.count) / Double(columns)).rounded(.up))
            let gap: CGFloat = 2
            let width = (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (proxy.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap), count: columns), spacing: gap) {
                ForEach(tiles) { tile in
                    MacMultiviewTile(tile: tile, hasSound: tile.id == multiview.soundID, open: open)
                        .frame(width: width, height: height)
                }
            }
        }
    }
}

private struct MacMultiviewTile: View {
    let tile: MacMultiview.Tile
    let hasSound: Bool
    let open: (UnifiedChannel) -> Void
    @Environment(MacMultiview.self) private var multiview
    @State private var hovering = false

    var body: some View {
        let playback = tile.playback
        let player = playback.player
        ZStack {
            Color.black
            if playback.channel != nil { player.surface }
            status(playback: playback, player: player)
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playback.channel?.numberAndName ?? "").font(.callout.weight(.semibold))
                        if let title = playback.programme?.displayTitle {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: hasSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    if let channel = playback.channel {
                        Button { open(channel) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Watch Full Size")
                    }
                    Button { multiview.remove(tile.id) } label: { Image(systemName: "xmark") }
                        .help("Remove")
                }
                .buttonStyle(.borderless)
                .padding(10)
                .background(.black.opacity(0.55))
                .opacity(hovering ? 1 : 0)
                Spacer()
            }
            .foregroundStyle(.white)
        }
        .overlay {
            Rectangle().stroke(Color.accentColor, lineWidth: hasSound && multiview.tiles.count > 1 ? 3 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { multiview.setSound(tile.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .clipped()
    }

    @ViewBuilder
    private func status(playback: MacLivePlayback, player: AetherPlayer) -> some View {
        if let notice = playback.notice {
            Text(notice).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center).padding()
        } else if case .failed(let message) = player.state {
            VStack(spacing: 6) {
                Text(message).font(.callout).multilineTextAlignment(.center)
                Button("Try Again", action: playback.retry).controlSize(.small)
            }
            .foregroundStyle(.white)
            .padding()
        } else if player.state == .idle || player.state == .loading || player.isBuffering {
            ProgressView().tint(.white)
        }
    }
}

/// A searchable list of channels to add.
private struct MacMultiviewPicker: View {
    let lineup: [UnifiedChannel]
    let pick: (UnifiedChannel) -> Void
    @State private var query = ""

    private var matches: [UnifiedChannel] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let all = text.isEmpty ? lineup : lineup.filter {
            $0.name.localizedCaseInsensitiveContains(text)
                || $0.channelNumber.map { String($0).hasPrefix(text) } == true
        }
        return Array(all.prefix(100))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Channels", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(matches) { channel in
                Button { pick(channel) } label: {
                    HStack(spacing: 8) {
                        MacChannelLogo(url: channel.logoURL).frame(width: 36, height: 24)
                        Text(channel.numberAndName).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: 380)
    }
}
