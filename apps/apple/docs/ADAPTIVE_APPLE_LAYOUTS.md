# iPad and iPhone Duo preparation

Implemented October 23, 2026. iPhone/iPad share the existing native app and bundle
identity; no separate account system or device-specific fork is added.

## Implementation

- iPhone browsing is portrait-only (October 28 release fix). The app delegate
  permits portrait and either landscape orientation only while a real player
  is attached to that phone window. Closing/dismantling the player restores
  portrait using UIKit's supported-orientation and scene-geometry APIs. The
  player's audio/subtitle/episode overlays keep the playback policy. iPad
  rotation and window resizing remain enabled. Keep the plist's landscape
  declarations: the delegate narrows them at runtime; removing them would also
  disable landscape playback.
- Read live SwiftUI scene geometry, not `UIScreen.main`, device model or physical
  orientation. The root view remains stable while the window changes size.
- `AdaptiveWindow` uses tablet bottom navigation at widths of at least 700 points
  and heights of at least 560. This follows the current Netflix tablet pattern:
  content shortcuts at the top, bottom navigation, a cinematic hero and larger
  poster rows. Narrow windows retain the phone dock. No left rail consumes
  browsing space. Category shortcuts share the header when they fit.
- Wide content uses the full available width. Keep the
  current destination, detail navigation path, query, account and player session
  rather than resetting them when geometry changes. Layout changes do not send
  requests, start a new player or increment account generation.
- Title details use the measured local container width for side-by-side artwork,
  metadata, actions and synopsis. Narrow views and accessibility text stack;
  episode/live art remains a landscape banner. Do not force a 520-point image into
  a smaller sheet merely because the parent scene is “regular.”
- Account-menu width is bounded by available space. Existing player panels use
  their own geometry for narrow/landscape layouts and retain safe-area controls.
- Navigation targets remain at least 48 points. Tablet dock labels stack at
  accessibility text sizes; hero content flows below the image rather than being
  clipped by a fixed-height banner. Policy text supports selection on iOS
  and paragraph focus/scrolling on Apple TV.

## Current Apple guidance and tooling boundary

Apple's [Duo preparation guide](https://developer.apple.com/iphone-duo/prepare/)
calls for dynamic resizing, current view/window geometry, safe areas and avoiding
idiom/orientation assumptions. It describes fuller edge-to-edge support and
vertical system bars with the iOS 27.1 SDK. The [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout)
also requires handling resizable iPad windows.

This host currently has **Xcode 27.0 (27A266a)** and the 27.0 SDK. No Xcode upgrade,
runtime download, simulator or physical-device test was performed for this work.
The source prepares responsive layouts but is **not a validated “Duo optimized”
release**. Next: build with Xcode 27.1, use its exported app-resizability skill
(`xcrun agent skills export`) if available, and validate system-bar/safe-area
behavior, not just rectangular width changes. Do not invent a hinge API or
hardcode a Duo model's dimensions. Tabletop/hinge-specific player controls are
not implemented or advertised by this pass.

## Deferred acceptance matrix

Use the licensed demo; keep the personal server and active playback unaffected.
No simulator is authorized by this document; use a suitable physical device or
obtain approval before resuming simulator use.

| Scenario | Expected behavior / remaining evidence |
| --- | --- |
| iPad portrait and landscape | Cinematic hero, wide details and bottom navigation; artwork/controls visible, no phone-width centered strip. |
| Half/third/quarter/narrow iPad window | Responsive dock and single-column detail; scroll and keyboard do not cover actions or request pagination. |
| Window resize with title/search open | Same route, selected season, query, account and scroll context; no unexpected server reload. |
| Duo outer → inner → outer; rotations/poses | Appropriate tablet/phone dock, camera/status-bar clearance and continuous navigation, pending 27.1 build. |
| Playback during resize/fold | Same AVPlayer session/position/paused intent; no duplicate session reports or unowned stream cleanup. |
| Largest Dynamic Type + VoiceOver | All actions reachable and labeled; no clipped consent, account or policy content. |
| Keyboard and pointer | Navigation and dismiss actions accessible; no hover-only or gesture-only action. |
| Plain independent Jellyfin | No Requests/Support setup necessary; normal sign-in, search, artwork and playback remain usable. |

Unit checks cover phone/tablet/shallow-window decisions, full-width tablet content and bounded artwork sizing
and invalid geometry. Compile results are recorded separately in release notes;
they do not establish the device scenarios above.

Current Netflix reference: [mobile and tablet layout](https://help.netflix.com/en/node/575087423404644). Zorofin retains its own jade palette, fonts and app-specific destinations. No Netflix artwork, logos or Clips feature is bundled.
