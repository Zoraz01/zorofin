# Zorofin for TV (LG, Android TV, Google TV, Fire TV, Samsung)

One Flutter codebase and one design for every non-Apple TV platform. The Apple
TV and iPhone apps stay in `apps/apple/` (Swift) and are built and released
separately; nothing here touches them. Platform ranking and store notes are in
[TV platform plan](../../docs/TV_PLATFORMS.md).

Like the Apple app, this is a client for any Jellyfin server. It ships with an
empty server field, no bundled address, and a preview mode with fictional
titles for store reviewers.

## Status

Feature-complete against the Apple TV app (1.1) and not yet tested on a TV.
Feature-by-feature status is in [TV_APPLE_PARITY.md](../../docs/TV_APPLE_PARITY.md);
the one-pass device checklist and install steps for LG, Fire TV, Google TV and
friends' devices are in [TV_DEVICE_TESTING.md](../../docs/TV_DEVICE_TESTING.md).

- Connect and sign-in like Apple TV (HTTPS/HTTP selector, Quick Connect,
  Keep this account on this device), saved accounts and Who's watching.
- Home with the Apple 1.1 rules: banner, Continue Watching, client rows,
  server rows, Explore more, Sports & live events and Your teams.
- Library grids, search, title details with quality badges and file details.
- Player with the Apple TV custom controls, text subtitles, Live TV rewind,
  up next, and Jellyfin progress reporting.
- Watch together on Jellyfin SyncPlay.
- Zorofin server modules: Requests, notifications inbox, support, alert
  settings, Live TV limit, account approvals.
- Every Apple TV profile setting page, administration pages for admins.
- Remote input: D-pad focus everywhere, OK/Select/Enter, Back (Escape,
  Android Back, webOS Back), media Play/Pause, LG Magic Remote pointer.

Open before store submission: secure token storage (the session is in
app-private preferences), a TV edition of the privacy text, and the device
test pass.

Validated so far: `flutter analyze` is clean and `flutter test` passes. CI
builds the signed Android APK and app bundle on every push.

### Build flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--dart-define=ZOROFIN_REQUESTS=false` | `true` | Removes Requests for store builds that must ship without it |
| `--dart-define=ZOROFIN_PREVIEW_SEED=<n>` | `1` | Fixed Home layout for the preview library (screenshots) |

## Layout

| Path | Contents |
| --- | --- |
| `lib/core/` | Jellyfin client, URL safety, models, playback planning, session storage, preview data |
| `lib/ui/` | Theme tokens (shared with `apps/apple/App/Theme.swift`), remote-focus widgets, screens, `player/` controls and option panels |
| `android/` | Android TV, Google TV and Fire TV (Fire OS) app: Leanback launcher, banner, no touchscreen required |
| `webos/` | LG webOS packaging (`appinfo.json`, icons, runner) from LG's flutter-webos template |
| `linux/` | Desktop preview for quick UI checks |
| `tool/webos/` | Ubuntu container and script for building the LG `.ipk` from macOS |
| `tool/android/` | `create_signing_key.sh`: the Android signing key and its CI secrets |
| `tool/render_sport_art.js` | Renders the Apple Live TV sport artwork to `assets/images/` |

The UI renders on a fixed 1920x1080 canvas scaled to the screen, so 720p,
1080p and 4K TVs share one composition.

## Toolchain

Use **Flutter 3.38.10**. LG's flutter-webos SDK is pinned to that release, so
every platform builds from the same framework version.

```sh
cd apps/tv
flutter pub get
flutter analyze
flutter test
flutter run -d linux          # desktop preview
```

## LG webOS

Requires webOS TV 26 Re:New or later (LG's minimum for Flutter). LG supports
building only on Ubuntu, so on macOS use the container:

```sh
apps/tv/tool/webos/build.sh --release   # prints the .ipk path under build/webos/
```

The container is x86-64 Ubuntu 24.04 with flutter-webos, the webOS NDK and the
`ares` CLI. On Apple Silicon it runs under emulation, which is slow and
often crashes in Flutter's file copy ("Unexpected EINTR"). Use the `.ipk`
from the *TV app* workflow instead: every push that touches `apps/tv/`
uploads `zorofin-tv-webos-<commit>`. A native Ubuntu machine works the same
way using LG's
[getting-started steps](https://github.com/lg-flutter-webos/flutter-webos/blob/main/doc/getting-started.md).

To install on a TV, enable Developer Mode and the Key Server on the TV, then
register it with `flutter-webos custom-devices add` and
`flutter-webos custom-devices get-key -d <id>`, and run
`flutter-webos run -d <id>`. Developer Mode installs are for testing only;
release is through the LG Content Store.

`appinfo.json` sets `transparent: true` because LG's video plugin draws video
on a plane behind the Flutter surface. `requiredACG` is empty because the app
calls no Luna services; add groups there if that changes.

## Android TV, Google TV and Fire TV

One APK/AAB covers all three (plus Sony, TCL and Hisense TVs running Google TV).
Requires the Android SDK.

```sh
flutter build apk --release        # sideload testing, including Fire TV
flutter build appbundle --release  # Google Play
```

Release builds are signed with the Zorofin key from `android/key.properties`
or the `ZOROFIN_KEYSTORE_*` environment variables, and fall back to the debug
key when neither is present. Create the key once with
`tool/android/create_signing_key.sh`; see
[TV_DEVICE_TESTING.md](../../docs/TV_DEVICE_TESTING.md). Never commit the
keystore or `key.properties` (both are ignored).

Fire TV devices on Vega OS cannot run Android apps and need a separate port.

## Samsung Tizen

Built with Samsung's [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen)
for Tizen 6.0+ (2021 and newer Samsung TVs) as a Tizen .NET app (`tizen/`,
package `org.zorofin.tv`). Samsung TVs only run the C# runner, so the .NET
SDK is required. flutter-tizen bundles a newer Flutter than the LG pin, so
`tool/tizen/build_tpk.sh` builds from a staged copy in `build/tizen-stage`,
adds `video_player_tizen` and `shared_preferences_tizen` there, and leaves the
shared `pubspec.lock` alone.

```sh
export PATH="$HOME/flutter-tizen/bin:$PATH"   # plus TIZEN_SDK if not in ~/tizen-studio
tool/tizen/build_tpk.sh --release --build-name 1.3.0 --build-number 1
# signed package: build/tizen/org.zorofin.tv-1.3.0.tpk
```

Setup, signing certificates, testing and store submission are in
[SAMSUNG_TIZEN.md](../../docs/SAMSUNG_TIZEN.md).
