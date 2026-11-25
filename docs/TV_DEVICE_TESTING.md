# TV app device testing

How to put the Zorofin TV app on LG, Fire TV and Google TV devices, yours or a
friend's, and one checklist that validates every feature in a single pass.
Feature status lives in [TV_APPLE_PARITY.md](TV_APPLE_PARITY.md); build
commands live in [`apps/tv/README.md`](../apps/tv/README.md).

Last updated November 4, 2026.

## Before the first test

1. **Signing key (once).** On the Mac, from the repository root:

   ```sh
   apps/tv/tool/android/create_signing_key.sh --github
   ```

   It creates `~/.zorofin/android/zorofin-tv-upload.jks`, writes the ignored
   `apps/tv/android/key.properties`, and stores three GitHub Actions secrets
   (`ZOROFIN_ANDROID_KEYSTORE_BASE64`, `ZOROFIN_ANDROID_KEYSTORE_PASSWORD`,
   `ZOROFIN_ANDROID_KEY_ALIAS`). Needs a JDK and the `gh` CLI. Back the
   keystore and password up in a password manager: every later build must be
   signed with it to install over the previous one, and it is the Play
   upload key.
2. **Builds.** Every push that touches `apps/tv/` runs the *TV app* workflow,
   which tests the app and uploads `zorofin-tv-android-<commit>` containing
   `app-release.apk` (sideloading) and `app-release.aab` (Play). The run
   number is the version code, so a newer build always installs over an
   older one. Without the secrets the APK is signed with a throwaway debug
   key. A signature mismatch is a stop condition: do not uninstall or clear
   saved accounts just to make an upgrade test pass.
3. **A test account.** Testers sign in to your Jellyfin server with their own
   account. For Watch together, give at least two accounts SyncPlay access
   (Jellyfin Dashboard > Users > the user > SyncPlay access).

## Fire TV (Fire OS)

Fire TV Stick, Cube and Fire OS televisions run the Android build. Devices on
Vega OS cannot run it.

**Your device, from the Mac**

1. On the Fire TV: Settings > My Fire TV > About, select the device name 7
   times to show Developer options, then turn on ADB debugging.
2. Find its address in Settings > My Fire TV > About > Network.
3. On the Mac (`brew install android-platform-tools` once):

   ```sh
   adb connect <fire-tv-ip>:5555     # accept the prompt on the TV
   adb install -r app-release.apk
   ```

**A friend's device**

1. Send them a direct download link to `app-release.apk` (for example a
   file-sharing link that downloads without a sign-in page; GitHub artifact
   links need a GitHub login and arrive zipped).
2. They install *Downloader* from the Amazon Appstore, allow it under
   Settings > My Fire TV > Developer options > Install unknown apps, enter the
   link, and install.
3. For updates they repeat step 2 with the new link. No uninstall is needed
   while every build uses the same key.

**Store distribution:** [Zorofin build 66 is live on Amazon Appstore](https://www.amazon.com/gp/product/B0HQBMFSRN).
Newer development builds are separate candidates. Amazon Live App Testing can
invite beta testers before a future public update.

## Google TV and Android TV

Covers Chromecast with Google TV, Google TV Streamer, and Sony, TCL and
Hisense TVs on Google TV.

**Your device, from the Mac**

1. Settings > System > About, select *Android TV OS build* 7 times, then
   Settings > System > Developer options > USB debugging (on newer models
   also turn on *Wireless debugging* and pair with the code shown).
2. `adb connect <tv-ip>:5555` (or `adb pair` for wireless debugging), then
   `adb install -r app-release.apk`.

**A friend's device:** the same Downloader route works (Downloader is on
Google Play). Allow it under Settings > Apps > Security & restrictions >
Unknown sources.

**Later, without sideloading:** a Google Play *internal testing* track
takes up to 100 testers by email and installs like a normal Play app. Upload
`app-release.aab`. It needs a Google Play Console account, which is your
call.

## LG webOS

The native Flutter package requires **webOS 26 Re:New or later**, including
Re:New on TVs that shipped with webOS 26. For the owner's current pre-26 TV,
use the separate **packaged web build**, initially targeting webOS 25. Its
setup, test gates and screenshot procedure are in LG_WEB_APP.md.
A reported firmware build number is not the webOS SDK version; read the latter
with `ares-device --system-info` after pairing.

**Your TV**

1. Install *Developer Mode* by LG Electronics from Apps / LG Content Store.
   Sign in on the TV, turn on Dev Mode Status, allow the restart, then reopen
   Developer Mode and turn on Key Server.
