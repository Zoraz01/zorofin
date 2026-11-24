# Native Requests

Implemented October 17, 2026 on `codex/custom-player-foundation`.

## Viewer flow

Requests appears only after the signed-in server advertises its Requests
capability. No embedded server address, external signup, shared Seerr API key or
second viewer login is introduced. Plain Jellyfin remains usable without Requests.

- Discover opens horizontal poster rows: Recommended to request (when the
  server has a ready personalized feed), Trending now, Popular movies, Popular
  TV shows and Coming soon. Each standard row has a See all action. Trending,
  Movies, TV shows and Coming soon also have paged catalog tabs; Activity stays
  separate. Search replaces the rows with movie/show results and debounces typing;
  person results are excluded. Standard discovery responses cache for 60 seconds
  in the existing account-scoped cache. Artwork is bounded in memory.
- iPhone pagination reserves the measured floating dock height inside the scroll
  content. Its page counter sits above the Previous/Next buttons to fit narrow
  phones. Apple TV keeps focus sections and visible focus rings for row actions.
- Display settings can hide fully available titles from Requests discovery/search.
  Partly available shows remain visible so missing seasons can still be requested.
  Pagination stays accessible even when every title on the current page is hidden.
- A title opens native details with a compact poster beside the title/date and
  the movie Request action directly under the metadata. TV shows group **Available
  to watch**, **Already requested** and **Missing seasons** separately. Only missing
  or partly available seasons have selection controls. Partly available seasons
  are labeled Missing episodes; no episode counts or completion are invented.
  Unknown per-season availability stays neutral rather than becoming a play claim.
- Requests has one viewer-facing request type. There is no Standard/4K picker or
  quality wording in confirmation. New intents use the existing normal request
  route (`is4k=false`); the server controls its quality/profile and permissions.
  Existing higher-quality availability/request records remain readable and do not
  become another selectable request. Core retains old quality-aware contracts for
  compatibility with stored receipts and server responses.
- Current status is displayed inline after submission and when an existing request
  opens. The detail view refreshes quietly every 30 seconds while active and when
  returning to the foreground. Discovery includes a compact personal-request preview;
  Discover and My requests are the primary tabs, with catalog categories in Browse.
  The Check request status button is removed. Retry remains for failures, and
  iPhone pull-to-refresh remains an optional shortcut. Queue labels are joined only
  to personal activity records. Request/queue completion never invents availability.
- Background refresh preserves manual season choices and cached artwork. Newer
  submissions supersede in-flight detail snapshots. Durable receipts, preflight
  validation, quotas, server-wide selection rules and explicit uncertain-delivery
  recovery remain in place. Automatic status checks never replay a POST.
- Sending requires an explicit title/season confirmation. The proxy
  derives the requesting viewer from the modern Jellyfin Authorization header;
  the app never supplies a user override, privileged routing options or API key.
  Permission enforcement remains authoritative on the server. The proxy does not
  expose a complete per-viewer permission bitmap, so it can reject an otherwise
  visible choice; the app reports that rejection and refreshes state.
- My requests and All activity use server-filtered records. Shared visibility is
  controlled by the server, not a client permission guess. Status filters and
  foreground refresh show approval, requested, release wait, download progress,
  importing, partial/full availability, decline and failure where exposed.
  Queue rows are joined only to visible request records. Queue completion never
  claims library availability. A server-provided library ID opens native details.

## In-app request notifications (October 22, 2026)

Notifications includes personal **Ready to watch** request cards alongside support
replies on iOS and tvOS. Each card has artwork, title, standard/4K availability,
**Open title** and **Mark as read**. The bell counts both sources and respects
Show unread badge. A Requests-capable server can expose the inbox without the
optional support service. Plain Jellyfin does not gain unsupported routes.

- Read only `arr/requests?userOnly=true&take=50&skip=...&filter=all`, using the
  current account's modern Authorization header. Two pages cap this inbox at the
  latest 100 personal requests. When more exist, the inbox points users
  to Requests → Activity for older records. This is a bounded inbox, not a complete
  notification archive. No shared activity, request creation, queue mutation,
  email or push test is issued by notification loading.
- The activity proxy can omit `is4k` and label media using standard availability.
  Resolve the matching request receipt from fresh movie/show details. Only an
  approved/completed receipt with known quality and available requested media
  qualifies. For season requests, every requested season must be ready in the
  requested quality; a partly available show can fulfill a specific season.
  Pending, declined, failed, removed and indeterminate records do not create a
  notification. Download completion and approval alone do not mean ready.
- Detail reads coalesce requests for the same title, run at most four at once,
  and skip available items already in local history. Both request availability
  and support replies refresh at most once every two minutes during the active
  scene. Opening the inbox respects that interval; explicit Retry bypasses it.
  Refreshing is quiet, without a recurring checking-updates banner. Cancellation
  and account-generation checks reject stale responses. Authorization failures
  clear the corresponding visible cards; other failures retain the last state.
