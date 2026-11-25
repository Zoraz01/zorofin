# Client-side Home rows

Current selection: enabled `homeRows` v2 uses the server's seven app rows
authoritatively; these device rules remain the ordinary/disabled/unsupported
server fallback and the legacy v1 merge. See the shared
app Home-row contract and
validation handoff.

Status: built for the first update after 1.0. Not part of the 1.0 release.

The iOS, iPadOS and Apple TV apps now compute five of the seven personalized
Home rows on the device. They use only ordinary Jellyfin reads made with the
signed-in viewer's own token. That means they work on any Jellyfin server, with
no Zorofin support service and no third-party plugin.

| Row | Where it comes from now | Needs on the server |
| --- | --- | --- |
| New episodes for you | Device: favorite series plus newest unwatched episodes | Jellyfin only |
| Watch in 90 minutes | Device: shared movie catalogue scan | Jellyfin only |
| 4K / HDR showcase | Device: video stream width and VideoRangeType | Jellyfin only |
| Seasonal / curated picks | Device: same calendar and matching rules as the server | Jellyfin only |
| Your teams / starting soon | Device: Live TV guide, sports programmes in the next 12 hours | Jellyfin Live TV |
| My requests (requests-ready) | Optional Zorofin server feed | Seerr |
| Popular this week | Optional Zorofin server feed | Playback statistics |

The rules are ports of `support-agent/home-rows.js` and
`support-agent/curated-seasons.js`. Card text, badges, limits (20 cards per row)
and empty/unavailable states match the server feed, so Home's pinned order,
weighted shuffle and card layout are unchanged.

## How Home combines the two sources

For legacy v1 only, `ClientHomeRows.feed(client:server:teams:)` merges rows in the server
contract's order:

- A client-computed row always wins, including an honest empty row.
- If a client row fails (`unavailable`) and the server sent the same row, the
  server row is shown instead. This keeps servers on the older feed working through a
  transient outage.
- `requests-ready` and `popular` only ever come from the server, and only when
  the server advertises `homeRows` in its capability manifest.
- A server feed failure no longer hides the device rows. Home shows its retry
  control and keeps the device rows. Signing out (401) still surfaces.

## Followed teams

Teams are now saved in Jellyfin's own per-user display preferences
(`/DisplayPreferences/zorofin-home?client=zorofin`, custom key `zorofinTeams`).
They follow the account to every device on any server. Saving is a
read-modify-write that keeps every other display preference intact.

Migration from the server feed is automatic and one-time. If the Jellyfin key
has never been written and the server advertises `homeRows` v1, the app reads the
legacy `/support/home/preferences` teams and copies them into Jellyfin. When the
server advertises `homeRows` v1, Save also updates the legacy preferences
(best-effort) so the companion web Home stays in step.

Profile → Your teams is now shown on every server, not only Zorofin servers.

## Request and resource bounds

- One shared movie scan: newest 2,000 movies, eight pages of 250, with the
  existing five-minute library cache. The 90-minute, showcase and seasonal rows
  share it.
- New episodes: one favorite-series read (up to 100 shows), then at most three
  pages of 200 newest unwatched episodes, stopping early once results are older
  than 14 days. No favorites means no episode scan.
- Seasonal: one collection listing (up to 200), at most two matching collections
  per theme and six child reads in total.
- Sports: reuses the cached Live TV channel snapshot, then at most three pages of
  500 guide programmes. Channels with no guide skip the programme read.
- All reads are GET requests with `userId` set to the viewer. Nothing is
  written except the viewer's own teams preference. A failing source makes only
  its row unavailable. Cold start hydrates from cache without network requests.

## Known differences from the server feed

- The seasonal calendar uses the device's time zone instead of the server's.
  That is closer to what each viewer expects.
- Operator-scheduled cultural events (`curated-calendar.json`: Ramadan, Eid,
  Diwali and the others) are server-only. The device can't read that file, so
  those themes appear only through the server's own feed or web Home.
- Playability is checked with `LocationType` and `IsPlaceHolder`. The server
  also drops remote-only media sources. The device skips that check so it
  doesn't have to download every media source for 2,000 movies.
- Showcase badges come from the item's media streams (all versions when
  Jellyfin sends `MediaSources`).

## Not moved yet

- **Requests** still use the Jellyfin Enhanced proxy to Seerr. A client can't
  call Seerr as the viewer with only a Jellyfin token. This needs the Zorofin
  plugin's Requests module (see `docs/ZOROFIN_BACKEND_PLAN.md`).
- **Popular this week** needs watch statistics across all accounts. A single
  viewer's token can't see those, so it needs Playback Reporting or a Zorofin
  module that records them.
- **Smaller downloads** (1080p/720p copies, subtitle burn-in) exist on the web
  client only. The Apple apps have no offline downloads yet. Adding them needs a
  background download manager, offline storage and offline playback. That is a
  separate, larger piece of work.

## Validation

Core logic has unit tests in `Core/Tests/ZorofinCoreTests/ClientHomeRowsTests.swift`,
including a two-year parity check against the server calendar. Regenerate the
fixture after changing `support-agent/curated-seasons.js`:

```sh
node apps/apple/tools/generate_seasonal_parity_fixtures.cjs
swift test --package-path apps/apple/Core -j 2
```

The iOS and tvOS app targets still need an Xcode build and a device check before
release: Home on a plain Jellyfin server (no Zorofin manifest), Home on
a server running the Zorofin plugin, and saving teams on one device and seeing them on another.
