<div align="center">

<img src="Branding/logo_glow_transparent.png" alt="Rivulet" width="220">

# Rivulet for Mac

**Plex, music and Live TV on your Mac.**

![macOS 27+](https://img.shields.io/badge/macOS-27+-000000?logo=apple)
![Apple silicon](https://img.shields.io/badge/Apple_silicon-only-000000?logo=apple)
![License](https://img.shields.io/badge/license-PolyForm_NC_1.0.0-blue)

</div>

## About

Rivulet for Mac is a native media client for Plex and Live TV, built for Apple
silicon Macs running macOS 27 or later. It brings together Plex video and music,
Live TV from Plex or IPTV sources, and a Mac-native interface with a sidebar, menus,
keyboard shortcuts, and full-screen playback.

This app is a Mac port of [Rivulet](https://github.com/l984-451/Rivulet), the
tvOS app by Bain Gurley. Plex features require access to a Plex account and
server; IPTV sources can be configured separately.

## Features

- **Plex**: sign in, choose a server and Home profile, browse Home, your movie
  and TV libraries and search. Play with resume, progress sync, Skip Intro and
  Credits, Up Next, and Home or Away streaming quality. Info, Chapters and
  Details panes open above the player controls.
- **Music**: browse Plex music libraries, play albums and artists, manage the
  queue, and listen to radio.
- **Live TV**: M3U playlists with XMLTV guides, Dispatcharr servers, and your
  Plex server's tuners. A guide with what's on now, favourites and recently
  watched. Pop the picture out into a floating window, or watch up to four
  channels at once in multiview.
- **Playback**: [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
  plays files directly, including MKV, HDR10, Dolby Vision and Atmos, with a Plex
  transcode as the fallback. Captions follow your Mac's caption settings.

## Keyboard

| Key | Action |
| --- | --- |
| Space | Play or pause |
| ← / → | Back 10 or forward 30 seconds (Plex) |
| Esc | Close the player |
| ↑ / ↓ in the channel list | Change channel |
| ⌥⌘← / ⌥⌘→ | Back 10 seconds or forward |
| ⌥⌘↑ / ⌥⌘↓ | Previous or next channel |
| ⇧⌘M | Mute or unmute |
| ⇧⌘L | Go live |
| ⌘D | Add or remove the channel from favourites |
| ⌘. | Stop |
| ⌃⌘F or double-click | Full screen |
| ⌘R | Refresh |
| ⌘, | Settings |

## Build

You need a Mac with Apple silicon running macOS 27 or later, and Xcode.

1. Clone the repo and open `Rivulet.xcodeproj`.
2. Choose the **Rivulet Mac** scheme and press Run. No Apple developer account is needed.

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE). Free for personal, noncommercial use;
not for sale.

Required Notice: Copyright (C) 2025-2026 Bain Gurley
