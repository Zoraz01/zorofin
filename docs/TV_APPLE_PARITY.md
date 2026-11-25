# TV app parity with Apple TV


### November13 Catch Up — two decisions, phone swipes, no Play

Apple/Flutter phones and tablets use one card with swipe-left Skip / swipe-right
Seen it plus buttons. TV clients use the same two choices with remote focus.
No Play/details/Like/Watch later actions; Seen it saves played=true before next,
Skip stays local with Undo. Existing likes/watchlist entries remain untouched.
LG preserves the published focus binding. Roku remains independently owned.
See the current1.4 contract.
Source syntax/format/diff checks only; regression suites/build/device gates NOT RUN.


### Account notification reads —1.4 source only

Apple, Flutter and LG now discover notificationReads v1 and merge account/local
request and exact-version support-reply read state across rows, history and
badges, with initialized-account first-device behavior, ready-read migration,
local fallback and <=500-item writes. Announcements unchanged; Roku independent.
See the portable implementation/gates.
Syntax/format/diff checks only. Regression suites, builds, server rollout and
all two-device acceptance remain NOT RUN; no deployment is authorized.


### 1.5 detail-page subtitle picks (Nov 24)

LG found (Sol task 243): the episode details page sent Automatic (-2) as an explicit subtitle index, bypassing the
player's per-show memory (Off in S2E2 → S2E3 still started English PGS), and always burned in PGS picked there. Fixed in
LG 7bfc9696. Flutter already leaves Automatic to the player memory and corrects PGS burn-in via
`PlaybackOptions.withDeviceCapabilities`; Apple and Roku unaffected by this path (Roku has no client PGS renderer).

### 1.5 Sports & live events parity (Nov 24)

Owner rule: the row is called **"Sports & live events"** in every app; no app shows "Live now" or "Live Now".
Owner rule (Nov 24, later): **no "On now" row anywhere** — not on Home, not in Live TV, not on the web. Live TV browsing
shows Sports & live events only; the Guide has every channel (commits 4ef1c79c and the follow-up).
Cards without match art or a crest pair show the bundled sport illustration (web/Apple `LiveSport-*`, Flutter
`live-sport-*.png`, LG `assets/live-sport-*.png`, Roku `images/sports/live-sport-*.jpg`), never a channel logo or text
label. A feed game matches a guide event by both teams or by its mapped channel, as web `gameIndexFor`; an explicit
companion channel mapping still wins over a team-matched simulcast of the same game (Roku `ZLiveArrange`). Roku fixed in
fc3e9a45 and 2b5054d9 after the owner saw "Live Now", logo cards and a missing scored game on the TCL Roku.

### Final Sports handoff: guide membership, companion settings, artwork only

Owner clarified the authoritative contract after the earlier feed-only proposal.
Strict current guide candidates are ordered/filtered with advertised companion
sportsEvents, including cap/favorites/spoilers, explicit channel preference and
unrelated live-event fallback. Artwork is applied last and cannot select games.
Native and LG companion stream summaries cover idle counts. See
the final1.4 contract.
Source checks only; suites/build/device acceptance NOT RUN. Roku owner separate.


### November 9 mobile Programs screenshot follow-up — source only

Horizontal program artwork cards and a general Sports rail replace the mobile
vertical channel-logo list on iPhone/iPad and Android phone/tablet. Shared Apple,
Flutter and LG event assembly now fetches the optional feed even with an empty
guide event selection, with strict explicit fixture/channel association and
current bounded metadata. Roku excluded; TV layout unchanged. See
the mobile follow-up.
Syntax/format/diff checks only; added regression suites, builds and all device
acceptance remain NOT RUN. Previously installed iPhone54/LG a382 are older code.

### November9 TV usability feedback — fix source, device acceptance pending

LG owner feedback prompted a Catch Up artwork/focus/action redesign, retained
Programs/Guide Live TV browsing with standard On now data, and Sign out ordering
including async admin entries. Native Flutter/tvOS Catch Up gets accurate TV-only
View details labeling/primary ordering; mobile and Roku remain unchanged. See
the1.4 follow-up.
Deferred regression sources added; test suites and physical acceptance NOT RUN.


## November 9: 1.4 development candidate (acceptance pending)

The owner requested mobile Live TV Programs/Guide browsing and 1.4 versions across
app packages. The common implementation also closes missing LG DOM wiring for
server looks and plugin Calendar/Catch Up. See
the 1.4 implementation handoff for scope, actual source
routes, package metadata, static checks and per-platform deferred gates. All new
runtime/automated/device checks are NOT RUN; earlier frozen-candidate results
remain historical. Only LG packaging and in-place installation are authorized
now, with no app launch/testing/screenshots. Roku remains independently owned.


## November 6: source 18 Play TV packaging and completed Apple TV validation

Source 18 keeps the Fire TV/shared sideload APK's optional Leanback and adds an
explicit TV-only Leanback requirement to the Play AAB. Package ID, existing upload
key, Dart behavior and decoder profiles are unchanged. The new CI route checks
both packaged manifests/signers and retains failed-build artifacts as unverified.
CI155 from frozen source 18 passed analyzer, 222 Flutter tests, nine packaging
tests and signed manifest/signature/alignment/bundle checks. Play processed its
AAB, cleared the dedicated-TV Leanback blocker and made 155 Available to internal
testers / Not reviewed. Later validator update: owner-approved178 country entries
saved/synchronized, production Ready to release; no production review/publication.
Exact source/artifact identities and the retained initial150 failure are in the
build 155 receipt. 155 is consumed.

