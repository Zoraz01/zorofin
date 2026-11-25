# Zorofin for Roku: release checklist

Current development candidate: **1.4.0**. See the 1.4 handoff for current changes, reproducible checks and separate device/portal gates. The 1.0.1 receipt below is historical.


Nothing here is submitted. The Roku Channel Store submission waits for a Roku
developer account (Vitality Labs LLC) and the owner's typed go.

Version 1.0.1 (`manifest`: `major_version=1`, `minor_version=0`, `build_version=1`).
Development zip: `npm run build` writes `out/zorofin-roku.zip`. The Channel
Store takes a signed `.pkg`, which Roku makes on a device (see "Signed package").

## Before submitting

| Step | Status |
| --- | --- |
| `npm run validate`, `npm run lint`, `npm test` clean | Done in the simulator workspace |
| Every screen walked in the brs-node simulator against Jellyfin 12.2 | Done (sign-in, Home, rows, details, library, search, Live TV guide and in-use states, player options, profile and settings) |
| Device pass on a real Roku (checklist below) | Done on the home TCL Roku TV (Roku OS 15.3.4), November 9, 2026: three walkthrough loops (about 40 screens) after a fresh boot with no black frames |
| Signed `.pkg` made on the TCL Roku TV | Made after the device pass; kept outside Git in the owner's release folder |
| Roku developer account for Vitality Labs LLC | Owner to create (browser handoff) |
| Privacy policy on zorofin.app covers Roku (wording below) | Draft ready; site update needs the owner's go |
| Reviewer server with licensed sample media and a reviewer account | Reuse the store reviewer server used for the other TV stores; owner supplies the details in the dashboard |
| Store listing text, poster and screenshots | Ready: text below, poster in `images/`, Roku screenshots from the sample-media demo server (see Screenshots) |

## What the owner does

1. Create the Roku developer account for Vitality Labs LLC at developer.roku.com (through the browser handoff), and accept the Channel Store distribution agreement.
2. Say "continue on the TV" so the device pass and the signed package run on the TCL Roku TV.
3. In the Developer Dashboard: add a public channel named Zorofin, upload the signed `.pkg`, paste the listing below, add the poster and screenshots, and fill the test-account fields with the reviewer server address, username and password.
4. Give the go for the zorofin.app privacy wording below.
5. Submit for certification only once all of the above is in.

## Signed package

Roku signs packages on a device in Developer Mode, and every later update must
be signed with the same key.

```sh
tool/package-signed.sh <roku-host> --genkey   # once: makes the key, saves its password in Keychain "zorofin-roku-signing"
tool/package-signed.sh <roku-host>            # each release: sideloads, signs, writes out/zorofin-roku-<version>.pkg
```

The developer web password comes from `ROKU_DEV_PASSWORD` or the Keychain item
`zorofin-roku-dev`; the signing password from `ROKU_SIGNING_PASSWORD` or
`zorofin-roku-signing`. Nothing is written to the repository or printed.

Keep the first signed `.pkg` and the `zorofin-roku-signing` Keychain item
backed up. Losing both means the store channel can no longer be updated. To
sign on another Roku, rekey it in that device's Utilities page with the old
`.pkg` and the password.

## Device checklist (real Roku)

Run with the TV muted. Prefer a low-end model as well, since Roku certification
checks performance on entry devices.

1. Fresh install: Connect screen, server by IP (`192.168.x.x:8096`) and by HTTPS name.
2. Quick Connect sign-in, password sign-in, a second account, "Who's watching", remove an account.
3. Home: banner, Continue Watching resumes in the player, plugin Home rows appear on a server with the plugin, hidden when empty.
4. Movie: direct play (H.264 MP4), HEVC MKV (direct or transcode), 4K/HDR on a 4K Roku, resume position, progress shows on the server dashboard.
5. Episode: Skip intro, Up next countdown, autoplay off in Profile.
6. Player options (Options or Down): Seasons & episodes switches episodes, audio track change, subtitles (SRT external, PGS burn-in), quality change, Playback info shows the stream bitrate and codecs.
7. Live TV: the guide pages earlier and later, the day picker, Now, Favorites and Find a channel work; OK opens program details; Play and Watch live tune; in the player, Up opens Channels & guide and switching channels frees the old tuner. A channel plays; with the companion's `liveTvStreams` module and one tuner, start a second channel from another device and confirm the Playing now strip, the channel line and the "Live TV is in use" alert with Watch and Not now.
8. Deep link: `curl -d '' "http://<roku-ip>:8060/launch/dev?contentId=<itemId>&mediaType=movie"` opens and plays; the same while the app is running (`/input`).
9. Back on Home exits; Home button and relaunch keep the saved sign-in.
10. Sign out, wrong password, server offline, expired token (sign out the device in the Jellyfin dashboard).
11. Memory and speed: open Home, a large library and search, play for 10 minutes; no crash, focus never lost.