2. Download the `.ipk` from the latest *TV app* workflow run
   (`zorofin-tv-webos-<commit>`). Building it on an Apple Silicon Mac runs
   under emulation and usually crashes, so use the CI build. Install it from
   the Mac with LG's CLI (`npm install -g @webos-tools/cli`, Node 20+):

   ```sh
   ares-setup-device --add lgtv -i "host=<tv-ip>" -i "port=9922" -i "username=prisoner"
   ares-novacom --device lgtv --getkey          # enter the passphrase from Developer Mode
   ares-install --device lgtv org.zorofin.tv_*.ipk
   ares-launch --device lgtv org.zorofin.tv
   ```

3. A Developer Mode session has a time limit, shown in the Developer Mode
   app; extend it there before it runs out, because apps installed through
   Developer Mode are removed when it lapses.

**A friend's TV:** Developer Mode is the practical local-testing route; LG's Alpha Test requires a separate commercial contract. Until the app is in the LG
Content Store, a friend needs Developer Mode on their own TV with their own
LG developer account, and you install the `.ipk` over their network (or they
install the `.ipk` themselves with LG's `ares-install`). Plan LG friend testing for after store
review unless someone is comfortable with that.

## Alternative distribution channels

Reviewed November 4, 2026. These are proposed channels; this review does not
publish builds or submit catalog entries. Keep the private operational repository
private and distribute only generic Jellyfin clients, without account data or
server defaults.

Recommended order:

1. **Public release-only GitHub repository and website download links.** Host
   versioned, signed APKs and LG IPKs with checksums, changelogs, compatibility
   notes and required licenses. Stable filenames can support
   [latest-release download links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
   CI artifacts are temporary build outputs, not the friend-facing download.
2. **LG webOSbrew.** Submit the public manifest and icon through the
   [catalog contribution process](https://repo.webosbrew.org/submit). Main and
   non-free pools have separate source expectations; maintainers review entries.
   See LG distribution details.
   webOS Dev Manager is an installer, not a second catalog.
3. **Android Obtainium compatibility.**
   [Obtainium](https://github.com/ImranR98/Obtainium) follows release sources and
   updates APKs. Users add our release URL; there is no separate catalog upload.
   Its TV remote experience is not validated. For Fire TV friends, a direct
   signed APK through Downloader remains the simpler sideload route.
4. **Optional own F-Droid repository.** Publish a signed index for the same APKs;
   users add its URL to their compatible client. The
   [custom repository guide](https://f-droid.org/en/docs/Setup_an_F-Droid_App_Repo/)
   allows binary repositories. Inclusion in the main F-Droid catalog is a
   separate proposal requiring compliance with its
   [open-source inclusion policy](https://f-droid.org/docs/Inclusion_Policy/).
5. **Aptoide TV, if there is demand.** A TV-oriented Android catalog. Confirm
   current TV onboarding and developer-plan fees before submission; manual
   submission can require a paid plan under the
   [Aptoide Connect submission FAQ](https://docs.connect.aptoide.com/docs/app-submission-faqs).
6. **Future Samsung distribution.**
   [Apps2Samsung community packages](https://github.com/Apps2Samsung/tizen-community-packages)
   accepts reviewed package definitions for compatible, redistributable Tizen
   apps. A tested Tizen build is required; APK/IPK files cannot substitute for it.
   TizenBrew is another possible route but requires its own module integration.

Apple TV friends use [TestFlight](https://developer.apple.com/testflight/) for
beta testing and the App Store for continuing distribution. A future Roku client
can use [Roku beta apps](https://developer.roku.com/dev/docs/channel-publishing-guide)
(up to 20 users, expiring after 120 days); that is not a permanent public catalog.

## One-pass feature checklist

Run this on each device. Mark each row per device; a row that passes on one
Android device usually passes on the other, so do the full pass on Fire TV
and LG, and a quick pass (sections A, D, E) on Google TV.

Use a server with: at least one 4K or HDR title, a series with more than 50
episodes in a season, a title with text subtitles and one with image
subtitles, Live TV with a guide, and the Zorofin server modules. Have a second
person ready for Watch together.

| # | Check | Expected | LG | Fire | Google |
| --- | --- | --- | --- | --- | --- |
| **A** | **Connect and accounts** | | | | |
| A1 | Open the app the first time | Connect page, HTTPS selected, empty address | ☐ | ☐ | ☐ |
| A2 | Explore the app preview, then Leave preview | Fictional library; back to Connect | ☐ | ☐ | ☐ |
| A3 | Enter the server, Next | Sign-in page with the server name and address | ☐ | ☐ | ☐ |
| A4 | Use Quick Connect, approve from a phone | Signs in within a few seconds | ☐ | ☐ | ☐ |
| A5 | Sign out, sign in with password and *Keep this account* off, restart the app | The account is not saved; the app opens at Connect or Who's watching | ☐ | ☐ | ☐ |
| A6 | Add a second account, switch with Change account | Each account keeps its own settings | ☐ | ☐ | ☐ |
| **B** | **Home** | | | | |
| B1 | Banner, Continue Watching, recently added | Banner shows a rated title; Continue Watching has one episode per show | ☐ | ☐ | ☐ |
| B2 | Scroll down | New episodes, short movies, 4K / HDR, seasonal, Explore more load as you go | ☐ | ☐ | ☐ |
| B3 | Sports & live events (during a live game) | Cards with LIVE badge and progress; OK opens the channel; All channels opens Live TV | ☐ | ☐ | ☐ |
| B4 | Profile > Your teams, add a team | Home reloads; sports row only shows that team | ☐ | ☐ | ☐ |
| B5 | Bell badge and inbox | Unread count; items mark read after a second on screen | ☐ | ☐ | ☐ |
| **C** | **Browse, search, details** | | | | |
| C1 | Movies, TV Shows, Live TV grids, Favorites filter | Pages load as focus nears the end | ☐ | ☐ | ☐ |
| C2 | Search a title, a nonsense word, Clear search | Grid results; *No matching titles*; recommendations return | ☐ | ☐ | ☐ |
| C3 | Title details on a 4K / HDR title | Quality badges; File details lists the source | ☐ | ☐ | ☐ |
| C4 | Long season | *More episodes* loads the rest | ☐ | ☐ | ☐ |
| C5 | Favorite, watched, start over | State sticks after Back and on another device | ☐ | ☐ | ☐ |
| **D** | **Playback** | | | | |
| D1 | Play a direct-play title, then a title that needs transcoding | Both start; progress shows on Jellyfin's dashboard | ☐ | ☐ | ☐ |
| D2 | Hidden controls: OK pauses, arrows reveal, Back hides then exits | As described | ☐ | ☐ | ☐ |
| D3 | Seek mode on the timeline, skip buttons | Lands on the chosen time | ☐ | ☐ | ☐ |
| D4 | Audio and subtitles: text track, image track, Off | Text subtitles follow Subtitle appearance; image subtitles burn in | ☐ | ☐ | ☐ |
| D5 | Quality panel, playback info | New quality applies on return; info shows method and source | ☐ | ☐ | ☐ |
| D6 | Finish an episode | Up next counts down and plays the next one | ☐ | ☐ | ☐ |
| D7 | Press Home during playback, return | Paused (with *Pause when leaving the app* on) | ☐ | ☐ | ☐ |
| D8 | Playback speed 1.5× in Playback settings | Movies play faster; Live TV stays 1× | ☐ | ☐ | ☐ |
| D9 | Remote Play/Pause key, LG Magic Remote pointer | Both work | ☐ | ☐ | ☐ |
| **E** | **Live TV** | | | | |
| E1 | Play a channel | Now and next; channel list switches channels | ☐ | ☐ | ☐ |
| E2 | Rewind 30 seconds, then Go live | Rewinds; Go live returns to the edge | ☐ | ☐ | ☐ |
| E3 | Exceed the tuner limit from another device | Conflict message instead of a failed stream | ☐ | ☐ | ☐ |
| **F** | **Watch together** (two devices) | | | | |
| F1 | Profile > Watch together > Start a group on device 1, Join on device 2 | Both list both participants | ☐ | ☐ | ☐ |
| F2 | Browse library, play a movie on device 1 | Opens on both, starts together | ☐ | ☐ | ☐ |
| F3 | Pause, seek, resume on device 2 | Device 1 follows within a second | ☐ | ☐ | ☐ |
| F4 | Open the audio panel on one device | The other keeps playing; closing the panel rejoins in sync | ☐ | ☐ | ☐ |
| F5 | Try Live TV while in the group | *Leave your group from Profile to watch Live TV.* | ☐ | ☐ | ☐ |
| F6 | Leave group | Back to the group list; playback is solo again | ☐ | ☐ | ☐ |
| **G** | **Requests** (server with Requests on) | | | | |
| G1 | Requests tab: Discover, a category, My requests | Posters and statuses load | ☐ | ☐ | ☐ |
| G2 | Request a movie and a season | Accepted once; a second press says already requested | ☐ | ☐ | ☐ |
| G3 | Search with no match > *Can't find it? Open Requests* | Opens Requests | ☐ | ☐ | ☐ |
| **H** | **Profile and settings** | | | | |
| H1 | Display: poster size, titles, ratings, badges, reduce motion | Home and grids change right away | ☐ | ☐ | ☐ |
| H2 | Account: change password (test account), Quick Connect approval | Works; other devices may need to sign in again | ☐ | ☐ | ☐ |
| H3 | Subtitles and Playback account defaults | Saved to the server; seen on another device | ☐ | ☐ | ☐ |
| H4 | Support: send a report | Reply appears under the bell | ☐ | ☐ | ☐ |
| H5 | Notification settings email and push sections | Load and save | ☐ | ☐ | ☐ |
| H6 | Administrator account: Dashboard, Metadata, Account approvals | Open inside the app | ☐ | ☐ | ☐ |
| H7 | Storage & app: Clear cache, Reset app preferences | Cache size drops; settings return to defaults | ☐ | ☐ | ☐ |
| H8 | Privacy Policy, App Support | Readable with the remote | ☐ | ☐ | ☐ |

Report a failure with the row number, the device, the title, and what
happened. For Android devices, `adb logcat -d > log.txt` right after the
failure captures the details.


## November 3 parity acceptance (pending on physical devices)

Run `flutter analyze` and `flutter test` from `apps/tv` with Flutter 3.38.10.
CI compiles the signed APK/AAB and webOS package. These checks do not establish
physical playback or store acceptance. Recheck store privacy answers for the
new opt-in sharing of launcher titles and thumbnails before submission.
Keep the existing screenshots; do not
represent a new build as device-accepted based on build 66's captures.

- Upgrade build 66 in place with a signed test build, using disposable regular
  test accounts. Confirm every saved account survives, the active selection is
  unchanged and different servers stay isolated. Cold-launch again, sign out,
  remove an account and confirm the removed token cannot restore. Test transient
  sign-in with Keep this account off. Never log tokens or inspect real account
  stores in a public artifact. The migration reads back encrypted data before
  removing either old preference key. Key invalidation shows Retry, not a reset.
- Open Quality, Audio & subtitles, and Episodes. The current selection takes
  focus; change segments and season, use Back and reopen. Playback info still
  focuses Close. Confirm D-pad can reach Close and focus returns to the opener.
- Start direct play and transcoding. Minimize, browse/search, pause/resume,
  expand, seek and close. Progress reporting and subtitles must stay correct.
  Starting another title stops the first decoder before opening the next.
  Check Up next, errors, Live TV, background pause and Watch together separately.
  Open Profile/account pages and confirm playback stops before account changes.
- Fire TV Profile > Home-screen recommendations initially reads Off. Cancel
  must publish nothing. Enable on a disposable sample account and confirm up
  to five local launcher cards. Check cold/warm card opens, disabled notification
  permission, missing images, offline/server errors, disable, sign out, remove
  account and switch between servers. Old cards must not open another profile.
  Fire TV controls card placement; a successful notification call does not prove
  the cards appeared. This does not integrate cloud watch-history personalization.
- Profile > Rate Zorofin opens only the local platform's store after selection.
  An unpublished listing can be unavailable. No review is posted automatically.

Rollback: install an older signed build only after considering Android version
code rules. Build 66 does not understand the encrypted account snapshot, so it
will require sign-in again after a successful migration. Do not restore plaintext
account backups as a rollback mechanism.

Implementation references:

- [Amazon recommendation notification channels](https://developer.amazon.com/docs/fire-tv/fire-os-7.html)
- [Android TV recommendation notifications](https://developer.android.com/training/tv/discovery/recommendations-row)
- [Amazon store links by application ID](https://developer.amazon.com/docs/reports-promo/deeplink-to-the-amazon-client.html)
- [Fire OS PiP boundary](https://developer.amazon.com/docs/fire-tv/fire-os-6.html)
- [Google TV system PiP usage restrictions](https://developer.android.com/training/tv/get-started/multitasking)

The mini-player is confined to Zorofin. It neither overlays system UI nor claims
system PiP support. The existing app pause-on-background behavior is preserved.


### Build 68 tablet-emulator observation — November 3, 2026

The signed APK at source `9b74856148b1075c074f5114d4c2842522c549a4`
(SHA-256 `dc35ec944f32636419eb04fc2c246e61c13f08e446129af8f26707d976d85815`)
was installed on Android Emulator 37.2.13.0 with the Android 11/API 30 AOSP
ARM64 image, SwiftShader, and a 1920 × 1200 landscape tablet configuration
(240 dpi, smallest width 800 dp). Home, Movies and Sintel details displayed
correctly against the isolated licensed sample library. Big Buck Bunny advanced
from 1:54 to 2:16 and paused with a decoded frame. Audio was disabled on this
emulator. The four unedited PNGs, provenance and credits are tracked in the
Vitality Labs repository under `docs/storefront/amazon/build-68-tablet/`.

**Open runtime issue:** after selecting Mini-player and then attempting Home,
playback displayed Unable to play. Native diagnostics reported
`MediaCodecVideoRenderer` / `c2.android.avc.decoder` failure with an
`ImageReader` buffer queue that no longer had a connected producer. The optional
mini-player screenshot was excluded. The cause has not been isolated to the app
versus the API 30 software emulator. Reproduce/isolate the surface transition and
verify on Fire TV before release; the controller-lifecycle widget test alone
does not establish that the native video surface survives the layout change.
Do not present this capture pass as complete acceptance of build 68.


## Fire TV device checkpoint — November 4, 2026

On an Amazon AFTTI43 (Android 9), signed build 102 upgraded the approved build 66
in place without removing app data. The saved account restored on first launch
and after a force-stop/cold launch. The owner explicitly confirmed that Live TV
picture and audio were good. This physical observation is separate from LG
playback evidence.

Build 102 checks:

- Home rows, sports/live-event cards, notifications and request history loaded.
  Home-screen recommendations remained Off; no private library cards were shared.
- Live TV decoded while playing full screen and in the in-app mini-player;
  closing playback released the tuner. A durationless-stream state bug still
  displayed Reconnect/Playback ended over continuing video.
- On-demand playback advanced, displayed text subtitles and continued in the
  mini-player after navigating Home. A forced 2 Mbps session reported transcoding
  at 1280 x 720. Current audio, quality and season received focus on panel open.
- Device Back closed both the season dropdown and its panel. The package-name
  rating URI opened App not found; the verified ASIN URI opened Zorofin's listing.

Source `eba67c7` fixes the durationless Live TV completion state/control fade,
season-menu Back layering and Amazon rating destination, and changes My requests
to responsive artwork/status cards. Flutter analysis and all 137 tests pass,
including regressions that failed before the Live TV and hardware-Back fixes.
[CI build 109](https://github.com/Zoraz01/yams-media-server/actions/runs/41901146374)
passed all three jobs (Android APK/AAB, native Flutter webOS and Flutter
webOS-web) for PR merge `7a2e34d`. Artifact 13359151789 has ZIP SHA-256
`867d83ddae09b12ac5e5587d862b44b0798e3ccd36216b1422477df3635c68b7`.

- APK: 57,966,463 bytes, SHA-256
  `bc86bf6bf508b4a8fe940970a3f31e02fd61434b883bb3eb233eba1c83c30cc6`.
- AAB: 48,361,346 bytes, SHA-256
  `750692dc8cb3406ade0117104706dbe3837aee5ec42790ab5f5b73a462b6ca5f`.

Build 109 installed in place over 102; the device reports versionCode 109 and
restored the signed-in Home. My requests displays two columns of artwork/status
cards without clipped text. On the physical TV, the season dropdown focused
the current season and hardware Back dismissed only the dropdown, then the panel.
Rate Zorofin opened the approved Vitality Labs listing. Live TV played with controls
fading and the correct pause icon; minimizing retained the decoded picture.

Two further findings prevented treating 109 as the final candidate:

- A different channel timed out in the native network reader. The generic native
  error incorrectly advised changing server transcoding settings. Source `4a64ce3`
  uses a neutral retry message for unknown native failures, retaining the specific
  unsupported-format message only for explicit playback-plan incompatibility.
  This wording correction does not repair an upstream channel timeout.
- Pausing Live TV at a nonzero reported buffer edge still produced Playback ended.
  Source `100fa88` limits finite completion to on-demand titles. The new regression
  reproduced paused-versus-ended failure before the fix and now passes for both
  unknown and finite live buffer durations; on-demand completion still offers Replay.

All 138 Flutter tests and analysis pass at `100fa88`.
[CI build 113](https://github.com/Zoraz01/yams-media-server/actions/runs/41904974534)
passed all jobs for PR merge `8809446` and installed in place over 109, preserving
the account. The device reports versionCode 113.

- Artifact 13359279587 ZIP SHA-256:
  `f0f01ed1849505982b54630db63eb8bfa8b1cb85b3268cba2d90488cbb3f9b0c`.
- APK: 57,966,463 bytes, SHA-256
  `7c0f260d92c34786b14588427d711857ed5278e37cbe1d4a8118918bd6a256c8`.
- AAB: 48,361,768 bytes, SHA-256
  `5fdf2c30db16e657b5e0cc8ab6e2e81b5da1c19d31816935f5a697744fe6b706`.

Physical pause/resume validation of build 113 remains open. The Fire TV was
unreachable during the later session; the owner will check it later. Do not
repeat connection attempts or treat build 113 as accepted for store upload.

The build-68 emulator surface failure was not reproduced during these physical
mini-player transitions. This does not establish the emulator failure's root
cause or acceptance across every Android decoder.

Operational note: if an existing ADB daemon reports a network error while the
same device port is reachable, an isolated test daemon can avoid disturbing
shared emulator connections: `adb -P 5038 connect <fire-tv-ip>:5555`. Use the same
port for install, capture and input, then stop only that owned daemon with
`adb -P 5038 kill-server`. Never commit device addresses, account state, raw logs
or personal-library captures. Retain listing screenshots from the licensed sample
library.


## Cross-client candidate checkpoint — November 4, 2026

[CI build 121](https://github.com/Zoraz01/yams-media-server/actions/runs/41916455621)
passed Android APK/AAB, native Flutter webOS and webOS-web jobs for source
`84fb927`. This candidate includes 4K device-capability negotiation, playback
bitrate/conversion diagnostics, Auto quality, full Flutter/Apple schedule guides,
remote mini-player traversal and shared resume fixes. Local checks: 150 Flutter
tests, clean analysis, 402 Apple core tests, and successful tvOS/iOS simulator
builds. These are build/regression results, not Fire TV or Apple TV acceptance.

LG-specific source `ab93734` adds guarded native resume/preroll. Its clean IPK
SHA-256 is `e42d4ba695cab3ee26f47c6dd9247e51d0bc9259b9d565306faa5be30c802389`
(1,975,472 bytes); 67 LG tests pass. It is ready for the next permitted install.
The earlier working physical candidate and exact acceptance limits are in
LG_WEB_PARITY.md.
The owner is watching and explicitly postponed further interruption until the
episode ends. The temporary inspector and isolated ADB daemon were stopped;
playback and shared services were preserved.

Remaining device gates: LG stop/readback/cold-reopen resume, controlled Auto
quality under buffering, new Fire TV build installation and playback/remote
regressions, and Apple TV guide remote/playback acceptance. Use the owned test
session only; preserve server/account isolation and other viewers. Amazon build
66 remains live; no new store submission or main merge was performed.


## Fire TV build 124 partial check — November 4, 2026

The owner made Fire TV available, then withdrew the testing window. Before the
withdrawal, signed CI build 124 for clean source `ad1ba34` upgraded test build 113
in place. The device reports versionCode 124 and restored its signed-in Home.
[CI run 124](https://github.com/Zoraz01/yams-media-server/actions/runs/41919964707)
passed; Android artifact 13365993945 has ZIP SHA-256
`bfe073b1f4b7eea04a763135c6f08d19c245f73fba5ced570d9cfa4aa33ab319`.
Installed APK SHA-256:
`e0b0b42836dfd867f41a4055d4495f94c0b0d00193134b22c5d5fd96f0d62149`.

Remote keys opened the schedule guide; channel/program rows loaded. Next advanced
the displayed window by two hours, Now restored the current window, and selecting
a channel opened the explicit Watch live dialog. Watch live was not activated.
No new Fire TV stream was started. New-build playback, Live TV pause/resume,
mini-player remote traversal, quality policy and physical picture/audio remain
unverified. The owner then said Fire TV was unavailable; all further device input
stopped and only the owned ADB daemon was shut down. A temporary screenshot on the
device is left for cleanup during the next authorized session. Do not reconnect
or continue Fire TV testing until the owner makes it available again. Amazon's
public build 66 remains unchanged.