Controlled remux fixture/API proof passed with video/audio copied under unchanged
permissions; app-decoded 155 remains pending. The owner requested current TV viewing
remain undisturbed, so 150 stays installed and its device pass is not relabelled.
Fresh Fire/Google Home/Next Up/account/playback, Play delivery, 16 KiB runtime and
broader media cases remain separate. iOS/LG/tvOS do not need this Android packaging
change. Source18 remains frozen; this update changes documentation only.

Apple TV source 17 / 1.3 (53) now passes signed tvOS and unsigned iOS compilation,
strict packaging checks and bounded physical playback/remux/remote/season/Next Up/
account/lifecycle cases. Final receipt imported from `e84d507`: internal Testing,
external/public Waiting for Review, existing automatic-after-approval setting
preserved. 53 is consumed; the separate iOS52 submission is untouched. Broader
matrix cases and paused replacement spinner observation remain open. Local IPA
hash/bytes, source equivalence, cleanup and evidence limits are in the
Apple TV receipt.

## November 6: source 17 Apple TV compile correction (historical checkpoint)

Source 16's signed generic tvOS Release build failed because the shared episode
browser attached an iOS-only DragGesture. Fix `5ce167f` conditionally compiles
that existing modifier for iOS; Apple TV retains onMoveCommand cancellation.
iPhone/iPad behavior, player/rotation, remux negotiation, versions and signing are
unchanged. Flutter/LG product source equals source 16. SDK syntax checks passed here;
signed tvOS build, iOS compile check and EP-06 physical interaction remain delegated
under BUILD-01. Proposed tvOS 1.3 (53) overrides require fresh portal availability.

The final iOS source 16 / 1.3 (52) receipt is imported: uploaded/processed, Internal
Testing, external Closed Beta Waiting for Review, public App Review Waiting for
Review after 1 Item Submitted on November 6 at 3:51 PM Eastern. Owned fixture/process
cleanup and account/permission restoration are complete. Source 17 does not replace
that iOS submission. Restrictive-policy physical HLS remains pending and UI-01
remains failed. Apple approval/public release and other platforms are separate.

## November 6: corrected iOS package and release authorization (historical)

Corrected iOS1.3(52), built from 3922019 with shipping code identical to frozen16,
passed 477 Core tests/65 suites (nine opt-in skips), archive/export and strict
signature/privacy/test-exclusion checks. The exact local package receipt is in
TESTFLIGHT_1.3_BUILD_52.md. The owner explicitly approved beta release and App Store
submission; the iOS release chat started upload at this checkpoint. The completed
submission receipt is recorded above. The corrected restrictive-policy HLS
physical rerun remains unrun, and UI-01 FAIL is retained. Android/LG/tvOS gates
are unchanged; no other client inherits iOS acceptance or release authorization.

## November 6: source16 remux negotiation correction

Same media/account/profile with restored video-transcoding=false returned HTTP
when EnableDirectStream=false and HLS when true. Fix `d544f74` now enables remux
negotiation in Apple and shared Dart requests, covering all client families.
Strict HLS conversion acceptance, authenticated same-server URLs, source/track
selection, permissions and decoder profiles remain unchanged. New regressions
cover the response shape/HTTP rejection and preserve live/codec assertions.

Testing is delegated. Source 16 needs fresh Apple archives, one shared Android
APK/AAB with an unused code above150, and rebuilt LG bridge/IPKs. The earlier
source13/iOS52 and source12/Android150 binaries lack the fix. Keep their receipts.
The iOS release owner subsequently rebuilt and consumed 52; preserve the final
submitted package recorded above.
No further broad UI rerun is planned. The prior HLS offline/isolation/cleanup pass
used temporary creation permission, now rolled back; repeat bounded HLS creation
on the corrected app under original restrictive permissions. See HLS-02/DL-02.
Final Google150 cleanup and signed-byte receipts were imported from 02d8aea.

## November 6: bounded phone UI outcome and MP4 offline pass

Source15 passed transport readiness, then failed its one bounded run at portrait-
window detection after 47.379 seconds. The ready snapshot shows the actual player
window402×874; the later first-window query remains suspect. Production permits
portrait and both landscapes, so no portrait assertion or app policy was relaxed.
UI-01 stays failed and runner execution stops for this session. The owner separately
confirmed MP4 offline picture/audio, reconnect/progress sync and exact-copy removal;
HLS offline, account isolation and restoration remain independent open gates.

## November 6: remux-only negotiation investigation (historical)

The exact source13 Apple request also returns HTTP for the isolated remux-enabled,
video-transcoding-disabled viewer; this is no longer only a minimal-profile
finding. Static upstream source suggests `EnableDirectStream=false` removes the
remaining remux capability before HLS profile selection. Both Apple and shared
Dart currently send that flag, so HLS-02 tracks all clients, including LG's bridge.
The iOS validator owns a one-field false/true comparison on unchanged media and
permissions. The pinned upstream trace and its deployed-revision limitation are
in the common handoff. No shipping change yet; preserve strict HLS-only conversion
acceptance and each platform's decoder profile. Existing source13/build52 and
source12/build150 receipts remain unchanged; hold the iOS upload while resolving
this compatibility case.

