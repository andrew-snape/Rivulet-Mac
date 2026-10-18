<div align="center">

<img src="Branding/logo_glow_transparent.png" alt="Rivulet" width="220">

# Rivulet for Mac

**Plex and Live TV on your Mac.**

![macOS 27+](https://img.shields.io/badge/macOS-27+-000000?logo=apple)
![Apple silicon](https://img.shields.io/badge/Apple_silicon-only-000000?logo=apple)
![License](https://img.shields.io/badge/license-PolyForm_NC_1.0.0-blue)

</div>

A Mac port of [Rivulet](https://github.com/l984-451/Rivulet), the tvOS app by
Bain Gurley. Same Plex and Live TV engine, rebuilt for the Mac with a sidebar,
menus and keyboard shortcuts.

## Features

- **Plex**: sign in, choose a server and Home profile, browse Home, your movie
  and TV libraries and search. Play with resume, progress sync, Skip Intro and
  Credits, Up Next, and Home or Away streaming quality. Info, Chapters and
  Details panes open above the player controls.
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
