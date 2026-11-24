# Custom Zorofin player

Current status — November 3, 2026, candidate **1.2 (43)**: Apple TV keeps
AVPlayerViewController transport, title, remote gestures and routing/PiP. The
owner requested tighter panel spacing, a season dropdown and useful initial
focus. iPhone/iPad retain their player layout.

- On-demand playback has separate Audio & subtitles, Quality and Playback info
  transport buttons, alongside Episodes when applicable. Live TV omits the
  app's track-selection action and keeps channels, applicable Go live, quality
  and information. Playback speed is hidden for both modes (`speeds = []`).
- Apple's audio-adjustments control remains available for Enhance Dialogue and
  Reduce Loud Sounds. The public SDK does not provide an independent switch to
  hide its audio button while retaining native transport/enhancements.
- `allowedSubtitleOptionLanguages = []` filters native subtitle language choices
  and Auto. `requiresFullSubtitles` stays false to preserve Off and avoid forcing
  captions. The complete Jellyfin selector still owns all server tracks and Off,
  including stream re-negotiation. Confirm actual native subtitle-icon visibility
  on the device; filtering is not proof that AVKit removes its system button.
- Panels reserve space above the native transport using AVKit's public
  `unobscuredContentGuide` with an 8-point gap and no screen-height minimum.
  Retain the latest visible measurement while controls hide. Episodes span
  the available width within the TV edge margins, with bounded height. Other
  panels remain compact; staged changes, reporting and tuner cleanup are retained.

