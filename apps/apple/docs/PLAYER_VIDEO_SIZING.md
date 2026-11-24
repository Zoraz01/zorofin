# Video Fit/Fill and pinch zoom

October 24, 2026. The custom player previously forced `resizeAspect` and exposed
no zoom gesture or sizing control. A 16:9 file containing cinematic letterboxing
can therefore show black bars above/below its picture and extra side borders on
a phone whose landscape display is wider than 16:9.

## Diagnosis

The running server identified itself through `/System/Info/Public` as
**Jellyfin 12.2.0**. The reported movie's video stream is **3840×2160**, 16:9,
HEVC/HDR10. Three short, single-threaded read-only frame checks at different
positions found consistent letterboxing: a downscaled 640×360 frame contained
approximately **640×268** active picture, with a 46-pixel border above and below.
This accounts for the four-sided borders visible in the user's phone screenshot
when the full encoded frame is fitted to the screen.

The diagnostic frame checks are temporary, not a running detector. No media was
rewritten, server setting changed, service restarted or playback request issued.
Private paths, movie identifiers and diagnostic artifacts are excluded from Git.

## Implementation

- Default to **Fit** for each player session, preserving the complete encoded
  frame. On iPhone/iPad, Fit respects the system safe area so Dynamic Island,
  notches and the home indicator do not obscure the picture. **Fill** expands
  the video surface to the physical screen edges and uses `resizeAspectFill` to
  enlarge proportionally. This explicitly opts into picture extending around
  the camera cutout, like the requested zoomed/full-screen behavior. Fill can
  crop picture edges and does not guarantee removal of every encoded black
  border. Use current system insets, never a hardcoded cutout width or position.
- Sizing on iPhone/iPad uses a gesture, with **no visible zoom button**. A
  VoiceOver custom action on the existing Playback info control provides the
  equivalent sizing action without adding another control. Apple TV retains
  its existing remote controls without a new zoom button.
- On iPhone/iPad, an outward pinch selects Fill; an inward pinch restores Fit.
  Apply once at the end of a successful gesture. Small movements and invalid
  values preserve the current mode; repeated outward pinches cannot toggle back.
- Locking controls, an open panel, active scrubbing or a closed player prevent
  sizing changes. Changing size reveals controls but preserves playing/paused
  intent, stream selection and position.
- Keep the chosen sizing if the current title's stream is replaced for an audio,
  quality or seek change. A different title/channel starts in Fit, preventing an
  earlier Fill choice from unexpectedly cropping the next video.
- Pass sizing to the existing `AVPlayerLayer` in both view creation and updates.
  Keep the existing player and PiP connection. Change the video view's ignored
  safe-area edges in place, without branching/recreating the renderer. The video
  fills its selected area and clips to its own bounds; the overlay retains
  safe-area controls in both modes. Apple TV video remains full-screen in both
  modes without adding overscan padding. No custom HDR conversion or continuous
  frame processing is added.
- Update the offline player preview to use the same sizing intent and controls.

Apple defines [aspect fit and aspect fill](https://developer.apple.com/documentation/avfoundation/avlayervideogravity)
and notes that [Fill can crop the image](https://developer.apple.com/documentation/avfoundation/avlayervideogravity/resizeaspectfill).
The pinch uses the standard [SwiftUI gesture callbacks](https://developer.apple.com/documentation/swiftui/adding-interactivity-with-gestures).
The iPhone display boundary uses [system safe-area edges](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)),
independently of the controls' safe areas.

The subsequent [player gesture update](PLAYER_GESTURES.md) adds swipe-down
dismissal and directional/double-tap skips, with one-finger pan limits and
interaction guards to preserve pinch and timeline input.

## Acceptance

- Player interaction/timeline/back/scrub suites: **46 tests passed**, including
  three new zoom cases covering presentation-only state changes, repeated or
  invalid pinches, and lock/panel/scrub/closed-state guards.
- Xcode **27.0 (27A266a)**, generic physical destinations: unsigned Release
  **0.1.0 (1)** iOS and tvOS builds and the iOS Debug preview build **passed**,
  including the same-title stream-replacement sizing refinement. No Swift source
  warnings remain; only the standard no-AppIntents-dependency metadata notice
  was emitted.
- The camera-safe Fit / full-display Fill and gesture-only refinement repeated
  all three compile checks successfully. It changes native presentation only;
  the existing 46-test player model result above remains the relevant automated
  state-machine evidence. Physical cutout/gesture behavior is still unverified.
- NVMe was mounted and all four Xcode data-directory symlink targets verified
  before builds. Output stayed on NVMe with two jobs per build.
- The running **12.2.0** server supplied read-only metadata only; no AVPlayer or
  device-playback compatibility claim follows from it. Physical pinch
  recognition, video bounds, track/quality replacement, HDR/PiP and accessibility
  remain device acceptance checks. No simulator was used.

Use openly licensed samples and verify:

1. Pinch outward/inward with controls both visible and hidden. Fit restores the
   complete picture, and each gesture changes size only once.
2. Confirm no zoom button was added to the header or footer. Use the VoiceOver
   custom action on Playback info without pinching. TV remote navigation retains
   its original controls.
3. Rotate/resize while playing and paused, including wide, 16:9, 4:3 and portrait
   sources and a letterboxed 16:9 source. Video stays within the screen; controls
   stay reachable and Full Picture/Fit remains available.
   On a Dynamic Island/notched phone, Fit keeps the picture inside the safe area;
   Fill extends to the screen edges around the island. Repeat after rotating so
   the cutout changes sides. The toolbar/transport remain clear in both modes.
4. Confirm time, pause state, selected tracks, HDR, PiP and Live TV behavior are
   retained when changing sizing. Zoom must not renegotiate a stream.
5. Verify pinch cannot steal an active scrub, resize behind a panel or bypass
   locked controls; reopening a new player starts in Fit.

After the owner's installation request, signed Release **0.1.0 (7)** from source
commit `00bb71f` was installed over build 6 on the paired iPhone 16 Pro. Strict
code-signature verification and device-service version readback passed. The app
was not launched; physical gesture/cutout/playback acceptance remains pending.
See the installation record. No TestFlight
upload was performed.
