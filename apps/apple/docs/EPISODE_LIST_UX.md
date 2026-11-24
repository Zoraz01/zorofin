# Default vertical episode browsing

October 24, 2026. The selected iOS direction is a vertical episode list by
default, without an overview carousel or an expansion step in the episode
section. The show overview remains above the episode section. This also applies
to episode/season details and the shared iOS in-player episode browser.

## Interaction

- Use compact, borderless episode rows with actual episode artwork, title,
  duration, synopsis and watched/current/progress indicators. Respect the
  existing progress preference. Larger accessibility text stacks the artwork
  and metadata and allows the synopsis to grow.
- The season pill opens a native `Menu` containing the season `Picker` above the
  content. It adds no expanded panel to the page layout and therefore does not
  push episode rows down. The pill uses ultra-thin material; the menu uses the
  system's presentation, including system transparency/accessibility settings.
  See Apple's [Menu documentation](https://developer.apple.com/documentation/swiftui/menu)
  and [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
- Keep the existing episode destinations: outside playback, a row opens episode
  details; inside playback, it selects the episode using the existing callback.
- Reuse `EpisodeBrowserState` for selected-season caching, request cancellation,
  server/account boundaries, page deduplication and retry behavior. The vertical
  stack requests another page when its end becomes visible, with a labeled
  button available as well. No backend, authentication or playback negotiation
  changes are part of this update.
- No tile-size controls. Apple TV retains its horizontal episode browser and
  explicit season focus/Back behavior.

## Validation

- Existing episode-navigation/request-boundary suites: **15 tests passed**,
  including selection restoration, paging, cancellation, wrong-season response
  rejection and retry behavior. No new backend behavior or tests were added.
- Xcode **27.0 (27A266a)**: unsigned Release **0.1.0 (1)** builds passed for
  generic physical **iOS** and **tvOS** destinations. No Swift source warning
  remains from the menu callback. The standard no-AppIntents-dependency
  metadata notice is unrelated to these screens.
- NVMe mount and all four Xcode data symlink targets were verified. Build and
  Swift test output remained on NVMe, with two jobs at a time.
- The mobile-audit helper checked **zero Swift files** and provides no UI
  coverage; it is not counted as validation.
- Native menu appearance, touch behavior, lazy scrolling and automatic page
  loading remain physical-device acceptance checks. No simulator, app launch,
  device installation, server restart or TestFlight upload was performed.

Physical acceptance should cover:

1. Open a show, season and episode: vertical rows appear immediately, with no
   carousel or expansion action required.
2. Open season choices: the menu floats over the rows without shifting them;
   tap outside to dismiss, or choose another season and see its selection check.
3. Scroll beyond the first page of a long season, retry a failed page, and change
   season while a request is pending. No repeated or wrong-season rows appear.
4. Open an episode and go back: preserve the chosen season and existing account.
5. Select an episode from the player's list and confirm the usual playback
   transition/current-episode behavior.
6. Check narrow iPad windows, landscape, large accessibility text, VoiceOver and
   Reduce Transparency. Keep the last episode reachable above the app dock.

The owner's phone first received these changes in signed Release **0.1.0 (6)**
from `f9231f9`, then was updated in place to **0.1.0 (7)** from `00bb71f`, which
also includes gesture-only video zoom. Device-service readback confirmed both
installations. The app was not launched. Physical visual acceptance remains
pending, and these updates have not been uploaded to TestFlight. See the
installation record.
