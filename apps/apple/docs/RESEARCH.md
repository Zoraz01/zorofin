# Apple clients and LG distribution research

Research date: 2026-10-16. This is implementation research, not store approval or
physical-device acceptance. The product requirements remain those recorded in
`docs/ZOROFIN_PRODUCT_PLAN.md` and its transcription at the repository root.

## Decisions

1. **Preserve the current UI.** The owner's October 16 clarification makes the
   recently completed browser UI the design contract. Reference branch:
   `codex/zorofin-ui-implementation`, reviewed at `d7ff866`; observed UI release:
   `f799e97b15fb`. Do not use the older main-branch navigation as a design source.
   Port the same compositions to SwiftUI, with touch on iOS and focus on tvOS.
2. **Own the interface and use public playback APIs.** Apple's web-view guidance
   explicitly excludes tvOS. A hosted-web wrapper cannot be the common Apple
   architecture. iOS technically permits one, but a faithful native port shares
   the Apple model layer, avoids DOM coupling, and delivers native playback.
   This follows the existing plan's custom-client requirement.
   [Apple web views](https://developer.apple.com/design/human-interface-guidelines/web-views)
3. **Use AVKit first, behind an adapter.** Standard system playback controls are
   an initial implementation choice, not a requirement to redesign browsing.
   Evaluate a second player only against demonstrated format gaps. Swiftfin
   documents materially different AVPlayer and VLC capabilities; neither is a
   promise that every codec, subtitle, HDR mode or receiver combination works.
   [AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller),
   [Swiftfin player comparison](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md),
   [Jellyfin codec matrix](https://jellyfin.org/docs/general/clients/codec-support/)
4. **Give Zorofin users the complete service by default.** The public Zorofin
   URL selects the built-in Requests, support and notification experience after
   account sign-in. No plugin setup, feature toggle, Seerr login or owner keys
   belong in that viewer flow. This uses the already operated backend and does
   not wait for a distributable plugin. Feature outages keep navigation stable.
5. **Keep other Jellyfin servers generic until configured.** Standard login,
   library, search and playback work without extra backend software. A future
   owner-installed Zorofin extension will advertise additional modules; it has
   not been developed yet. This companion-server relationship is comparable to
   [Moonbase for Moonfin](https://github.com/Moonfin-Client/Plugin). Authenticate
   to the selected server; URL classification never grants permissions. See the
   [account proposal](../../../docs/ZOROFIN_ACCOUNT_SELECTION.md) and
   [server contract](SERVER_EXTENSIONS.md). New connections remain server URL ->
   sign in -> Home. Full account selection and native Requests browsing/submission
   are still pending.
6. **Keep compatibility claims bounded.** The development machine has Xcode 27.0
   and iOS/tvOS 27 simulators. Provisional deployment floor is iOS/tvOS 18;
   compilation for that floor does not demonstrate behavior on an OS 18 device.
   Flexible compact/expanded layouts cover current phones/tablets. No unannounced
   foldable-device behavior is claimed.

## Mobile design checkpoint

| Question | Decision |
| --- | --- |
| Platforms and framework | SwiftUI, native iOS/iPadOS and tvOS targets; AVKit player |
| Source of visual decisions | Approved October 16 UI, not a new theme |
| Input | 48-point phone controls; at least 60-point TV actions and visible focus |
| Navigation | Four phone dock destinations; wide/TV top navigation; native Back |
| Data and performance | Bounded pages, lazy rows, cancellable search and image loads |
| Persistence | Viewer session in Keychain; no password retention; memory-only artwork cache |
| Network | Standard TLS validation; no blanket ATS bypass; explicit local-network policy |
| Offline | Clear failure/retry state; downloaded media is a separate future feature |
| Accessibility | Labels, Dynamic Type, contrast, reduced motion, focus restoration |
| Validation | Contract tests, both simulator targets, then hardware acceptance matrix |

Apple's media-catalog sample demonstrates lazy horizontal shelves and unclipped
focus effects. Focus scopes and default-focus preferences should complement
native navigation rather than implement a second directional-navigation engine.
[SwiftUI tvOS catalog](https://developer.apple.com/documentation/swiftui/creating-a-tvos-media-catalog-app-in-swiftui),
[focus APIs](https://developer.apple.com/documentation/swiftui/focus)

## Jellyfin protocol findings

The running server reports version **10.11.11** through its public information
endpoint. The downloaded official stable OpenAPI document identifies **12.2.0**.
These are different versions; do not equate compiling against the latest schema
with testing the deployed server. Authorization source was checked at both
`v10.11.11` and current main. Private server identity was excluded from this work.
[Official OpenAPI](https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json),
[10.11.11 authorization](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs)

### Client layer and authentication

The official Swift SDK is a viable future transport replacement. Its current
package uses Swift 6, supports iOS/tvOS 16 and brings Get and NIO transport
dependencies. A small typed client keeps this first implementation auditable and
dependency-free. It must preserve an adapter boundary and test the exact wire
contract, rather than invent Jellyfin-specific business rules.
[Official Swift SDK](https://github.com/jellyfin/jellyfin-sdk-swift)

Use `Authorization: MediaBrowser Client="Zorofin", Device="…", DeviceId="…",
Version="…", Token="…"` for API and image requests. Keep the token in Keychain,
bind all async results and cache entries to the active session, and clear them
on account changes. Never display raw URLSession errors containing request URLs.
Clear the local session on signout and attempt server revocation. If the server
is unreachable, explain the unconfirmed revocation without retaining local access.

TV Quick Connect avoids remote-control password entry. Initiate, poll with its
temporary secret, then exchange the authorized secret for a normal user session.
Cancel polling when leaving the screen. The displayed code and secret have
different purposes; never persist either. Quick Connect is not MFA.
[Jellyfin Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/)

### Native playback authentication

`AVURLAssetHTTPHeaderFieldsKey` is **not a supported public API**, according to
Apple's media engineer. Do not use that undocumented key for an App Store app.
Jellyfin accepts the modern `ApiKey` query parameter for native media delivery;
the older `api_key` and legacy headers are controlled by legacy-auth settings.
An AVPlayer URL may therefore contain a viewer token in memory. Do not log it,
persist it, put it in analytics, show it in errors, or attach it to another host.
[Apple engineering answer](https://developer.apple.com/forums/thread/671139),
[Jellyfin stream URL construction](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Model/Dlna/StreamInfo.cs)

Validate returned URLs against the configured server origin and base path.
Reject userinfo, protocol-relative external destinations, traversal and insecure
downgrades. A URLSession redirect delegate protects API/image requests. AVPlayer
also follows nested HLS references, so the selected server remains a trust
boundary: a deliberately malicious server cannot be made safe merely by checking
the first manifest URL. Do not claim a manifest check protects all media fetches.

### Negotiation, tracks and lifecycle

POST `/Items/{id}/PlaybackInfo` with the user, bitrate, selected audio/subtitle
indexes, start ticks and a conservative device profile. The current schema has
no `IsPlayback` property. Prefer direct MP4/H.264/AAC only when the profile and
server agree; otherwise use server-negotiated HLS. Do not open a media-source
filesystem `Path` or provider URL. Do not assume MKV/DTS, image subtitles,
advanced ASS styling, Dolby Vision, HDR or lossless passthrough.

Initially advertise H.264 SDR and AAC stereo, bounded video level/dimensions and
bitrate, with encoded subtitle fallback. This trades server transcode cost for
predictability. Widen capabilities only after device measurements. A selected
subtitle must participate in negotiation; if the chosen direct-play path cannot
represent it, request transcoding. External subtitle support needs explicit
delivery testing, not a fictitious direct-play promise.

Use exact item, media-source, play-session and live-stream identities when
reporting start/progress/stop. Jellyfin ticks are 10,000,000 per second. Report
start after actual playback readiness, progress periodically and on pause/seek,
and a final stop on dismissal or completion. Serialize reports so an in-flight
progress cannot arrive after stop. Opening a live stream is a user Play action,
never a browsing prefetch; close only the stream owned by that playback session.

## Optional Zorofin services: existing contracts

The browser already calls these routes with the signed-in viewer's authorization.
They are an inventory, not a new deployed capability-discovery endpoint:

| Feature | Existing route family | Native integration requirement |
| --- | --- | --- |
| Request account health | `/JellyfinEnhanced/jellyseerr/user-status` | Advertised Requests stays available; show account/service errors inside the feature |
| Discover/search/details | `/JellyfinEnhanced/jellyseerr/…` | Bounded pages, no direct Seerr admin key |
| Request creation | `/JellyfinEnhanced/jellyseerr/request` | Explicit action, season selection, quota/conflict handling |
| Own requests | `/JellyfinEnhanced/arr/requests?userOnly=true` | Keep results account-scoped; unknown POST outcome must not auto-retry |
| Download progress | `/JellyfinEnhanced/arr/queue` | Match only current viewer's request cards; completion is not import |
| Recommendations | `/support/recommendations` | Capability and API-version contract still needed |
| Support and replies | `/support/ticket`, `/support/notifications` | User consent for diagnostic details; notification bell represents replies |
| Announcements | `/support/announcement/me` | Account-scoped dismissal |
| Recap | `/support/recap/…` | Recently completed server feature; native port is a separate scope |

Do not probe arbitrary cross-origin extension hosts or convert plugin absence
into a login failure. Use the versioned server capability contract in [Server extensions](SERVER_EXTENSIONS.md);
keep integration configuration out of viewer onboarding. The same-origin
default is intentional. Requests artwork hosted by TMDB is a distinct approved
public image origin and must never receive a Jellyfin token.

## Network policy

Support valid HTTPS servers first, including non-root Jellyfin base paths.
Local HTTP requires deliberate app support: a local-only policy, the system's
local-network permission, and a clear insecure-connection choice. It must not
silently turn off TLS for public servers or accept invalid certificates.
Apple's current ATS documentation distinguishes IP addresses, unqualified names
and `.local` domains; local privacy permission is independent of ATS.
[ATS local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking),
[local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Apple distribution path

The owner intends to publish Zorofin through **Vitality Labs**. This is publisher
context only; keep the app UI branded Zorofin without a publisher footer or splash
label. Apply the same publisher direction to future LG distribution. Enrollment,
legal seller identity, signing access and production app identifiers still need
to be verified during release setup.

Build and simulator testing require no account setup from the owner. Physical
device signing and TestFlight require a valid development team, bundle IDs and
App Store Connect access. Create separate platform targets sharing source;
decide whether to offer a universal purchase under one App Store record before
creating production identifiers. Do not hard-code a developer team into Git.

The release packet needs functioning reviewer access to lawful test content,
support/privacy URLs, truthful data disclosures, icons/screenshots, age rating,
export-compliance answers and review notes describing user-provided servers.
Any paid digital access/account-creation flow needs a separate review against
the applicable storefront rules. Do not embed the personal signup/payment site
in the prototype or infer that an existing web subscription settles store rules.
Native playback and an owned UI provide tangible utility, but do not guarantee
review acceptance. Relevant guidelines include 2.1 completeness, 4.2 utility,
5.1 privacy and 5.2 rights.
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

TestFlight is the beta route, not publication. External testing may require beta
review, and builds expire after 90 days. Do internal device testing first, then a
small external cohort with a playback matrix and reproducible issue collection.
[TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

## LG app and publishing route

Keep the owner's provisional **webOS TV 27** target. LG's currently published
engine table reaches webOS 26 (Chromium 132); this research does not establish a
released webOS 27 SDK or a tested TV. Confirm the actual model, installed OS and
Re:New status before selecting minimum support. Flutter is an official option
from webOS 26 Re:New; TVs originally shipped with 26 also require the Re:New
update. A dedicated packaged web app has wider potential compatibility, but
still uses the TV's web engine. Neither is automatically faster.
[LG engine versions](https://webostv.developer.lge.com/develop/specifications/web-api-and-web-engine),
[Flutter announcement](https://webostv.developer.lge.com/news/flutter-for-webos-tv-is-now-available-for-developers)

Retain the same current TV screen composition in either implementation. The
implementation decision should follow a short physical-TV experiment comparing
startup, focus movement, image memory, HLS seeking, subtitles and Live TV. Share
tokens/contracts/fixtures with Apple; do not try to share SwiftUI rendering.

Publishing sequence:

1. Verify target hardware and SDK; install a development IPK through Developer
   Mode for physical testing. Developer Mode is temporary distribution.
2. Prepare the package, app identity/version, icons, promotional assets,
   description, service countries, support/privacy information and reviewer
   credentials/test content.
3. Complete LG's mandatory self-checklist and UX scenario, including remote
   direction/OK/Back behavior, visible selection, pointer support where required,
   reconnect/error recovery and secure session handling.
4. Create the Seller Lounge entry and upload the IPK plus required materials.
   Complete pretest, functional/content QA, resolve findings and obtain approval.
5. Select release settings and verify the published listing/device installation.
   Updates repeat the submission/approval process.

LG specifically requires the IPK, image files, UX scenario and self-checklist.
Submission is through Seller Lounge, not the Developer Mode app. This research
has not created a seller account, accepted terms, uploaded a package or obtained
a publication receipt.
[LG approval process](https://webostv.developer.lge.com/distribute/app-approval-process),
[LG self-checklist](https://webostv.developer.lge.com/distribute/app-self-checklist),
[Seller Lounge](https://seller.lgappstv.com),
[Developer Mode](https://webostv.developer.lge.com/develop/getting-started/developer-mode-app)

Include `requiredACG` in webOS 27 packaging, even an empty list when no Luna APIs
are used. Enumerate access groups used indirectly by plugins too. On webOS 26
Re:New, LG describes this as opt-in; on 27 it becomes required. Recheck the exact
Flutter packaging and media-plugin permissions against the release SDK.
[LG ACG guide](https://webostv.developer.lge.com/develop/guides/acg-guide)

## Release gates

- Actual iPhone and Apple TV: login, account isolation, remote focus/Back,
  interrupted networking, playback/resume, captions, audio selection and signout.
- Controlled media matrix: direct H.264/AAC; HLS transcode; unsupported codec;
  external text, embedded text and image subtitles; HDR variants; Live TV open,
  channel change and cleanup; seek/end/background/relaunch.
- Production-equivalent viewer account, never an embedded admin key; no
  unsolicited request creation, library changes or playback on real accounts.
- Profile memory/scrolling/startup on the lowest supported hardware; simulator
  speed does not settle TV performance.
- Complete feature/parity inventory, artwork/license audit, privacy manifest,
  review access and signing before TestFlight or either store submission.
