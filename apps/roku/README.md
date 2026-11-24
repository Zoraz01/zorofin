# Zorofin for Roku

A native Roku app (BrightScript and SceneGraph) for Jellyfin servers. It follows
the Apple TV app's layout, focus styling and wording, and talks to the same
Jellyfin API and optional Zorofin plugin and companion routes. Roku cannot run
the Flutter code in `apps/tv`, so this is a separate codebase that shares the
design and API contract.

Status: matches the Apple TV app's screens and features except Watch together.
Jellyfin SyncPlay runs over a WebSocket, and Roku has no built-in WebSocket
client, so it would need a bundled third-party socket and TLS library.
Checked in a Roku simulator against a local Jellyfin server and partly on a
TCL Roku TV; not yet submitted. See [docs/RELEASE.md](docs/RELEASE.md) for the store checklist.

## What it does

| Area | Details |
| --- | --- |
| Sign-in | Server address with the same rules as the other apps (HTTPS, plain HTTP only for local addresses, port 8096 fallback), Quick Connect code, public user picker, username and password, several saved accounts with "Who's watching". |
| Home | Hero banner with Play and More info, focused-title backdrop and info, Continue Watching (Next Up first), Zorofin plugin Home rows (Sections, then Rows v1/v2), "Recently added" per library, "On now" Live TV row. Empty rows are hidden. |
| Browse | Movies and Shows libraries (A to Z, Recently added, Top rated, Newest; All, Unwatched, Favorites). Details like Apple TV: quality badges, Play / Resume / Play next episode, Start over, audio and subtitle pickers, File details, genres, Seasons & episodes, Cast & Crew, More like this, Mark watched, Favorite. |
| Search | Recommended titles for an empty search (Apple's ranking), top matches while typing, then results by type. |
| Live TV | Grid guide like Apple TV: two hour pages up to seven days ahead, day and time picker, Now, All channels or Favorites, find a channel, a preview of the focused program and program details with Watch live and Favorites. With the companion's `liveTvStreams` module: a "Playing now" strip with Join, a line for the focused channel ("ESPN is using the only Live TV stream."), and a "Live TV is in use" alert with Watch ESPN / Not now before a channel that needs a free tuner starts. |
| Player | Direct play when the Roku can decode the file, HLS transcode otherwise (with one automatic HLS retry), Skip intro from media segments, Up next with a 15 second countdown, Jellyfin progress reporting, a 45 second start timeout. Player options (Options or Down): Seasons & episodes, Channels & guide on live TV (also on Up), Audio & subtitles, Quality and Playback info. |
| Profile and settings | Like the Apple TV Profile: Change account, Quick Connect, Support and notifications (with the plugin), Privacy Policy, App Support and Sign Out, plus settings pages for Account (password, account defaults saved to Jellyfin), Display, Playback, Subtitles, Controls, Notification settings and Storage & app. |
| Roku requirements | Deep links (`contentId` + `mediaType`) at launch and while running, `AppLaunchComplete` beacon, Back on Home exits. |

Requests are compiled out of the first store build (`bs_const=ZOROFIN_REQUESTS=false`
in `manifest`), as planned for every TV store in
[docs/TV_PLATFORMS.md](../../docs/TV_PLATFORMS.md).

## Layout

| Path | Contents |
| --- | --- |
| `manifest` | App name, version, icons, splash, `bs_const` flags |
| `source/main.brs` | Entry point, global fields, deep-link forwarding |
| `source/lib/` | Pure logic shared by the UI and tasks: addressing and auth headers, HTTP, item mapping, Home rules, device profile, Live TV stream wording, settings storage |
| `components/MainScene.*` | Screen stack, tab bar, session, deep links, Live TV availability check, alerts |
| `components/screens/` | Connect, Home, Library, Detail, Search, Live TV, Accounts, Profile, Settings, Support, Player |
| `components/widgets/` | Cards, buttons, tab bar, menus, dialogs, text entry, the guide grid, the player options panel, Playing now strip |
| `components/tasks/JellyfinTask.*` | All network calls, off the render thread |
| `images/`, `fonts/` | Generated artwork and Inter fonts (OFL, see `fonts/Inter-LICENSE.txt`) |
| `tool/` | Packaging, sideloading and asset generators |
| `tests/` | BrightScript unit tests for `source/lib` |

## Commands

Requires Node 20 or newer. Run from `apps/roku`.

```sh
npm ci              # tools: brighterscript, bslint, brs-node simulator
npm run validate    # BrighterScript compile check (must report no errors)
npm run lint        # bslint
npm test            # unit tests for source/lib in the brs interpreter
npm run build       # out/zorofin-roku.zip, the package Roku installs
npm run sim         # build, then run in the brs-node simulator with ECP on port 8060
tool/sideload.sh <roku-ip>   # install on a Roku in Developer Mode
tool/package-signed.sh <roku-ip>   # signed Channel Store .pkg (see docs/RELEASE.md)
```

`tool/make_images.py` (Pillow) and `tool/make_fonts.py` (fontTools) regenerate
`images/` and `fonts/` from `apps/tv/assets/images` and Inter. The outputs are
committed, so these only run when artwork changes.

## Testing on a Roku

1. On the Roku remote press Home three times, Up twice, then Right, Left,
   Right, Left, Right. Enable the installer and set a developer password.
2. On the Mac, store the password in the login Keychain (never in chat or the
   repository): `security add-generic-password -s zorofin-roku-dev -a rokudev -w`
3. `tool/sideload.sh <roku-ip>`, then watch logs with `telnet <roku-ip> 8085`.

The simulator cannot decode video, so playback, subtitles, Skip intro and Up
next still need a pass on hardware. [docs/RELEASE.md](docs/RELEASE.md) lists
the full device checklist.

## Notes for contributors

- BrightScript names are case-insensitive and some words are reserved (`run`,
  `tab`, `pos`, `step`). A local variable that matches a function name breaks
  the build; `npm run validate` catches both.
- Network calls belong in `JellyfinTask` commands. The render thread must not
  create `roUrlTransfer`.
- Rounded corners come from Android-style `.9.png` images. A 9-patch drawn
  smaller than its corners renders badly, so small pills use `badge.9.png`.
- The Live TV wording must match `apps/apple/Core/Sources/ZorofinCore/LiveTVStreams.swift`
  and `apps/tv/lib/core/live_tv_streams.dart`; `tests/LiveTvStreams.test.brs`
  mirrors the Apple tests.
