# Rivulet for Mac - Claude Context

Rivulet for Mac is a macOS media client for Plex and IPTV, for Apple silicon
Macs (arm64 only, macOS 27+). It is a port of Rivulet, a tvOS app; the tvOS and
iOS apps were removed from this repo, and their shared Plex and Live TV code
lives on in `RivuletCore/`. Views are SwiftUI with small AppKit bridges.

The video player is **AetherPlayer**, an adapter around AetherEngine (FFmpeg
demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a
software backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It plays Plex video
on demand and Live TV. Video renders through the engine's own surface
(`AetherPlayer.surface`, the engine's `AetherPlayerSurface`), never an
AVPlayerLayer the app builds.

## Quick Reference

- **Platform**: macOS 27+ (Golden Gate), Apple silicon only (`EXCLUDED_ARCHS = x86_64`; Xcode's "recommended settings" strip an explicit `ARCHS = arm64`, so not that)
- **Language**: Swift 6 language mode, default actor isolation `MainActor`
- **UI**: SwiftUI (`NavigationSplitView` shell), AppKit where SwiftUI has no answer (key monitor, full screen, pasteboard)
- **AetherEngine**: upstream SwiftPM dependency (`superuser404notfound/AetherEngine`), pinned `exactVersion` (7.39.0, which itself requires macOS 15, below our 27 target). There is no fork: engine fixes need an upstream release or a host-side workaround. FFmpeg and libdovi arrive only through it, as embedded dynamic frameworks whose macOS minimum (14) must stay at or below the deployment target. Its LibTrueHD and LibDTSX object-audio packages are not even fetched: they sit behind package traits, and Rivulet enables none.
- **App icon**: `RivuletMac/Assets.xcassets/AppIcon.appiconset`, rendered from `Branding/logo_square_1024.png` on the macOS icon grid (824 pt squircle on a 1024 canvas).
- **Signing**: "Sign to Run Locally" (`CODE_SIGN_IDENTITY = "-"`, no team). Sandboxed with outgoing and incoming network access, nothing else; hardened runtime off (only notarisation needs it).
- **Repo is public**: keep commit messages short and plain.

## Project Structure

```
RivuletCore/            # Plex and Live TV logic, no views. The ONE Plex client
│                       #   (PlexNetworkManager, PlexAuthManager, PlexUserProfileManager),
│                       #   Models/Plex, WatchProgressPolicy, Streaming/ (quality ladder,
│                       #   version ranking, stall tracker), LiveTV/ (LiveTVDataStore,
│                       #   Plex + IPTV providers, LiveTVSourceConnector), IPTV/ (M3U,
│                       #   XMLTV, Dispatcharr), Security/ (Keychain), CaptionAppearance.
│                       #   Some tvOS-only leftovers (TMDB, Downloads, Sentry) still
│                       #   compile here unused.
RivuletMac/
├── RivuletMacApp.swift # App, Playback menu, MacAppDelegate (Space / arrows / Esc monitor,
│                       #   quit waits up to 3 s for Plex's stopped reports)
├── MacRootView.swift   # Sidebar shell: Home, Search, libraries, Live TV; VOD overlay
├── MacSettingsView.swift # Plex (account, server, quality, skipping), Sources, Playback
├── MacSupport.swift    # MacArtworkCache, channel logo, CaptionStyle.font(ofSize:), MacWindowReader
├── Plex/               # MacPlexSession (+Content, +Account, +Playback): the content
│                       #   store, ported from the iOS app's IOSPlexSession; the views
│                       #   (Home, Library, See All, Search, Detail, sign-in, profiles)
├── LiveTV/             # MacLiveTVView: channel list + inline player
└── Player/             # AetherPlayer (the only file naming engine types),
                        #   MacPlexPlayback (Plex reporting, markers, Up Next, quality),
                        #   MacPlaybackController + MacVODPlayerView, MacLivePlayback,
                        #   MacPlayerView (live chrome), MacCaptionOverlay
```

`RivuletCore/` and `RivuletMac/` are `PBXFileSystemSynchronizedRootGroup`s: a
file joins the target by where it sits on disk and never needs a project edit.

**RivuletCore carries no `#if os(...)`** (lint-enforced). Where it needs a value
from the app, the app injects it at launch, before touching the stores:
`PlexAPI.platform` / `.deviceName`, `PlexAuthManager.onAuthenticated` /
`.onSignedOut` (set by `MacPlexSession.init`), `PlexUserProfileManager.onProfileChanged`
/ `.onInitialProfileSelected` (`installProfileHooks()`), and
`LiveTVDataStore.foregroundNotification` (AppKit's did-become-active).
`CaptionStyle` holds `CGColor`s and a font descriptor; the app builds the font.

## Rules that look wrong until you know them

- **AetherPlayer is the only file allowed to name an AetherEngine type.** Map
  engine values to app types there and publish those. The engine's
  `SubtitleCue` cannot even be named in that file (module and class share a
  name), which is why cues are mapped inline.
- **The sandbox allows incoming connections.** AetherEngine hands AVPlayer
  its remuxed video through a local HTTP server (`HLSLocalServer`). Without
  `com.apple.security.network.server` that socket cannot listen, and Plex
  direct play and raw MPEG-TS never start. The engine's own demo app is not
  sandboxed, so its docs never mention this.
- **`macPlexActionHost` wraps the `NavigationSplitView`, not the detail
  `NavigationStack`.** The split view hosts the stack's pushed pages, and they
  miss environment values set inside its detail column: with the host on the
  stack, every button on a detail page (Play, episodes, watchlist, the item
  menu) read the default no-op `plexActions`.
- **Playback trusts the same certificates as the Plex API session.**
  `EngineTLS.serverTrustEvaluator` answers with
  `PlexCertificateDelegate.trustsUnverifiedCertificate` (IPv4 literal,
  `*.plex.direct`, port 32400). Never send a Plex server request through
  `URLSession.shared`: it fails on servers behind a raw-IP or private certificate.
- **Routing (VOD)**: `MacPlexSession.stream` picks Original (direct play through
  Aether) or a capped Plex transcode from the Home or Away quality setting and,
  for Auto, a throughput probe. A direct-play file that never starts gets one
  retry as a transcode; Auto steps down after repeated stalls (`StallTracker`).
  A relay connection is always a capped transcode.
- **Live TV**: HLS goes to AVPlayer natively; raw MPEG-TS through the engine's
  demux. A Plex `/livetv/sessions/` grant loads with `forceEngineDemux`, since
  AVPlayer cannot decode broadcast mp2 or teletext. `MacLivePlayback` waits
  250 ms before tuning, so arrowing through the list tunes only where it stops.
- **AU teletext captions** are on page 801 without being flagged; the
  `liveTeletextPage` setting overrides (0 is auto).
- **One stream at a time**: starting a Plex title stops Live TV, and leaving
  the Live TV page stops its channel, unless the picture is popped out into
  its floating window (`MacLivePlayback.isPoppedOut`). The engine's surface can
  be on screen in one place only, so the page shows a stand-in meanwhile;
  closing the window off the Live TV page stops the channel.

### Watch state

`WatchProgressPolicy` is the **only** definition of "has a resume point" and
"how far in" (2% floor, 90% ceiling). A resume point outranks the watched flag:
`PlexMetadata.isWatched` reports false while a rewatch is in progress. Drawing a
partial progress bar is a different rule (`0 < fraction < 1`) at the render
sites. After a watched-state change, `MacPlexSession.watchStateDidChange()`
bumps `watchStateRevision` so open pages reload.

### Settings keys

A settings control is wired to nothing by existing. When you add or touch one,
grep its key: a single hit means it is dead. Keys read today:
`homeStreamingQuality`, `awayStreamingQuality`, `autoSkipIntro`,
`autoSkipRecap`, `autoSkipCredits`, `autoSkipAds`, `useIntroDB`,
`liveTeletextPage`, `macLibrarySort.<key>`, `macChannelFilter`.

## Plex Metadata Hierarchy

Show (`grandparentRatingKey`) → Season (`parentRatingKey`) → Episode
(`ratingKey`). Episodes have `index` (episode number) and `parentIndex`
(season). Hub items may lack parent metadata; fetch full metadata when needed.

## Plex Discover API

Three hosts: `discover.provider.plex.tv` (watchlist CRUD),
`metadata.provider.plex.tv` (matches), `metadata-static.plex.tv` (images). Use
the account `authToken`, not `selectedServerToken`; pass `includeGuids=1`;
`X-Plex-Container-Size` is rejected on the watchlist endpoint; resolve an
external GUID to a discover `ratingKey` before PUT actions.

## Plex server API gotchas

- **`X-Plex-Container-Size` is ignored unless `X-Plex-Container-Start` is sent
  with it** (measured on PMS 1.43.4). A limit that only sets the size does
  nothing.
- **Neither `updatedAt` nor `scannedAt` on `/library/sections` detects new
  content.** The working signal is the newest item on `/library/recentlyAdded`.

## Plex Live TV

| Tuner Type | URL Source | Notes |
|------------|-----------|-------|
| HDHomeRun | `PlexLiveTVChannel.streamURL` | Direct stream |
| DVB / cloud-EPG | Tune → decision handshake in `PlexLiveTVProvider.resolveStreamURL` | See below |

1. **Tune**: `POST /livetv/dvrs/{dvr}/channels/{id}/tune`. Parse the first
   `/livetv/sessions/` key as the session path. HTTP 200 with
   `MediaContainer.status: -1` is a failed tune.
2. **Decision**: `GET /video/:/transcode/universal/decision` with the shared
   param set. `mdeDecisionCode == 1000` → play the returned Part key verbatim
   (load with `forceEngineDemux: true`); otherwise `start.m3u8` with the
   identical params.
3. **Keepalive**: PMS releases the tuner on a 300 s timer.
   `PlexLiveTimelineKeepalive` pings every 10 s (first ping delayed 3 s) and
   sends `state=stopped` on teardown.

`X-Plex-Client-Profile-Extra`: clauses joined by raw `+`, comma lists
pre-encoded `%2C`, whole value percent-encoded once. Do not "fix" it.

## Build & Run

One-time setup: `RivuletCore/Config/Secrets.swift` is gitignored and required
to compile. Copy the template; placeholders are fine.

```bash
cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift
xcodebuild -scheme "Rivulet Mac" -destination 'platform=macOS,arch=arm64' build
```

Or open `Rivulet.xcodeproj`, pick the **Rivulet Mac** scheme and Run.

CI: `swiftlint.yml` runs the one custom lint rule on Linux. There is no CI
compile (GitHub's runners lag the Xcode the project needs), so build locally in
Xcode. There are no unit tests yet (the tvOS suite went with the tvOS app).

Sentry is linked (RivuletCore imports it) but never started on the Mac. Never
send stream URLs anywhere: IPTV paths embed credentials and Plex URLs carry
tokens; use `SensitiveDataRedactor.safeURLString`.

## Design Philosophy

- **Simplicity first**: remove rather than add. The interface should feel calm.
- **Mac-native**: sidebar, menus, keyboard shortcuts, Settings window, full screen.
- No "just in case" features, no redundant icons or labels, no aggressive animation.
