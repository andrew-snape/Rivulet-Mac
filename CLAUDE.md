# Rivulet for Mac - Claude Context

Rivulet for Mac is a macOS media client for Plex (video and music) and IPTV, for Apple silicon
Macs (arm64 only, macOS 27+). It is a port of Rivulet, a tvOS app; the tvOS and
iOS apps were removed from this repo, and their shared Plex and Live TV code
lives on in `RivuletCore/`. Views are SwiftUI with small AppKit bridges.

The video player is **AetherPlayer**, an adapter around AetherEngine (FFmpeg
demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a
software backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It plays Plex video
on demand and Live TV. Video renders through the engine's own surface
(`AetherPlayer.surface`, the engine's `AetherPlayerSurface`), never an
AVPlayerLayer the app builds. Music does not use it: `MacMusicPlayer` wraps an
`AVQueuePlayer` (see Music below).

## Quick Reference

- **Platform**: macOS 27+ (Golden Gate), Apple silicon only (`EXCLUDED_ARCHS = x86_64`; Xcode's "recommended settings" strip an explicit `ARCHS = arm64`, so not that)
- **Language**: Swift 6 language mode, default actor isolation `MainActor`
- **UI**: SwiftUI (`NavigationSplitView` shell), AppKit where SwiftUI has no answer (key monitor, full screen, pasteboard)
- **AetherEngine**: upstream SwiftPM dependency (`superuser404notfound/AetherEngine`), pinned `exactVersion` (7.44.0, which itself requires macOS 15, below our 27 target). There is no fork: engine fixes need an upstream release or a host-side workaround. FFmpeg and libdovi arrive only through it, as embedded dynamic frameworks whose macOS minimum (14) must stay at or below the deployment target. Its LibTrueHD object-audio package is not even fetched: it sits behind a package trait, and Rivulet enables none. DTS:X decodes through FFmpeg's own `dca` decoder, so it needs no package of its own.
- **App icon**: `RivuletMac/Assets.xcassets/AppIcon.appiconset`, rendered from `Branding/logo_square_1024.png` on the macOS icon grid (824 pt squircle on a 1024 canvas).
- **Signing**: "Sign to Run Locally" (`CODE_SIGN_IDENTITY = "-"`, no team). Sandboxed with outgoing and incoming network access, nothing else; hardened runtime off (only notarisation needs it).
- **Updates**: Sparkle (pinned `exactVersion`), checking the latest GitHub release's `appcast.xml` and installing quietly on quit. Sandboxed, so the installer goes through Sparkle's launcher XPC service (`SUEnableInstallerLauncherService` plus the `-spks` / `-spki` mach-lookup entitlements). Sparkle compares `CURRENT_PROJECT_VERSION`: raise it every release. Publish with `scripts/release.sh <version>`; the EdDSA private key lives in the login keychain, and losing it strands installed copies.
- **About panel**: `MacAbout` adds the engine, FFmpeg, dav1d and Sparkle versions, all read at run time (`AetherEngine.version`, `dlsym` of `av_version_info` / `dav1d_version`, Sparkle's bundle). libdovi reports none, so it is left out rather than hard-coded.
- **Repo is public**: keep commit messages short and plain.

## Project Structure

```
RivuletCore/            # Plex and Live TV logic, no views. The ONE Plex client
│                       #   (PlexNetworkManager, PlexAuthManager, PlexUserProfileManager),
│                       #   Models/Plex, WatchProgressPolicy, Streaming/ (quality ladder,
│                       #   version ranking, stall tracker), LiveTV/ (LiveTVDataStore,
│                       #   Plex + IPTV providers, LiveTVSourceConnector), IPTV/ (M3U,
│                       #   XMLTV, Dispatcharr), Security/ (Keychain), CaptionAppearance,
│                       #   Music/ (MusicQueue, LoudnessLevelling).
RivuletMac/
├── RivuletMacApp.swift # App, Playback menu, MacAppDelegate (Space / arrows / Esc monitor,
│                       #   quit waits up to 3 s for Plex's stopped reports)
├── MacRootView.swift   # Sidebar shell: Home, Search, libraries, Live TV; VOD overlay
├── MacSettingsView.swift # Plex (account, server, quality, skipping), Sources, Playback
├── MacSupport.swift    # MacArtworkCache, channel logo, CaptionStyle.font(ofSize:), MacWindowReader
├── Plex/               # MacPlexSession (+Content, +Account, +Playback): the content
│                       #   store, ported from the iOS app's IOSPlexSession; the views
│                       #   (Home, Library, See All, Search, Detail, sign-in, profiles)
├── Music/              # MacMusicPlayer (AVQueuePlayer), MacMusicPlayback (queue, radio,
│                       #   Plex reporting), library / artist / album pages, the bottom
│                       #   bar and Now Playing
├── LiveTV/             # MacLiveTVView: channel list + inline player; MacMultiview (up to
│                       #   four channels, sound follows the clicked tile)
└── Player/             # AetherPlayer (the only file naming engine types),
                        #   MacPlexPlayback (Plex reporting, markers, Up Next, quality),
                        #   MacPlayerPanes (Info, Chapters, Details, the Up Next card),
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
- **The window's search field** searches Plex everywhere but Live TV and
  Radio, where it filters that page: channels by name, number and anything in
  the guide from now on; stations by name and group. Radio shows the song a
  station sends (ICY StreamTitle, or ID3 in HLS) in its bar and Now Playing.
- **AU teletext captions** are on page 801 without being flagged; the
  `liveTeletextPage` setting overrides (0 is auto).
- **One stream at a time**, Multiview aside: starting a Plex title stops Live TV
  and every Multiview tile and internet radio, and pauses music (so do tuning a
  channel and starting a station; starting music stops Live TV and radio), and leaving the Live TV page stops its channel (and the tiles), unless the picture is popped out into
  its floating window (`MacLivePlayback.isPoppedOut`). The engine's surface can
  be on screen in one place only, so the page shows a stand-in meanwhile;
  closing the window off the Live TV page stops the channel.

### Music

- Music libraries (`type == "artist"`) are in `plex.libraries` for the sidebar
  but add no Home rows: anything reading `libraries` for video filters
  `isVideoLibrary`.
- `MacMusicPlayer` plays through `AVQueuePlayer`, with the next track already
  queued for gapless albums. It trusts Plex certificates through an
  `AVAssetResourceLoaderDelegate` (`MacMusicTrust`) answering with
  `PlexCertificateDelegate.trustsUnverifiedCertificate`. Files AVFoundation
  cannot open (Opus, Vorbis, WMA, DSD) and relay connections get an AAC 320
  transcode (`buildMusicTranscodeURL`); a direct file that fails retries once as one.
- Plex hears about tracks through the same timeline and scrobble calls as video.
- Loudness levelling uses Plex's `gain` / `albumGain` / `peak` on the audio
  stream (only in full metadata, so each track's source fetches it). Album gain
  for an album in order, track gain otherwise; the player can only turn down.
- Radio refills Up Next below 5 tracks: sonically similar (`/nearest`) when the
  server has analysed the library, else random tracks from it.
- Now Playing and the media keys: Plex title first, then music when it is
  playing or no channel is on (`MacAppDelegate.musicInFront`), then Live TV.
  `MacPlaybackController` owns all of it.

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
`liveTeletextPage`, `macLibrarySort.<key>`, `macChannelFilter`,
`musicLoudnessLevelling`, `autoPlayNextEpisode`, `skipBackSeconds`,
`skipForwardSeconds`. Sparkle keeps its own (the Updates tab).

### AirPlay

`MacAirPlayButton` wraps `AVRoutePickerView`. Video hands it
`AetherPlayer.airPlayPlayer`, which is set only while AVPlayer reads the
stream straight from its server (a Plex transcode, a native HLS channel): the
engine puts its local relay on the LAN for a receiver on iOS only, so on the
Mac a direct-play file or an engine-demuxed channel would hand an Apple TV a
127.0.0.1 address. With no player the button picks the Mac's sound output.

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

```bash
xcodebuild -scheme "Rivulet Mac" -destination 'platform=macOS,arch=arm64' build
```

Or open `Rivulet.xcodeproj`, pick the **Rivulet Mac** scheme and Run.

CI: `swiftlint.yml` runs the one custom lint rule on Linux. There is no CI
compile (GitHub's runners lag the Xcode the project needs), so build locally in
Xcode. There are no unit tests yet (the tvOS suite went with the tvOS app).

There is no crash or analytics reporting. Never log stream URLs: IPTV paths embed credentials and Plex URLs carry
tokens; use `SensitiveDataRedactor.safeURLString`.

## Design Philosophy

- **Simplicity first**: remove rather than add. The interface should feel calm.
- **Mac-native**: sidebar, menus, keyboard shortcuts, Settings window, full screen.
- No "just in case" features, no redundant icons or labels, no aggressive animation.
