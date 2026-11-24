# Personalized Home rows

> **Post-1.0 update:** five of these rows (new episodes, 90 minutes, 4K/HDR,
> seasonal and your teams) are now computed in the app on any Jellyfin server,
> and teams are saved in Jellyfin's display preferences. Only My requests and
> Popular still need the server feed below. See
> [Client-side Home rows](CLIENT_HOME_ROWS.md).

The Apple app automatically selects seven extra rows when supported by the
connected server. All Jellyfin servers get library-based discovery; extra rows require a capability
manifest that explicitly enables `homeRows` version 1. Empty rows stay hidden.
Profile → Your teams is the only native Home preference; there are no row toggles,
time-limit or curated-theme controls. Teams are saved to the authenticated account.

| Row | Evidence and behavior |
| --- | --- |
| My requests | Own Seerr requests only, exact TMDb identity, accessible local media, unwatched, added within 14 days. TV checks a requested season's episode. 4K requests require a verified 4K source and corresponding Seerr availability. Appears after Continue Watching. |
| New episodes for you | Jellyfin favorite series are followed shows. Shows unwatched locally available episodes added within 14 days. Use the existing heart on a show's details. |
| Watch in 90 minutes | Positive full runtime at or below 90 minutes; excludes played and virtual movies. The native app applies this limit automatically. |
| 4K / HDR showcase | Video width at least 3840 for 4K; Jellyfin VideoRange/VideoRangeType for HDR, HDR10, HDR10+, HLG and Dolby Vision. Never infers quality from a title or HEVC alone. Badges describe available source formats, not the output guaranteed by a device. |
| Seasonal / curated picks | Automatic year-round holiday/season calendar, including Fourth of July, summer and back to school. The heading names the selected theme. Matching collections come first, then relevant metadata; unmatched holidays fall through to honestly named seasonal/mood picks. See [Seasonal programming](SEASONAL_ROWS.md). |
| Popular this week | Playback Reporting recorded watch seconds over the previous seven days. Sessions under 2 minutes and invalid durations over 6 hours are excluded. Episodes combine under their series. Only accessible library items reach the viewer; no viewer identities or individual histories are exposed. |
| Your teams / starting soon | Games for the viewer's followed teams (full names) on now or starting within the hour, on a channel the viewer can open. No teams, no row: generic sports channels never fill it. On the plugin, viewers who follow no teams get the server's favorite teams (companion Sports, `ZOROFIN_SPORTS_FAVORITES`). Expired broadcasts disappear. “On now” describes broadcast time, not independent live verification. |

## Service contract and account boundaries

- `GET /support/home/rows`: versioned rows, sanitized media cards, preferences,
  generation timestamp. Empty data and unavailable data are distinct states.
- `GET /support/home/preferences`: account preferences.
- `PUT /support/home/preferences`: idempotent replacement with bounded validation.
- Every route validates `X-Jellyfin-Token` with Jellyfin `/Users/Me`. The viewer
  identity never comes from a query or request body. All library/guide lookups use
  that same viewer token. Seerr ownership is additionally checked before joining.
- Responses are private/no-store. Preferences use atomic files with owner-only
  permissions. Tokens stay in the app Keychain and are never written to preferences.
- New feed requests coalesce per session; no cross-account response cache. Only
  aggregate popularity is cached (five minutes). Limit 12 simultaneous feed builds.
- Movie scans cap at 5,000 recent entries, request history at 100 requests, followed
  shows at 100, guide programs at 1,500 and channels at 500; each row returns at
  most 20 cards. These are bounded discovery shelves, not exhaustive catalogs.
- Home loads existing library shelves independently, refreshes on foreground and
  every five minutes while visible/active, and cancels old results on account change.
  Errors have retry controls; no persistent Home refresh button is introduced.

## Popularity source

`home-popularity.py` reads native Jellyfin's Playback Reporting SQLite database in
read-only/query-only mode with a three-second query deadline. It returns aggregate
item IDs and seconds only. Its default path is the standard macOS Jellyfin data
folder. `HOME_ROWS_PLAYBACK_DB` and `HOME_ROWS_PYTHON` can override the runtime paths.
Never point the helper at a Docker-owned live SQLite database. This avoids the
installed plugin's failing custom-query HTTP endpoint. Missing reporting data
makes the row unavailable rather than substituting curated “Top Ten” results.

## Update and verification

Deploy `home-rows.js`, `curated-seasons.js`, `home-popularity.py` and any scoped receiver route changes
alongside the existing support receiver. Back up the receiver, compare the runtime
file before writing, check its queue/processing/recap state, then restart only that
idle launchd service. No Jellyfin restart, Docker restart, database write, request
submission, or notification is part of this update. Roll back the receiver backup
and restart the same service if health fails.

