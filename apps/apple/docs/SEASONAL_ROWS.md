# Seasonal and curated programming

Home has one automatic, specifically named seasonal/mood shelf within the existing
weighted mix. It can say **Fourth of July**, **Back to school**, or **Summer movie
nights**, instead of the generic Seasonal / curated picks heading. Continue
Watching, My requests and Live TV keep their pinned order. No new viewer controls,
extra section heading, media request or download is introduced.

## Automatic calendar

Windows use the server's local calendar date. These are editorial US/northern
hemisphere defaults, not claims about every viewer's holidays or school dates.
Actual holidays are used rather than shifted workplace observance dates.

| Theme | When considered |
| --- | --- |
| New year, fresh starts | December 27–January 7 |
| Valentine’s picks | February 7–15 |
| Black History Month | February |
| Spring break | March 8–April 12 |
| St. Patrick’s Day | March 10–18 |
| Earth Day: wild worlds | April 15–23 |
| Mother’s Day | Week before the second Sunday in May, through Monday |
| Memorial Day weekend | Friday before the last Monday in May, through Tuesday |
| Graduation & new beginnings | May 15–June 20 |
| Pride stories | June |
| Juneteenth | June 15–21 |
| Father’s Day | Week before the third Sunday in June, through Monday |
| Fourth of July | June 26–July 7 |
| Back to school | August 10–September 15 |
| Long-weekend movies | Friday before September’s first Monday, through Tuesday |
| Spooky season | October 1–November 1 |
| Thanksgiving weekend | Ten days before November’s fourth Thursday, through Sunday |
| Christmas favorites | December 1–26 |

Closest holidays take priority over broader editorial windows. A candidate only
wins if it has matching playable titles. A missing holiday collection does not
cause unrelated films to acquire a holiday label. Next candidates are tried in
order: active editorial windows, the season, then rotating evergreen moods.

Seasonal fallbacks are **Winter nights** (December–February), **Springtime stories**
(March–May), **Summer movie nights** (June–August), and **Autumn evenings**
(September–November). Evergreen choices rotate weekly: **Comfort watches**,
**Movie night**, **Rainy-day mysteries**, and **Weekend adventures**. Rainy-day is
an editorial mood, not a weather feed. Titles are ordered consistently within the
week for the account, with unwatched films first; browsing never reshuffles them.

## Matching and privacy

Existing named Jellyfin collections win. Metadata fallback uses theme-specific
names, tags and synopsis terms; some themes also require matching genres. Generic
Action/War titles cannot become Fourth of July picks merely because of their genre.
Back-to-school matches school/campus metadata plus Comedy, Drama, Family or
Animation. A genre alone can support an explicitly genre-based mood such as
Rainy-day mysteries. Holiday and identity-specific collections require explicit
collection/tag evidence; the service never infers religion, nationality, ethnicity
or sexuality from people, titles or watch history.

Every lookup keeps the requesting viewer's token and user ID. Virtual, placeholder
and remote-only media are removed, duplicate IDs collapse, and at most 20 cards
are returned. Movies and collections remain subject to existing Jellyfin access
controls. There is one collection listing (up to 200 entries), at most two matching
collections per theme and six child queries total (40 movies each). The existing
bounded movie catalog is shared with other rows. No external discovery API, new
background job, credential or cross-account recommendation cache is added.

## Dated cultural holidays and events

Recipes also exist for Ramadan, Eid, Diwali, Hanukkah, Lunar New Year, Easter,
Game-day movies and Awards-night picks. They require a verified date window and
matching collections/tags; no dates, award winners or sports fixtures are guessed.
An operator can atomically replace `curated-calendar.json` alongside the existing
server-side Home preference files. There is no new public route or viewer setting.
The file is optional and read on the next feed build, so later calendar updates
need no service restart. Nothing writes to it through a client account.

The file has `schemaVersion: 1` and an `events` array. Each entry contains a known
`theme` ID, `start` and inclusive `end` in `YYYY-MM-DD` form. Supported event IDs:
`ramadan`, `eid`, `diwali`, `hanukkah`, `lunar-new-year`, `easter`, `game-day`,
`awards-night`. Other known theme IDs can also be scheduled. Entries precede the
automatic calendar in supplied order. Maximum 64 entries, 45-day difference between
start/end and 32 KiB file size. Invalid dates or malformed configuration make only
the curated row unavailable; other rows keep working. No variable-date events are
preloaded by this change. The legacy manual Eid preference remains compatible.

## Compatibility and validation

The Home feed remains schema version 1 with the same seven row IDs, unchanged
preferences and at most 20 cards. Only the curated heading and matching titles
change. Existing iOS/iPadOS/tvOS builds can consume it; no app reinstall is needed.
Their five-minute Home freshness window still applies. Empty rows remain hidden.

Run `node --test support-agent/home-rows.test.js support-agent/curated-seasons.test.js`
and the Swift Core suite. Date tests cover more than three full calendar years,
local midnight, leap days, floating holidays, overlapping windows and year rollover.
Matching tests cover unavailable media, explicit collections, false genre matches,
weekly ordering, request bounds, private DTOs and independent row failure.

Date-rule references: [OPM holiday definitions](https://www.opm.gov/policy-data-oversight/pay-leave/pay-administration/fact-sheets/holidays-work-schedules-and-pay/)
and [US Code, Father’s Day](https://www.govinfo.gov/content/pkg/USCODE-2024-title36/html/USCODE-2024-title36-subtitleI-partA-chap1-sec109.htm).
Editorial lead-in windows and seasons are product choices, not holiday-authority claims.


## Activation receipt — October 17

- 25 seasonal/Home-service tests passed, plus all 193 Swift Core tests in 23
  suites. The app wire contract and Swift source are unchanged, so no new app
  build or install was required. Native visual acceptance is not claimed.
- The live Home module matched its pre-change repository hash and the receiver
  matched the canonical source. Only `home-rows.js` and `curated-seasons.js` were
  copied after a scoped backup. The receiver was idle (queue zero, processing
  false and recap capture not busy) before its restart.
- The receiver returned healthy with queue zero and processing false afterward;
  anonymous Home requests still return HTTP 401. Runtime hashes match the tested
  modules. No Jellyfin or Docker restart, account/preference write, library scan,
  request submission or media operation was performed.
- An optional authenticated real-library canary was rejected by automatic approval
  review because it would read a credential from billing configuration. It was
  not executed or retried through another credential source. Tests and unauthenticated
  health/auth-boundary checks establish this activation; matching actual library
  titles and the phone/TV result remain unverified.
