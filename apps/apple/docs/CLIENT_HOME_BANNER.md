# Native Home banner

The shared SwiftUI Home screen on iPhone, iPad and Apple TV selects its own
feature banner. It does not depend on custom Home rows or a server-side banner
plugin. Artwork and metadata stay scoped to the signed-in Jellyfin viewer.

## Selection and loading

- Read up to 12 movies/shows through standard `GET /Items`, sorted by
  `CommunityRating,SortName`, using the existing account-scoped library cache.
- Prefer titles rated at least 7 when available. Among those, favor backdrop
  artwork, then posters, then the existing neutral artwork treatment.
- Choose from at most eight eligible titles with equal artwork suitability.
  Keep the selection stable while shelves arrive, tabs change and metadata
  refreshes. A new Home/account session can select another title.
- If the optional featured read is empty or fails, use already loaded movie/show
  shelves, discovery results or resume movies. Shows-only libraries work too.
  Empty libraries keep the normal empty state; channels and episode cards are
  not promoted to the feature banner.
- Publish cached/ordinary shelves promptly. The optional query runs beside them
  and does not block their display or add an error for an unsupported feature.
- Reuse the existing adaptive banner layout, Play/Resume, Details and Favorite
  controls and artwork cache. No autoplay, trailer fetch or external art service
  is introduced. Server ratings are used as provided; no global popularity
  statistics are inferred or advertised.

The selection helper is `Core/Sources/ZorofinCore/HomeBanner.swift`; Home state
and load integration are in `App/LibraryViews.swift`.

## Validation — October 26, 2026

- Ten focused Swift tests passed: generic API shape/authentication and warm-cache
  reuse, high-rating preference and variety, stable selection/metadata refresh,
  shows/discovery-only sources, absent posters/backdrops, empty/invalid content,
  and fallback when the preferred pool is absent.
- A macOS Swift probe using the actual Core implementation checked
  `/System/Info/Public` and verified **Jellyfin 12.2.0** on the isolated demo.
  The existing restricted viewer had no custom Home extension. The standard
  featured query returned six titles; selection, authenticated backdrop download
  and ordinary-library fallback passed. The temporary probe session logged out.
- Unsigned **Release** builds passed for generic iOS and tvOS destinations with
  Xcode **27.1 (27A9275)**, app version **0.9.0 (10)**. Build output used NVMe
  paths after verifying the mount and all four Xcode migration symlinks. No
  simulator, installation, physical-device UI check or App Store upload is
  implied by the unit/runtime checks. The owner deferred installation and
  screenshot capture until later.

## Physical iPhone capture — October 27, 2026

A signed local Release **0.9.0 (11)** build from `8b2564f` compiled, passed signature
verification, installed and launched on the physical iPhone 16 Pro / iOS 27.0.1.
The plain demo viewer retained its account. The client-selected Caminandes 3
banner appeared without a custom Home extension, and a genuine **1206 × 2622**
PNG was exported. This establishes the visible phone banner on that demo setup;
it does not establish iPad/Apple TV behavior, a full playback regression pass,
TestFlight availability or final App Store image approval. See the release capture
evidence for the separate remaining screenshot gates.
