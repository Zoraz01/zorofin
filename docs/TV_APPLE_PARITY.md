# TV app parity with Apple TV

The Flutter TV client in [`apps/tv/`](../apps/tv/README.md) is meant to look
and behave like the Apple TV app in `apps/apple/`. This checklist compares it
with the Apple app on `release/zorofin` (1.1, build 23, commit `eac0622`),
feature by feature. The Apple files named in each row are the reference.

Status: **Done** matches Apple TV. **Differs** works, with a TV-platform
difference that is noted. **Open** is still to do. **Apple only** has no
equivalent on other TV platforms.

Every row marked Done or Differs is covered by the
[device test plan](TV_DEVICE_TESTING.md), so one pass on each TV checks it.

Last updated October 29, 2026.

## Reviewed UX additions for 1.4

The November owner review and proposed app behavior are in the
Mobbin UX plan. The
plugin web implementation and coordinator handoff
records the web candidate separately. Those web fixture checks do not change
any native Done/Open status below. The testing coordinator owns applying and
validating the equivalents in the active 1.4 app candidate.

## Connect and accounts

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Connect page: HTTPS / HTTP selector, address hints, preview button | `ConnectView.swift` `serverPage` | Done | HTTP only for private-network addresses |
| Sign in: server card, Quick Connect first, username and password | `ConnectView.swift` `signInPage` | Done | Quick Connect code lasts 2 minutes, as on Apple |
| Keep this account on this device | `AppModel.accept(remember:)` | Done | An account not kept is never written to storage |
| Who's watching, Change account, add or remove saved accounts | `SavedServersView` | Done | |
| Preview mode with the fictional library | `PreviewLibrary` | Done | Home uses a fixed layout in preview so screenshots match |
| Token storage | Keychain | Open | App-private preferences today; webOS has no secure storage plugin yet |

## Shell and Home

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Header: Home, Movies, TV Shows, Live TV, Requests, search, bell, profile | `Shell.swift` | Done | Requests tab only when the server offers it |
| Home banner (rated title, best artwork, kept per visit) | `HomeBanner` | Done | |
| Continue Watching (resume plus next up, one per show) | `ContinueWatchingFeed` | Done | |
| Recently added movies and shows | `HomeView` shelves | Done | |
| Client Home rows: new episodes, short movies, 4K / HDR showcase, seasonal picks, your teams | `ClientHomeRows.swift` | Done | Merged with the server feed when the homeRows module is on |
| Server rows: requests ready, popular this week | `HomeRows.swift` | Done | Need the Zorofin server modules |
| Row order (pinned rows, weighted shuffle) | `HomeRowOrder` | Done | |
| Explore more discovery rows | `BrowseContinuation` | Done | |
| Sports & live events with sport artwork and All channels | `LiveEventsShelf` | Done | Artwork manifest when the liveArtwork module is on |
| Your teams | `HomeTeamsView` | Done | Profile > Your teams |
| Library grids with Favorites filter | `CatalogView` | Done | |
| Search with recommendations and grid results | `SearchView` | Done | "Can't find it? Open Requests" when Requests is on |

## Title details

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Artwork, heading, rating, metadata | `DetailView.swift` | Done | |
| Play / Resume / Play next episode, favorite, watched, start over | `playbackActions` | Done | |
| Quality badges and File details | `qualityBadges`, `MediaFileInfoView` | Done | |
| Seasons and episodes browser with More episodes paging | `SeasonEpisodeBrowser` | Done | |
| Cast & Crew, More Like This | `DetailView` | Done | |
| Live TV limit notice and conflict alert | `LiveTVCapacity` | Done | Needs the liveTVAvailability module |

## Player

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Custom controls, remote seek mode, skip intervals | `NativePlayer.swift` | Differs | Apple TV 1.1 uses Apple's native controls; the TV app keeps the custom design Apple previews in Storage & app |
| Quality, audio and subtitles, playback info, episodes panels | `customSettingsPanel` and others | Done | Playback info has no dropped-frame count (`video_player` does not expose it) |
| Text subtitles drawn by the app, subtitle appearance | `subtitleFields` | Done | |
| Default playback speed | `NativeSettings.playbackSpeed` | Done | Ignored in a Watch together group, as on Apple |
| Up next with countdown | `nextEpisode` overlay | Done | Uses the account's autoplay setting |
| Live TV now / next, channel switching, rewind and Go live | `LivePlayer.swift` | Done | |
| Pause when leaving the app | `pauseInBackground` | Done | Triggers when the TV switches app or input |
| Picture in Picture, AirPlay, Top Shelf, Home Screen previews | | Apple only | |

## Watch together

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Group list, start, join, leave | `WatchTogetherView.swift` | Done | Shown when the account's SyncPlay policy allows it |
| Shared queue, play, pause, seek, buffering wait | `WatchTogetherModel.swift` | Done | Server clock offset and drift correction as on Apple |
| Live TV blocked while in a group | `Shell.play` | Done | |

## Requests

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Discover, trending, categories, My requests, activity | `RequestsView.swift` | Done | Build flag `ZOROFIN_REQUESTS=false` removes it for first store builds |
| Request details, seasons, 4K, quota, duplicate protection | `RequestDetailsView` | Done | |
| Hide available titles in Requests | `displayFields` | Done | |

## Profile and settings

| Feature | Apple reference | Status | Notes |
| --- | --- | --- | --- |
| Profile header, Change account, Sign Out / Leave preview | `ProfileView` | Done | |
| Account: photo removal, password change | `accountFields` | Differs | Choosing a new photo is iOS only on Apple too |
| Quick Connect approval | `ProfileQuickConnectView` | Done | |
| Display, Playback, Subtitles, Controls, Storage & app | `NativeSettings` | Done | |
| Notification settings, Notifications inbox, Support | `HomeUtilityView` | Done | Need the Zorofin modules |
| Administration: Dashboard, Metadata, Account approvals | `AdministrationWebView` | Done | Administrators only |
| Privacy Policy, App Support, sample media credits | `PublicInformationView` | Differs | Text is copied from Apple and still names Apple services; a TV edition is needed before store submission |

## How to check

Run `flutter test` in `apps/tv`. Widget tests drive the preview library with
remote keys (Home rows and live events, details, player panels, Requests,
search, Your teams, Watch together, notifications, support), and unit tests
cover the Jellyfin client, Home row rules, SyncPlay handling, request
submission and settings. Playback, remotes and server modules need real
devices: follow [TV_DEVICE_TESTING.md](TV_DEVICE_TESTING.md).