## November 6: atomic iPhone test observations and final Sony artifact

Source `home-rows-candidate-20261106-15` changes only phone test snapshot reads.
Source14 failed between live exists/label lookups; one immutable app tree now
supplies player attributes and each enclosing window, while live hittability
remains required. One bounded rerun is authorized by the testing plan; preserve
failures and stop repeated runner attempts if it fails again. Shipping Apple
source/settings equal13 and other client source equals12.

Google TV build150/source12 now passes all 219 tests and bounded physical episode
positioning/remote-selection checks. Exact shared APK/AAB hashes, retained initial
fixture-CPU conversion timeout, later TS conversion pass and remaining Fire,
format/runtime/store/cleanup gates are in the common handoff/matrix. No platform
pass substitutes for another device's acceptance.

The iOS source14 file-download journey separately passed (one test, zero skips,
45.245 seconds), with an owned saved copy retained for the owner's offline check.
Source13 signed local export1.3(52) passed; its exact receipt is preserved.
Offline/progress/isolation and real HLS download gates remain open. Both minimal and exact production-profile HLS preflights returned HTTP;
the newer HLS-02 investigation above retains the unchanged-permission boundary. No upload or
App Review acceptance is established.

## November 6: iPhone test transport observation

Source `home-rows-candidate-20261106-14` changes only the nonshipping phone UI
waiter: inspect visible transport first, reveal only without mounted controls,
limit repeated reveal taps, preserve exact Pause/Play and reachability assertions,
and retain private failure screenshot/control diagnostics. Source13's automated
transport timeout stays failed; the owner's bounded human playback/rotation pass
on iPhone16Pro/iOS27.2 is separate. All shipping clients/settings are unchanged;
source13 Core/hosted evidence retains its identity. Rebuild the phone test runner,
then continue UI/download/offline and remaining device/release gates.

## November 6: iOS/iPadOS offline download authorization

Source `home-rows-candidate-20261106-13` enforces fresh authenticated current-viewer
permission for new downloads, retries and queued starts. Unknown/denied policy
fails closed; account-generation/preparation guards reject stale work. Existing
saved-copy playback/cancel/removal remains usable. Only iOS/iPadOS has this offline
manager/UI; LG/Flutter/tvOS have no equivalent offline feature to change. Shared
Swift optional policy decoding remains backward-compatible. No runtime server
permission is changed by this product fix.

The opt-in phone journey and hosted/touch harness corrections are nonshipping.
Use `DL-01`/`DL-02`, `ROT-01`/`ROT-02` and `UI-01` in the common matrix. The iOS
validator reports Core475 tests/65 suites PASS (nine opt-in skips), hosted7 PASS /
four delayed opt-in SKIP and Release UI build PASS on exact source13. Touch,
download/offline and final packaging/release gates remain pending; preserve
source11 harness failures and skipped stress cases.
Flutter/LG product source is identical to12, and Apple rotation/Next Up fixes,
iOS1.3(52), tvOS1.2(49), signing/privacy and package identities remain intact.

## November 6: episode metadata fits native Flutter cards

Source `home-rows-candidate-20261106-12` constrains current/watched status text to
its card and removes the spacer when runtime is absent. Source11/CI148 had a clean
analyzer but 213 passing/four failing tests: the 300-pixel metadata Row overflowed
18 pixels. The positioning assertions passed before exception checks; source 12
preserves all of them and adds runtime/status bounds. The validator subsequently
passed all 17 focused checks with `fcfe34b`; full tests/build/device reruns are
delegated and pending. No148 artifact exists. Google/Fire use the next collision-checked
shared signed build above 148. Native Flutter webOS shares the fix but is deferred.

This is a Flutter RenderFlex constraint. iOS uses stacked episode metadata;
tvOS and LG use native SwiftUI/DOM layout. Their implementations remain intact,
with independent device checks. Apple product code remains identical to 8 and test sources to 9. The separate
release-default commit sets iOS1.3(52) while retaining tvOS/TopShelf1.2(49) and
other project/signing/privacy settings. iOS testing has resumed under the owner's
newer authorization.
See the shared handoff for release boundaries and pending evidence.

## November 6: current episode visibility after page two

Source `home-rows-candidate-20261106-11` corrects Flutter player/details rows that
loaded episode45 but left it offscreen. Positioning now uses the same 300/380-pixel
card widths as rendering, explicit item extents and loaded-content bounds. Season
focus and interaction/selection/account guards remain. Six new regression cases
check full visibility after a delayed page, last/first items, remote input and
account replacement. CI148 exposed the metadata overflow above; Google/Fire
device retests need source 12 and a new artifact.
The same widget serves native Flutter webOS; that device gate remains deferred.

LG DOM targets the selected element; Apple centers an episode ID through its
native scroll view. Those equivalents and their cancellation guards were reviewed
and remain unchanged. Use independent `EP-03`/`EP-06` acceptance across platforms.
Source10/build147 meanwhile passes the original Sony quality-conversion reproduction
with actual TS delivery; broader HLS/Fire cases stay open. Its later Auto40
restoration used HEVC remux, not the initial DirectPlay route.

