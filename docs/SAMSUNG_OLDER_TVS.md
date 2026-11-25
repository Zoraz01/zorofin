# Older Samsung TVs (Tizen 5.5 and earlier)

Written 2026-11-23 after a Zorofin viewer with a 2020 Samsung TV (Tizen 5.5)
could not find Zorofin in the Samsung store.

## Why the store app is missing on 2020 and older TVs

Two separate blocks, either of which is enough on its own:

1. **Samsung's store.** Samsung no longer lets new apps be published to TVs
   from 2020 or earlier. The official Jellyfin app, released to the Samsung
   store in February 2026, is limited to 2021 and newer models for the same
   reason ([SamMobile](https://www.sammobile.com/news/jellyfin-app-samsung-tv-launched-plex-alternative/),
   [Linuxiac](https://linuxiac.com/after-years-of-waiting-jellyfin-finally-lands-on-samsung-tizen-tvs/)).
   Lowering our package's minimum version does not change this.
2. **Flutter.** Samsung and flutter-tizen support Flutter apps only on
   Tizen 6.0 (2021) and later
   ([Samsung](https://developer.samsung.com/smarttv/develop/native/flutter.html),
   [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen)).
   `apps/tv/tizen/tizen-manifest.xml` sets `api-version="6.0"` for this reason.
   Changing it to 5.5 would not make the Flutter engine run there.

Samsung model years: 2020 = Tizen 5.5, 2019 = 5.0, 2018 = 4.0, 2017 = 3.0,
2021 = 6.0, 2022 = 6.5 ([Samsung general specifications](https://developer.samsung.com/smarttv/develop/specifications/general-specifications.html)).

## What a viewer with an older Samsung TV can do

In order of how well it works:

1. **Use a streaming stick.** A Fire TV Stick runs the Zorofin store app with
   every feature. Google TV and Roku follow once their store reviews finish.
2. **Sideload the Jellyfin web app.** The community
   [Jellyfin2Samsung installer](https://github.com/Jellyfin2Samsung/Samsung-Jellyfin-Installer)
   puts the open-source jellyfin-tizen web app on older Samsung TVs through
   Developer Mode and a computer on the same network. It signs in to a
   Zorofin server like any Jellyfin client. It shows the standard Jellyfin
   look, not the full Zorofin app.
3. **TV web browser.** Opening the server's address in the TV's browser can
   work, but the 2020 browser engine is old and remote control in the web
   client is clumsy. Not tested.

## The older-TV app

[apps/legacy-tv](../apps/legacy-tv/README.md) is a small Tizen web app (`.wgt`)
for Tizen 3.0 to 5.5, sideloaded with TizenBrew Installer and offered at
https://zorofin.app/samsung-tv#older-tvs.

- 0.1.0 (2026-11-23) opened the server's web interface in a wrapper. On a real
  2020 TV it looked broken: the web client relies on newer CSS that Chromium 69
  ignores, and it was slow.
- 0.2.0 (2026-11-23) replaces it with a custom lightweight TV interface in ES5
  with the Apple TV 1.4 features the old TVs can run: Who's watching, Zorofin
  Home rows (requests ready, new episodes, live sports, picks), Live TV,
  Pick Together hosting, skip intro and next episode. Trailer previews are left
  out for smoothness. Every screen is checked in Chromium 69 with
  `apps/legacy-tv/tool/validate.cjs`.

Next: test on one real 2017 to 2020 Samsung TV and fix what breaks.

## Store submission note

The 1.3.0 store submission (2026-11-08) recorded 46 model groups from 2022 to
2026. Flutter supports 2021 (Tizen 6.0) TVs too, so check whether the 2021
model groups can be added to the next release request.
