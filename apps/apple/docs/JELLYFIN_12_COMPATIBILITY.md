# Native Jellyfin compatibility — 2026-10-17

## Result and scope

**Compatibility is substantially exercised, but not fully accepted.** Actual
12.2.0 Core/AVPlayer checks pass, and both physical Apple TV and iPhone decoded
production movie and live video. A physical iPhone subtitle-change failure
remains open: the unlocked October 22 iPhone follow-up reproduced the paused
movie subtitle failure with numeric AVPlayer code **-12889** at `877098e`.
The same phone passed resumed episode playback, episode subtitle switching,
movie startup with subtitles already enabled, and a playing movie quality
replacement. Apple TV episode playback, paused subtitle switching and real Live
TV also passed at that source; see
the physical follow-up.
A subsequent local change serializes readiness → seek → paused preroll and
bounds recovery for the observed timeout. Its offline AVPlayer and regression
checks pass; the phone reproduction still needs retesting. See
the preparation follow-up.
Do not label this a complete iOS/tvOS release acceptance pass.

The native client already uses modern authentication. Runtime testing found a
separate playback bug: audio/subtitle choices were sent without `MediaSourceId`.
Jellyfin ignored those choices, including subtitles Off, and unnecessarily
transcoded the synthetic H.264/AAC MP4 to burn in the default subtitle.

Commit `8ee0208` supplies the known detail source, or discovers the source through
GET PlaybackInfo before POST negotiation. It never assumes the item ID is the
source ID. This also keeps track indexes attached to the selected file. The
conservative codec profile is unchanged. Three regression tests cover discovery,
explicit source/track selection, and a missing source.