## November 6: HLS conversion and platform-specific parsers

Source `home-rows-candidate-20261106-10` changes the Android (Google TV / Fire TV)
HLS profile to TS after a physical Media3 1.9.2 negative-`tfdt` failure during
HEVC→H264/AAC quality conversion. Hardware/direct-file codecs, Main10/4K evidence
and selected tracks/positions are retained. LG retains native fMP4 with TS live
fallback; Apple retains its AVPlayer profiles. These platforms do not use the
failing Android parser. Shared-Dart regressions assert the split; no decoder
workaround or server timestamp change is copied to other players.

Google TV source7/build146 passed analyzer and 209 tests and several bounded
physical cases, but the conversion failure remains open. Static TS and fMP4
inputs also passed: the report is specific to the converted negative-timestamp
stream. Source10/build147 analyzer and 211 tests pass; the original Sony conversion
reproduction passes with TS. Broader conversion checks and Fire TV remain pending.
Use `HLS-01` in the validation matrix; retain
source-specific artifacts and independently cover LG/Apple startup/seek/audio.
The iOS owner later resumed testing and authorized an update after release checks;
see the current common handoff rather than the historical pause receipt.

## November 6: Continue Watching selection and direct playback

Source `home-rows-candidate-20261106-6` preserves Next Up order before older
Resume titles. Resume records replace matching episodes/series without changing
the server's rank; unmatched resumes follow, with existing bounds/deduplication.
Shared Swift and Dart implement the same rule, including catalog fallback and LG
bridge. Home Continue Watching cards now play directly across Apple, Flutter and
LG, with zero/saved ticks as appropriate; library cards retain details navigation.
Latest main iOS offline downloads/rotation changes are merged; Android letterbox
fix `1c0730c` remains intact. No backend or watched-state change is required.

Added Swift/Dart selection, Dart catalog/bridge, Flutter remote/tap and LG DOM
regression sources await the separate testing chats. Use `NEXT-01`–`NEXT-04` in
CLIENT_VALIDATION_MATRIX.md, plus playback refresh,
account/stale-response and platform build/physical checks. No source-6 artifact
or acceptance is claimed. Older validation records below retain their identities.

The Flutter TV client in [`apps/tv/`](../apps/tv/README.md) is meant to look
and behave like the Apple TV app in `apps/apple/`. This checklist compares it
with the Apple app on `release/zorofin` (1.1, build 23, commit `eac0622`),
feature by feature. The Apple files named in each row are the reference.

Status: **Done** matches Apple TV. **Differs** works, with a TV-platform
difference that is noted. **Open** is still to do. **Apple only** has no
equivalent on other TV platforms.

Every row marked Done or Differs is covered by the
[device test plan](TV_DEVICE_TESTING.md), so one pass on each TV checks it.

Last updated November 4, 2026. The original comparison remains against 1.1;
selected-choice focus and Rate Zorofin now follow the Apple 1.2 behavior.
Implementation/test status is distinct from physical-device acceptance.

## Current cross-client fixes and enhancements

This matrix supersedes the older Apple 1.1 comparison for the changes below.
**Implemented** describes source behavior, not store availability or proof on
all hardware. Device results and remaining gates live in
[TV_DEVICE_TESTING.md](TV_DEVICE_TESTING.md) and LG_WEB_PARITY.md.

| Behavior | LG DOM client | Flutter clients | Apple TV / iPhone / iPad |
| --- | --- | --- | --- |
| Saved playback position and honest timeline | Shared tick fix; actual seek; guarded native HLS preroll; settling candidate awaits device validation | Shared tick fix; actual VOD/HLS seek; preserve bookmark on failed startup | Existing actual AVPlayer seek/preparation and bookmark protection; no synthetic offset |
| Continue Watching after exit | Await final stop acknowledgement, then refresh | Shared saved state and fresh item lookup; device regression remains | Existing server progress reporting and Home reload |
| 4K negotiation | DeviceInfo UHD/codec profile; copied HEVC HLS accepted on one TV | Android hardware-decoder profile; other platform adapters remain gates | Hardware HEVC-aware AVPlayer profile; physical format matrix remains |
| Playback Info | Source/reported output bitrate, limit and conversion reasons | Same shared diagnostics | Source/stream/network bitrate, limit, conversion reasons and decoded size |
| Auto quality after buffering | Downward-only reconnection with cooldown | Same downward-only policy and retained tracks/position | Equivalent downward-only Swift policy and AVPlayer reconnection |
| Full Live TV schedule | Existing guide and Now & Next | New two-hour guide, search/favorites and program details | New shared iOS/tvOS guide with explicit Watch live |
| Unknown playback errors | Neutral retry/quality advice | Removed unsupported server-transcode diagnosis | Neutral retry/quality advice now applied to AVPlayer failure observer too |
| Live TV pause/completion | Separate live timeline and owned-stream lifecycle | Fixed durationless/finite live buffer being mistaken for VOD completion | Existing live timeline; AVPlayer lifecycle tested separately |
| Selected-option focus and selectors | Anchored season/notification menus and current-choice focus | Current-choice focus; Back closes season menu before panel | Existing current-choice focus and native platform presentation |
| Skip controls | Visible configurable seconds, default forward 30 | Configurable intervals, default forward 30 | Configurable intervals, default forward 30; custom controls label seconds |
| Mini-player | One decoder, remote controls | Remote entry/traversal/Select regression fixed | Native system Picture in Picture where supported |
| Saved sign-ins | Keymanager3-backed AES-GCM; temporary sign-in if unavailable | Android Keystore vault; native webOS/Tizen secure storage remains open | Existing Keychain storage |
| Home / requests / notifications | Incremental rows, near-end loading, sports, request cards, inbox | Shared Home/module repairs and request cards | Existing Apple reference behavior; avoid replacing native UI with web workarounds |
| Server announcements in Notifications | Authenticated feed; compact expandable cards; unread and bounded account history | Same feed in native inbox/read history | Same feed in Apple inbox/read history; distinct source label |
| Seen notification history | First successful ready-request snapshot goes to Hidden; 60% visible/900 ms dwell; read entries hidden on reopening | Immediate read on reply activation; scaled viewport dwell corrected; persisted server/viewer history | Existing first-snapshot history and session-stable Hidden behavior retained; no source change |
| External home-screen content | No approved LG equivalent implemented | Fire OS recommendations require explicit opt-in, off by default | Existing Apple Top Shelf; Apple-only integrations remain native |
| OLED/idle behavior | Preserve system screensaver; fade playback controls | Preserve platform idle lifecycle | Preserve system idle lifecycle |