Run `node --test support-agent/home-rows.test.js`, Swift core tests and iOS/tvOS
builds. Use `--demo` or `--demo --profile-preview` in a Debug simulator for
fictional visual fixtures. The native automatic-feed path can migrate legacy Home
preferences as described below; raw `homeFeed()` remains a read-only query.
Fixtures do not establish physical playback or account/device acceptance.

Open `apps/apple/Zorofin.xcodeproj`, choose `Zorofin-iOS` and the paired iPhone,
then Run to replace the development app. Signing settings are preserved. This is
not a TestFlight or App Store release. Physical-device acceptance remains with the
user, including team-name matches and the preferred ordering of rows.

## Validation receipt — 2026-10-17

- 54 Swift tests in six suites and 10 Home-service tests passed.
- Final iOS simulator, tvOS simulator and signed generic-iPhone builds succeeded
  using two compiler jobs. Existing Xcode signing edits were preserved.
- iPhone simulator inspection confirmed all seven toggles, native shelf layout,
  format badges and VoiceOver labels using explicit fictional fixtures. The
  temporary simulator was shut down and removed afterward.
- A read-only live feed completed in about six seconds: short movies, showcase,
  curated picks, popularity and sports returned real library/guide items. A
  second account check returned one ready request. Empty requests/favorites for
  another account remained empty instead of being filled with sample data.
- Both local and public feed endpoints reject anonymous requests with HTTP 401.
  The support receiver reported healthy with an empty queue after activation;
  Jellyfin and Docker were not restarted.
- The paired physical iPhone was unavailable to Xcode. The signed build is
  prepared, but installation and real-account phone acceptance are outstanding.
- The mobile skill audit discovered zero Swift files; its generic PASS is not
  counted as validation evidence.

## Continuous browsing and simpler presentation — 2026-10-17

Native iOS/iPadOS and tvOS Home keeps one Continue Watching shelf and removes the
separate Next Up shelf. The October 24 fix below restores the next-episode query
inside Continue Watching. The title-detail next-episode lookup remains.
There is no Made for you group, row-description paragraph, or empty-row placeholder.
All populated rows use the same title-and-cards layout. Format/rank badges,
short-movie runtime, collection context and sports timing remain where useful.
The earlier Customize Home slider has been removed by the mobile-header update
below. The account-scoped service contract remains, with automatic native defaults
and Your teams in Profile.

After the three pinned rows, a weighted per-visit mix combines the deliberate
rows, recently added shelves and generated discovery. Discovery covers highly
rated movies (community rating at least 7), unplayed movies/shows,
actual library genres, decades, and broad movie/show selections. Each query pages
through accessible library items in a stable sort order. A lane with more results
returns later with its next page instead of ending at a fixed number of shelves.
This works with a generic Jellyfin server without the future Zorofin extension.

After five ordinary generated rows, the feed may insert **Because you watched
[title]**. Seeds require `UserData.Played == true`; watched episodes collapse to
one series. The app uses the server's Similar endpoint, removes the seed itself,
and does not fabricate viewing history when history is empty or unavailable.
At most eight distinct recent seeds are used per visit, with at least five normal
rows between recommendation rows. Movie/series cards are deduplicated within a
row, against the deliberate shelves, and against the previous six generated rows.

Movies and Shows grids automatically fetch another page when their continuation
becomes visible. A focusable Explore more / Try again control remains available
for TV remotes, VoiceOver, sparse results and network failures. Existing cards
stay visible after a failed next-page request; retry uses the same offset. Server
page offsets count raw results, so discarded duplicates cannot stall pagination.

Resource and lifecycle bounds:

- One initial discovery batch starts after the library and Home-row loads settle,
  so generated rows can join the first weighted mix. The pinned rows display
  independently during preparation. Later discovery starts only when the bottom
  comes into view. Each demand loads at most two rows, 24 cards per request, and
  eight page requests while skipping sparse/duplicate pages. Metadata fetches
  occur once per feed visit.
- Empty batches that still have more pages require Explore more; they cannot
  produce a background request loop. Truly exhausted or repeated server pages
  stop. Continuous browsing has no arbitrary row-count cutoff, but a finite
  library cannot provide unlimited distinct titles.
- Rows keep stable, namespaced IDs; they cannot collide with fixed Home shelf IDs
  inside SwiftUI's flattened lazy stack. New pages append without reordering.
