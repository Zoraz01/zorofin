# Server-dependent Apple app features

## Client-only presentation

Zorofin is a Jellyfin client. New connections start with an empty server-address
field, then a separate sign-in page after server verification. There is no
bundled server address, server directory, hosted-account promotion or signup
link. Saved connections and the sign-in destination remain visible to the viewer
who entered them. Display names never select capabilities or override an address.

All servers use the same flow. Optional modules appear after the signed-in server
advertises them; normal library browsing does not depend on discovery. For these
advertised modules, viewers do not configure integrations, enter shared keys or
install infrastructure. Separately, a planned optional **Connect Seerr** flow will
let ordinary-server users link their own owner's Requests service after onboarding,
without any Zorofin plugin. Plain Jellyfin with no Seerr remains a required mode.
See [independent-server acceptance and the native Seerr plan](SERVER_COMPATIBILITY.md).
The native Requests screens now use the advertised same-server proxy; see
[native Requests](NATIVE_REQUESTS.md) for contracts and validation. The direct
Seerr connector and distributable backend plugin for other owners remain future work.

## Capability discovery

After authentication the client reads `GET /Zorofin/Capabilities`, relative to
the chosen base path. Only a 404 tries `GET /support/capabilities`, the existing
support adapter's equivalent endpoint. Two 404s keep a plain Jellyfin experience.
A disabled primary manifest is authoritative. A denied, malformed or unknown
schema response never falls back to another service. There are no health probes
or hostname allowlists, and nothing contacts a different server.

```json
{
  "schemaVersion": 1,
  "features": {
    "support": { "version": 1, "enabled": true },
    "notifications": { "version": 1, "enabled": true },
    "requests": { "version": 1, "enabled": true },
    "homeRows": { "version": 1, "enabled": true },
    "liveArtwork": { "version": 1, "enabled": true },
    "enhancedSettings": { "version": 1, "enabled": true },
    "accountApprovals": { "version": 1, "enabled": true },
    "notificationSettings": { "version": 1, "enabled": true }
  }
}
```

Only explicitly enabled, implemented feature versions are supported. Requests
and app Home rows accept versions 1 and 2 through their own route adapters;
other features retain their existing version-1 checks. `homeSections` version 1
is the companion web feed and never selects app Home rows. Missing/disabled and
unknown-version features stay unavailable. See the shared
app Home-row contract. The manifest contains no deployment
addresses, account identity, signup links, endpoint overrides or executable code.
Advertisement is not authorization: individual routes enforce their permissions;
administration links additionally need a fresh current-viewer administrator policy.

The support adapter requires a valid, enabled Jellyfin viewer and trusted browser
origin (native requests have no Origin). Responses are private/no-store. It
advertises the integrations in that installation; other implementations should
advertise only their available modules. Capabilities refresh every 30 seconds in the foreground and on app activation,
including after a conclusive check, so module/version changes reach Home. Transient failures retain already known
features for that session; denial or invalid responses clear them.

Extension calls carry the viewer's `X-Jellyfin-Token` and standard Jellyfin
Authorization headers over the existing scoped transport. URLs and redirects stay
within the configured server/base path. Optional static live artwork is requested
only when advertised, on that same server, using allowlisted paths and no token.
Privileged/shared server keys never belong in the app.

## Support reports and replies

`POST /support/ticket` sends exactly the user-entered camelCase report fields:

```json
{"issueType":"Other","description":"What happened and when","affectedMedia":"Optional title"}
```

The existing backend limits are 64 UTF-16 units for issueType, 1,500 for
description and 200 for affectedMedia. The client validates these limits before
sending. Identity comes from the token, not a client-supplied user ID. No logs,
passwords or automatic device diagnostics are attached. The form explains the
recipient before the user taps Send report. Submitting uses the server's existing
support-agent policy; the app does not approve privileged repairs.

Only HTTP 202 with a valid `ticketId` confirms receipt. A request is sent once.
Lost connections, ambiguous server errors, unexpected success statuses or invalid
receipts show delivery unconfirmed and do not offer automatic retries. Closing
the sheet retains a pending result for the current app session. A confirmed
receipt allows starting a new report. There is no durable outbox or server
idempotency contract yet; an app restart during delivery remains an acceptance
and product-design limitation.

`GET /support/notifications` returns the current user's unread replies:

```json
{"notifications":[{"id":"Tabc12345","status":"resolved","issueType":"Other","affectedMedia":"Example","message":"Reply text","updatedAt":"2026-10-16T12:00:00Z"}]}
```

Opening the inbox does not mark replies read. `POST
/support/notifications/{id}/read` must return 204 before its row/badge is removed.
The server must enforce ownership. Reads overlapping an acknowledgement are
discarded to avoid overwriting its result. A fetch failure retains the last
replies and displays a retry message. Polling runs every 30 seconds only while
the app scene is active. No APNs registration, background push delivery, request
alerts, announcement feed or OS app-icon badge is implemented in this increment.

Capabilities, drafts, in-flight report work, unread replies and errors reset on
account changes/sign-out/preview changes. Async results are checked against the
session generation. Preview uses fictional replies and cannot submit a ticket.

## Acceptance boundary

Contract tests use synthetic responses. Native compilation does not establish
end-to-end authentication, delivery, remote focus or visual acceptance. Test with
a controlled backend/account before beta, including feature disable/permission
changes, reconnect, account changes during slow requests, notification/read
races, lost POST receipts and relaunch during delivery. The distributable
plugin and APNs registration/delivery remain separate work. No live tickets or
notification acknowledgements are created by automated validation.

## Apple TV Live TV capacity

`liveTVAvailability` version 1 enables the optional Apple TV notice and fresh
playback preflight. `GET /support/live-tv/status` accepts the viewer's `deviceId`
and optional `channelId`, with the normal authenticated extension headers. It
returns `limit`, `state` (`available`, `busy`, or `unknown`), `sameChannel`,
`differentChannel`, and `ownStream`. Other viewer identities, channel titles,
provider URLs and privileged credentials are never returned or requested.

Apple TV displays the reported limit on Live TV and channel details, with
foreground-only 30-second checks. Each Play/channel-change attempt checks again.
A confirmed different-channel conflict shows a native alert before any tuner is
opened or existing playback is released. Joining the existing feed and the sole
viewer's same-device channel switch remain allowed. The preparation path checks
again to narrow the race with another viewer starting playback. This advisory
check does not reserve capacity; provider/tuner enforcement remains authoritative.

An unavailable, malformed or missing optional status does not block native
playback. Failed polling clears the old busy/available state; account/server
changes, backgrounding and leaving the screen cancel checks and clear the notice.
No server address or fixed provider limit is bundled. Plain Jellyfin servers and
iPhone/iPad presentation retain their existing behavior.

Validate with `swift test --package-path apps/apple/Core --scratch-path
"$NVME_BUILD_ROOT/Core" -j 2` and `node --test
support-agent/tests/receiver-capabilities.test.js support-agent/tests/live-tv-guard.test.cjs`.
Compile the generic tvOS target with the documented release commands; physical
remote/focus and live busy/same-channel/free-state checks remain separate gates.