Auto only lowers bitrate and holds the stable limit for the session. Increasing
quality requires an explicit viewer choice. No speculative parallel transcodes
are opened. Auto quality is not seamless multi-rendition HLS ABR. A completed build is not a
4K/HDR or device acceptance claim. LG's muted-preroll workaround is specific to
its native HTML video decoder and is deliberately not copied into AVPlayer or
Android's decoder. The shared behavior required everywhere is an actual seek,
no early picture/audio/progress, cancellation safety and bookmark preservation.

### Platform reach and release gates

- **LG DOM** is the current lightweight LG candidate, using the shared Dart
  services. Its resume candidate is installed; the owner postponed further
  interruption until the episode ends. Final stop/readback/reopen is pending.
- **Fire OS, Android TV, Google TV and Android phone/tablet** share Flutter source.
  Common fixes propagate to those builds; layout, remote/touch and codec tests
  are still required on each device class. Fire TV will be available later.
- **Apple TV, iOS and iPadOS** share the Swift source. Native player behavior,
  focus and touch layouts retain platform-specific implementations. New guide
  and quality features still need physical acceptance.
- **Native Flutter webOS and Samsung Tizen** inherit shared Dart behavior, but
  secure storage, capability adapters, decoder behavior and packaging require
  their own acceptance. Do not call them release-ready from Android CI.
- **Vega, Roku and Xbox** remain roadmap targets. The behaviors above are their
  required acceptance baseline, not a claim that clients or fixes ship there.
- **Jellyfin's browser UI** is separately maintained upstream/branding code; a
  native decoder workaround is not a reason to alter shared server services.

For every future client bug or enhancement: identify the shared layer, audit the
other active clients, port the user-visible behavior where applicable, add a
regression for each distinct implementation that needs one, and update this
matrix with any justified platform difference or remaining release gate. Keep
source/test, installed-device and published-store status separate.

## Reviewed UX additions for 1.4

The November owner review and proposed app behavior are in the
Mobbin UX plan. The
plugin web implementation and coordinator handoff
records the web candidate separately. Those web fixture checks do not change
any native Done/Open status below. The testing coordinator owns applying and
validating the equivalents in the active 1.4 app candidate.

## Connect and accounts

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Connect page: HTTPS / HTTP selector, address hints, preview button | `ConnectView.swift` `serverPage` | Done | HTTP only for private-network addresses |
| Sign in: server card, Quick Connect first, username and password | `ConnectView.swift` `signInPage` | Done | Quick Connect code lasts 2 minutes, as on Apple |
| Keep this account on this device | `AppModel.accept(remember:)` | Done | An account not kept is never written to storage |
| Who's watching, Change account, add or remove saved accounts | `SavedServersView` | Done | |
| Preview mode with the fictional library | `PreviewLibrary` | Done | Home uses a fixed layout in preview so screenshots match |
| Token storage | Keychain | Differs | Android/Fire OS Keystore encryption with verified migration and no plaintext fallback; webOS/Linux preferences remain open |

## Shell and Home

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Header: Home, Movies, TV Shows, Live TV, Requests, search, bell, profile | `Shell.swift` | Done | Requests tab only when the server offers it |
| Home banner (rated title, best artwork, kept per visit) | `HomeBanner` | Done | |
| Continue Watching (resume plus next up, one per show) | `ContinueWatchingFeed` | Done | |
| Recently added movies and shows | `HomeView` shelves | Done | |
| Client Home rows: new episodes, short movies, 4K / HDR showcase, seasonal picks, your teams | `ClientHomeRows.swift` | Done | Legacy v1 merge; supported v2 feed is authoritative. See Home-row contract |
| Server rows: requests ready, popular this week | `HomeRows.swift` | Done | Need the Zorofin server modules |
| Row order (pinned rows, weighted shuffle) | `HomeRowOrder` | Done | |
| Explore more discovery rows | `BrowseContinuation` | Done | |
| Sports & live events with sport artwork and All channels | `LiveEventsShelf` | Done | Artwork manifest when the liveArtwork module is on |
| Your teams | `HomeTeamsView` | Done | Profile > Your teams |
| Library grids with Favorites filter | `CatalogView` | Done | |
| Search with recommendations and grid results | `SearchView` | Done | "Can't find it? Open Requests" when Requests is on |

