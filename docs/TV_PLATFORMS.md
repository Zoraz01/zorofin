# TV platform plan (non-Apple)

Initial platform plan decided October 27, 2026; Vega OS added to the roadmap
by the owner on November 3, 2026. Apple TV and iPhone remain the Swift app in
`apps/apple/`. The lightweight LG DOM candidate shares Dart services with the Flutter client;
see [current parity](TV_APPLE_PARITY.md). Native Flutter webOS, Samsung Tizen,
Android TV/Google TV and Fire OS share the Flutter client in [`apps/tv/`](../apps/tv/README.md), with separate platform
integrations and acceptance tests. Roku and Vega require separate client
implementations; Xbox remains a proposed Flutter-web integration.

## Why Flutter

Flutter is supported by LG and Samsung for eligible TVs and builds Android
apps for Google TV and Fire TV running Fire OS. Shared Dart widgets and models
reduce duplication across those targets; their playback, storage, remote input
and release packaging still need platform-specific implementation and testing.

- **LG:** official [Flutter for webOS](https://webostv.developer.lge.com/news/flutter-for-webos-tv-is-now-available-for-developers)
  SDK, webOS TV 26 Re:New or later, pinned to Flutter 3.38.10, Ubuntu-only
  build host, with LG's `video_player` implementation.
- **Samsung:** [Flutter on Tizen](https://developer.samsung.com/smarttv/develop/native/flutter.html)
  from Tizen 6.0, publishable to the Samsung TV store.
- **Android TV, Google TV, Fire TV (Fire OS):** standard Flutter Android.

This supersedes the earlier suggestion in the
product plan of a separate Kotlin client for
Android TV.

## Ranking

Order combines the owner's priority (LG, then Fire TV, then Google TV) with
development effort.

| Rank | Platform | Effort | Notes |
| --- | --- | --- | --- |
| 1 | LG webOS | Medium | Owner's first choice. Flutter needs webOS TV 26 Re:New or newer, so confirm the target TV model and year first. The owner authorized a packaged web target on November 3, initially for webOS 25; physical testing and screenshots precede store upload. See LG web app. |
| 2 | Fire TV (Fire OS) | Low after Android | Same build as Google TV plus Amazon testing. Vega OS devices are not covered. |
| 3 | Google TV / Android TV | Lowest technically | Same build as Fire TV. Covers Sony, TCL and Hisense. Android TV was the largest identified TV group in the October device snapshot. |
| 4 | Samsung Tizen | Medium to high | flutter-tizen works on 2021+ TVs; packaging and review take the most effort. |
| 5 | Android phones and tablets | Low to medium | Same Flutter codebase and Android project, with a touch layout added for small screens. Ships in the same Google Play listing as the TV build. |
| 6 | Xbox | Medium | Xbox runs UWP apps only, and Flutter's Windows build is Win32, so it does not run there. Plan is the Flutter web build inside a thin UWP WebView2 shell (the approach the official Jellyfin Xbox app takes), with controller focus handled by the existing D-pad navigation. |
| 7 | Roku | High | Roku apps must be BrightScript and SceneGraph, so this is a separate codebase that reuses the design and API contract but not the Flutter code. Built in [`apps/roku`](../apps/roku/README.md) (November 2026); device pass and store account pending, see [its release checklist](../apps/roku/docs/RELEASE.md). |
| Planned; sequencing proposed below | Fire TV (Vega OS) | Substantial port; simulator-first milestones | Owner added November 3. Separate React Native for Vega client and VPKG; Fire OS APKs do not run on Vega. Start with the bounded feasibility phase below. |

Added October 27, 2026 at the owner's request: Android phones and tablets,
Xbox and Roku. Their order after Samsung is a starting suggestion, not an owner
decision.

Fire OS and Google TV can share the Android build pipeline, while each needs
its own store configuration and device acceptance. Vega is a separate target.
The existing Fire OS build-66 Amazon submission does not include Vega support.

## Fire TV Vega roadmap — added November 3, 2026

**Decision:** include Vega OS as a planned TV target. This records scope and
estimated effort; implementation, hardware purchases and submission are not
part of this roadmap edit. Keep the existing Fire OS release moving independently.
Proposed sequencing is a small feasibility phase after the current Fire OS,
LG and Google TV release work is stable, then consider Vega ahead of Roku.
The owner has not chosen a new ordering relative to Samsung or the other targets.

### Implementation and reuse

The initial implementation choice is a separate TypeScript/React Native for
Vega client, proposed under `apps/vega/` in this repository when work begins.
Reuse Zorofin's approved design, licensed assets, Jellyfin API behavior, domain
rules, test scenarios and store materials where accurate. Port the behavior of
Dart models and API code into TypeScript with shared fixtures; Dart widgets,
Flutter plugins and Android player/Keystore implementations do not transfer
directly. Keep server/account isolation and blank server onboarding.

Amazon's [ADBT porting guide](https://developer.amazon.com/apps-and-games/blogs/2026/10/port-your-tv-app-to-react-native-with-adbt)
lists WebView/HTML5, React Native and Java/Kotlin migration paths. It does not
list a direct Flutter/Dart conversion. Use its supported workflow and official
samples to accelerate scaffolding, but do not treat generated output or a build
as accepted playback. Amazon's [video sample](https://github.com/amazonappdev/vega-video-sample)
provides a starting point for Vega media APIs and Shaka-based adaptive playback.

A simulator-first feasibility phase may compare React Native with the existing Flutter web UI
inside Vega WebView, which Amazon documents as a supported migration route.
A wrapper is viable only if remote focus, playback integration, server access,
startup and memory meet the same acceptance criteria. The working plan is the
separate React Native client; revise it if the prototype proves substantial
reuse. No WebView shortcut has been validated for Zorofin.

### Effort and simulator-first milestones

The owner requested a simulator-first, agent-driven approach. The initial
human engineer-week estimate is superseded by these milestones; no multiweek
calendar schedule is adopted. Code generation and repeated tests can move
quickly, but there is no measured Zorofin/Vega port yet from which to promise
an elapsed completion time. Give a better remaining-work estimate after the
first real sign-in/playback result. This is a substantial client port with
reusable product behavior and assets, not just another Flutter build flag.

| Milestone | Evidence to complete it |
| --- | --- |
| 1. Simulator feasibility and player prototype | Reproducible VPKG build; launch in Vega Virtual Device; isolated sample-server sign-in; decoded playback, seek and Back; remote-focus and secure-session API feasibility recorded |
| 2. Core beta in the simulator | Server/account handling, secure saved sign-ins, Home/library/search/details, movies/episodes, resume/progress, audio/subtitles/quality controls, basic settings and error recovery implemented and exercised; repeatable regression checks and screenshots |
| 3. Physical-device validation and release packaging | Supported-format matrix, direct play and transcode fallback, repeated playback, lifecycle/network recovery, remote/accessibility/performance checks on actual Vega hardware; accurate listing/reviewer instructions and signed store package |
| 4. Broader parity | Live TV/rewind, Watch together, mini-player, consent-based launcher recommendations and optional server modules assessed and validated separately |

The first milestone needs the SDK and an isolated licensed test library, not
a physical Vega TV. The core subset is a proposed first milestone, not removal
of features from existing clients. Reuse existing approved design/assets and
Amazon account; no new monetization or content-DRM integration is assumed.
Hardware access and Amazon review remain separate external dependencies.

Amazon's [Vega Virtual Device guide](https://developer.amazon.com/docs/vega/2.0/run-apps)
supports macOS/M-series packages, a virtual remote, keyboard input and rendered
UI inspection. Use it for UI/focus, Jellyfin sign-in and browsing, basic media
flows, automated regression and screenshots once the port works. The current
[Vega environment comparison](https://developer.amazon.com/docs/vega/2.0/run-apps-overview)
says virtual-device performance measurements are not supported, and Launcher
and Login with Amazon middleware are absent. WebView support is available on
Mac M-series hosts. Our Jellyfin sign-in is distinct from Login with Amazon.
A simulator playback pass is not proof of actual hardware codec/HDR/audio or
long-session performance. Amazon's [test guidance](https://developer.amazon.com/docs/vega/2.0/vega-test-tools-overview)
requires physical Fire TV testing before submission. This is a later release
gate and does not block implementing or testing the prototype in the simulator.
No Vega SDK installation, simulator run, hardware test or implementation is
claimed by this roadmap update.

Playback is the largest uncertainty: Jellyfin direct-play capability profiles,
HLS/transcode fallback, selected audio/subtitle preservation, 4K/HDR/audio-device
variation and native surface lifecycle all require measurement. Saved tokens
must use a verified secure-storage path with sign-out/account-switch cleanup.
Do not translate Android Keystore calls or advertise secure persistence without
an implemented and tested Vega equivalent. Mini-player and launcher sharing are
later acceptance gates; recommendations remain off by default and require the
viewer's explicit opt-in. The build-68 Android mini-player failure does not
establish Vega behavior either way.

### Delivery and acceptance

1. Select the current supported SDK/runtime and pin it after the feasibility
   check. [Vega 2.0](https://developer.amazon.com/apps-and-games/blogs/2026/10/vega-2-0-sdk-launch)
   was announced October 29, 2026; do not copy old SDK constants without checking.
2. Keep portable setup/build/test commands and CI in the repository. Use a
   separate Vega package and feature branch; do not rewrite the Flutter clients.
3. Use a virtual device for fast iteration plus a physical Vega device for
   playback/performance acceptance. Use only isolated authorized test media.
4. Reuse the existing Amazon developer account. Amazon documents Fire OS
   APK/AAB and Vega VPKG binaries within a submission, filtered by OS; see
   [device targeting](https://developer.amazon.com/docs/app-submission/target-app.html).
   Confirm identity/version/signing and device mapping in the portal before
   adding Vega to a later release. Do not change the already-submitted build 66.
5. Report build, virtual-device, physical-device, store submission and review
   acceptance separately. Track any non-parity feature explicitly in the listing.

## Store publishing

**Release blocker from 1.5 on (owner decision, Nov 24 2026):** the Android,
Fire TV and Google TV builds link Jellyfin's GPL-3.0 FFmpeg audio decoder for
DTS/TrueHD. Publish the matching app source under GPL-3.0 before uploading any
of those builds to a store. Apple builds use AetherEngine (LGPL-3.0 with an App
Store exception); ship its license texts in the app. Details in
APP_UPDATES_1_5.md.

Official store listings remain the primary release goal. The owner also wants
an optional LG sideload/Homebrew route before store approval; see
the distribution plan.
Self-hosted media clients do get approved on these stores:

| Store | Precedent | Account | What to expect |
| --- | --- | --- | --- |
| LG Content Store (Seller Lounge) | Official Jellyfin webOS app | [Individual or corporate seller](https://webostv.developer.lge.com/distribute/app-ecosystem) | LG QA: pretest, function and content tests; use LG's self checklist first |
| Amazon Appstore | Jellyfin listed | Amazon developer account | Lightest review |
| Google Play (TV) | Jellyfin, Wholphin and others listed | Play Console | TV quality review; newer personal accounts must run a 14-day closed test with at least 12 testers before production |
| Microsoft Store (Xbox) | Jellyfin for Xbox listed | Partner Center individual or company account | Certification run per submission; Xbox needs a controller-only path |
| Roku Channel Store | Jellyfin listed | Roku developer account | Certification checklist, including deep linking and performance on low-end devices |
| Samsung TV Seller Office | Jellyfin approved in early 2026 after a failed first review | [Public seller is US-only](https://developer.samsung.com/tv-seller-office/guides/membership/becoming-seller-office-member.html); other countries need a partner contract | Slowest; only 2021+ models accept new apps |

Review readiness for every store:

1. **Bring your own server.** No bundled address, signup or private service.
   Matches the Apple app's product contract.
2. **Reviewer access.** Preview mode with fictional titles ships in the app. A
   reviewer server with legally licensed sample media is still needed so
   playback can be tested.
3. **Keep Requests out of the first store builds.** Content-acquisition
   features invite extra scrutiny; add them after initial approval as optional
   server modules.
4. **Privacy policy and support URL** for every listing.

Developer accounts and submissions need the owner's go-ahead.

## Open items

- Test TV: LG OLED77B5PUA (2025 B5), currently webOS 25 (10.3.2), firmware 33.31.75.
  LG is rolling webOS 26 out to 2025 OLEDs (G5 first from August 2026, then
  C5/B5); as of October 27, 2026 this TV reports no update. Flutter apps run
  only after it receives webOS 26.
- First on-device pass of [TV_DEVICE_TESTING.md](TV_DEVICE_TESTING.md) on
  Fire TV and Google TV, then LG once it has webOS 26.
- Secure token storage and a TV edition of the privacy text before store
  submission.


## Playback quality requirement — November 4, 2026

4K playback is a requirement across Zorofin clients on capable hardware. A 1080p
UI canvas must not impose a video-resolution ceiling. Negotiate actual container,
codec/profile/level, frame rate, bit depth, HDR format, audio and bitrate support
separately. Keep transcoding/remuxing fallbacks and manual quality ceilings for
less capable devices, incompatible media and slower connections. Never equate
"4K source" with verified 4K output or unrestricted HDR/Dolby Vision support.

Current implementation uses LG DOM `deviceInfo`, Android/Fire TV hardware decoder
capabilities and Apple's hardware HEVC availability. Unknown players retain the
compatibility profile. Apple does not claim direct MKV support; HLS fragmented
MP4 permits the server to copy supported video when repackaging is necessary.
Selectable bitrate ceilings extend to 120 Mbps; the existing 40 Mbps default and
saved limits stay unchanged. LG additionally retains documented per-codec limits.

Native Flutter webOS, Tizen, Vega and Roku require their own platform capability
adapter and physical format matrix before a 4K release claim. They must not
inherit Android/LG flags merely from a platform name or display resolution.

Automatic quality is also requested: detect sustained/repeated buffering, ignore
startup/seeking/user pauses/background operation, reduce bitrate with a cooldown,
and hold the reduced limit; smooth playback must never trigger an upshift. Preserve manual fixed
quality, selected tracks and playback position. The current single-quality stream
requires reconnection when its bitrate changes; seamless switching requires a
server-provided multi-variant HLS ladder. Network adaptation must not disguise
codec/server errors. Playback Info should explain automatic changes.


Implementation checkpoint: automatic quality is present in the LG DOM, Flutter
and Apple clients, with manual fixed choices preserved. See
LG_WEB_PARITY.md for the exact thresholds and acceptance
limits. Flutter and Apple now also have a full two-hour schedule view; browsing
uses metadata only. A passing app build is not device or store acceptance.
