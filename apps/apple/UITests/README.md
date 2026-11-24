# Physical iPad UI acceptance

`Zorofin-iPad-UI` is a separate, iPad-only XCTest scheme. It uses the shipping
iOS application target in Release and installs a separate UI-test runner; neither
the runner nor the scheme is included by either shipping archive scheme.

Connect an explicitly authorized physical iPad, enable Developer Mode, unlock it,
and approve **Touch ID for XCTest — Enable UI Automation** directly on the device
when prompted. Do not share the passcode or bypass that approval. Device Hub's
iOS 27+ screen-sharing requirement is separate from XCTest authorization.

Verify NVMe is mounted and the four Xcode storage symlinks are intact. Supply
the device identifier and existing signing team privately; do not commit either.
Use a fresh result-bundle path for each attempt:

```sh
xcodebuild test -project apps/apple/Zorofin.xcodeproj -scheme Zorofin-iPad-UI \
  -configuration Release -destination "platform=iOS,id=$IPAD_UDID" \
  -derivedDataPath "$NVME_BUILD_ROOT/iOS" \
  -resultBundlePath "$NVME_RESULT_ROOT/ipad-ui-run.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-device-destinations 1 \
  -collect-test-diagnostics never -jobs 2 \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_ALLOWED=YES
```

The explicit physical destination, iPad-only runner family and `iphoneos`-only
test target prevent using a phone or simulator by accident. Do not substitute
another device without owner authorization. Generic result directories and code
may live in Git; raw device identifiers, provisioning records and diagnostics do not.
Verbose system diagnostics are disabled in the documented command to avoid
unnecessary private device/host data in test artifacts.

The first journey requires empty connection setup and never resets an account.
It checks pre-login privacy/support, then enters the clearly labelled fictional
preview for Home, search, movie details, file info, series episodes and Profile,
returning to connection setup at the end. App-only screenshot attachments are
named `ipad-fictional-*` where applicable. They are **not App Store screenshots**
or evidence of real-server authentication, requests or decoded media playback.

Inspect the result bundle in Xcode for test status and exported attachments.
A build, installed runner or runner-start message does not mean the journey ran.
Current evidence is recorded in VALIDATION.md.
Real demo-server login, full library screenshots and actual playback require a
separate, credential-safe test pass; no password/token is embedded in this suite.

On iPadOS 18, SwiftUI can propagate the navigation container identifier to its
buttons. The harness matches declared navigation labels within the dock and uses
an element-type-independent query for document scroll views. Fictional titles
without media metadata do not expose File details; that action is exercised only
when present, and must be checked separately with a real server.

The first completed physical preview journey passed on October 27 with Release
0.9.0 (21), iPad 7th generation / iPadOS 18.7.9. Ten app screenshots were retained.
Landscape attachment orientation metadata rendered inconsistently in external
viewers; those exports are not listing-ready or sufficient visual-layout
acceptance. Do not infer upright display dimensions from UIImage's `size` alone.
An experimental screen-capture aspect assertion failed and was discarded; the
retained application-screenshot harness matches the passing journey. See the
validation record for remaining real-server and screenshot checks.

Project generation remains reproducible with `python3 apps/apple/tools/generate_project.py`.
Existing app/extension build configurations and equivalent plist bytes are preserved.

## iPhone player layout regression checks

The separate **Zorofin-Player-Tests** scheme runs hosted UIKit/SwiftUI checks from
[`Tests/PlayerLayoutTests.swift`](../Tests/PlayerLayoutTests.swift) in Debug. It
loads the real player with generated video fixtures: the existing three-second
MP4 and a one-minute HLS test pattern. It never signs in or reads library media.
Its runner and fixtures are absent from
the shipping app and extension resource phases. Debug builds enable test access;
Release packaging retains its normal configuration.

After verifying NVMe and the Xcode storage symlinks, supply an isolated simulator
identifier privately. The affected-device matrix is iPhone 15 Pro Max and iPhone
16 Pro. Run each sequentially and use a fresh result path:

```sh
xcodebuild test -project apps/apple/Zorofin.xcodeproj \
  -scheme Zorofin-Player-Tests -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$NVME_BUILD_ROOT" -resultBundlePath "$NVME_RESULT_PATH" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -collect-test-diagnostics never -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO
```

The checks cover repeated portrait/landscape viewport resizing, actual full-screen
scene rotation with larger text, retained decoded player/item and paused position,
return to portrait after dismissal, overlapping leases and moving between windows.
The SwiftUI-cover check additionally exercises the presenting root's GeometryReader,
NavigationStack and bottom inset, comparing both cover and video with the window
through the Pro Max's compact/regular horizontal size-class changes. It also checks
the decoded video rectangle.

