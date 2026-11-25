# Zorofin for Apple platforms

Zorofin is a native Jellyfin client for iPhone, iPad and Apple TV. It does not
provide a server, media subscription, account signup or bundled server directory. The current Zorofin web UI
is the visual and behavioral contract. This project ports that design and keeps
its phone/TV compositions; it does not introduce another theme.

Apple TV **1.3 (53)** is submitted for App Store Review. Internal TestFlight is
Testing; the existing closed beta is Waiting for Review. Signed package checks,
bounded physical playback/episode/account checks and the owner's picture, sound
and remote confirmation passed. Apple approval and broader device-matrix checks
remain separate. See the Apple TV validation and submission record.

iOS/iPadOS has a separate 1.3 (52) release record
and its own review submission. Source defaults remain iOS 1.3 (52) and
TV/Top Shelf 1.2 (49); the TV delivery used documented 1.3 (53) build overrides.
Never reuse a consumed build number. Read the
common handoff and
validation matrix for exact shared source
and remaining platform cases. The 1.2 record retains
historical build and rotation evidence.

Both platform targets use `org.zorofin.app` for one intended App Store Connect
listing. Apple TV previously used `org.zorofin.app.tv`; the identity change needs
fresh TV setup/sign-in and later device validation. The TV-only Top Shelf extension
and App Group retain their existing identities. See beta identity and rollout
status before distributing a build.

Release preparation: privacy disclosures,
listing draft, review package
and [iPad / iPhone Duo work](docs/ADAPTIVE_APPLE_LAYOUTS.md). Privacy and App Support
are readable offline from connection setup and Profile. Their public static pages
are in `release-site/`; publishing a stable public URL is still required.

## Open and run

Open `Zorofin.xcodeproj` in Xcode. Choose `Zorofin-iOS` or `Zorofin-tvOS` and a
matching simulator. No manual project creation is needed. On the first connection
page, enter your Jellyfin server address in the empty field and choose
**Next**. Bare hostnames use HTTPS. Bare local-network addresses also try HTTP
after HTTPS fails to connect; explicitly entered schemes are preserved.
After the server is
verified, the next page offers username/password and Quick Connect sign-in.
Use Back or **Change server** to return to the address page. **Explore the app
preview** on the first page opens fictional data; Profile > Leave preview
returns to connection setup. Simulator builds require no developer-team configuration.
Physical-device builds require selecting your own signing team.

The project is checked in. Regenerate it after adding source/resource files:

