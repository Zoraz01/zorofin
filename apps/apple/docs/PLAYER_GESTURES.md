# iPhone and iPad player gestures

October 24, 2026. These gestures apply to the video background, below the
existing player controls. Apple TV keeps its existing remote input behavior.

| Gesture | Result |
| --- | --- |
| Single tap | Show/hide playback controls. |
| Swipe down | Close the player after a deliberate downward swipe finishes. |
| Swipe left/right | Skip backward/forward once using the viewer's configured amounts. |
| Double-tap left/right side | The same backward/forward skip, with brief on-screen feedback. |
| Double-tap center | Show/hide controls without seeking. |
| Pinch outward/inward | Full-display Fill / camera-safe Fit, as documented in [video sizing](PLAYER_VIDEO_SIZING.md). |

Horizontal swipes perform one skip when released; they do not continuously seek
while a finger moves. The timeline keeps its existing continuous scrub behavior.
Skip commands reuse the player's existing seek boundaries, pending-seek handling
and playing/paused intent. A Live TV stream without a seekable/DVR range does not
receive gesture seek commands. Swipe-down dismissal still remains available.

## Input safeguards

- A small amount of movement, ambiguous diagonals and upward movement do nothing.
  Swipes that start near the view's screen edges are rejected to leave room for
  system gestures. Thresholds adapt to the current view size, not a device model.
- Only one-finger pans can produce swipe actions. A second touch cancels the pan;
  pinch recognition on the ancestor remains available. No swipe is committed
  from a canceled recognizer or during intermediate movement.
- Single-tap recognition waits for double-tap and pan recognition to fail. The
  recognizer dependencies avoid showing/hiding controls twice during a skip.
  See Apple's [gesture failure relationships](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require(tofail:))
  and [pan recognizers](https://developer.apple.com/documentation/uikit/uipangesturerecognizer).
- The gesture surface sits behind buttons and the timeline. Open panels, active
  scrubbing, locked controls, pressed controls and a closed player block surface
  actions. Callback guards read the current interaction state before dispatch.
- VoiceOver disables these touch recognizers and the pinch recognizer so its
  navigation gestures remain available. Existing close/skip buttons and the
  sizing action on Playback info remain accessible.
- Skip feedback is noninteractive and clears after 800 ms, respecting Reduce
  Motion. Repeated skips replace the feedback timer; leaving the view cancels it.
- Removing the native gesture view disables/detaches recognizers and clears its
  callbacks. No gesture observers or temporary services outlive the player.

## Validation

- **51 tests passed** in the player gesture, interaction, timeline, Back and
  pending-seek suites. Five new cases cover directional intents, accidental
  movement, system-edge/invalid inputs, double-tap zones and blocked interaction.
- Xcode **27.0 (27A266a)**, unsigned **0.1.0 (1)**: generic physical iOS Release,
  tvOS Release and iOS Debug preview builds passed. No Swift source warnings.
- NVMe mount and the four Xcode data-directory symlink targets were checked;
  builds/tests used NVMe output with two jobs at a time. No simulator or server
  restart was performed. These checks do not prove physical touch arbitration.

Physical acceptance should verify:

1. Downward swipes dismiss once; short/diagonal/upward or screen-edge movements
   do not dismiss or skip accidentally.
2. Swipes and side double-taps seek in the expected direction, obey settings and
   bounds, preserve pause state and accumulate correctly during rapid repeats.
3. Center double-taps affect controls once. Existing back, transport, footer,
   AirPlay, PiP and timeline controls remain reachable and responsive.
4. Pinches work with controls visible and hidden. Adding a second finger after
   beginning a pan must not close or seek when the pinch ends.
5. Locked controls, panels, timeline scrubbing and VoiceOver prevent conflicting
   background input. Verify Live TV with and without DVR separately.
6. Rotate/resize and repeat on iPhone and iPad, including camera-cutout Fit/Fill.

Signed Release **0.1.0 (8)** from `c5ecd1c` was installed over Wi-Fi on the
owner's iPhone 16 Pro after wireless pairing was completed again. Strict
code-signature verification and installed-version readback passed. The app was
not launched; device touch validation remains pending. Earlier connection
failures and the successful installation are recorded in the
installation record.
