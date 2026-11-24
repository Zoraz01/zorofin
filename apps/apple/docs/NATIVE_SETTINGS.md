# Native viewer settings

Implemented October 17, 2026. Open Profile, then the setting category. These
screens replace the viewer-settings browser handoffs. Zorofin remains a Jellyfin
client: it includes no server directory, signup service or private deployment
address. Settings belong to the connection the viewer supplied.

| Screen | Controls | Where they apply |
| --- | --- | --- |
| Account | Current account/server, profile photo, current/new/confirm password | Selected Jellyfin account; photo picker on iPhone/iPad, existing photo display/removal on Apple TV |
| Display | Poster size, titles, watching progress, ratings, quality badges, hide available Requests titles, reduced motion | This device, separately for each server/account |
| Playback | Maximum bitrate, default speed, audio language, original default track, remember audio, automatic next episode | Bitrate/speed on this device; audio/episode preferences on the server |
| Subtitles | Language, Default/Always/Smart/Forced only/Off, remember selections; system/custom appearance with size, color, background and bold preview | Language/mode on selected server/account; appearance on this device |
| Controls | Skip backward/forward, Picture in Picture, pause when leaving | This device; PiP switch on iPhone/iPad |
| Notification settings | Combined request-availability/support unread badge; email save/remove/test; server push setup/test/reset/remove | Badge on this device; delivery actions on a server that advertises the module |
| Storage & app | Cache usage, clear cache, reset device preferences, app version | Only the selected account on this device |

