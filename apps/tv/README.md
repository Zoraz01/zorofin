# Zorofin for TV (LG, Android TV, Google TV, Fire TV, Samsung)

Shared Flutter code and design for LG webOS, Android TV/Google TV, Fire TV
running Fire OS, and the planned Samsung Tizen port. The Apple TV and iPhone
apps stay in `apps/apple/` (Swift) and are released separately. Roku and Vega
OS require separate clients; this Android build does not support Vega devices.
Platform ranking, the planned [Vega port](../../docs/TV_PLATFORMS.md#fire-tv-vega-roadmap--added-november-3-2026),
and store notes are in [TV platform plan](../../docs/TV_PLATFORMS.md).

Like the Apple app, this is a client for any Jellyfin server. It ships with an
empty server field, no bundled address, and a preview mode with fictional
titles for store reviewers.

## Status

Core feature comparison uses Apple TV 1.1, with the November 3 parity changes
listed below. Build 66 received a separate Fire TV screenshot/playback check;
that does not validate this newer feature branch.
Feature-by-feature status is in [TV_APPLE_PARITY.md](../../docs/TV_APPLE_PARITY.md);
the one-pass device checklist and install steps for LG, Fire TV, Google TV and
friends' devices are in [TV_DEVICE_TESTING.md](../../docs/TV_DEVICE_TESTING.md).

- Connect and sign-in like Apple TV (HTTPS/HTTP selector, Quick Connect,
  Keep this account on this device), saved accounts and Who's watching.
- Home with the Apple 1.1 rules: banner, Continue Watching, client rows,
  server rows, automatic discovery near the bottom, Sports & live events and Your teams.
- Library grids, search, title details with quality badges and file details.
- Player with the Apple TV custom controls, text subtitles, Live TV rewind,
  up next, and Jellyfin progress reporting.
- Watch together on Jellyfin SyncPlay.
- Zorofin server modules: Requests, notifications inbox, support, alert
  settings, Live TV limit, account approvals.
- Every Apple TV profile setting page, administration pages for admins.
- Remote input: D-pad focus everywhere, OK/Select/Enter, Back (Escape,
  Android Back, webOS Back), media Play/Pause, LG Magic Remote pointer.

November 3 parity update:

- Audio, subtitle, quality and season panels focus their current choice.
- Android TV / Google TV / Fire OS saved accounts use Keystore-backed encrypted
  storage, with verified migration from build 66 preferences. Android backup
  and device transfer are disabled for account data. A failed vault read never
  resets accounts or falls back to plaintext; startup offers Retry.
- Profile offers Rate Zorofin on Amazon and Google store devices. A draft app's
  listing may not resolve until it is published.
- The in-app mini-player preserves the decoder and progress while browsing.
  Expand returns to full screen; Close stops playback. Opening Profile or a
  separate utility/account page ends playback. Account changes dispose it.
- Fire TV Home-screen recommendations are off by default for each saved account.
  Enabling them requires an explicit viewer confirmation. Up to five cards share
  titles, labels and decoded thumbnails with that TV's launcher, without a
  server URL or token. Disable, sign out and account changes clear previous cards.
  Clicks recheck the current account and fetch the title through Jellyfin before
  opening its details. Transient sign-ins and the fictional preview never publish.
- TV privacy text now describes this port's actual capabilities.

November 4 feedback update: shared playback explicitly opens/closes required
Live TV streams; safe endpoint filenames restore event/artwork manifests. Home
renders library shelves without waiting for optional feeds and loads discovery
near the end. Player seasons use an anchored dropdown. Sign-in separates Quick
Connect from the password form; shared notifications avoid batch barriers.
See the LG feedback record for device evidence.
Android/Fire TV acceptance of this newer branch remains separate from build 66.

The webOS and Linux preview ports still use app-private session preferences;
there is no webOS secure-storage implementation in this update. The Linux
preview build now needs `libsecret-1-dev` (runtime `libsecret-1-0`) for the
secure-storage package's registered Linux plugin.

Physical acceptance of migration, remote focus, store handoff and mini-player
playback remains a release gate. See the additional checks in
[TV_DEVICE_TESTING.md](../../docs/TV_DEVICE_TESTING.md).

Validated so far: `flutter analyze` is clean and `flutter test` passes. CI
builds the signed Android APK and app bundle on every push.

### Build flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--dart-define=ZOROFIN_REQUESTS=false` | `true` | Removes Requests for store builds that must ship without it |
| `--dart-define=ZOROFIN_PREVIEW_SEED=<n>` | `1` | Fixed Home layout for the preview library (screenshots) |
| `--dart-define=ZOROFIN_FORM_FACTOR=phone` | detected | Forces `tv`, `phone` or `tablet` (desktop previews, screenshots) |

## Layout

| Path | Contents |
| --- | --- |
| `lib/core/` | Jellyfin client, URL safety, models, playback planning, session storage, preview data |
| `lib/phone/` | Android phone and tablet touch layout (mirrors the iPhone and iPad app), offline downloads |
| `lib/ui/` | Theme tokens (shared with `apps/apple/App/Theme.swift`), remote-focus widgets, screens, `player/` controls and option panels |
| `android/` | Android TV, Google TV and Fire TV (Fire OS) app: Leanback launcher, banner, no touchscreen required |
| `webos/` | LG webOS packaging (`appinfo.json`, icons, runner) from LG's flutter-webos template |
| `linux/` | Desktop preview for quick UI checks |
| `tool/webos/` | Ubuntu container and script for building the LG `.ipk` from macOS |
| `tool/android/` | `create_signing_key.sh`: the Android signing key and its CI secrets |
| `tool/render_sport_art.js` | Renders the Apple Live TV sport artwork to `assets/images/` |

The TV UI renders on a fixed 1920x1080 canvas scaled to the screen, so 720p,
1080p and 4K TVs share one composition.

## Android phones and tablets

The same APK starts the touch layout in `lib/phone/` when the device is not a
TV: `MainActivity.formFactor()` reports `tv` for TV UI mode or remote-only
devices, `tablet` at a smallest width of 600dp or more, otherwise `phone`.
Fire TV and Google TV keep the TV layout. The phone screens follow iOS 1.2
(dock, Home rows, details, player, Live TV guide, Requests, Profile, offline
downloads); settings, Quick Connect, Watch together and Your teams reuse the
TV pages through `CompactSettings`. Downloads are stored in the app support
folder (`Zorofin Downloads/`) and run while the app is open.

Phone and tablet screenshots of the preview can be rendered without a device:

```sh
ZOROFIN_SCREENSHOTS=/tmp/shots flutter test test/phone_screenshots_test.dart --update-goldens
```

Emulator testing: start a phone AVD (`emulator -avd <name>`), then
`flutter run -d emulator-5554`, or install `build/app/outputs/flutter-apk/app-release.apk`
with `adb install -r`.

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

There are two build targets with the same proposed store ID, `org.zorofin.tv`:

- **Packaged web app:** initial device-test target webOS 25; shared Flutter UI
  compiled to JavaScript, bundled CanvasKit, and the HTML5 video implementation.
  Build and acceptance details: LG web app handoff.
- **Native Flutter app:** webOS 26 Re:New or later, built with LG's Linux SDK.

One public listing is the intended release plan, with separate web/native IPK
files and platform targeting if Seller Lounge accepts that combination. This
has not been verified. Do not label a native IPK as Web or promise one combined
binary. Store upload is on hold until physical TV testing and screenshots.

### Native Flutter target

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

Google Play listing copy, branding, build-138 provenance, reviewer preparation
and remaining release gates are in the Google Play release packet.
Screenshots, policy publication, device acceptance and Console submission remain
separate steps.

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