## Title details

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Artwork, heading, rating, metadata | `DetailView.swift` | Done | |
| Play / Resume / Play next episode, favorite, watched, start over | `playbackActions` | Done | |
| Quality badges and File details | `qualityBadges`, `MediaFileInfoView` | Done | |
| Seasons and episodes browser with More episodes paging | `SeasonEpisodeBrowser` | Done | |
| Cast & Crew, More Like This | `DetailView` | Done | |
| Live TV limit notice and conflict alert | `LiveTVCapacity` | Done | Needs the liveTVAvailability module |

## Player

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Custom controls, remote seek mode, skip intervals | `NativePlayer.swift` | Differs | Apple TV 1.1 uses Apple's native controls; the TV app keeps the custom design Apple previews in Storage & app |
| Quality, audio and subtitles, playback info, episodes panels | `customSettingsPanel` and others | Done | Current-choice focus including asynchronously loaded season; Playback info focuses Close. No dropped-frame count from `video_player` |
| Text subtitles drawn by the app, subtitle appearance | `subtitleFields` | Done | |
| Default playback speed | `NativeSettings.playbackSpeed` | Done | Ignored in a Watch together group, as on Apple |
| Up next with countdown | `nextEpisode` overlay | Done | Uses the account's autoplay setting |
| Live TV now / next, channel switching, rewind and Go live | `LivePlayer.swift` | Done | |
| Pause when leaving the app | `pauseInBackground` | Done | Triggers when the TV switches app or input |
| In-app mini-player | Picture in Picture | Differs | One decoder while browsing; no system overlay or background playback entitlement |
| Fire TV home-screen recommendations | Top Shelf | Differs | Explicit viewer opt-in; local launcher cards, account isolation and clear-on-sign-out. Actual placement is controlled by Fire TV |
| AirPlay and Apple system player / Top Shelf APIs | | Apple only | Native Apple APIs cannot run on Fire OS |

## Watch together

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Group list, start, join, leave | `WatchTogetherView.swift` | Done | Shown when the account's SyncPlay policy allows it |
| Shared queue, play, pause, seek, buffering wait | `WatchTogetherModel.swift` | Done | Server clock offset and drift correction as on Apple |
| Live TV blocked while in a group | `Shell.play` | Done | |

## Requests

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Discover, trending, categories, My requests, activity | `RequestsView.swift` | Done | Build flag `ZOROFIN_REQUESTS=false` removes it for first store builds |
| Request details, seasons, 4K, quota, duplicate protection | `RequestDetailsView` | Done | |
| Hide available titles in Requests | `displayFields` | Done | |

## Profile and settings

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Profile header, Change account, Sign Out / Leave preview | `ProfileView` | Done | |
| Account: photo removal, password change | `accountFields` | Differs | Choosing a new photo is iOS only on Apple too |
| Quick Connect approval | `ProfileQuickConnectView` | Done | |
| Display, Playback, Subtitles, Controls, Storage & app | `NativeSettings` | Done | |
| Notification settings, Notifications inbox, Support | `HomeUtilityView` | Done | Need the Zorofin modules |
| Administration: Dashboard, Metadata, Account approvals | `AdministrationWebView` | Done | Administrators only |
| Privacy Policy, App Support, sample media credits | `PublicInformationView` | Done | TV wording updated for implemented storage and handoffs |
| Rate Zorofin | Profile rate entry | Differs | Amazon / Google store detail links on demand; store listing must be published to resolve |

## How to check

Run `flutter test` in `apps/tv`. Widget tests drive the preview library with
remote keys (Home rows and live events, details, player panels, Requests,
search, Your teams, Watch together, notifications, support), and unit tests
cover the Jellyfin client, Home row rules, SyncPlay handling, request
submission and settings. Playback, remotes and server modules need real
devices: follow [TV_DEVICE_TESTING.md](TV_DEVICE_TESTING.md).


### LG installed-policy check — November 4, 2026

Clean `ad1ba34` is installed on the paired LG after cleaning completion. At
12 Mbps, real media resume, exact stop/server readback, Continue Watching and
cold-app-reopen passed. A controlled buffering signal exercised the installed
policy and native player: 12→8 Mbps, preserved timeline, no upshift over more
than 210 seconds of advancing media. Original completed-episode history was
restored and the app/inspectors closed. Two 40 Mbps starts timed out; high-limit
startup and new-build physical picture/audio remain open. This does not advance
Fire TV or Apple device acceptance. Details: LG validation.

### Episode status refresh — November 4, 2026

LG card watched markers and post-playback detail refresh are implemented locally.
Flutter details and loaded episode rows now consume the existing playback
revision, preserving the chosen season while displaying fresh server UserData.
Apple episode rows already consume the player's library revision. The LG server
readback contained the expected bookmark and watched flags; this was a client
presentation issue, not evidence that all playback-reporting paths are accepted.
See LG validation for tests and remaining device gates.

