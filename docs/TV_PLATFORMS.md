# TV platform plan (non-Apple)

Decided October 27, 2026. Apple TV and iPhone remain the Swift app in
`apps/apple/` and are released separately. Every other TV platform shares one
Flutter codebase in [`apps/tv/`](../apps/tv/README.md) with one design.

## Why Flutter

It is the only stack that LG and Samsung both support for TV apps, and it
builds native Android apps for Google TV and Fire TV. One Dart codebase and one
widget design cover every platform below.

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
| 1 | LG webOS | Medium | Owner's first choice. Flutter needs webOS TV 26 Re:New or newer, so confirm the target TV model and year first. If older TVs matter, a packaged web app on LG alone is the fallback. |
| 2 | Fire TV (Fire OS) | Low after Android | Same build as Google TV plus Amazon testing. Vega OS devices are not covered. |
| 3 | Google TV / Android TV | Lowest technically | Same build as Fire TV. Covers Sony, TCL and Hisense. Android TV was the largest identified TV group in the October device snapshot. |
| 4 | Samsung Tizen | Medium to high | flutter-tizen works on 2021+ TVs; packaging and review take the most effort. |
| 5 | Android phones and tablets | Low to medium | Same Flutter codebase and Android project, with a touch layout added for small screens. Ships in the same Google Play listing as the TV build. |
| 6 | Xbox | Medium | Xbox runs UWP apps only, and Flutter's Windows build is Win32, so it does not run there. Plan is the Flutter web build inside a thin UWP WebView2 shell (the approach the official Jellyfin Xbox app takes), with controller focus handled by the existing D-pad navigation. |
| 7 | Roku | High | Roku apps must be BrightScript and SceneGraph, so this is a separate codebase that reuses the design and API contract but not the Flutter code. Built in [`apps/roku`](../apps/roku/README.md) (November 2026); device pass and store account pending, see [its release checklist](../apps/roku/docs/RELEASE.md). |

Added October 27, 2026 at the owner's request: Android phones and tablets,
Xbox and Roku. Their order after Samsung is a starting suggestion, not an owner
decision.

In practice, Fire TV and Google TV ship together from one Android build after LG.

## Store publishing

Official store listings, not sideloading, are the release goal. Self-hosted
media clients do get approved on these stores:

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
