# Native library performance

Implemented 2026-10-17 for the shared iOS/iPadOS and tvOS client.

## Screen behavior

Home, Movies, Shows, Live TV and Search keep their browsing state in the active
account's AppModel. Changing tabs no longer discards loaded pages, discovery
rows, favorites filters or the search query. Home and catalogue scroll positions
use stable item IDs. Account/server changes reset this visible state.

A cold visit first reads an account-scoped disk snapshot, then checks freshness.
Home publishes each shelf as it arrives instead of waiting for the slowest one.
Returning to the foreground checks freshness without emptying shelves or
restarting the discovery feed. Custom Home rows follow the same snapshot pattern.

Movie/show pages remain valid for five minutes. Deep browsing (more than one
loaded page) stays intact until an explicit refresh or a local library mutation;
new titles are not inserted into the middle of an existing pagination session.
On iOS, pull down in a catalogue to start a fresh list. Switching the Favorites
filter starts its own query immediately. There is no Home refresh button.

Favorites, played-state updates, Home preference saves and acknowledged playback
stops invalidate metadata. Continue Watching combines Resume and Next Up activity
reads, so a completed episode can be replaced by its next available episode.
Tagged artwork stays cached. Permission checks, login, playback negotiation and
support notifications always use the network.

## Cache layers and limits

| Layer | Lifetime / budget | Purpose |
| --- | --- | --- |
| Retained screen state | Active account session | Loaded pages, discovery cursor, query and scroll target |
| Decoded artwork | 40 MiB NSCache cost target; automatic pressure eviction | Reuse ready-to-display thumbnails |
| Encoded responses in memory | 16 MiB per active cache | Reuse JSON and compressed artwork; least-recently-used eviction |
| OS cache files | 96 MiB per server/viewer; oldest files evicted | Survive app restarts; OS may reclaim this storage |
| Catalogue / genres / similar / episodes | 5 minutes fresh; snapshots up to 24 hours | Initial rendering with quiet refresh |
| Resume / Next Up detail data / Live TV / history | 60 seconds fresh; snapshots up to 1 hour | Recent viewing state without repeated requests |
| Custom Home rows | 5 minutes fresh; snapshots up to 1 hour | Requests, episodes, curated and other configured rows |
| Full title details | 2 minutes, memory only | Reopen a title without persisting playback sources |
| Tagged artwork | 30 days; keyed by tag, type and size | Changed artwork tags cause a new fetch |

Concurrent identical requests share one in-flight fetch. Cancelling one screen
waiter does not cancel another waiter. Metadata invalidation rejects results from
before a mutation without cancelling artwork. Account retirement cancels pending
work; sign-out/removal also deletes that account's cache files. Old work cannot
write files back after logout.

The disk namespace hashes the normalized server origin/base path and viewer ID.
Each request filename is also hashed. Tokens never form a cache key. Persisted
library/custom-row JSON is re-encoded from known models with MediaSources removed,
so unknown response fields, playback URLs and open tokens are not stored. Detailed
items stay in memory. Files use private permissions, are excluded from backup and
use protected-file writes on iOS. Saved sign-in credentials remain in Keychain.
The cache is not a download or offline-playback feature.

## Network and artwork work

URLSessionDataDelegate appends complete data chunks rather than iterating every
response byte asynchronously. Both declared Content-Length and received bytes
are limited to 12 MiB. Redirects remain confined to the configured server/base
path. Cancellation and HTTP status behavior have regression tests.

Catalogue queries no longer request MediaSources for each card; full playback
metadata is fetched on the detail/playback paths. Poster decoding/downsampling and
cache-file work run off the main actor. Disk metadata is indexed once per cache,
not scanned for every poster. Lazy stacks/grids still limit visible artwork work.

## Validation and remaining checks

The core suite covers fresh hits, concurrent request coalescing, stale snapshots,
disk reuse after recreation, custom Home persistence, server/account/base-path
isolation, known-model disk projection, metadata invalidation, artwork survival,
HTTP errors, malformed responses, logout races, cancellation and storage budgets.

An optional release-mode benchmark compares old byte iteration with the new
transport using an in-process 512,000-byte URLProtocol fixture (seven runs):
median 5.712 ms versus 0.304 ms on the development Mac. This measures response
assembly only; it is not a phone launch, scrolling, server-latency or download
benchmark. Warm cache tests verify request counts rather than fragile timing
thresholds.

Run the benchmark with:

```sh
ZOROFIN_RUN_CACHE_BENCHMARK=1 swift test -c release --package-path apps/apple/Core \
  --scratch-path build/native-cache/core -j 2 \
  --filter TransportCacheTests.fixtureBenchmark
```

Device acceptance still needs: Home → Movies → Shows → Home, background/foreground,
force quit/reopen, long-scroll position, a favorite change, playback then Continue
Watching, and switching between two accounts/servers. First-time uncached data
still depends on server/network latency. No physical-device speed claim is made
from the fixture benchmark.

Apple references: [URLSession response handling](https://developer.apple.com/documentation/foundation/fetching-website-data-into-memory),
[SwiftUI scroll position](https://developer.apple.com/documentation/swiftui/scrollposition).

## Empty Search recommendations — 2026-10-17

The empty Search screen presents up to 24 movie/show poster cards. It reuses the
same two recent Movie and Series page reads as Home, so a warm Home cache needs
no additional metadata requests. Cold reads are concurrent, limited to 30 items
per format, and retain the existing account/server cache boundaries. Selection
alternates available movies/shows; within each format unwatched titles, available
posters and higher ratings take precedence, with recent-page order as the tie-break.
This is a library browse selection, not an external trending or collaborative feed.

Warm Home metadata or disk snapshots display first; a background refresh keeps
existing cards visible. Recommendations are retained for tab returns/clearing the
query and refreshed after five minutes or a library revision. Missing data has
loading, empty and retry states. Artwork uses the same bounded decoded-image and
encoded-image caches as other poster grids; it is never eagerly fetched for the
whole recommendation set. Switching account/server resets the Search state.

Recommendations and typed results have separate state and rendering branches.
The normalized query switches presentation immediately. Completed results retain
the query that produced them and only render for that query. Search retains the
300 ms debounce and real Items searchTerm request; cancelled/older request IDs,
changed library revisions and old account generations cannot publish results.
An in-flight replacement does not erase the last completed query's cached matches.