`testProductionStartupAndHiddenControlsRetainWindowGeometry` uses the actual
ZorofinShell, dock and navigation, its incoming-playback presentation path, the
player view's metadata/preparation task and PlaybackController. Jellyfin JSON
is synthetic; AVPlayer fetches/decodes real loopback HLS. No group is joined.
Negotiation stays pending for one minute,
with rotation during preparation, then the test checks decoded playback, actual
automatic control hiding, pause/resume, repeated rotation, item/surface retention,
portrait restoration and stopped-session reporting. A read-only observer supplied
through the SwiftUI environment in Debug exposes the actual phase, controls'
visibility and viewport; the test
does not set the controller phase or interaction state. The origin is created
and stopped inside the test. [Fixture provenance and regeneration](../Tests/Fixtures/README.md) are
kept beside the generated assets. Add
`-only-testing:Zorofin-PlayerTests/PlayerLayoutTests/testProductionStartupAndHiddenControlsRetainWindowGeometry`
to the command above for this focused check. Allow roughly 90 seconds after
runner startup. This synthetic flow does not reproduce the affected remote
stream's delivery, server negotiation or physical OS conditions.

Simulator results do not establish physical device, PiP/AirPlay or App Review
acceptance. A tester must retry the affected physical phone before support can
announce that their problem is fixed. Shut down and delete only temporary test
devices created for the run; preserve existing simulators.

### Delayed HLS delivery and first-frame traces

Four additional checks are opt-in: `testDelayedPlaylistFirstFrameRotation`,
`testDelayedInitialSegmentFirstFrameRotation`,
`testDelayedResumeSegmentFirstFrameRotation` and
`testCombinedDelayedResumeFirstFrameRotation`. Without
`ZOROFIN_ROTATION_FIXTURE_ROOT`, these four checks skip. Five ordinary passing
checks plus four skips do not establish delayed-media coverage.

The replay uses the real shell and an Episode presentation, with a synthetic
2160p HEVC/6-channel E-AC-3 source DTO and generated 1080p H.264 High / 23.976 fps,
stereo AAC / 48 kHz HLS. It preserves the difference between source metadata and
delivered video. The full VOD timeline allows a real nonzero resume seek and
nonzero MPEG-TS timestamps. English audio selection and subtitles Off are
verified in the production PlaybackInfo request. No original media bytes,
account identifiers, tokens or server addresses belong in this fixture.

For a report-specific replay, first select matching **offline** item/session
snapshots, a delivered-segment ffprobe JSON and a transcode log containing the
same item ID and its resume `-ss`. Keep these inputs and the recovered profile
private. The extractor exports numeric settings only; an app version string in
server logs does not prove a TestFlight build or current device OS.

```sh
python3 apps/apple/tools/recover_rotation_profile.py \
  --item "$PRIVATE_ITEM_JSON" --sessions "$PRIVATE_SESSIONS_JSON" \
  --delivered-probe "$PRIVATE_DELIVERED_PROBE_JSON" \
  --resume-log "$PRIVATE_RESUME_LOG" --output "$PRIVATE_REPLAY_PROFILE"
python3 apps/apple/tools/generate_rotation_replay.py \
  --output "$NVME_ARTIFACT_ROOT/rotation-replay-fixture" \
  --profile "$PRIVATE_REPLAY_PROFILE" --ffmpeg "$FFMPEG_BIN"
```

FFmpeg must include libx264 and AAC. Generation contains only SMPTE bars and a
tone and takes a few minutes; reuse is automatic when the completed profile
matches. Omitting `--profile` uses a generic 30-minute VOD with a resume at 23
minutes. Large generated media belongs on mounted NVMe, outside Git. The payload
bitrate, source decoding/transcoding workload and remote transport are not
reproduced by this synthetic fixture.

Build the existing Debug test scheme for an isolated simulator, then choose its
generated `Zorofin-Player-Tests_iphonesimulator…-arm64.xctestrun` as
`PLAYER_SOURCE_XCTESTRUN`. Set `PLAYER_REPLAY_XCTESTRUN` to a **fresh sibling**
path; product-relative references require the same parent directory.

```sh
xcodebuild build-for-testing -project apps/apple/Zorofin.xcodeproj \
  -scheme Zorofin-Player-Tests -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$NVME_BUILD_ROOT" -parallel-testing-enabled NO \
  -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
python3 apps/apple/tools/configure_rotation_replay.py \
  --xctestrun "$PLAYER_SOURCE_XCTESTRUN" \
  --fixture-root "$NVME_ARTIFACT_ROOT/rotation-replay-fixture" \
  --output "$PLAYER_REPLAY_XCTESTRUN"
xcodebuild test-without-building -xctestrun "$PLAYER_REPLAY_XCTESTRUN" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -resultBundlePath "$NVME_RESULT_PATH" -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 -collect-test-diagnostics never
```

All nine hosted checks run when this configuration is supplied. Each new case
waits for an actual AVPlayer item and held HTTP request before delaying delivery.
A short negotiation/bootstrap gate lets recording start before media setup and
the cover finish presenting. Each media hold is verified after an AVPlayer item
exists. Individual playlist, initial-segment and resumed-segment cases hold for
eight seconds. The combined case requests six seconds at each of the three
gates. Scheduling, decoding and retries can extend the elapsed time beyond the
production preparation timeout; eighteen seconds of requested holds is not an
eighteen-second startup guarantee. Production timeout, phase and
control-hide values are unchanged. Debug console tags distinguish timed-out,
interrupted and numeric AVFoundation preparation failures.