Quick Connect, saved servers/accounts, Your teams, support and the inbox keep
working from Profile. The bell inbox shows new updates; existing request history
and previously viewed items are under collapsed Hidden. Read history is local to
the selected server/account and device, separate from email/push delivery settings.
Dashboard uses the server's full Jellyfin web UI inside the iPhone/iPad app.
Metadata Manager and Account approvals remain native; see
[Administration](#native-administration--november-3-2026). Apple TV asks
administrators to use the iPhone/iPad app. Custom settings from arbitrary
web plugins are available only when the server's dashboard exposes them.

## Save and account boundaries

- Opening a page reads settings; it does not change server state. Edits need Save
  or a named action such as Update password. Leaving dirty fields asks whether
  to discard. The action becomes busy synchronously, preventing duplicate taps.
- Device preferences use an atomic Codable file under Application Support,
  identified by a hash of the canonical server/base path and viewer ID. They
  survive relaunch, stay separate across users and servers, and include no
  token/password. Invalid data or failed writes are errors, not saved receipts.
- Server preferences read `Users/Me`. Saving fetches a fresh configuration,
  checks the selected user's preference permission, merges only edited supported
  keys while preserving unknown fields, and rejects an edited-field conflict.
  A readback must confirm the requested values before the app reports success.
  The Jellyfin API does not provide conditional configuration writes; another
  client's edit between that final read and POST cannot be prevented atomically.
- Password changes include the current password and explicit active user ID;
  this also requires an administrator to prove their own current password.
  Empty new passwords are rejected. Photos are downsampled to a 512-pixel JPEG
  before the viewer explicitly uploads; the endpoint receives base64 image data.
- Uncertain mutation results are never retried automatically. Reload settings
  before deciding to repeat an operation. Password and one-time push credentials
  are cleared when leaving the screen or foreground and are not persisted.
- Account changes cancel settings work and fence late responses. Network
  requests remain bound to the authenticated server/base path and viewer.

## Playback and display behavior

The native player reads fresh per-viewer media metadata at playback start, so
remembered audio/subtitle choices do not come from an older browse cache.
Jellyfin's selected stream defaults take precedence, including a remembered Off
subtitle choice. Where the server omits defaults, language/mode rules provide a
fallback. Explicit title-level track choices remain authoritative. Original
file-default audio remains implicit so compatible files can still direct play.

Streaming quality defaults to **40 Mbps** for new or reset device preferences.
An explicitly saved lower limit remains in effect for that account. The bitrate
is a ceiling, not a promise of a particular resolution. AVPlayer
uses the selected default speed. The chosen skip intervals apply to the native
player's **Controls** menu; AVKit's system skip buttons retain their own system
behavior. Active PiP continues when the app backgrounds. Otherwise, the pause
preference applies, including if preparation finishes after backgrounding.

After an episode finishes, automatic playback verifies the immediately following
item in the same series, then shows a five-second Play now / Cancel countdown.
Backgrounding or leaving the player cancels it. The previous playback session
is stopped and cleaned up before the next one starts. No server-requested live
stream is closed unless it belongs to this player.

Poster preferences apply to grid/shelf cards. With Show ratings enabled, the
numeric score and star appear in yellow on a dark capsule at the thumbnail's top
right, for both poster and landscape cards. There is no rating line below the
artwork. Turning the setting off removes the badge and its VoiceOver value;
missing ratings show no badge. Progress stays at the bottom of the artwork and
is controlled independently. Reduced motion combines with system accessibility settings.
Typography continues to use Dynamic Type. Home rows remain automatic; this does
not restore the removed Home customization menu.

## File quality and detail controls

Poster and landscape cards show compact source resolution and dynamic-range
badges at the lower left, above watch progress. Yellow ratings stay at the upper
right. Labels use the standard Jellyfin `MediaStreams` fields in the existing
paged requests, including search, resume, recommendations and episode lists;
there is no request per poster and no backend extension is required. Sanitized
account-scoped disk pages retain this typed metadata and container, while
playback sources, tokens and stream URLs remain excluded.

The detail page shows resolution, HDR/Dolby Vision, container (such as MKV), video
codec and audio format when reported. The information icon opens file size,
bitrate, exact dimensions, frame rate and bit depth as available. File versions
are listed separately. Series/season pages identify the next episode whose
format is shown, with one cached detail read for that episode. Changing the
audio menu updates the displayed audio facts. These describe the source file;
negotiated playback output can differ.

Do not infer formats from a title, filename, HEVC, 10-bit video, or EAC3/TrueHD
alone. Only recognized Dolby Vision range variants produce DV; `DOVIInvalid`
does not. Atmos/DTS:X require the spatial-audio field or an explicit older-server
profile. Unknown data stays absent. Cinematic crops retain their resolution tier
(e.g. 3840×1600 is 4K); exact dimensions remain in file details. Legacy extension
rows can supply their existing available-format badges, now on the artwork;
those may describe multiple available versions rather than one default file.

Details reserve actual layout space for the Back bar. Play uses the standard
48-point mobile target. Secondary actions are icon-only circles with 48-point
mobile / 60-point TV targets: favorites, watched state, start over when resumed,
audio, subtitles, seasons/episodes and file information when relevant. Actions
wrap on narrow screens, retain accessibility names/state and TV focus rings,
and respect Reduce Motion. Metadata chips wrap with Dynamic Type.

Metadata reference: [Jellyfin MediaStream definitions](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/Entities/MediaStream.cs).

## Notifications and storage

The native Notification settings page is available for servers with an inbox or
delivery settings. Delivery controls and their network reads appear only when the
authenticated capability manifest advertises them. The current optional adapter supports email and ntfy.
These are server delivery settings; direct APNs delivery in Zorofin is not
implemented. Sending a test requires the viewer to tap its explicit test action.
The app never submits a notification test merely by opening the page.

Cache clearing closes the old account cache first, preventing in-flight reads
from repopulating it, then starts a new cache. Other accounts, sign-ins and server
media are preserved. Disk errors are shown. Reset preferences resets only this
account's device choices, not server-side preferences or saved connections.

## Validation and remaining acceptance

148 Swift tests in 17 suites passed after this increment's core changes. Coverage
includes independent persistence across users/base paths and relaunch, failed
writes, unknown-field preservation, stale-field conflicts, read-only accounts,
password/image wire contracts, notification ownership, lost receipts without
retries, remembered tracks, fresh playback metadata and next-episode adjacency.
The existing cache and playback lifecycle regression suites also passed.

Signed iPhone and Apple TV simulator-target builds passed with two compiler jobs
and existing NVMe caches, including the final UI polish. The paired iPhone
installation returned an explicit success receipt after one disconnected attempt.
The app was not launched remotely. No simulator was booted: host memory pressure was elevated. Native rendering,
largest Dynamic Type sizes, Apple TV focus/remote behavior, real account changes,
photo selection, PiP, language/codec combinations and episode transitions remain
physical-device acceptance checks. Tests use fictional accounts; no real password,
photo, email, push subscription or delivery test was changed during validation.

The mobile audit script inspected zero Swift files, so its nominal pass is not
counted as evidence. The user's Xcode project/signing edits are preserved and
excluded from the feature commit. Docker and Jellyfin were not restarted.

## API references

- [Jellyfin stable OpenAPI](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json)
- [Jellyfin user controller](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/UserController.cs)
- [Jellyfin 10.11 image controller](https://github.com/jellyfin/jellyfin/blob/release-10.11.z/Jellyfin.Api/Controllers/ImageController.cs)
- [Jellyfin per-viewer stream defaults](https://github.com/jellyfin/jellyfin/blob/release-10.11.z/Emby.Server.Implementations/Library/MediaSourceManager.cs)
- [Apple AVPlayerViewController](https://developer.apple.com/documentation/AVKit/AVPlayerViewController)

## TV navigation and account selection — October 17, 2026

Apple TV uses one top navigation bar. Support and notifications are alongside
Search at the right, with Search last. Home and catalog pages do not repeat the
active tab title in another header. The avatar opens **Change account** or
**Settings**; there is no separate server button in the top bar. Settings starts
at the left content margin, and TV account/settings destinations use the full
screen. Phone navigation remains contextual.

**Who’s watching?** lists each saved account as one row: larger photo or initial,
name, then the supplied server URL. Accounts on different servers remain separate
even if the names match. Photos use each account's own server-bound session.
Add account goes directly to sign-in when one server is saved, or first chooses
among saved servers when there are several. Add server starts with a blank server
address. Reauthentication retains the saved server and expected user identity.
The Cancel header has its own layout space above the logo on both platforms.

TV title details put artwork on the left and the heading, source-quality badges,
compact Play/Resume and icon actions, then synopsis alongside it. Phone detail
layout and accessible action names remain intact.

## Metadata on optional Home rows — October 17, 2026

The older Home adapter's card serializer omits community ratings and stream
metadata. The native app now displays those rows immediately, then fills missing
metadata through authenticated ordinary Jellyfin Items reads. Requests deduplicate
IDs and use batches of 50, bounded to 140 cards for the current seven-row feed.
They use the existing account-isolated library cache, including a cache-only
first paint. No request is tied to an individual poster or scroll event.

The merge preserves row identity, order, descriptive text and user state. Optional
metadata failure leaves the row visible; authentication errors are surfaced.
Unknown formats/ratings remain absent. Live channels are excluded and a series
is not assigned a uniform episode format. Seasonal titles no longer repeat the
row name under every thumbnail. No backend deployment is needed for this fix.


## Viewer settings completion pass — October 22, 2026

All existing viewer categories remain native: Account (password/photo), Display,
Playback, Subtitles, Controls, Notification settings and Storage & app. Dashboard
and Metadata Manager retain the server-web handoff approved by the owner; tvOS
shows the credential-free URL for a phone/computer because it has no supported
embedded browser. Account approvals are still a separate server-administration
handoff. Arbitrary plugin preferences and native APNs delivery are not claimed.

This pass adds missing subtitle appearance controls and a live sample, quality
badge visibility and hiding fully available Requests titles. Subtitle appearance
uses [AVTextStyleRule](https://developer.apple.com/documentation/avfoundation/avtextstylerule)
on every prepared/replacement AVPlayerItem, including quality/track switches and
paused preparation recovery. System appearance is the default. Text styling does
not restyle burned-in/image subtitles; embedded style and system accessibility
choices may take precedence. Device rendering remains an acceptance check.

New preferences are optional fields in the existing account-scoped store. Older
saved files retain their quality/skip/display settings; absent fields preserve
quality badges, show all request titles and use system subtitle appearance.
No server setting or credential is changed by opening these pages.

### Support icon parity — October 22, 2026

The iPhone Home button, Apple TV header, Profile Support entry, support-unavailable
state and support replies use the web toolbar's microphone-headset vector. The
prior plain-headphones SF Symbol is removed from these surfaces. Both platforms
bundle the same 24-point SVG as a tintable vector asset; the path and two-point
rounded stroke match `support-agent/inject.js`. The Modern web toolbar clones
that same glyph. Button hit areas, focus behavior, labels and actions are unchanged.

## Native administration — November 3, 2026

The initial PR #40 made all three administration entries native. The owner then
requested that **Dashboard return to the server's original Jellyfin web UI**.
Build 1.2 (35) restores that full-screen WKWebView flow; Metadata Manager and
Account approvals remain native. The native Dashboard, Users, Tasks, Activity,
Devices, Plugins and Logs screens are removed. Their server APIs remain in Core,
while those operations are exposed through the server's full dashboard.

Dashboard rechecks current administrator rights before opening. Quick Connect
creates a separate temporary browser session; the native token is never copied
into the page or a URL. The browser uses a nonpersistent store, restricts
navigation to the selected server/base path, has no native message bridge, and
revokes its issued browser token on dismissal. If Quick Connect is unavailable,
the server presents its own sign-in screen inside the app. Foregrounding
rechecks permissions; server/account changes dismiss the view.

| Entry | Behavior |
| --- | --- |
| Dashboard | Full server-provided Jellyfin dashboard, including its library, user, task, log, plugin and server configuration pages |
| Metadata Manager | Native search/browse, metadata edit and locking, refresh, Identify and apply using ordinary Jellyfin APIs |
| Account approvals | Native Waiting/Reviewed signup requests, approve and deny with confirmation using the advertised gateway |

Account approvals gives the username and request date separate, wrapping lines.
Approve/Deny actions sit below the details and stack when the width or Dynamic
Type size needs more room. Loading, errors and the empty state are distinct;
a failed decision remains visible instead of being erased by an automatic reload.
See the [isolated layout review](#account-approvals-layout-review) for preview commands.

The native screens use the signed-in account's own token. The server enforces
administrator rights, and the app rechecks them on open and foregrounding.

Metadata saves send only edited fields, merged into a fresh copy of the item, and
refuse with "changed on another device" if someone else edited the same field in
the meantime. Image editing and deeper server configuration (transcoding, networking,
branding, plugin catalog/settings, API keys, backups and Live TV tuner setup)
remain server-provided dashboard features rather than native controls.

Validation and physical-device acceptance for the latest candidate are tracked
in the 1.2 release record. The restored dashboard
includes its account, URL/navigation and bootstrap regression tests. The opt-in
isolated-lab runtime check does not run without explicit lab configuration.

### Account approvals layout review

Debug iOS builds can show the production layout with fictional requests, without
restoring accounts, calling a server or approving/denying anyone. Launch an
installed Debug app on an owned simulator:

```sh
xcrun simctl launch "$SIMULATOR_ID" org.zorofin.app --approvals-preview
# Terminate the app before changing preview arguments.
xcrun simctl terminate "$SIMULATOR_ID" org.zorofin.app
xcrun simctl launch "$SIMULATOR_ID" org.zorofin.app \
  --approvals-preview --approvals-large-text
```

Other preview flags are `--approvals-reviewed`, `--approvals-loading`,
`--approvals-empty` and `--approvals-error`. Use `simctl --set "$DEVICE_SET"`
with a custom device set. Check a narrow phone, accessibility text sizes and
iPad widths. Capture with `simctl io "$SIMULATOR_ID" screenshot output.png`.
These fixtures and captures are for layout review only, never store artwork or
evidence of live account operations. The preview is excluded from Release builds.

