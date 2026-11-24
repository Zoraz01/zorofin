# Native Live TV guide

The 1.2 candidate replaces the Live TV poster catalogue with a schedule. It uses
ordinary viewer-authenticated Jellyfin APIs; no server plugin, directory, EPG
provider account or hardcoded server is required.

## Browsing

- Apple TV and wide iPad windows show channels beside a two-hour timeline with
  half-hour labels, duration-proportional program cells and a current-time line.
  Channel labels and the time header remain visible while changing time windows
  or scrolling channels. TV focus previews the program title, time and synopsis.
- iPhone, narrow iPad windows and accessibility text sizes use a vertical channel
  agenda with the same date/time selection and program details.
- Search matches channel names/numbers. All channels/Favorites uses the active
  viewer's Jellyfin favorites. More channels progressively extends the rendered
  rows; a focusable button remains available alongside automatic continuation.
- Now returns to the current half hour. Previous/Next move by two hours. The date
  menu browses today and the following six days, using device-local dates/times.
  The current-time line and progress refresh every 30 seconds; foreground data
  refreshes every two minutes. Browsing a future time does not jump back on refresh.
- Selecting a program opens details. **Watch live** plays the channel's current
  broadcast through the existing player/capacity preflight. It does not play a
  future program or offer recording, reminders, catch-up or DVR. Missing listings
  remain explicit, and channel details stay usable if the program endpoint fails.
  Capacity information remains in TV channel/program details before playback.

## Data and isolation

`LiveGuide.swift` owns window/slot normalization and the two reads:

- `GET LiveTv/Channels`: 200 channels per page, viewer data and channel-number
  sorting. The screen bounds its index at 4,000 channels and explicitly reports
  a truncated index. Existing catalog/player channel APIs are unchanged.
- `GET LiveTv/Programs`: at most 40 channel IDs per batch, `minEndDate` and
  `maxStartDate` covering the viewport, 200 programs per page. Total counts drive
  paging, including servers returning short pages. Repeated or oversized pages
  and scans exceeding the page bound fail explicitly. An empty page ends the scan.

Only programs with a valid interval and a requested channel identity enter the
schedule. Rows clip at viewport boundaries, de-duplicate/trim overlaps and fill
unknown gaps. They never infer events from a channel name or unrelated scoreboard.
DST transitions use elapsed broadcast time while labels use local wall time.

`LiveGuideState` belongs to the current `AppModel` account generation and resets
with library state on account/server changes. Both async paths guard cancellation
and request identity. Backgrounding cancels reads/refresh timers. Same-window
refreshes retain prior program rows while refreshing; failures are visible.
HTTP 401/403 clear retained data for the denied resource. No persistent guide
cache or private account/media data is added. Preview programs are synthetic and
only available in the explicit demo session.

## Reproduction and acceptance

```sh
swift test --package-path apps/apple/Core --scratch-path "$NVME_BUILD_ROOT/Core" \
  -j 2 --filter 'LiveGuideTests|LivePlayerGuideTests'
python3 apps/apple/tools/generate_project.py
xcodebuild -project apps/apple/Zorofin.xcodeproj -scheme Zorofin-tvOS \
  -configuration Release -destination 'generic/platform=tvOS' \
  -derivedDataPath "$NVME_BUILD_ROOT/tvOS" -jobs 2 build
xcodebuild -project apps/apple/Zorofin.xcodeproj -scheme Zorofin-iOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$NVME_BUILD_ROOT/iOS" -jobs 2 build
```

Use the existing signing team/provisioning setup for device builds. Test layout,
remote/touch focus, row scrolling, search, favorite filtering, date changes,
missing-guide/retry states, and returning from details/playback separately from
build success. Guide browsing only reads metadata and does not reserve a tuner.
Use licensed samples for public screenshots; keep private guide captures out of
Git and store artwork. Current build/device results live in
the 1.2 release record.

API and focus references:
[Jellyfin program reads](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LiveTvApiGetLiveTvProgramsRequest.html),
[Jellyfin channel reads](https://typescript-sdk.jellyfin.org/interfaces/generated-client.LiveTvApiGetLiveTvChannelsRequest.html),
[Apple focus navigation](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/).