- Lazy stacks/grids retain row metadata for scrolling back. Off-screen artwork
  releases decoded images; the existing encoded-image cache remains capped at
  24 MiB and is replaced on account/server changes.
- Feed snapshots commit only for the current account generation and refresh
  revision. Cancellation or an old server response cannot populate a new account.
- All discovery requests are read-only, use the current user's Jellyfin token in
  the authorization header, and preserve the selected server's base path. No
  privileged server key or new backend deployment is involved.

API behavior was checked against the Jellyfin 10.11.11
[Items controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/ItemsController.cs)
and [Genres controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/GenresController.cs).
The UI uses SwiftUI [lazy stacks](https://developer.apple.com/documentation/swiftui/lazyvstack)
and scroll visibility, also illustrated in Apple's
[tvOS media catalogue guidance](https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui).

## Standard Sports & live events row — 2026-10-17

Native Home now includes the web Home's **Sports & live events** row immediately
below Continue Watching and Your requests are ready (when those rows have content).
It is separate from the personalized **Your teams / starting soon** option. There
is one heading and an **All channels** link, with no descriptive subheading.
Both open the existing native Live TV catalogue; each event opens its channel's
native details, using the existing playback flow.

The Swift implementation in `Core/Sources/ZorofinCore/LiveEvents.swift` follows
`branding/zorofin-live-events.js`: current finite guide windows, explicit live
status, sports/event identification, studio/replay/placeholder exclusions,
football/basketball/soccer priority, favorite tie-breaking, and exact named
simulcast deduplication. Unsupported inferred matchup suffixes are removed. A
sports flag or a channel name alone cannot establish an event. Cards show the
event title, channel/number, broadcast time and elapsed-broadcast progress. This
is guide evidence, not proof of stream availability.

Servers advertising `liveArtwork` use the version-2 same-server artwork catalogue.
Only one dated fixture matching both teams, sport and supported competition can
supply art. Images are allowlisted local static filenames, fetched without
credentials; no third-party artwork requests are added. The worker includes
verified Championship event photos alongside the other supported competitions.

The native image order is verified catalogue event photo → programme Thumb,
Backdrop, then Primary → verified paired team crests → bundled sport illustration.
Programme images come from standard Jellyfin `CurrentProgram` metadata and the
programme's own `Items/{id}/Images/{kind}` route, using the selected server's normal
authentication. A missing programme ID, channel ID reused as programme ID, blank
image tag, or a tag shared with channel artwork cannot supply an event thumbnail.
Image tags participate in both the request cache and the rendered artwork identity.
Server/account, programme-window or image-source changes hide the old artwork
immediately, and cancellation prevents late results being displayed.

All eleven final illustrations are bundled vector assets in both native targets.
Ordinary Jellyfin servers need no extension for programme thumbnails or local
fallbacks. Loading/failure keeps the card visible; an unavailable image advances
to the next candidate. Event posters fit without cropping text; both crests must
load before a pair is displayed.

Regenerate with `node apps/apple/tools/generate_live_artwork.cjs` from the repository
root; add `--check` to verify every native sport and both catalogs against the web
source without changing files. Existing account-scoped metadata/decoded image
caches, strict fixture matching and guide eligibility remain unchanged.

Guide scans run independently of the movie/show shelves, page in batches of 200,
and stop on repeated/empty pages or at 20 pages / 4,000 channels. The complete
All channels catalogue remains independently pageable. Guide snapshots are
memory-cached per account for 60 seconds; still-current cards may remain for up
to two minutes after a transient failure. Expired/stale cards disappear on the
five-second display tick and are rechecked immediately at activation. A cold
launch fetches current guide data. Home refreshes once per minute while active;
account switches discard visible state and cancel old cache work. No eligible
current broadcasts means no Home row, matching the web behavior.

Selection, date parsing and artwork matching run off the main actor. The display
tick only filters expiry and updates progress. Artwork uses the existing encoded
disk cache and bounded decoded-image cache. This adds no server endpoint, guide
mutation, tuner change, Docker restart or web-client deployment.

Regenerate the 38 web/native selection cases after changing the web rules:

```sh
node apps/apple/tools/generate_live_parity_fixtures.cjs
swift test --package-path apps/apple/Core -j 2
```

The tests also cover current/stale timing, artwork ambiguity and unsafe paths,
account boundaries, page caps, cache reuse and credential-free public assets.

## Mobile headers and automatic Home — 2026-10-17

- iPhone and iPad have no persistent shared brand/server bar. Home owns one
  scrolling header with the approved image-only logo, Support, Notifications and
  Search. The separate Home heading and customize button are removed.
- Movies, Shows and Live TV keep their own titles, a Home back action and relevant
  catalogue controls. Search owns its search field, Requests its own heading,
  Profile its account identity, and detail pages a Back control. The bottom dock
  remains available on iPhone/iPad. Apple TV retains its remote-oriented top nav.
- Server switching/addition remains in Profile → Servers & accounts. Profile →
  Your teams is the only Home preference. Capability gates, unread badge and
  account-change state isolation remain in place.
- On a network Home load, old hidden-row, runtime or theme choices are normalized
  to all rows enabled, 90 minutes and automatic curation. The client reads fresh
  account preferences before the idempotent update so cached team choices cannot
  overwrite newer ones, then refetches the feed once. Existing automatic accounts
  incur no additional preference reads/writes. Cache-only hydration never writes.
- This normalization uses the existing account preference contract, so those
  defaults also apply to other clients reading the same server-side preferences;
  followed teams are preserved. No backend deployment is required. A failed save
  reports a retryable Home-row error instead of claiming defaults were applied.

## Pinned priorities and weighted row order — 2026-10-17

The first three populated shelves always appear in this order:

1. Continue Watching
2. My requests (the viewer's ready-to-watch requests)
3. Live TV (Sports & live events)

Unavailable/empty shelves stay hidden without a placeholder. The hero remains
above these shelves. The three IDs are excluded from the shuffle entirely.

Everything below is mixed: new episodes, short movies, format showcase, curated
picks, popularity, team picks, recently added media and procedural discovery.
A deliberate row has three selection tickets versus one for a generated row.
Selection is without replacement: the preference raises the chance of appearing
earlier but never repeats or silently drops a populated deliberate row.

The initial mix includes one bounded batch of generated candidates, so procedural
rows need not wait behind every deliberate shelf. Each visit gets a new random
seed; the retained account Home state preserves the published order on tab returns,
detail navigation and metadata refresh. New rows append in a weighted batch rather
than reshuffling above the reader. Account/server switches discard the ordering.
Generated lane order also varies per visit while preserving stable server item
sorts, cursor progression, finite-library bounds and sparse recommendations.

## Continue Watching episode handoff — 2026-10-24

A reported Apple TV failure exposed that Home loaded only `/UserItems/Resume`.
Finishing an episode can remove it from Resume, while its unstarted successor
belongs to `/Shows/NextUp`. Removing the separate Next Up shelf had also removed
that query, so the successor was absent even after a fresh Home load.

The shared iOS/iPadOS and tvOS shelf now reads both endpoints concurrently using
the selected viewer's authenticated client and activity cache. Unfinished titles
retain their existing order and position; next episodes follow in server order.
The combined shelf contains at most 40 cards, with one episode per known series
and no duplicate item IDs. A resume episode wins over a second suggestion for the
same show. Missing series metadata does not collapse unrelated episodes. No
successor is guessed locally: Jellyfin chooses the accessible next episode.

One source outage keeps the usable half and exposes Home's retry control. Both
sources failing remains an error, not an empty library. Authentication errors and
cancellation cannot publish a partial success. Cache-only startup reads never
start a network request, and account/server isolation still applies.

After an acknowledged playback stop, the Core client invalidates metadata before
another read can reuse pre-completion Resume/Next Up data. The existing player
exit flow waits for stop/cleanup and increments Home/library revisions for the
same account. This also refreshes after automatic episode changes without waiting
for the activity cache's 60-second lifetime. Apple TV Home Screen previews also
accept the unstarted next episode from this combined shelf instead of requiring a
nonzero resume position. The change does not alter autoplay preferences or mark a
viewer's episodes played outside normal session reporting.

Regression coverage uses synthetic transport responses for unfinished-to-next
handoff, warm-cache replacement after final stop, duplicate series, optional
metadata, source outages, authentication, cancellation and account isolation.
Physical acceptance remains separate: finish an episode on Apple TV, return Home
and confirm the next available episode appears once and starts at zero; also
leave an episode halfway through and confirm it retains its resume position.

Validation for this fix: the Release Core runner reports 349 tests in 46 suites
passed, with eight opt-in runtime/benchmark checks skipped. Unsigned generic-device
Release builds succeeded for iOS/iPadOS and tvOS using Xcode 27.1 (27A9275). NVMe
mount and the four Xcode symlink destinations were verified before building;
Derived Data and Core build output stayed on NVMe. No simulator was used. No live
server watch state was changed, and no physical-device validation, installation
or TestFlight upload was performed for this fix. The existing beta does not yet
contain it.