The source-ID requirement exists in both the
[10.11.11 implementation](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Helpers/MediaInfoHelper.cs)
and the [12.2 implementation](https://github.com/jellyfin/jellyfin/blob/v12.2/Jellyfin.Api/Helpers/MediaInfoHelper.cs).
The running 12.2 lab reproduced the failure before the fix and passed afterward.
Physical Apple TV and iPhone results are reported separately below.

## Physical test follow-up: HLS resume

After the migration owner gave the explicit all-clear, the physical Apple TV
restored the saved account and decoded a production movie through HLS. The
player reported 1920×1080 transcoding with a 40 Mbps ceiling and zero dropped
frames during the short check. Play/Pause, the playback-info control and Back
were reachable.

That check exposed a second client bug: the movie showed its opening frames
while the UI displayed the saved 24-minute position. The controller had assumed
HLS started at the requested offset, skipped AVPlayer's seek, and added that
offset to the displayed/reported time. The migration owner independently found
that the encoding had started without a seek offset.

The controller now seeks both direct VOD and HLS before playing, and uses
AVPlayer's absolute playlist position for the timeline and session reporting.
A failed initial seek does not silently play from the beginning. The updated
actual-runtime AVPlayer test requires decoded frames beyond the requested
40-second position; all three runtime tests passed on 12.2.0. The earlier
resume test only proved decoding after sending StartTimeTicks and was not proof
of accurate resume. Commit `35d34c2` contains this correction.

Physical retesting passed on the same Apple TV and production 12.2.0: the movie
resumed in its middle scene around 24:57, with decoded video and visible
subtitles, rather than displaying the opening logo with an artificial timestamp.
After pausing at 25:01, the remote reached the forward control and a 30-second
skip displayed a new decoded scene at 25:31. Back returned to movie details.
This is visual playback evidence; Device Hub does not establish audible sound.

## Physical test follow-up: live source identity

A real Apple TV tune attempt loaded the channel and program but failed before
AVPlayer setup with `NoCompatibleStream`. Sanitized metadata probes against
production 12.2.0 showed that the channel detail's `MediaSources` contained a
placeholder File source with a different ID from the current tuner source.
POST PlaybackInfo using that placeholder returned zero sources; discovering the
current source through GET PlaybackInfo returned a valid Http source with an
open token and `RequiresOpening=true`. Neither diagnostic probe opened a tuner.

The item-aware playback entry point now always discovers current sources for
live channels. VOD retains its known file/version for audio/subtitle selection.
Two regressions cover the live placeholder and preservation of VOD's chosen
version. The synthetic live AVPlayer test now begins with channel details and
uses the same entry point and default subtitle option as the real app. Commit
`fd435b3` contains this correction; all 245 tests passed against the actual lab.

Physical retesting passed against production 12.2.0: Fox 5 DC decoded moving
video, Pause held the picture, and Go Live resumed at the current broadcast.
The remote reached the guide and selected ABC 7 DC, which decoded a different
live football broadcast. Back closed playback and returned to details. A
sanitized server-session read at 20:36 UTC showed one native TV client session
with no NowPlayingItem. This proves session stop, not independent tuner/encoder
resource cleanup; that server-side check remains open.

## Physical follow-up: paused quality replacement and iPhone

The next physical TV pass found another client bug: changing from 40 to 8 Mbps
while paused decoded the replacement frame, but left controls disabled with
“Preparing video.” AVPlayer had become ready without a subsequent time-control
or periodic-time event. `9fe983f` observes initial item status and refreshes the
presentation immediately on readyToPlay. Both signed device builds succeeded.

Retesting on Apple TV passed: the replacement retained the paused 26:10 picture,
Play remained reachable with direction/Select controls, and resuming produced
moving video with visible subtitles. The iPhone also retained its 0:14 frame
and usable controls after a paused 40 → 8 Mbps switch. Its playback-info panel
reported transcoding, an 8 Mbps ceiling, 1920×1080 output, approximately 4.4 Mbps
stream bitrate and zero dropped frames during this brief check.

On the physical iPhone 16 Pro / iOS 27.0.1, the saved account restored, Home and
artwork loaded, empty Search showed recommendations with thumbnails, an actual
query returned the expected series, and the season/episode browser loaded.
A movie decoded from its opening sequence, and ABC 7 DC decoded moving live
football video. Back returned from both players to details. This does not prove
all settings, account/server switching, episode playback or long playback.

**Open iPhone subtitle case:** selecting English SUBRIP while paused at 0:14
in the tested movie eventually failed with AVPlayer's safe “Unable to play”
message. This used 8 Mbps and had no decoded replacement picture. Back still
worked. The migration owner inspected the corresponding encoder: H.264/AAC and
subtitle font initialization succeeded, more than 5,400 frames encoded at about
8.7× realtime, buffering throttled normally, and the encoder exited with code 0
after Back. Its start offset was 12.012 seconds, 4-second segments, sequence 3.
Caddy access logging was disabled, so the delivered playlist/segment HTTP chain
for that phone attempt is unknown. No server changes were requested or made.

A temporary Mac AVPlayer probe using current Core and the same movie, English
subtitle, 8 Mbps cap and 14-second resume decoded beyond 16 seconds through both
the public route and loopback. Neither reported an AVPlayer error. This used the
existing private API credential in memory, not the phone token, and made no
watch-state writes. Each owned encoding was closed. The first loopback setup
attempt was rejected by the client's explicit local-HTTP gate before accessing
media; the corrected loopback probe passed. The temporary source was removed.
This is useful isolation evidence, **not a fix or a phone pass**.

Debug builds (`02d61ed`) now emit only numeric AVPlayer, underlying and media error codes
on failure for the next device reproduction. They never print error descriptions,
headers, media URLs, user information or access-log objects. The phone was
returned to the user before this diagnostic build was installed. Next checks:
reproduce the paused subtitle switch with numeric diagnostics, compare a subtitle
start from zero and a switch while playing, and observe a fresh login token if
needed. Do not infer an authentication, seek or server defect without that evidence.

## Network-path audit

| Path or feature | Implementation and evidence |
| --- | --- |
| Discovery and login | `/System/Info/Public` is anonymous; login uses the supported root API and MediaBrowser client identity. Current runtime version/ID checked before lab sign-in. |
| Authenticated APIs | Central `requestData` sends `Authorization: MediaBrowser ... Token="…"`. No `X-Emby-Token` is emitted. Library, search, resume, favorites, viewer settings reads and language options passed on the actual 12.2 lab. |
| Quick Connect | Anonymous initiate/connect/authenticate; approval uses the current user's modern authorization. A disposable receiver completed approval/login/logout on 12.2. |
| Collections/playlists | Generic item queries and collection membership passed; playlist members were fetched through the supported playlist route. This is API compatibility evidence, not finished dedicated native collection/playlist management UX. |
| Images | Authenticated artwork is loaded through the shared transport, with account-scoped caching. Primary artwork bytes passed. A non-admin lab viewer uploaded, fetched and removed its synthetic profile photo. Optional static sports assets use no token or cookies. Photo-picker UX remains a physical acceptance check. |
| VOD negotiation | Supported PlaybackInfo routes, now bound to the media source. Both subtitles Off and a selected external subtitle tested against the runtime. |
| Direct play | `/Videos/{id}/stream` uses `ApiKey`. A byte-range request and real macOS AVPlayer decoding passed without custom HTTP headers. |
| HLS/transcoding | Initial URL replaces legacy token query names with `ApiKey`. Actual master → variant → segment requests passed without header injection or child-URL rewriting; the generated variant used `ApiKey`. macOS AVPlayer decoded the subtitle-transcoded stream. |
| Subtitles | External VTT returned expected synthetic text with query authentication. Current playback profile requests subtitle burn-in; the selected-subtitle HLS path decoded. Visible subtitles were also observed during the physical TV HLS check; exact timing and iPhone rendering remain open. |
| Live TV | Channel/guide reads, opening a synthetic local channel, macOS AVPlayer decoding, and closing the owned stream passed. Separately, the physical Apple TV decoded two production channels, switched between them, and exercised Pause/Go Live/Back. Tuner-resource cleanup remains a separate check. |
| Playback lifecycle | Start, progress, stop accepted; a fresh item read confirmed the requested position. The disposable item's original user data was restored. |
| Generic servers | A server without the Zorofin extension returned no optional features, without a retry error. Core browsing/playback worked. Seerr is not required. This is lab coverage, not the mandatory independent physical-server acceptance gate. |
| Downloads | No native offline-download implementation exists to validate. Do not infer download support from direct-play byte-range success. |
| Optional backend | `X-Jellyfin-Token` remains only for the Zorofin extension contract alongside modern API auth. It is a distinct backend header, not legacy Emby authorization. Real extension/support/Requests/notification behavior after the production upgrade remains a separate check. |

No hardcoded `/emby` or `/mediabrowser` prefixes were found. Viewer-configured
reverse-proxy base paths are preserved. The client does not enable or depend on
legacy server authorization. Models retain optional metadata fields; no response
model incompatibility was observed in the runtime cases above.

Keychain storage remains `WhenUnlockedThisDeviceOnly`. Authenticated redirects
through the API transport stay on the selected origin/base path; metadata caches
exclude token-bearing source URLs. Initial AVPlayer URLs are validated before
handoff. Actual server-generated HLS descendants were tested, rather than
assuming successful API auth meant media requests would work. Tests never print
credentials, playback URLs, headers, AVPlayer error descriptions or raw responses.

## Evidence by environment

- **12.2.0 actual runtime:** synthetic loopback lab, identified using
  `/System/Info/Public` before sign-in. Full run: **246 tests in 30 suites passed**,
  comprising 242 ordinary Core tests and four explicit runtime tests (HTTP,
  non-admin viewer writes, macOS VOD AVPlayer, macOS synthetic-live AVPlayer).
  The non-admin test writes, reads back and restores seven viewer settings,
  favorite/watched state and a synthetic profile image, then confirms logout
  invalidates its saved token. These mutations affect only the disposable lab viewer.
- **macOS AVPlayer:** macOS **27.0.1**, Apple silicon, Xcode **27.0 (27A266a)**.
  Six VOD cases passed: direct play, direct resume, subtitle burn-in, subtitle
  resume, explicit audio selection and a 2 Mbps limit. Resume cases seek to 40
  seconds. Every VOD case and synthetic live produced a decoded video pixel
  buffer more than two seconds beyond the requested start. URL-only loading matches
  the app's AVPlayer handoff. This is a Core test host, not an iOS/tvOS app run.
- **10.11.11 actual runtime:** the migration owner's earlier Swift HTTP rehearsal
  passed login, library/resume/favorite reads, negotiation and Quick Connect.
  That runtime is now stopped. This app change has not been rerun against it;
  backward compatibility is supported by shared source behavior and regression
  tests, not a new runtime/AVPlayer pass.
- **App builds:** Debug **0.1.0 (1)**, signed iOS and tvOS builds succeeded
  with Xcode **27.0 (27A266a)** / SDK 27.0. Both physical devices received source
  through `9fe983f`; later numeric-only debug diagnostics compiled for both but
  were not installed. NVMe output directories and all four Xcode symlinks were
  verified; no links were replaced. User Xcode project/scheme edits were preserved.
- **Physical Apple TV:** Apple TV 4K (3rd generation), **tvOS 27.0**, Debug
  **0.1.0 (1)**. The earlier offline remote-navigation checks in `VALIDATION.md`
  passed at `e96b8b5`. The final playback source through `fd435b3` passed real HLS movie
  decoding, corrected resume, paused forward seek, live tune/channel switch,
  Pause/Go Live and Back to details against
  production **12.2.0**, identified via `/System/Info/Public` after the migration
  owner's explicit all-clear. Settings menu focus/selection/save/Done passed in
  the isolated offline preview. The final margin build `610eb36` was installed
  and checked on Home, the first focused shelf card, and episode details.
  Header and content now share one 48-point horizontal inset; focus outlines
  remain clear of the screen edge. Device Hub direction/Select/Back/Play-Pause
  controls were used; handheld Siri Remote gestures and audible sound are open.
- **Physical iPhone:** iPhone 16 Pro, **iOS 27.0.1**, Debug **0.1.0 (1)** through
  `9fe983f`, actual production **12.2.0** rechecked via `/System/Info/Public`.
  Movie/live decoding, paused quality replacement, search and season browsing
  passed as detailed above. The subtitle replacement failed and remains open.
  Further phone interaction stopped immediately when the user reclaimed it.
- **Physical iPad/LG:** not tested. LG is not built by the Apple project.
- **Simulator:** none launched or tested in this increment.

The server migration owner retains configuration, backup, service lifecycle and
cutover ownership. After the owner reported migration and scan completion, a
public-info probe confirmed production 12.2.0 and native device checks began:
saved sign-in, Home/artwork, horizontal movie details, and navigation worked.
Movie and episode resume attempts remained Preparing; the owner then reported
a final restart was still pending/overlapping. Both attempts were stopped, the
app process terminated, and the device returned to Home. These playback attempts
are **inconclusive**, not an established app regression or compatibility pass.
The owner subsequently gave an explicit all-clear; the physical HLS/resume
results above supersede those inconclusive attempts. The app did not restart
services or perform the cutover.

A final sanitized production read at 21:03 UTC returned **12.2.0** and two
native sessions, neither with a NowPlayingItem. This confirms stopped session
state, not every tuner/encoder resource.

Native work changed no server configuration or service lifecycle. The existing
lab was preserved. Tests log out
only their disposable sessions and close only their own encodings/live streams.

## Reproduce the opt-in lab checks

Use the migration branch `codex/jellyfin-12-lab` and its
`docs/JELLYFIN_12_LAB.md`, `docs/JELLYFIN_12_RESULTS.md` to obtain an already-running
synthetic lab. Coordinate with its owner; the tests do not start or configure it.

Set `ZOROFIN_LAB_ROOT` to that private lab directory, `ZOROFIN_LAB_INSTANCE` to
`candidate` (default) or `baseline`, and `ZOROFIN_LAB_AVPLAYER=1` to enable actual
macOS decoding. Then run `swift test --package-path apps/apple/Core --scratch-path
<external-build-directory> -j 2`. The marker, server ID, exact runtime version and
fixed loopback port must match before authentication. The live test requires the
lab's pre-existing `Lab Sports` generated channel.

Sanitized reports are written privately under the selected lab instance, with a
runtime version and timestamp. Credentials stay in the existing private marker,
never in command arguments or committed fixtures. Normal tests without these
environment variables skip all four runtime checks.

## Remaining acceptance

1. Production public-info returned **12.2.0** after the explicit all-clear.
   Continue checking it for future runtime reports.
2. Remaining Apple TV checks: direct play, next episode/episode changes, actual
   audio-track switching, tuner/encoder resource cleanup, sustained playback and
   audible sound. At `877098e`, a real episode and paused external-English → Off
   → embedded-English subtitle replacement passed on tvOS 27.0. Real Live TV
   hidden-control Select pause/resume and Go Live also passed. See the October
   21–22 follow-up in `VALIDATION.md`. Paused quality switching passed on both
   devices in the earlier pass and was repeated successfully on Apple TV.
   HLS movie picture, corrected resume, forward skip,
   live tune/channel switch/Pause/Go Live, session stop and Back have passed.
   Exercise the handheld remote gestures; Device Hub Back after hiding controls passed.
3. **Resolve/retest the iPhone subtitle replacement failure above.** The unlocked
   October 22 pass reproduced paused Off → embedded English at about 0:15 with
   an 8 Mbps ceiling: `failure=-12889 underlying=0`, with five media-log codes of
   -12889. This does not identify the root cause or establish HTTP delivery.
   The same movie decoded with embedded subtitles selected from zero (40 Mbps)
   and after a playing 40 → 8 Mbps replacement around 0:25. A resumed episode
   passed paused quality replacement and Off → embedded English at 4 Mbps.
   Home/search/season browsing, movie/live picture, quality switching and Back
   have passed. Landscape layout was observed via Device Hub Rotate Left;
   handheld rotation and orientation-transition stability still need testing.
   Remaining iOS checks include direct play, audio-track/episode changes,
   background/PiP, account/server switching, cache behavior, settings saves and
   failed/recovered connections. Also fix the incomplete episode-action row's
   alignment (implemented in the preparation follow-up, awaiting device review);
   the movie five-icon row and inline All channels link passed.
4. Repeat the fixed-source runtime tests on 10.11.11 when its isolated baseline
   is available; do not restart it as part of a production cutover.
5. Complete the independent-server release checklist, including another real
   server without the custom backend and optional Seerr absence/outage cases.
6. Validate real post-upgrade backend extras and sustained live-provider behavior.
