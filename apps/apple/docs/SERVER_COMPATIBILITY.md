# Independent-server acceptance and optional Requests

Updated October 22, 2026. Required product behavior and implementation plan.
The independent-server/device checks below are **not yet run**. The owner plans to
test a friend's server after the friend creates an account; that dependency is
pending. No separate demo server is being provisioned for the invitation-only beta.
Direct native Seerr integration is **planned, not implemented**. Native Requests discovery,
search, title details, season/4K choices and activity now use the advertised
same-server proxy. See [implementation and current evidence](NATIVE_REQUESTS.md).

## Required modes

| Server setup | Required native experience | Requests |
| --- | --- | --- |
| Ordinary Jellyfin; no Zorofin plugin, injected web UI, support service or Seerr | Server-first login, Home, library/search, details/episodes, playback, watch state, native settings, account/server switching and caching | Absent; no setup prompt or broken tab |
| Ordinary Jellyfin plus an independently configured Seerr | The same complete core experience, even if Seerr is unavailable | Optional direct Seerr connection; no Zorofin backend required |
| Jellyfin with advertised Zorofin modules | Core experience plus only the modules advertised and permitted for that viewer | Existing same-server adapter; automatic when configured |

No mode depends on a particular hostname. The app presents itself as a client,
with no bundled private-server address, signup funnel or shared service account.
“Native” means the everyday viewing/settings flows run in native UI over Jellyfin
APIs; it does not mean the app supplies a media server or downloads missing films.
Owner-only server administration remains a separate, explicit web handoff.

## Mandatory independent-server release checklist

A successful test on the owner's installation does not prove independent-server
compatibility. Complete this checklist against an ordinary Jellyfin installation
**other than the owner's server** before claiming that coverage. The planned venue
is the friend's server with its own account and configuration. Record the actual
optional services available there; use an ordinary no-extension configuration for
that case. Do not clone the owner's database or configure a replacement demo server.
The owner has separately validated and approved the custom player as the Release
default; that selection decision does not mark this independent-server checklist
complete. The first invited testers already have server access.

- [ ] Record app commit/build, Jellyfin version, OS/device, connection type and
  enabled services. Start with no Zorofin extensions, Seerr, support adapter,
  injected scripts or custom web theme. Use a non-admin viewer as the main case.
- [ ] Fresh install: empty server address → verify server → native sign-in → Home.
  Test password and Quick Connect where enabled, cancellation, bad credentials,
  restore, expiry, sign-out and server revocation. No service/signup detour.
- [ ] Browse artwork and metadata, paginate Movies/Shows, use recommendations in
  empty Search and typed search, open seasons/episodes and resume watching. Test
  an empty/restricted library as well as a populated one.
- [ ] Continue Watching and library-generated discovery work without backend rows.
  No Requests, Support, Notifications or extra-settings controls appear merely
  because the server has a familiar name. Missing optional rows leave no gaps.
- [ ] Native account/preferences, favorites and watched state operate on the
  selected viewer. Non-admin restrictions remain enforced. Normal viewing does
  not require opening Jellyfin's website or loading custom JavaScript.
- [ ] Exercise direct playback and transcoding, nonzero resume, seeking, tracks,
  captions and next episode using the Release custom player on physical
  iPhone/iPad and Apple TV. The Debug stock-player switch is available for
  comparison if diagnosing failures. Record missing codec coverage rather than
  counting compilation as playback acceptance.
- [ ] Test ordinary Jellyfin Live TV with a controlled/legal source and EPG,
  with no Zorofin artwork endpoint or backend. Check no-DVR and measured-DVR
  behavior, channel switching, program rollover, network failure and cleanup.
  Separately test no tuner and a viewer without Live TV access.
- [ ] Warm navigation retains images, rows and scroll state; reconnect recovers
  without reloading the full library unnecessarily. Measure cold/warm library,
  search and playback times on this independent server.
- [ ] Both optional capability routes returning 404 is a valid plain-server case.
  Denial, malformed JSON and slow/unavailable optional services must not delay
  Home/playback, sign the viewer out, or reveal private-server features.