- The first complete successful availability snapshot becomes Hidden history,
  including upgrades from the older read-receipt-only build. It does not generate
  a backlog of new notifications. Pending requests are not treated as available;
  a later verified availability transition creates a new item. An empty successful
  baseline counts, but a failed check never establishes a baseline.
- Opening resolves current availability and the corresponding standard/4K
  Jellyfin library ID again, then opens native details. Playback requires its
  normal explicit action. Missing/stale links show a recoverable message; nothing
  is automatically played or requested.
- A row must be at least 60% visible for 900ms to count as viewed. Scrolling it
  away or closing the panel cancels that dwell. Viewed rows remain in place for
  that presentation to avoid moving the focused remote target; on the next open
  they are under the collapsed Hidden section. Unseen offscreen rows remain new.
- History is device-local and server/account scoped. The bounded archive keeps
  100 available request cards and 30 viewed support replies, plus read identities,
  under a hashed server-base-path/viewer key. iOS uses atomic Application Support
  files excluded from backup; tvOS uses size-bounded UserDefaults. Legacy integer
  request receipts are preserved. No token/password is stored. Archive content
  contains titles, allowlisted artwork URLs and support messages; treat it as
  private user data. Corrupt/full storage reports an error without resetting the
  baseline or read state. Switching accounts clears visible data.
- Automatically viewing a support reply is acknowledged locally using its ticket,
  timestamp and message hash. It does not issue the server's ticket-only read ACK,
  which could acknowledge a newer reply that arrived while the older one was on
  screen. Web/other-device support unread state is independent. A later reply on
  the same ticket remains new.
- The Apple TV bell opens a top-right panel attached to the bell, with a fixed
  compact header and clipped scrolling content. Background controls are disabled
  while open; Close/remote Back dismiss it and return focus to the bell. iOS uses
  a native bell-attached popover. Request rows open titles directly; support rows
  expand their full message. Profile retains an inbox entry.

