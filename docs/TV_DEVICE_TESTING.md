# TV app device testing

How to put the Zorofin TV app on LG, Fire TV and Google TV devices, yours or a
friend's, and one checklist that validates every feature in a single pass.
Feature status lives in [TV_APPLE_PARITY.md](TV_APPLE_PARITY.md); build
commands live in [`apps/tv/README.md`](../apps/tv/README.md).

Last updated November 2, 2026.

Recording a run and getting an automatic smoothness, audio and AI review: see
AV_CHECKS.md.

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
2. **Builds.** PR/main changes run app validation without packaging. Request
   the *TV app* workflow manually on the intended branch and choose Android,
   webOS web, native webOS, or all available platforms. Android defaults to
   `zorofin-tv-android-<commit>` containing `app-release.apk` and
   `app-release.aab`. The workflow run number remains the Android version code.
   Ordinary packages last seven days; set `release_candidate=true` for 30 days.
   Existing Play packages keep their 30-day retention and release safeguards.
   See the Actions policy for dispatch commands and
   branch-specific inputs. Without signing secrets, ordinary Android builds
   retain the existing debug-key fallback; Play builds still require the
   existing release certificate.
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

**Later, without sideloading:** Amazon Appstore Live App Testing invites
testers by email. It needs an Amazon developer account, which is your call.

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

LG runs Flutter apps only on **webOS 26 and later**. The LG B5 at home is on
webOS 25 and reported no update on October 27, 2026; check Settings > General
> About this TV > Check for updates before each session.

**Your TV**

1. Install *Developer Mode* from the LG Content Store and sign in with an LG
   developer account. Turn on Dev Mode Status and Key Server; the TV restarts.
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

**A friend's TV:** LG has no public beta channel. Until the app is in the LG
Content Store, a friend needs Developer Mode on their own TV with their own
LG developer account, and you install the `.ipk` over their network (or they
install the `.ipk` themselves with LG's `ares-install`). Plan LG friend testing for after store
review unless someone is comfortable with that.

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