- [ ] Switch between two accounts and between this server and an extension-enabled
  server. Tokens, cookies, caches, rows, settings, drafts and pending responses
  never cross accounts. Optional tabs appear/disappear correctly and selection
  returns to a valid destination when Requests disappears.
- [ ] Enter a bare LAN IP such as `192.168.1.50:8096` on iPhone and Apple TV
  with HTTPS selected; confirm it falls back to `http://` and signs in.
- [ ] Test root and reverse-proxy Jellyfin base paths, public HTTPS, explicit
  local-network HTTP permission and failed TLS/redirects. Inspect a sanitized
  request trace: no contact with the owner's private services or guessed Seerr
  endpoints. Optional capability probes stay on the selected server.
- [ ] Verify small-phone/landscape/large-text/VoiceOver and physical TV focus,
  Back, Play/Pause and long-list behavior. Complete the existing player soak and
  background/PiP/AirPlay checks on this independent setup.
- [ ] Repeat with Seerr absent, then configured, then stopped/expired/denied.
  Seerr failure affects Requests alone. Test no request permission, approval and
  quotas, account/server switching, cancellation and ambiguous submission results.
  Disconnecting Seerr must leave the Jellyfin login and playback intact.
- [ ] Save sanitized results with pass/fail/blocker per scenario, measured timings
  and device evidence. Every unchecked item stays open. Test fixtures, simulator
  builds and successful playback on the owner's server do not close this gate.

## Optional native Seerr connection — implementation decision

We will keep the app usable without Seerr and add Seerr as a separate Requests
provider. An existing Seerr installation supplies request processing; the native
client supplies the screens. An ordinary Jellyfin server does not advertise a
standard Seerr URL, so the app must not guess hosts or scan services.

Proposed setup, after ordinary Jellyfin onboarding:

1. In **Profile → Connected services → Requests**, choose **Connect Seerr**. This
   screen is a planned addition, not present in the current build.
2. Enter the Seerr address supplied by that server's owner. Show the destination
   and selected Jellyfin account before linking. Cancel leaves core viewing intact.
3. Read Seerr's public settings/version without Jellyfin credentials. Accept only
   an already initialized service; never run Seerr's owner/bootstrap workflow.
4. Prefer Seerr's Jellyfin Quick Connect where available. Initiate at Seerr,
   explicitly authorize its code through the already selected Jellyfin account,
   then finish at Seerr. The native app can provide the authorization UI; it does
   not require a browser or the Zorofin backend. Cancel/expiry stops bounded polling.
5. If unavailable, offer a native Seerr sign-in form using a supported Jellyfin
   username/password or local Seerr account. State which service receives it; do
   not silently replay the original Jellyfin login or retain passwords. A Jellyfin
   access token is not a drop-in Seerr session credential. Respect advertised login
   modes and access denials; a disabled method is not a reason to bypass the owner's
   policy through another endpoint.
6. Confirm the Seerr session with its current-user endpoint. When a Jellyfin user
   ID is returned, compare it to the chosen viewer before linking. A mismatched
   identity is an error; a local Seerr login is explicitly a separate account,
   never an inferred match from its display name. An entered URL is not proof that
   two servers belong together; do not claim automatic server verification.
7. Enable native Requests for that connection. Keep the existing automatic adapter
   for extension-enabled servers; viewers there do not need this setup.