LG loading now reserves the final player layout: metadata, time labels and VOD
timeline stay in their slots before readiness, with seek controls disabled. The
80-test LG suite and a 1920×1080 synthetic browser layout comparison pass. Flutter
already reserves the timeline; Apple's AVKit loading UI remains native. Physical
LG acceptance and installation of this layout follow-up remain pending while
the owner is watching. See the LG handoff for evidence and artifact information.

### Flutter loading geometry — November 4, 2026

Owner requested the same loading consistency check in Flutter. Its timeline and
header already persist, but elapsed/remaining labels expanded from placeholders
to runtime-dependent widths, moving the timeline edges. Both VOD time slots now
reserve 88 logical pixels, matching LG. A 1920×1080 widget regression confirms
identical header/timeline rectangles from preparing with unknown duration to
playing a long title; the timeline remains disabled until ready. The full Flutter
suite passes (160 tests, including the codec-profile regression below), and
analysis has no issues. Apple retains AVKit's native presentation. Fire TV remains
unavailable; no install or store update occurred.

### HD60 sports playback profile — November 4, 2026

LG's detected UHD H.264 and Apple's hardware-capable AVPlayer profiles no longer
apply the 4K30 limit to 1080p60 sports. Dimension-specific guards preserve existing
4K ceilings; unknown-player fallbacks and Android's detected caps are unchanged.
Monumental negotiation on the real server loses VideoFramerateNotSupported with
the exact new LG profile, leaving only the container reason. This was metadata
negotiation against an existing source, not an actual playback/recovery test.
Physical LG, Apple and Fire TV gates remain separate. See LG handoff for official
codec references, regression coverage and non-disruptive investigation details.

### November 4: Live compatibility and LG selector rendering

LG and Flutter detected playback profiles now include TS/H264/AAC HLS alongside
preferred fragmented MP4; Apple hardware HEVC profiles receive the same fallback.
This supports sources requesting UseMostCompatibleTranscodingProfile. Exact LG
metadata negotiation changes from unusable HTTP to HLS without opening a tuner.
Unknown-device compatibility and legitimate codec/bitrate restrictions remain.
All clients replace the generic instruction to change server transcoding settings
with a compatible-stream failure message. See LG_WEB_PARITY.md for evidence/gates.

LG detail/player dropdown chevrons use SVG instead of a font glyph; open/closed
browser rendering and Back focus restoration pass. Flutter/Apple already use
platform icon systems. Local suites: LG80, Flutter160, Apple409 pass, analyzer
clean. Device acceptance remains separate; installed LG caab387 is unchanged.

### LG account entry polish and device notification check

Owner authorized resumed LG testing/screenshots, then requested a cleaner account picker and login. LG uses large initial-avatar profile tiles, server labels, a separate Manage accounts mode and a two-column branded connection/sign-in layout. Existing account IDs, consent, encrypted storage and authentication paths are retained. Flutter already separates management from switching and renders account avatars; Apple has its native saved-account UI. Those clients were inspected for applicability; no auth/storage changes are needed there for this LG presentation fix. 85 LG DOM tests pass, including exact-account selection and removal-confirmation regressions. Device layout acceptance follows installation.

Seen-notification behavior passed on the paired LG comparison build: two viewed ready notices stayed stable while open, disappeared on reopen, and moved into the collapsed Hidden history. Saved personal sign-in restored after upgrade. The isolated reviewer account connected without clearing the saved personal account. Reviewer sample playback failed to start (direct MP4, 4.1 Mbps, decoded video unavailable), and four sample posters remained blank. Independent HTTPS probes returned six valid JPEGs and video HTTP 206; this does not establish LG decoding acceptance. Investigate before submission; no production playback history was intentionally changed.

### Apple TV sign-in reference — November 5, 2026

Owner explicitly requested the Apple TV sign-in layout, superseding the split
intro/form design in a9f79fb. LG now follows ConnectView.swift: centered column,
brand, connected server name/address, Sign in heading, primary Use Quick Connect,
or sign in divider, visible username/password, secondary Sign in, keep-account
choice, password reassurance, Privacy Policy and App Support. Quick Connect
replaces credentials with the approval card until cancelled/completed. Remote
Back cancels that card first. Password entry remains transient; saving remains
explicit and protected by the existing LG vault. Apple is the reference, with no
Apple auth changes; Flutter's native auth is not replaced by this LG presentation.

Validation: 88 LG DOM tests and 13 shared frontend tests pass. Cancellation ignores
late codes; failed passwords restore both choices and clear entered passwords.
Server label comes from the validated connection, never a bundled private server.
Physical visual acceptance follows installation and is recorded in LG_WEB_PARITY.

### LG sample-library reliability audit — November 5, 2026

Apple ConnectView's vertical avatar list is the LG account reference; LG now
implements that layout, management and server-scoped add-account flow. Avatar
requests are isolated per saved session. Flutter already uses a vertical 820-pixel account list and retains its native
account behavior. The LG MP4-family MIME fallback, Dart bridge readiness
and failed-image cache retry are DOM/native-webOS concerns; do not apply the MIME
workaround to AVPlayer or native Flutter decoders. Library refresh adds a one-minute
return expiry and explicit Refresh while preserving focus; Apple's existing
revision/refresh path is retained. Live TV policy is now serialized in the shared
Viewer and checked before shared snapshot requests; Apple entitlement filtering
was not changed or device-validated in this pass. LG fixture passes and temporary
controlled decoder proof do not establish physical picture/audio acceptance.