This adds **foreground in-app notifications**, not APNs/background delivery or
cross-device read sync. Existing server email/ntfy settings remain separate.
Upstream contracts were reviewed in the
[Jellyfin Enhanced activity controller](https://github.com/n00bcodr/Jellyfin-Enhanced/blob/main/Jellyfin.Plugin.JellyfinEnhanced/Controllers/JellyfinEnhancedController.cs)
and [Seerr request route](https://github.com/seerr-team/seerr/blob/develop/server/routes/request.ts).
These source checks do not establish the deployed server's behavior for this
feature. See VALIDATION.md for automated/build evidence and open runtime gates.

## Backend contract

The request proxy routes below are relative to the selected Jellyfin base path,
under `JellyfinEnhanced`; authentication uses `Authorization: MediaBrowser ... Token`.
Personalized recommendations additionally use the existing same-server
`support/recommendations` GET when the Requests and Support capabilities are
advertised. The extension transport includes its `X-Jellyfin-Token` header along
with modern Authorization; credentials never go to a separate recommendation host.
Only a `ready` feed renders personalized titles. A missing route or unready feed
hides that row, with no generic fallback presented as personalized. Loading reads
only: selecting a recommendation enters the same native details and explicit
submission flow as other titles. Each discovery row appears as its own read completes and can fail without hiding the
others, and account/search changes cancel the load and reject late responses.

| Operation | Relative path |
| --- | --- |
| Account availability | `jellyseerr/user-status` |
| 4K feature switches | `public-config` (decode only the two booleans) |
| Limits | `jellyseerr/quota` |
| Season policy | `jellyseerr/settings/partial-requests` |
| Browse/search | `jellyseerr/discover/{trending,movies,tv,movies/upcoming}`, `jellyseerr/search` |
| Details | `jellyseerr/{movie,tv}/{tmdbID}` |
| Submission | `POST jellyseerr/request` |
| Activity | `arr/requests?userOnly=...&take=24&skip=...&filter=...` |
| Download status | `arr/queue` |

POST bodies use camelCase `mediaType`, `mediaId`, `is4k`, plus selected `seasons`
and optional `tvdbId` for TV. Public poster URLs are restricted to TMDB's image
host and known image paths. They use a separate credential-free, redirect-bound,
size-limited transport; Jellyfin credentials never go to the image provider.

Contracts were checked against the installed runtime and the upstream
[Jellyfin Enhanced controller](https://github.com/n00bcodr/Jellyfin-Enhanced/blob/main/Jellyfin.Plugin.JellyfinEnhanced/Controllers/JellyfinEnhancedController.cs).
Only the advertised proxy is implemented. Direct Seerr, advanced quality profiles,
request approval/deletion/admin tools and a distributable backend remain separate.

## Submission guarantees and limits

Fresh access, detail, quota, 4K configuration and season-policy checks run before
each send. An account/server-scoped receipt journal is saved atomically **before**
POST. It contains media IDs, quality, seasons, time and receipt IDs, never tokens,
names or raw server addresses. Its filename is a hash of server plus viewer;
files are excluded from backup. All journal instances serialize access, including
switching away from an account while a submission is still running.

An acknowledged positive request ID confirms receipt. A timeout, cancellation,
conflict, 5xx or malformed success body remains unconfirmed across relaunches.
There is no automatic POST retry and no invented idempotency-header guarantee.
Explicit 400/401/403/404/422/429 rejections remove the attempt guard. Overlapping
TV seasons are protected separately for each quality. A fresh matching server
receipt reconciles an uncertain attempt. Confirmed declined/failed receipts can
be cleared after fresh reconciliation.

If the server never received an attempt, the viewer can choose **Allow another
attempt** after checking Activity or their server owner. This requires an explicit
warning acknowledgement, fresh eligibility checks, at least one minute since the
attempt, and no active submission. It only clears the local guard; Request and
its confirmation must still be selected. The proxy offers no transactional
idempotency contract, so cross-device requests and delayed upstream processing
remain server-arbitrated. A negative read alone cannot prove non-delivery.

Activity responses on the installed plugin omit per-request 4K metadata; the app
does not invent those labels. Standard/4K detail state is available separately.
Download information is optional and cannot prevent activity from loading.

## Validation

- Core implementation: `3ea0b05`; screens and recovery flow: `6a0ba24`;
  TV layout/focus corrections: `9f603eb`; TV library Back handling: `c972bf7`;
  pagination focus: `d0e6487`.
- Automated: the 269-test Core suite (33 suites) passed on macOS with Swift
  Testing; seven opt-in runtime/benchmark tests were skipped. Coverage includes
  duplicate/overlapping requests, concurrent journal instances, account/server
  isolation, explicit rejection, network/cancellation/5xx/conflict uncertainty,
  malformed receipts, corrupt storage, manual recovery, quota, season policy,
  quality separation, URL/auth safety and importing-versus-availability.
  The Requests runtime test was then enabled separately and passed against the
  running server. Automated tests use fixtures for submission outcomes.
- Running-server read test: `/System/Info/Public` reported **12.2.0**. The actual
  Swift client decoded 80 discovery items, search and movie/show details, quota,
  season settings, 24 personal and 24 shared activity records, queue data and a
  real poster response. Temporary owner verification sessions were revoked and
  their private session files removed. **Zero media request POSTs** were sent.
- Production currently advertises both 4K request switches as false. 4K handling
  has fixture coverage; enabling it is a server-owner decision, not an app change.
- Xcode 27.0 / SDK 27.0: signed Debug 0.1.0 (1) builds succeeded for both iOS
  and tvOS device targets at `d0e6487`.
  Build outputs: DerivedData folder `Zorofin-requests`, Core scratch:
  `Zorofin-requests-core`. The mount and all four migrated Xcode symlinks were
  checked. Two compiler jobs; no simulator launched; no service restarted.
- Physical Apple TV 4K (3rd generation), tvOS 27.0: signed build installed and
  launched using the existing owner account. Device Hub supplied directional,
  Select and Back remote inputs to real hardware. Verified tab/category access,
  actual poster loading, movie/show details, season selection, disabled existing
  seasons, Activity/filter reachability, request confirmation and Cancel, opening
  native library details, and Back returning from library details while focus is
  in the persistent header. Fixed the narrow TV detail sheet, horizontal layout,
  unreachable actions below the last season, and header Back exiting the app.
  Pagination loaded a second catalog page, scrolled to the top, and focused the
  first new poster after the correction.
- Search HTTP results passed the live Swift check. The TV search field and system
  keyboard opened, but Device Hub text/Select input did not produce a retained
  search term. Actual Siri Remote/companion-keyboard entry remains an explicit
  device check; it is not counted as passed or assumed to be a confirmed app bug.
- No simulator was used. iPhone physical checks remain deferred at the user's
  request. This pass did not requalify AVPlayer or other playback paths.

Remaining release checks: one intentionally chosen real request through approval,
download and availability; non-admin quotas/permissions against a live server;
enabled 4K movie/TV server; iPhone/iPad touch, large text and VoiceOver; independent
Jellyfin/Seerr setup; a current 10.11.11 runtime. The new feature was tested against
12.2.0, not merely compiled against its schema. Prior compatibility evidence for
other network/player paths remains in JELLYFIN_12_COMPATIBILITY.md.
