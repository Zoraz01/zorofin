# Zorofin for older Samsung TVs

A small Tizen web app (`.wgt`) for Samsung TVs from 2017 to 2020 (Tizen 3.0
to 5.5). The Flutter TV app in `apps/tv` needs Tizen 6.0, and Samsung's store
no longer accepts new apps for 2020 and older TVs, so this app is installed by
sideloading. See [docs/SAMSUNG_OLDER_TVS.md](../../docs/SAMSUNG_OLDER_TVS.md).

## What it does

A custom lightweight TV interface written in ES5 (no build step), with its own
remote-control focus engine. Movement uses CSS transforms, artwork is sized
for each card and loads only near the focused card, and the layout is drawn
at 1920x1080 and scaled for 1280x720 TVs.

- **Connect and sign in:** server address (checked with
  `/System/Info/Public`), username and password, or Quick Connect.
- **Who's watching:** each profile signed in on the TV is saved; with two or
  more the app opens on a profile picker, like the other TV apps. Add, switch
  and sign out from the profile menu (top-right).
- **Home:** hero banner for the focused title, Continue Watching (wide cards),
  then the Zorofin plugin's rows (`/Zorofin/Home/Rows`: requests ready, new
  episodes, live sports, short movies, showcase, curated, popular), new movies,
  new in shows and collections. Servers without the plugin get library rows
  (new, top rated, collections). Two card styles only: wide 16:9 for
  Continue Watching, episodes and sports; posters for everything else.
- **Details:** movies (resume, play from start, mark watched) and series
  (play or resume the next episode, seasons, episode row).
- **Search, Movies, Shows:** search as you type and a six-column poster grid.
- **Live TV:** channels with what's on now and its progress; Left/Right or
  Channel +/- change channel in the player.
- **Pick Together:** the TV hosts (Movies or Shows), shows the join code and
  who is swiping, and lists titles everyone likes and the "almost" ones.
  Phones do the swiping, as on Apple TV.
- **Player:** the TV's own `<video>` decoder. Direct play for H.264/HEVC in
  MP4/MKV/MOV, server transcode to H.264/AAC HLS for the rest; Live TV always
  goes through the server's HLS. Subtitles (Down), seek (Left/Right, longer
  when held), Skip intro / recap / credits from Jellyfin media segments, next
  episode at the end, progress reported every 10 seconds.

Left out to stay smooth on 2017 to 2020 TV processors: trailer previews on
Home, the animated media bar, and swiping on the TV itself.

## Code

`tizen/js/core.js` (API client, device profile, helpers), `ui.js` (cards and
focus), `screens.js`, `player.js`, `main.js` (routing, keys, profiles). All of
it must parse as ES5 (Chromium 47 on Tizen 3.0); `test/app.test.js` checks this
with acorn. The CSS avoids `gap`, `clamp`, `aspect-ratio`, custom properties
and other newer features.

The web scripts on the server still matter for the other clients;
`tools/tests/old-tv-browser-syntax.test.cjs` blocks `?.` and `??` in
`branding/` and the companion's `web-ui/`.

## Build and validate

```sh
cd apps/legacy-tv && npm install && npm test   # unit tests and ES5 check
apps/legacy-tv/tool/package_wgt.sh             # writes apps/legacy-tv/build/zorofin-legacy-tv-<version>.wgt
node apps/legacy-tv/tool/mock-server.cjs       # app on :8730, fake Jellyfin on :8731
```

`tool/validate.cjs` drives the app with remote keys in Chromium 69 (the 2020
TV engine) against the mock server and saves screenshots at 1920x1080 and
1280x720 for every screen; it fails on any script error or a card with the
wrong shape. Setup and run commands are at the top of the file.

To release: bump the version in `tizen/config.xml` and `core.js`, package,
copy the `.wgt` to `release/`, and set `legacy_tv_version` and
`legacy_tv_package_sha256` in `apps/apple/release/site-product.json`.

The `.wgt` is unsigned on purpose. Samsung TVs only install packages signed
for that specific TV, so the installer signs it on the viewer's side.

## Install on a TV (viewer steps)

Needs a Windows, Mac or Linux computer on the same Wi-Fi as the TV.

1. On the TV, open **Apps**, type **1 2 3 4 5** on the remote, turn
   **Developer mode** on, enter the computer's IP address, then restart the TV.
2. On the computer, download **TizenBrew Installer** from
   https://github.com/reisxd/TizenBrewInstaller/releases and open it.
3. Connect it to the TV, choose to install a WGT file, and pick
   `zorofin-legacy-tv-<version>.wgt`.
4. Open **Zorofin** from the TV's apps, type the server address and sign in.
   Other people can add their own profile from the profile menu.

Tizen Studio works too (`tizen package -t wgt -s <profile>` then
`tizen install -n <file>.wgt`), using a Samsung certificate made for that TV.

## Status

Preview 0.2.0 (2026-11-23). Validated in Chromium 69 at 1920x1080 and
1280x720 against the mock server; not yet run on a real 2017 to 2020 Samsung
TV (the Tizen emulator needs an Intel or AMD PC). 0.1.0 was a wrapper around
the server's web interface and looked poor on a real 2020 TV, so it was
replaced. The reviewed package is tracked in `release/` and served at
https://zorofin.app/samsung-tv#older-tvs.