## Texture memory (black screens)

On the TCL Roku TV the app went black after a handful of screens until
November 9, 2026. Roku keeps about 10 MB of the 100 MB texture pool free by
evicting images, but only when an image loads, and a frame needs about 8.3 MB.
Every distinct font size and weight adds a permanent glyph atlas (about
0.13–0.43 MB) that eviction does not count, so 44 text styles used up the
margin. `ZTypeStyle` in `source/lib/Utils.brs` now snaps every `ZFont` call to
seven styles, and `tests/Theme.test.brs` keeps it that way. Do not add new
sizes outside the scale. Other findings: `roTextureManager.UnloadBitmap` frees
nothing on Roku OS 15.3, image format and burst size do not matter, and the
splash is HD only because Roku keeps it loaded all session.

## Certification items already handled in code

- Deep linking with `contentId` and `mediaType` at launch and through `roInput`.
- `AppLaunchComplete` when Home is ready or a cold deep link actually plays. Connect uses paired AppDialog beacons.
- Back on the Home screen exits the app.
- `supports_input_launch=1`, FHD UI with HD artwork and focus icons; the splash is HD only (1280×720) because Roku keeps the splash bitmap in texture memory for the whole session, and an FHD one costs 8.3 MB.
- Network work in Task nodes only.

Check the current Roku certification criteria in the Developer Dashboard before
submitting; the list above is what the code covers, not the full official list.

## Store listing draft

**Name:** Zorofin

**Category:** Movies and TV (pick the closest match the dashboard offers).

**Short description:**
Your Jellyfin library on Roku. Browse, resume and watch from a server you already use.

**Description:**
Your library. Your server.

Bring your Jellyfin movies, shows and Live TV to Roku with an app designed for the remote.

Pick up where you left off with Continue Watching, browse your libraries with artwork, search your collection, and open details with seasons, episodes and similar titles. Playback uses your Roku's own player, with audio, subtitle and quality options, Skip intro and the next episode queued up.

Compatible servers can add more, like Home rows from the Zorofin plugin and Live TV stream status that shows which channel is using a tuner.

Zorofin is a client app. It does not provide media, server hosting, account signup or a content subscription. You need access to a Jellyfin server and permission to view its content.

Zorofin is independently developed and is not affiliated with the Jellyfin project.

**Support URL:** https://zorofin.app/support

**Privacy policy URL:** https://zorofin.app/privacy

**Publisher:** Vitality Labs LLC

**Poster:** `images/store_poster.png` (540 × 405). Focus icons: `images/icon_focus_fhd.png` (540 × 405) and `images/icon_focus_hd.png` (290 × 218).

**Screenshots:** five Roku captures (1920 × 1080 JPEG) taken on the TCL Roku TV against the isolated demo server's licensed Blender films (`apps/apple/demo-server`), never against a personal server: `01-home`, `02-movie-details`, `03-movies-grid`, `04-search` and `05-home-rows`. They live in the owner's release folder outside Git with the signed package. They show no server address, account page or private names. The older Google TV captures in `release/screenshots/` remain as a fallback. To retake them, sign the app in to the demo server through a temporary LAN forwarder and use the Developer Mode web page ("Utilities", "Screenshot"); paused video captures black there, so leave the player out.

**Reviewer notes:** Use the server address, username and password supplied in the submission's test-account fields. The app has no in-app purchases and no ads.

## Privacy policy addition (for zorofin.app/privacy)

Add Roku to "Your device and saved sign-ins". The Roku app stores saved
sign-in tokens, server addresses and preferences in the app's private storage
on the Roku device (the Roku registry); Roku does not offer the app a hardware
keystore. Suggested sentence:

> The Roku app saves sign-in tokens, server details and preferences in its private storage on your Roku device. Removing an account in the app, or removing the app from your Roku, deletes them.

Everything else in the current policy (server-side processing, no ads, no
analytics SDK, optional server features) already applies to the Roku app.
Only publish this once the owner says to deploy the site.