The owner's build-23 photos confirmed that `playbackControlsIncludeInfoViews =
false` removed neither native track button. Earlier statements that those buttons
were removed are superseded by that observation. The setting remains useful for
the bottom Info view, with `infoViewActions = []`; it is not a track-button API.

Build 43 removes the expanding maximum-height wrapper, sizes the scrolling body
to its contents, and removes redundant track headings. A scoped, one-time focus
request selects the current option or a useful fallback once content loads.
Seasons use a native dropdown. No new gestures or forced visibility are added to
AVKit transport. See the 1.2 release handoff for current
build/device evidence. Dated notes below preserve earlier decisions.

Official API references:
[transport menus](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/transportbarcustommenuitems),
[subtitle filtering](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/allowedsubtitleoptionlanguages),
[subtitle Off behavior](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/requiresfullsubtitles),
[unobscured layout](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/unobscuredcontentguide).

October 22, 2026 approval: the owner reports validating the custom player
and explicitly approves it for Release. Release now always selects the shared
custom player on iOS and tvOS, for on-demand titles and Live TV. Debug retains the
saved comparison switch and launch argument. This approval resolves the player
selection decision; it does not certify every device scenario or TestFlight
acceptance. Build evidence is recorded in VALIDATION.md.

The foundation and dated implementation notes below preserve earlier decisions;
the former Release AVKit gate is superseded by this approval.

## Apple TV player edge padding — fixed (2026-10-18)

- [x] Reduce excessive inset around the player controls (`37746eb`). The tvOS
  control geometry previously inherited the system safe area and then added its
  own padding. It now uses the full container with one explicit 48-point
  horizontal / 32-point vertical control margin.
- The video layer already fills the container and retains aspect-fit rendering.
  No cropping, stretching or iOS safe-area change was introduced. Real episode
  playback on the physical Apple TV showed the narrower control margins, intact
  letterboxing and visible subtitles, with controls visible and hidden.
- Remaining visual acceptance: a separate real 16:9 title and the user's viewing
  distance/TV overscan preferences. The offline preview is not video-aspect proof.

## Apple TV center-button pause — fixed (2026-10-18)

- [x] One center/Select press pauses active playback while controls are hidden
  (`37746eb`). The previous hidden surface only had a gesture that revealed
  controls. A transparent, focusable tvOS button now issues an explicit pause and
  reveals the transport. Repeated stale callbacks cannot toggle playback twice.
- Select resumes from the focused Play button. Visible controls, panels, locked
  controls and draft seeking retain their own Select behavior. Phone tap-to-reveal
  behavior is unchanged.
- Physical Apple TV validation used Device Hub's remote buttons: one hidden Select
  paused a real episode and Jellyfin reported the paused position; Select resumed,
  the dedicated Play/Pause key paused, Back canceled a draft seek, and the Quality
  button remained reachable and opened its panel. Back then closed playback.
- Offline Live TV controls on the same physical TV passed hidden Select pause and
  Select resume. Actual Live TV was deferred because another viewer was using a
  tuner. A hand-held Siri Remote and real Live TV remain explicit acceptance checks.
- See VALIDATION.md
  for build, server, automated-test and device evidence.

## Product decision

Own the player interface. Keep AVFoundation for decoding and output; retain the
existing Jellyfin negotiation, account boundaries and ordered session reporting.
The intended experience is cinematic and restrained: the video dominates, controls
appear when wanted, and Zorofin's jade is reserved for progress and selection.
Netflix informs hierarchy and restraint; Zorofin uses its own assets and layout.

Phone, iPad and Apple TV share terminology and capabilities. Layout and input differ.
The current web player remains a functionality reference and stays untouched.

## Evidence and desktop inventory

Inspected the installed Jellyfin web playback markup and implementation, plus the
repository's theme and mobile performance overrides. These are source observations,
not a fresh authenticated rendering/playback test. A control in the bundle does not
prove it is available for every title, viewer or playback method.

| Existing desktop behavior | Intended custom UI | Native implementation gate |
| --- | --- | --- |
| Play/pause, rewind/forward, elapsed/remaining | Three clear transport controls, thin timeline | Ready/paused/buffering states; configured skip intervals |
| Timeline and trickplay thumbnails | Wide invisible hit area; timestamp/thumbnail above thumb | Never seek on every drag update; bounded thumbnail cache |
| Audio and subtitles | One Sound & subtitles panel, languages first, technical detail second | Select supported AV media options or renegotiate at the current absolute position |
| Subtitle timing adjustment | Inside subtitles, only where supported | Native text pipeline; burned-in tracks cannot be shifted locally |
| Chapters and previous/next | Chapters panel; next episode contextual to series | Real chapter metadata and eligible episode verification |
| Quality | Dedicated icon; show actual playback method/format separately | 40 Mbps default is a ceiling, not a guarantee of 4K/HDR |
| Playback speed | No speed control in the player | Saved viewer playback preference remains separate |
| AirPlay and PiP | Route and PiP actions in top trailing area | AVRoutePickerView; explicit AVPictureInPictureController lifecycle |
| Fullscreen, volume/mute, keyboard shortcuts | Orientation/fit on phone; system volume; keyboard support on iPad | No arbitrary orientation lock or system-volume replacement |
| Playback information/stats | Secondary diagnostics, outside normal control layout | No tokens, private hostnames or sensitive stream URLs |
| Live programme, channel actions, recording | Live badge and Go live only with a valid DVR window | Programme metadata and server/viewer permissions; no invented seek range |
| Queue/previous/next track | Episode browser now; deliberate queue UI later | Stop old session before starting the replacement |
| Segment skip | Small Skip intro/recap action when verified | Not found in inspected core video bundle; separate server/plugin capability work |

The current native codec profile is intentionally conservative (H.264/AAC SDR).
Custom controls do not change codec support. HEVC, HDR/Dolby Vision, multichannel
passthrough and subtitle fidelity require their own media/device qualification.

## Visual and interaction contract

- Full-bleed video on black; no global app header, tabs, wordmark or permanent card.
- White primary icons/text. Jade timeline/selected state. Gentle top/bottom black
  gradients provide contrast over bright scenes. No large frosted control capsule.
- Top: a slim Back chevron, concise title/episode context, contextual Episodes or
  Channels icon, then available route/PiP actions.
- Center on all devices: back 10, play/pause, forward 30 by default (respect saved
  intervals). Play/pause gets the strongest visual weight, not a huge green pill.
- Bottom: an inline elapsed time / scrubber / remaining time strip, followed by
  exactly three icon-only actions: Quality, Subtitles (with audio choices inside),
  and Playback info. No More or speed control. In narrow windows the three icons
  stay together on a second line; their targets remain at least 44 points.
- Back has a 20-point regular-weight chevron inside a rectangular 44-point tap
  target on iOS. A touch in progress suspends auto-hide. Close immediately pauses
  playback, cancels pending seeks/replacements/auto-next and clears the parent's
  full-screen presentation binding; server reporting/cleanup runs afterward.
  Late panel callbacks cannot restart a dismissed player.
- Portrait preserves the video's aspect ratio, with header/footer in the available
  black letterbox space and transport over the video. Landscape puts controls over gradients; iPad preserves
  safe-area insets and split-window sizing. Fit is default; Fill is explicit.
- TV uses the same centered transport and inline footer, with larger remote targets.
  Menu/Back closes a panel, cancels a draft seek, or unlocks controls first. During
  active playback it then hides controls and exits on the next press. Paused,
  preparing, failed and VoiceOver states can exit directly. Play/Pause
  remote key works even when controls are hidden. Center/Select pauses and reveals
  hidden controls; directional input reveals them without pausing. Once visible,
  Select activates the focused control. Scrubbing commits on Select and
  cancels on Back; left/right focus movement must not accidentally seek.
- Controls fade after four seconds only during active playback. Pause, scrubbing,
  panels, pressed buttons, errors, buffering and VoiceOver keep required actions available. Motion
  is opacity-only and respects Reduce Motion. No hide timer survives dismissal.
- Tap reveals/hides controls; double-tap seek is an optional later shortcut with
  a visible alternative. No brightness/volume swipe hijacking in the first release.
- A screen lock suppresses accidental touch actions but retains a visible Unlock
  action. It is app control locking, not a device/orientation lock.
- All actions have 48-point minimum phone targets and meaningful accessibility
  labels. Timeline supports VoiceOver adjustment, keyboard and remote alternatives.
  Long titles wrap/truncate without moving controls; large text reflows secondary UI.

## State and timeline architecture

`PlayerInteraction` is a deterministic value type for visibility, panels, locking
and scrub intent. `PlayerTimeline` handles finite values, seekable gaps, live DVR
windows and mapping between item time and absolute media time. Neither owns a
network client, server token or AVPlayer. Tests inject time instead of sleeping.

The AVFoundation adapter owns observers and a normalized presentation snapshot.
SwiftUI owns layout and emits intents. Existing PlaybackController and
PlaybackReporter remain responsible for negotiation, stream ownership and reports.
The renderer is replaceable: AVPlayerLayer for custom controls; the current AVKit
surface remains the production fallback until feature and device acceptance.

A transcode resumed at 1,200 seconds can have a local HLS time of zero. Display and
report the absolute 1,200-second position. Seeking within known ranges maps back
to local time. Seeking earlier than the transcode window needs renegotiation;
never silently clamp a full-film scrub to the start of the current HLS playlist.
Discontinuous seekable ranges are respected, and live duration is never fabricated.

VOD panel opening remembers whether playback was intended, pauses while browsing
and restores that intent on cancellation. Live panels keep the broadcast moving;
paused intent is still preserved when a panel is dismissed. Selecting an episode or changing a stream
cancels pending seeks, stops/reports the old session, verifies account/generation,
and only then prepares a replacement. An error must never trigger a retry loop.

## One-hour foundation scope

1. Capture desktop parity, visual hierarchy, input flows and platform constraints.
2. Build portable timeline and interaction foundations with behavioral tests.
3. Add a development-only custom control surface and fictional design preview.
4. Wire basic transport and existing Episodes to an explicit experimental launch
   flag; keep normal launches on the current player while missing parity is closed.
5. Produce an interactive design comparison and validate its small-screen layout.
6. Compile iPhone/tvOS, check service health and commit/push scoped changes.

No server/plugin changes, codec claims, automatic viewer-history writes, production
player switch or store release are part of this foundation. The experimental path
must never masquerade as a finished custom player.

## Delivery slices and acceptance

| Slice | Deliverable | Required evidence before enabling by default |
| --- | --- | --- |
| Foundation | Design, reducer, timeline, custom controls, opt-in pilot | Unit tests, both platform builds, visual review |
| Media controls | Tracks, quality, chapters, real trickplay, recoverable restart | Direct-play and resumed HLS, burn-in/text subtitles, rapid switching |
| System integration | PiP restoration, AirPlay, Now Playing/remote commands, interruptions | Physical iPhone/iPad and route transitions; background policy |
| TV interaction | Focus map, remote scrubbing, contextual actions and overlays | Siri Remote + iPhone Remote; Back hierarchy; no focus traps |
| Release polish | Gestures, lock, captions avoidance, accessibility, performance | Bright/dark video, small phone, landscape, large text, VoiceOver, soak test |

Test media matrix: short episode, long film, resumed HLS with nonzero offset,
multiple audio tracks, forced subtitles, ASS/PGS burn-in, missing captions,
chapters/no chapters, live without DVR, live with moving DVR window, no network,
server rejection, expired account, unavailable next episode and rapid close/reopen.

Performance targets to measure, not claims: no network work from dragging the
thumb; at most two presentation updates per second outside active scrubbing;
no periodic UI work after close; no video-frame decoding for thumbnail previews;
bounded, account-scoped trickplay cache; responsive 60 Hz controls; no sustained
memory growth across ten episode/track switches. Record device/OS/build and sample
sizes for every measured result. Keep Docker running during development.

## Design checkpoint

Platform: iOS/iPadOS and tvOS. Framework: existing SwiftUI + AVFoundation/AVKit.
Read mobile design thinking, iOS, touch psychology, performance, backend, testing
and debugging guidance. Apply large invisible hit areas, explicit lifecycle state,
and bounded caching. Avoid stock control chrome as the final aesthetic, hidden-only
gestures, speculative controls and whole-screen redraws for every video frame.

## Primary references checked

- [Apple: custom-player Picture in Picture](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)
- [Apple: customizing the tvOS playback experience](https://developer.apple.com/documentation/avkit/customizing-the-tvos-playback-experience)
- [Apple: AVPlayerLayer](https://developer.apple.com/documentation/avfoundation/avplayerlayer)
- [Apple: AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview)
- [Apple: controlling player transport](https://developer.apple.com/documentation/avfoundation/controlling-the-transport-behavior-of-a-player)
- [Apple: seekable time ranges](https://developer.apple.com/documentation/avfoundation/avplayeritem/seekabletimeranges)
- [Apple: monitoring playback progress](https://developer.apple.com/documentation/avfoundation/monitoring-playback-progress-in-your-app)

Apple documents that seekable ranges may be discontinuous and observers must be
removed. Custom PiP requires its own retained controller, availability observation
and restore delegate. Changing `showsPlaybackControls` while AVPlayerViewController
is onscreen is discouraged; the pilot chooses its rendering surface at creation.

## Implemented foundation

The candidate uses `AVPlayerLayer` and custom SwiftUI transport, timeline and
flat choice panels. Play/pause, configured skip intervals, elapsed/remaining,
commit-on-release touch seeking, Select/Back remote seek intent,
VoiceOver adjustment/persistent controls, playback information, Episodes, audio/subtitle choices
and a 2–40 Mbps quality ceiling are wired. Track choices use the negotiated media
source. VOD track/quality changes preserve absolute position, other selected options,
and the previous playing/paused intent through ordered session replacement. Live
changes retain the selected options and intent, but reconnect with zero start ticks.
Same-title track/quality/seek restarts retain the catalog cache. Episode changes
invalidate the captured prior account's metadata; player exit refreshes watch state.
A late replacement cannot start after the player disappears.

A pending-seek request carries its own ID, target and resume intent. Repeated
skip taps build from the pending target; completion of an older seek cannot clear
newer state. Opening a panel, leaving the app, or explicitly toggling playback
cancels pending seeks. Failed playback offers an explicit retry; completed VOD
can be replayed. There is no unbounded automatic retry.

AirPlay uses the platform route picker. PiP has an owned controller, availability
observation, restoration callback and stale-callback guards. These adapters compile;
they are not yet physical-device acceptance evidence. Now Playing/remote command
ownership and audio-route/interruption recovery still need implementation and tests.
The custom player also supports Live TV and is now the Release default.

The custom path is selected with `--custom-player` or **Profile → Storage & app →
Use the custom player** in Debug builds. The switch now defaults on for device
validation; an explicitly saved off selection is preserved in Debug only. Release
always uses the custom surface. Separate offline fixtures are available in Debug:
**Preview player design** and **Preview Live TV player**. The `--player-preview`
argument also opens the VOD fixture; `--live-player-preview` opens the live fixture.
Each creates its own demo model and dismisses
without altering the real account. These previews demonstrate UI/state, not decoding.

Implementation files remain in the existing `NativePlayer.swift` compilation unit
so local Xcode project/signing edits are preserved. A future maintenance pass can
extract rendering, controls, system adapters and session orchestration into dedicated
files and explicitly register them in the project. Portable behavior already lives
separately in ZorofinCore. This refactor is not part of the approved Release switch.

## Review directions and scope

[Player study source](design/player-study.html) contains two interactive directions:
**Cinematic**, with centered transport, and **Quiet controls**, with transport
lower left. Cinematic is the current native candidate. Both use the same restrained
color, thin timeline and secondary panels. The HTML study includes fictional
chapters and demonstrates route/PiP placement; those are design demonstrations,
not claims that every native feature is implemented. Native previews use the
actual SwiftUI controls but fictional media.

The study is a visualization fragment intended for the conversation renderer.
For a standalone local review, render it with the visualize plugin's `render.py`;
then run `PLAYWRIGHT_MODULE=<installed module> node tools/check_player_study.cjs
<rendered-html>`. Set `PLAYER_SCREENSHOTS` to an existing output directory to
capture images. The checker closes its browser in `finally` and creates no server.
It checks both variants at 320, 390, 736 and 1,024 CSS pixels, including overlap,
episode/season selection, subtitle and quality choices, pause intent and locking.
Those browser checks are not native SwiftUI visual acceptance.

## Decisions still requiring evidence

| Decision | Current choice | Evidence needed before broadening |
| --- | --- | --- |
| Media engine | AVFoundation, conservative server profile | Real device/codec matrix before considering another decoder |
| Stream selection | Renegotiate validated tracks at absolute position | Direct play, forced/CC subtitles, burn-in, missing tracks, multiple sources |
| Seek preview | Timestamp only in native pilot | Server-provided trickplay metadata, authenticated account-scoped cache and request cancellation |
| Intro/credits skip | Hidden until supported | Verified segment data, exact bounds, resume/report behavior; no heuristic fake skip |
| Subtitles | Existing server-encoded path | Native text renderer and subtitle styling/timing before exposing local controls |
| Episodes | Existing season browser paused over player | Current/watched state, unavailable episodes, prior pause intent and next-episode playback |
| Next episode | Existing verified next-episode flow | Redesign contextual end card, cancel/pause/background race testing |
| Fit/fill | Fit only in native pilot | Crop/rotation/safe-area checks, including captions and PiP transitions |
| TV controls | Shared centered transport and inline footer | Physical remote focus map, Select/Back cancellation and hidden-controls reveal |
| Playback diagnostics | Not on the everyday surface | Sanitized method/codec/buffering view with no private URLs or tokens |

## Release acceptance script

Record device model, OS, build commit, source media format, playback method and
observed result. Use a test viewer with explicit viewing-history changes; keep
credentials and complete stream URLs out of evidence. Do not mark these passed
from compilation or mock data.

1. Start and resume direct-play VOD and resumed HLS at a nonzero offset. Confirm
   displayed time, seek target and server-reported position agree. Seek before the
   current transcode window and confirm a controlled restart at the selected time.
2. Drag many times without release: zero stream negotiations. Commit once: one
   local seek or replacement. Repeat skip quickly, then pause: no late auto-resume.
3. Open each panel while playing and while paused. Cancel, change a selection,
   select the same selection, background during dismissal, and return. Preserve
   intent and position; discard obsolete completions after account/generation change.
4. Change audio, captions and quality in sequence. Confirm stream-index validity,
   language, subtitle appearance and old session cleanup. Quality labels remain
   ceilings; the UI must not promise a format the active stream is not delivering.
5. Enter PiP, return through its restore action, close PiP, close the player, change
   audio routes, disconnect headphones and take an interruption. Test AirPlay
   connect/disconnect and background behavior. Exactly one playback owner remains.
6. Test small phone portrait/landscape, iPad split view, long titles, largest text,
   VoiceOver, Reduce Motion, bright scenes and subtitle-heavy scenes. Controls must
   remain distinguishable, nonoverlapping and reachable, with focus restored after
   panels. Test all three default transport buttons without hidden-only gestures.
7. On Apple TV, navigate from Back through transport, timeline and panels. Select
   commits a timeline draft; Back/focus departure cancels it. Play/Pause works with
   hidden controls. Exit repeatedly without a focus trap or background player.
8. Fail the network, reject a stream, expire a session and remove a selected track.
   Show useful recovery, never raw server URLs, stale controls or a silent blank
   player. Close remains usable during preparation and replacement.
9. Repeat ten play/close/episode/track switches, inspect observer/transcode/session
   cleanup, UI frame pacing, CPU, memory and artwork/thumbnail request counts.
   Verify idle/closed players stop presentation work. Compare to the current player.

The owner approved the default-player switch on October 22, 2026 after reporting
validation. This checklist remains the detailed acceptance matrix; the approval
does not identify which individual scenarios were exercised. Source privacy,
generic-client behavior and multi-server/account isolation remain release checks.

## Next-slice API contracts

The installed server reports Jellyfin 10.11.11. Its public OpenAPI document returned
HTTP 500 during this read-only planning pass, so endpoint/schema research used the
official API description and version-pinned server source instead. This verifies
contracts, not the presence of chapter images, trickplay files or segment-provider
data in a particular library. No scan/generation job or plugin change was triggered.

- **Chapters:** `ChapterInfo.StartPositionTicks`, `Name`, and optional `ImageTag`.
  Decode optional metadata, sort valid finite nonnegative chapter starts, preserve
  the original chapter image index, and seek using the absolute timeline adapter.
  Use a timestamp/name fallback when artwork is missing; do not block playback.
  [Server model](https://github.com/jellyfin/jellyfin/blob/v10.11.11/MediaBrowser.Model/Entities/ChapterInfo.cs)
- **Trickplay:** authenticated `GET /Videos/{itemId}/Trickplay/{width}/{index}.jpg`,
  with `mediaSourceId` for the selected media version; a `tiles.m3u8` endpoint also
  exists. Choose the smallest adequate provided resolution. The metadata's
  `Interval` is milliseconds, while player/report positions use seconds/ticks.
  `TileWidth`/`TileHeight` count thumbnails, not pixels. Cache by server + viewer +
  media source + metadata revision + width + tile; never by item ID alone.
  [Pinned controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/TrickplayController.cs),
  [official API schema](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json)
- **Segment skipping:** authenticated `GET /MediaSegments/{itemId}` returns typed
  start/end ticks. This is a standard Jellyfin capability; it need not depend on a
  private extension. Providers populate the data. Only show a skip action for a
  verified, useful interval on the active item/source, never from title heuristics.
  Keep manual skipping as the initial policy. Ignore unknown types and invalid,
  reversed or out-of-duration intervals; do not repeatedly offer a dismissed
  segment. Prompt once and never force a jump merely because the user scrubbed
  backwards into an interval.
  [Segment guide](https://jellyfin.org/docs/general/server/metadata/media-segments/),
  [pinned controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/MediaSegmentsController.cs),
  [DTO](https://github.com/jellyfin/jellyfin/blob/v10.11.11/MediaBrowser.Model/MediaSegments/MediaSegmentDto.cs)

Proposed thumbnail loader limits: one current tile plus one adjacent prefetch,
coalesced identical requests, cancellation on dismissal/account changes, bounded
decoded-pixel memory, and no frame extraction or server generation from scrubbing.
Validate dimensions/counts before multiplication/cropping and reject oversized or
malformed responses. Missing/403/404 artwork falls back to timestamps; login
expiry follows the existing session flow. Final byte/pixel budgets should be
measured on the smallest supported device, not selected from desktop headroom.

Keep media metadata caches distinct from stream ownership. Cached chapter or
thumbnail metadata must never keep an old transcode session or account alive.


## Live TV implementation — October 17, 2026

Live events use the same visual language as VOD, with a different timeline and
session lifecycle. The top title is the current programme when verified, with the
channel beneath it; missing guide data falls back to the channel name. The footer
shows Live / Live TV / Paused, how far playback trails the safe live edge, and Go
Live when applicable. Channels replaces Episodes, and playback speed is hidden.

- **Guide:** viewer-authenticated `GET /LiveTv/Programs`, one selected channel,
  at most eight programmes over twelve hours. One foreground refresh per minute;
  stale snapshots expire after two minutes. Reject unrelated channels and invalid
  date ranges. The guide is independent of tuner ownership and playback progress.
  Existing viewer-scoped channel caching feeds the search panel; channel switching
  keeps this cache warm. Programme titles expire independently of channel names.
- **Live window:** AVFoundation's real seekable ranges establish the window, not
  programme duration. Thirty seconds of actual seekable media enables the rewind
  timeline and skip buttons; gaps do not count toward this threshold. Go Live uses
  the recommended offset from the final range end, with a bounded fallback.
  A committed seek rechecks the moving window, clamps expired positions and avoids
  seeking beyond the safe live edge. No window means no invented DVR controls.
- **Channel selection:** the current broadcast continues while browsing. A new
  selection closes/reports the prior stream before negotiation begins. Concurrent
  switches are blocked. Failed stream release blocks replacement; an explicit retry
  can retry only that owned stream's cleanup. Direct playback carries the opened
  LiveStreamId through to the video URL. No automated channel/retry loop.
- **Settings:** the 40 Mbps default remains a ceiling. Quality/audio/captions
  changes explicitly reconnect at live and clear rewind history. Fresh channels
  resolve their own viewer/track defaults; they never inherit another channel's
  stream indices. Live always plays at 1×, regardless of saved VOD speed.
- **Lifecycle:** while foregrounded, live UI/window state updates at two samples
  per second even while paused. Paused live-network updating is disabled in the
  background except PiP/AirPlay; guide reads stop in the background. Task identity,
  cancellation, account generation and presentation checks reject obsolete results.
- **Offline preview:** fictional event/channel choices, rewind/no-rewind variants,
  Go Live, pause and buffering states. It uses the actual custom control component,
  with no server calls, tuner reservations or history writes.

This does not add server-side DVR, recording, start-over outside the measured
buffer, live scores, provider credentials, codecs, or backend-extension requirements.
The channel picker is a bounded, cached channel browser, not a full multi-day EPG.

### Live acceptance still required

1. Play one allowed channel on a physical phone and TV. Check channel/current/next,
   programme rollover, unavailable/stale guide, long names and missing metadata.
2. Test streams with no rewind, a short buffer and a moving DVR window. Pause until
   old segments expire; resume/scrub/Go Live without stalling or inventing start-over.
3. Browse without interrupting audio; select the same channel; switch repeatedly;
   cancel during preparation; simulate failed close and verify no second tuner opens.
4. Change tracks and quality while playing/paused, reconnect after failure, close
   during negotiation and verify old-session/transcode/tuner cleanup on the server.
5. Test foreground/background, PiP/AirPlay, network loss, expired accounts, VoiceOver,
   small phone landscape, large text, Siri Remote focus and Back behavior. Measure
   memory/CPU during sustained event viewing before making the player the default.

Primary contracts checked for this increment:
[Apple recommended live offset](https://developer.apple.com/documentation/avfoundation/avplayeritem/recommendedtimeoffsetfromlive),
[Apple paused live resources](https://developer.apple.com/documentation/avfoundation/avplayeritem/canusenetworkresourcesforlivestreamingwhilepaused),
[Apple seekable ranges](https://developer.apple.com/documentation/avfoundation/avplayeritem/seekabletimeranges),
and [Jellyfin 10.11.11 Live TV controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/LiveTvController.cs).
[Jellyfin video stream controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/VideosController.cs)
confirms the opened LiveStreamId is accepted by the direct stream endpoint.
These establish API behavior; device and actual stream acceptance remains separate.


## Inline controls and close reliability — 2026-10-17

The current candidate replaces the earlier Speed/More footer with three symbols
for quality, subtitles/audio and playback information. Episodes and Channels are
contextual header icons. Audio selection and quality negotiation retain their
existing behavior; the saved playback preference is unchanged, but there is no
in-player speed adjustment. The former More-menu lock entry is no longer exposed.

Playback info is read-only and leaves playback running. It shows the negotiated
playback method, AVPlayer's presentation dimensions, requested bitrate ceiling,
advertised stream bitrate, observed network delivery and dropped frames when
available. Original source formats are explicitly separate from playing output.
Values that AVFoundation reports as unknown stay hidden. It does not expose URLs,
paths or tokens and performs no diagnostic requests to the server. Auto-next is
held while a panel is open and can resume after that panel closes.

At that checkpoint the custom controls retained the Debug opt-in / Release AVKit gate. The
ordinary AVKit Close button also uses the direct parent-owned dismissal path.
State regressions cover press-versus-idle-timer timing and closing during every
playback phase, an open panel and a pending scrub. Physical playback, VoiceOver,
AirPlay/PiP and remote behavior still require device acceptance.

Statistics follow Apple's installed AVFoundation SDK: `indicatedBitrate` is the
server-advertised throughput requirement; `observedBitrate` is observed delivery,
not source video quality. See [AVPlayerItemAccessLogEvent](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent).

## Shared phone and Apple TV player — October 17, 2026

Debug builds now open the custom player by default on iPhone, iPad and Apple TV,
for both on-demand titles and Live TV. An existing explicit off preference remains
respected; **Profile → Storage & app → Use the custom player** enables it again.
At this October 17 checkpoint, Release retained AVKit. The owner approved replacing
that gate on October 22; Release now uses the custom player as described above.

The TV transport is centered like iPhone. The shared footer contains elapsed
time, timeline, remaining time and only the Quality, Subtitles/audio and Playback
info icons. Live playback uses the same surface with its guide, live-edge state
and real DVR capabilities. Remote targets are 64 points and the central
Play/Pause target is 84 points. Play/Pause is the default focus when ready; focus
returns there when controls are revealed. A focused background receives remote
commands while controls are hidden. Timeline focus refreshes the idle timer.
Select enters seek mode; Left/Right adjusts the draft by ten seconds. Select commits
and Back cancels. Outside seek mode, Left/Right navigates to the footer icons.

Remote Back uses a tested interaction policy shared with the offline design
fixture. It unwinds a panel or draft scrub before exiting; cancelling a draft
restores playing intent only when playback was previously playing. Paused,
loading/error and VoiceOver states cannot get stuck behind permanently visible
controls. The hardware Play/Pause action remains available with controls hidden.

Validation: 237 core tests across 29 suites and signed physical-target iOS/tvOS
Debug builds passed. A subsequent physical Apple TV 4K/tvOS 27.0 offline run
verified rendered controls, header/transport/footer reachability, Select/Back
seek intent, panel access, auto-hide and hidden-control Play/Pause after focus
fixes. See VALIDATION.md for the exact scope. No simulator was started. Real
AVPlayer seek/caption/quality changes and playback remain separate device gates.


## Approved Cinema overlay — October 23, 2026

The Release player now presents options directly over the full player surface
instead of a centered system sheet. Audio and Subtitles use flat, checkmarked
columns on wide screens; narrow screens and larger Dynamic Type stack them.
Track variants in the same language retain distinguishing metadata. Quality and
information use the same surface, as do Live TV channels and the shared season/
episode browser. The Debug offline preview follows this surface too.

Selections remain visible while choosing audio and subtitles together, then apply
in one replacement on Close/Back. Resume intent and position are preserved; a
background interruption clears resume intent. Other playback negotiation, session
reporting and owned-live-stream cleanup contracts remain unchanged. The shared
season pill expands to a flat list in the player and on show/season/episode pages.
Episode cards use genuine episode artwork, flat text and jade watch progress;
the current card returns to playback rather than restarting it.

This is source/build validation, not a new physical-device acceptance claim.
Recheck track combinations, remote focus/Back, real episode selection, Live TV
reconnects and foreground/background behavior on the intended beta build.