Seerr v3.5.0 was the latest tagged release checked for this design. Its published
API supports user-session login and Jellyfin Quick Connect; the auth handler
rejects Quick Connect during initial setup. This is contract evidence, not a
completed native integration or compatibility claim for older releases.
[Release](https://github.com/seerr-team/seerr/releases/tag/v3.5.0),
[API contract](https://github.com/seerr-team/seerr/blob/v3.5.0/seerr-api.yml),
[authentication routes](https://github.com/seerr-team/seerr/blob/v3.5.0/server/routes/auth.ts).

## Implementation boundaries

Introduce a `RequestsProvider` boundary with three cases: none, advertised
same-server adapter, and explicitly connected Seerr. One provider supplies the
native discovery, title/season detail, request submission and activity screens.
Selecting Seerr must not turn on unrelated Support, Notifications or Home modules.
Only one active Requests provider may receive a submission.

Use a separate Seerr transport/session store. Bind it to Jellyfin server + viewer
and Seerr origin + user. Store its session credential in Keychain, scope it to that
service and keep cookie jars separate across accounts. Never send Jellyfin headers
or privileged Seerr/API/downloader keys to the Requests service. Credentials must
not follow cross-origin redirects or artwork URLs; use the app's normal TLS rules.
No shared cookie storage, credential logging or credentials in invite links.

Seerr's user session uses a cookie; its API-key path grants privileged access and
is not suitable as an app setup requirement. User admission and request permissions
remain the server owner's decisions. Linked Jellyfin user IDs are available in the
server's user model, but the API schema alone is not enough to assume every field
is present across versions.
[Auth middleware](https://github.com/seerr-team/seerr/blob/v3.5.0/server/middleware/auth.ts),
[user identity model](https://github.com/seerr-team/seerr/blob/v3.5.0/server/entity/User.ts),
[user settings](https://docs.seerr.dev/using-seerr/settings/users/).

Initial native operations under Seerr's `/api/v1`:

| Purpose | Contract |
| --- | --- |
| Verify configured service | `GET /settings/public`, `GET /status` without update checks |
| User session | `POST /auth/jellyfin` or `/auth/local`; `GET /auth/me` |
| Quick Connect | `POST /auth/jellyfin/quickconnect/initiate`, `GET …/check`, `POST …/authenticate` |
| Discovery/details | `GET /discover/movies`, `/discover/tv`, `/search`, `/movie/{id}`, `/tv/{id}` |
| My activity | `GET /request` with bounded paging and the authenticated Seerr user's `requestedBy` filter |
| Request | `POST /request` with media identity/type and explicit season/4K choices |
| Disconnect | `POST /auth/logout` best effort; erase the local session regardless |

Preserve server permission/quota/approval decisions. Do not send admin overrides,
owner IDs, root folders or downloader configuration. Send writes only after the
viewer requests a title; lost receipts remain unconfirmed and are reconciled with
activity before any retry. A request receipt is not proof that a title is playable.

When matching an available request to the selected Jellyfin library, verify exact
provider IDs, viewer access and the requested season/format. Never join by title
alone or assume a Seerr availability flag means this account can play it. Keep
credentials off poster/image origins and paginate/cancel all discovery work.

Seerr outage/expiry leaves saved connection metadata available for reconnect but
never blocks the library. Account changes cancel in-flight work and choose that
account's provider; disconnecting removes Requests and its cached data. Server
notifications and APNs remain separate capabilities, not automatic consequences
of connecting Seerr.

## Delivery order and evidence

1. Finish the mandatory plain-server acceptance pass first, including actual
   playback and native settings with every optional backend absent.
2. Implement scoped Seerr session storage, connection/authorization and identity
   checks, then contract-test supported versions with fixture responses.
3. The shared native Requests screens and same-server adapter are implemented.
   Extend their contracts to the direct adapter and test ordinary-user permissions,
   season selection, quota and uncertain writes against independent servers.
4. Run against an independent configured Seerr instance and the plain Jellyfin
   server, then repeat with Seerr stopped and with account/server switches.
5. Qualify physical iPhone/iPad and TV behavior; expose the connection flow only
   after these gates pass. Preserve the existing automatic extension experience.

Earlier planning evidence: source review confirms ordinary Jellyfin APIs and library
browsing are independent of the optional capability discovery, and existing
fixtures cover absent/denied/malformed manifests. This document adds the explicit
independent-server release gate and researched integration design. It adds no app
UI, Seerr credentials, backend installation, real request or completed device test.
The subsequent same-server implementation and device evidence are recorded in
NATIVE_REQUESTS.md; those checks do not qualify the planned direct connector.