```sh
python3 tools/generate_project.py
swift test --package-path Core -j 2
xcodebuild -project Zorofin.xcodeproj -scheme Zorofin-iOS \
  -destination 'generic/platform=iOS Simulator' -jobs 2 CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Zorofin.xcodeproj -scheme Zorofin-tvOS \
  -destination 'generic/platform=tvOS Simulator' -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

Use `-derivedDataPath` and Swift's `--scratch-path` to put build output on an
appropriate development volume. Keep simulator use bounded on a host running
the media server. The Debug launch argument `--demo` opens the preview directly.
Add `--profile-preview` to open its Profile menu; `--profile-admin-preview`
adds fictional administration rows in Debug previews only. Add `--settings-preview`
and a page name (for example, `Account` or `Playback`) to open native settings
from the demo Profile menu.

## Implemented scope

- **Offline downloads** on iPhone and iPad: download button on movie and episode
  pages, Downloads in Profile with storage management, background downloads and
  offline playback with progress sync. See [offline downloads](docs/OFFLINE_DOWNLOADS.md).

- Profile-only **Watch together** for iPhone/iPad, using Jellyfin's standard
  SyncPlay APIs and authenticated same-server WebSocket. Create/join, participants,
  browse/continue, and leave live in Profile; the existing AVPlayer receives
  scheduled group commands without new title/player controls. Compilation is
  verified; playback trials were declined for this increment. See
  [implementation and operational handoff](../../docs/GROUP_WATCH_PLAN.md).

- Shared typed Jellyfin client, HTTPS/base-path validation, local-HTTP opt-in,
  modern authorization and scoped redirect handling.
- Separate server connection and sign-in pages, with username/password or Quick
  Connect; viewer session stored in Keychain.
- Home has a client-selected feature banner on ordinary Jellyfin servers. It
  chooses a stable, varied title from a cached pool of highly rated movies and
  shows, falling back to available library/discovery artwork when ratings or the
  preferred pool are unavailable. No Home plugin is required. See
  [banner behavior and validation](docs/CLIENT_HOME_BANNER.md).
- Home shelves with continuous discovery, automatically paged movies/shows, channel list, search, details, seasons and
  episodes, favorites and watched-state actions. Series, season and episode details
  share a season selector with episode thumbnails, synopsis and watch progress.
  The player has an Episodes picker; selecting another episode starts/resumes it
  after the previous playback session finishes cleanup.
- Phone floating dock, wide/TV navigation, current jade palette, original
  wordmark, bundled Inter, local preview artwork and bounded image cache.
- AVKit player integration with conservative negotiation, track options, resume
  parameters, ordered/coalesced session reporting and owned live-stream cleanup.
- Server capabilities: Requests, Support, Notifications, Home rows, live artwork
  and optional web settings appear when the signed-in server advertises them.
  No viewer integration toggle/setup or bundled private-server address is needed.
  The existing support adapter implements discovery; a distributable plugin
  for other server owners has not been developed yet.
- Home Support report sheet and unread-reply bell, account-scoped foreground
  polling, explicit read acknowledgement and safe handling of uncertain delivery.
  These are in-app support replies; APNs push is not implemented.
- Native Requests discovery, search, movie/show details, missing-season choices with one server-managed request type, personal/shared activity, and approval/download/availability status.
  The advertised same-server proxy uses the signed-in Jellyfin account. Durable
  attempt receipts prevent automatic resubmission after uncertain delivery.
  See [native Requests behavior and validation](docs/NATIVE_REQUESTS.md).
- Profile menu follows the live website's avatar, row order and layout. Quick
  Connect authorization and streaming quality have native controls; Support and
  Notifications reuse the existing native sheets. Administration rows require a
  fresh current-user permission response. Account, Display, Playback, Subtitles,
  Controls, Storage and advertised notification settings open native screens.
  Account settings use the selected server; device preferences persist separately
  for each server/viewer. Password changes and profile photo updates are native
  (photo selection is available on iPhone/iPad). The player applies language,
  remembered tracks, speed, skip intervals, PiP/background and next-episode choices.
  Dashboard opens the server's complete Jellyfin web dashboard inside the
  iPhone/iPad app, using a separate temporary browser login. Metadata Manager and
  advertised Account approvals remain native. Apple TV directs administrators to
  the iPhone/iPad app; see [administration](docs/NATIVE_SETTINGS.md#native-administration--november-3-2026).

- Live TV has a native channel/time guide on Apple TV and wide iPad windows, an
  adaptive phone agenda, channel search/favorites, seven-day date browsing and
  program details with Watch live. See [guide behavior and validation](docs/LIVE_TV_GUIDE.md).

Direct Seerr connections, request administration, broader personalization, guide recordings/reminders, APNs push and
notification types beyond support replies, announcements, recaps, downloads,
store packaging remain open. Native settings are implemented; physical-device
acceptance of settings saves and the playback behavior matrix remains open.
Server plugins' custom web-only options are not automatically portable to AVKit.
System playback controls remain available alongside the native Controls menu.

- [Research and platform decisions](docs/RESEARCH.md)
- [Independent-server checklist and optional native Seerr plan](docs/SERVER_COMPATIBILITY.md)
- [Jellyfin 12 native compatibility audit and runtime evidence](docs/JELLYFIN_12_COMPATIBILITY.md)
- [Server extension contract](docs/SERVER_EXTENSIONS.md)
- [Current UI contract](docs/UI_CONTRACT.md)
- [Custom player design, pilot and acceptance plan](docs/CUSTOM_PLAYER.md)
- [Native settings behavior and validation](docs/NATIVE_SETTINGS.md)
- [Saved-account design proposal](../../docs/ZOROFIN_ACCOUNT_SELECTION.md)
- [Current native account picker and preview decision](docs/ACCOUNT_PICKER.md)
- Validation and remaining gates
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [App icon artwork and reproducible exports](Branding/README.md)

Private server addresses, deployment topology and privileged keys are not part
of the app. Server addresses come only from the viewer or their saved connections.
Keep that same client-only positioning in onboarding, previews, screenshots and
store copy; never suggest a private server or a hosted Zorofin account. The future
open-source distribution must be exported from this
directory with its own license review; the parent operational repository is
not a public-app distribution repository.

Library caching, freshness, storage limits and the performance validation boundary
are documented in [Native caching](docs/NATIVE_CACHING.md).

## Custom player development preview

Debug builds expose **Profile → Storage & app → Preview player design**. This
uses fictional artwork and a separate in-memory preview model; it does not load
saved sign-ins, contact a media server, or report playback. Close returns to settings.
The `--player-preview` launch argument opens that same fixture directly.
Use `--live-player-preview` to open the offline Live TV fixture directly.

In Debug builds, **Profile → Storage & app → Preview Live TV player** opens an
additional fictional broadcast fixture with channel switching, a rewind buffer,
and Go Live. Playback info can also simulate a stream without rewind.

On iOS, **Use the custom player**, in that same section, controls the experimental
AVPlayerLayer/SwiftUI player for movies, shows and Live TV. The `--custom-player`
launch argument does the same. Real playback uses the signed-in server and reports
viewing normally. The toggle defaults on in Debug for device validation; an explicitly saved off
selection is preserved in Debug. Turn it off there to compare with AVKit.
iOS Release always uses the custom player, approved by the owner on October 22, 2026.
Apple TV now uses AVPlayerViewController's system controls in both Debug and
Release, per the October 27 approval. Native transport owns pause, skip/scrub,
Back, AirPlay and PiP; Zorofin adds episodes/channels and Streaming options.
The latter preserves full server track selection, quality and playback info.
The old TV comparison toggle is hidden; fictional custom-design previews remain
development references. System scrub thumbnails depend on stream support and
still require physical-device acceptance. iOS presentation is unchanged.
See [the player plan](docs/CUSTOM_PLAYER.md) for implemented controls and the
remaining detailed acceptance matrix.