LG long detail descriptions now disclose their complete synopsis/credits through
More; the initial view is limited to three lines. Full server text is retained
verbatim in the dialog, with Back/Done focus restoration. Apple/Flutter currently
show their full synopsis and remain a presentation follow-up; no metadata or
license text is deleted. This avoids altering sample metadata just for captures.

## Home-row switchover — November 5, 2026

Shared Dart, fast LG DOM and both Apple targets now select v1/v2 explicitly.
Client code, regression sources and backend refresh follow-up are consolidated
on `feature/home-rows-switchover`. Execution and physical acceptance remain
unclaimed. Use the common candidate handoff
for one source pin, dependencies, commands, signed-artifact receipts and the
required physical Google TV gate. Android letterbox fix `1c0730c`, newer LG
account/playback/description work, Apple release settings and Google Play
preparation are preserved. Decoder-specific fixes remain platform-specific.

## Candidate 3: common playback and episode-browser repair

The isolated-server stop retry failure is repaired in the Dart bridge and shared
Dart/Swift transient reporting paths. LG additionally retains failed completions
with Retry across close/autoplay; native reporters remain bounded after exhaustion.
That difference is explicit, not marked complete. The episode-selection fix is
carried into LG, Flutter and shared Apple: resolved current/resume/up-next season,
paging, empty-season fallback and late interaction/account guards. Native controls
and Android black margins are retained.

CLIENT_VALIDATION_MATRIX.md is the shared ledger for
fix applicability, automated/fixture/build/physical/store gates, source/artifact
identity and pending differences. Use it for every run. Candidate-3 tests/builds/
devices are NOT RUN; old evidence does not close new gates. LG device control is
on hold while the owner watches; native Flutter webOS is deferred.

## Candidate 4: regression-gate repair

LG's clean candidate-3 run passed analyzer but failed DOM and Flutter suites.
Candidate 4 repairs the incomplete Users/Me reporting fixture and older unawaited
future assertions, retaining the shared bridge's stale-account protection. LG alone
needed a detached-DOM reporting guard and browser-lifecycle-aware test cleanup;
native mounted/task guards remain applicable. The fake player now exposes focusRoot,
and uncaught jsdom errors fail the harness instead of appearing beside a pass.
See the matrix for original counts, required reruns
and installation-only authorization. No candidate-4 tests/builds/devices ran here.


## Default saving on sign-in — November 6, 2026

The owner requested default saving upon LG sign-in. The fast LG client now selects
Keep this account for both password and Quick Connect when protected storage is
available. Opt-out, unsupported temporary sessions, explicit failed-save recovery
and encrypted-only persistence remain intact. Late save responses are scoped to
the current sign-in/account UI. No current session is saved by installation/startup.

Native audit: Flutter `SignInScreen._remember` already defaults from
`supportsPersistentSignIn`; Apple's shared `ConnectView.remember` already defaults
to true. Both methods share each platform's completion path and respect opt-out.
No native auth/vault/player changes are required for this request. Regression
execution, actual protected writes/restoration and physical sign-in remain separate
per-platform gates: see ACCOUNT-01/02 in the matrix.
New DOM and bridge test sources are added; this implementation owner ran no tests.

The previous LG source passed 112 DOM/199 Flutter, analyzer/core and exact packaged
fixture/server checks, and both app IDs installed successfully. Those receipts
remain pinned to source 4 in the common handoff;
new default-save packages and their acceptance are still pending.

## iOS/tvOS 1.4: Pick Together, trailer previews, Mobbin refinements — November 18, 2026

Apple-only source on `feature/ios-1.4-pick-together-trailers` (over the 1.4 candidate).

| Change | Apple | Flutter TV / phone | LG DOM | Roku |
| --- | --- | --- | --- | --- |
| Pick Together (schemaVersion 1) | Implemented: phone/tablet vote from Catch Up Together and Watch together; Apple TV hosts as a display from Home and Watch together | Pending | Pending | After 1.4.0 certification |
| Trailer previews (expanding card) | Implemented on Apple TV Home rows of movies/shows; iPhone/iPad unchanged | Pending | Pending | After 1.4.0 certification |
| Mobbin library/playback refinements (c2aab580) | Re-applied | Not re-applied (004e416e stays reverted) | Not re-applied | n/a |

Automated: `swift test` 551/551 (includes the Pick Together contract and the
PreviewCoordinator rules); iOS and tvOS simulator builds succeed unsigned. Two
Sports parity fixtures were corrected to carry guide evidence and a channel name
distinct from its programme, as `LiveRules.cleanTitle` and placeholder rules require.

Not yet done: device or simulator acceptance (the demo companion has no
`pickTogether` module and no trailers; unsigned simulator builds cannot open the
keychain), trailer caption sidecars and Logo wordmarks (title text is used),
previews in server-defined custom Home rows, and the Pick Together cross-device
acceptance in the apps handoff.