A retained `rotation-*-geometry` JSON attachment records roughly 60 samples per
second, plus readiness/control events and explicit checkpoints. It includes
window/cover/surface/layer/video rectangles, safe areas, transforms, trait classes,
render readiness, item generation, media time, phase and control visibility.
HTTP events omit queries and distinguish attempted response start from send
completion/failure, including AVFoundation retries. First-frame readiness starts
rotation promptly; the test also rotates during playing and after real controls
hide. The test owns/cancels its sampler, observer, first-frame task, listener and
connections and dismisses through the real account-generation path.

```sh
xcrun xcresulttool export attachments --path "$NVME_RESULT_PATH" \
  --output-path "$NVME_ATTACHMENT_PATH"
python3 apps/apple/tools/summarize_rotation_traces.py "$NVME_ATTACHMENT_PATH" \
  --output "$PRIVATE_TRACE_SUMMARY"
```

Keep raw traces and exact replay timing outside Git. The summary separates
post-transition checkpoints from animation frames: intermediate coordinate
differences alone are not proof of the reported persistent displacement. Stable
checks allow one point of geometry tolerance and 0.01 aspect-ratio tolerance.
The summary reports reached-playing, failed-phase, completed-dismissal and
decoded-checkpoint evidence. Zero geometry issues from an incomplete startup
is not a successful playback/rotation result. It also reports sampling gaps;
a mismatch span across an unsampled gap
does not establish continuous visual displacement throughout that interval.
These are synthetic simulator results; physical retry, exact OS/display settings
and release acceptance remain separate evidence gates.

The November 4 investigation passed all four delayed cases on the iPhone 15 Pro
Max simulator. On iPhone 16 Pro, the three individual delays and five existing
checks passed, while the combined case hit `preparation=timedOut`, failed to
reach playing and also reported a cleanup transition error. This opt-in stress
case remains a failing diagnostic on that run; do not weaken its assertions or
count an undecoded post-timeout rectangle as clipping coverage. Preserve failed
result bundles as well as successful ones. See
the evidence and limits.

## Real sample-library portrait capture

`testDemoLibraryPortraitCapture` is opt-in. Build for testing, then copy the
generated `.xctestrun` beside the original (so product-relative paths still work).
Set that target's `EnvironmentVariables.ZOROFIN_CAPTURE_SERVER` to the selected
HTTPS sample origin in the private copy. Set `OnlyTestIdentifiers` and use
`-only-testing:Zorofin-iPadUITests/IPadAcceptanceTests/testDemoLibraryPortraitCapture`
with `test-without-building`, the authorized physical device, a new result path,
and `-collect-test-diagnostics never`. No password/token belongs in that config.

Start from empty connection setup. The test enters the operator-supplied origin,
opens Quick Connect and waits for approval, then captures four portrait screens
(Home, Movies, Sintel details and Search). It never captures the approval screen
as a listing asset. Preserve existing signed-in accounts; the test skips them.

The operator can approve from an existing viewer sign-in. For credential-safe
host approval, Device Hub's Controls → Screenshot can export the challenge even
when that device's OS does not support remote screen sharing. Compile
`UITests/read_quick_connect.swift` on macOS with Vision; supply that temporary
image and a private mode-600 output code-file path. It prints no code. Then run
`demo-server/approve_capture.py --env /private/path/demo.env --server https://sample-origin
--code-file /private/path/code.json`. It verifies the isolated demo's identity and
runtime and uses only its restricted viewer for approval; no token is persisted.
Remove the temporary challenge image afterward, retaining no approval image in
the public capture set. Do not publish raw XCTest recordings or failure bundles.

The helper's `--temporary-session-slot` additionally requires explicit owner
approval at execution time. It uses the local demo administrator to change only
the viewer's MaxActiveSessions from three to four, verifies it, approves as the
viewer, logs out the helper and restores/readbacks three in `finally`. A private
`capture-session-slot.json` checkpoint is retained if restoration is interrupted.
Inspect and restore that exact demo field before proceeding; never change a
production policy, end another device session or raise limits permanently to
work around a capture failure. The owner approved and the helper completed this
temporary adjustment on October 27; approval is not a standing grant for future
security-setting changes.

The owner subsequently approved a permanent demo-viewer limit of ten. That is
now the setup default. The historical three-to-four helper intentionally refuses
this new limit; normal capture approval needs no temporary slot adjustment.

`testFinishDemoCapture` is separately opt-in. In its private test configuration,
set ZOROFIN_CAPTURE_CLEANUP=1, ZOROFIN_CAPTURE_SERVER_NAME and
ZOROFIN_CAPTURE_VIEWER. It verifies both visible Profile identities before
signing out only this iPad and checking the signed-out saved-server chooser,
freeing a reviewer session
slot. It skips without explicit identity inputs; other devices are untouched.
