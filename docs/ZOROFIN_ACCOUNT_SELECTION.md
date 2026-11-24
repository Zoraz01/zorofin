# Saved accounts and account selection

Native implementation update, 2026-10-17: the owner requested multiple-server
support and easy switching. See the [Apple saved-server implementation and
validation](../apps/apple/docs/SERVER_SWITCHING.md). The broader browser and
third-party-wrapper flow below remains a design proposal.

Status: design proposal awaiting owner approval. No account-switching feature or
production deployment is included in this change. Prepared 2026-10-16.

## Product decision

Keep the current Zorofin interface, palette, wordmark, phone dock and TV
navigation. Add a device-local account chooser and account management to the
existing Profile destination. This selects independently authenticated Jellyfin
accounts; it does not create unauthenticated profiles beneath one account.

Zorofin is the product name. The owner intends to publish the apps through
**Vitality Labs**. This is distribution context only: do not add a publisher
label, footer, splash screen or other publisher branding to the app. Store
enrollment, signing-team identity and production identifiers remain release
configuration work.

## Server-first entry and client boundary

Owner clarification, 2026-10-16: server selection/connection comes before account
sign-in. There is no separate global Zorofin account or Vitality Labs sign-in.
The account is authenticated by the selected Jellyfin server.

The proposed fresh-launch order is **server -> account -> Home**. Show an entered
or saved server first and let the user continue without retyping its address.
Verify the server before exposing username/password or Quick Connect. Keep its
name/address visible on the account step, with Change server available. Never
carry credentials or saved account choices across different server identities.
Normal navigation and brief background returns do not restart onboarding.

The public Zorofin URL selects the complete hosted-service experience. Requests,
support and notifications are included automatically after sign-in; viewers do
not enable integrations, configure Seerr or install a plugin. The URL step may
prefill the Zorofin address while remaining editable for other Jellyfin servers.
An outage does not remove the Requests destination or require viewer setup.

Other servers keep generic Jellyfin onboarding unless the owner later installs
and configures the future Zorofin backend/extension. That distributable extension
has not been developed yet. Its future capability contract does not gate the
hosted Zorofin experience. URL recognition selects product defaults only; the
server still authenticates accounts and authorizes actions.

Preserve the current desktop/mobile Zorofin website. Web-based Jellyfin clients
that load those server assets may expose the same supported integrations;
validate each wrapper's storage and behavior. Independently rendered clients
such as Swiftfin need their own integration and cannot inherit native features
from a server URL alone. No separate web-asset isolation rollout is required by
this clarification. The account-picker proposal still covers supported web and
native surfaces, with the existing approval gate for implementation/deployment.

A Zorofin app can connect to an ordinary Jellyfin server. Core viewing uses
standard APIs; server-dependent extras appear only when that selected server
supports them and the signed-in account has permission. Opening the app cannot
install server plugins, create integrations or grant extra account permissions.

The Apple client now separates new-connection setup into a server URL page with
Next, followed by sign-in after a successful public server-information check.
Back/Change server cancels pending authentication and clears entered credentials.
Existing saved-session restoration is unchanged. The earlier interactive preview
depicts the account step only; the broader saved-account launch gate still awaits
implementation. Native server-feature detection, support reports and in-app
support replies are implemented locally; see the Apple validation record. Home
has no persistent refresh button; a failed library load can still offer Retry.

## Entry and switching

| Situation | Proposed behavior |
| --- | --- |
| Fresh launch / new server | Show server connection/selection first, then only that server's saved accounts or sign-in |
| One valid account saved for the selected server | After the server step, open that account's Home |
| Two or more accounts saved for the selected server | After the server step, show **Who's watching?** |
| Only account saved for the selected server needs authentication | After the server step, open sign-in for that account |
| Returning briefly from background or navigating between pages | Keep the active account; do not interrupt playback with a chooser |
| Profile > Switch account | Open the chooser, with a way back to the current account |
| Expired or revoked session | Mark that account **Sign in again** and reauthenticate it |
| Server unreachable | Keep the saved accounts and offer Retry; an offline server is not evidence of an expired password |

Only accounts successfully added to this device/browser appear. Do not list all
server users, even if a server endpoint exposes public usernames. A saved record
without a usable token still counts as a configured account and appears with
**Sign in again**. Last used is a subtle hint, not an automatic selection when
multiple accounts are configured for the selected server.

The browser must treat reload as continuation of an active tab, not a new visit.
Define and validate that behavior against the actual Jellyfin client lifecycle
before implementing the gate. Switching in one browser tab must not silently
attribute another tab's playback or requests to a different account.

## Screens

- **Phone:** full-height chooser with large avatar/name rows, then Add account
  and Manage accounts. Use the current floating Home/Search/Requests/Profile
  dock once an account is active.
- **Desktop:** centered avatar choices with name, last-used or sign-in status,
  and an Add account tile. Keep existing signed-in navigation.
- **TV:** larger avatar choices and visible native focus. Quick Connect is the
  first sign-in option; password entry remains available. Native directional
  focus and Back behavior must work without a pointer.
- **Profile:** current identity followed by Switch account, Add account, Manage
  accounts and Sign out. These extend the existing Profile screen.
- **Manage accounts:** saved identities and Remove actions. Confirm removal with
  wording that it affects only this device, not the server account or library.

The interactive design preview uses fictional Ava, Sam, Riley and Jamie
accounts. Its Home and playback areas are context only. No credentials are sent
and no server accounts are changed by the preview.

## Adding an account

1. Choose Add account from the chooser or Profile.
2. Confirm or choose the server first; then sign in with an existing account on
   that server using username/password or Quick Connect. Creating a new server
   user is a separate owner/invitation flow, not an implicit Add account action.
3. Keep **Keep this account on this device** explicit and checked in this
   proposed flow. If unchecked, use the account for this visit only.
4. Save a successful session, then enter that user's Home. Adding the same
   server/user again refreshes its sign-in instead of adding a duplicate.
5. Cancel or failed authentication preserves the previous active account and
   every other saved account.

For Quick Connect, show the server-issued code and ask the user to approve it
from a device already signed in as the intended account. Never accept a public
username alone as authentication. If Quick Connect is disabled or unsupported,
offer password entry. Cancel polling when the screen closes; handle code
expiry with a fresh-code action. Do not persist the code or temporary secret.
If approval returns a different identity during reauthentication, explain the
identity and require an explicit choice before replacing the active account;
do not overwrite the selected user's saved record.

## Sign out and removal

**Switch account** retains saved sign-ins and does not log every account out.
**Sign out** removes this account's usable local credential and attempts to
revoke its device token, keeping a name/avatar placeholder marked Sign in again.
If revocation cannot be confirmed, clear local access and explain that outcome.
**Remove from device** clears the saved record and secret, and attempts scoped
revocation. Neither action deletes the server user, media or watch history.
Other saved accounts remain available.

The chooser is a convenience on a shared device, not a new parental-control
boundary. A local cosmetic PIN would not enforce server permissions; PIN/biometric
locking is outside this proposal.

## Account isolation requirements

Before displaying the next account's library:

1. End the old playback session with its original identity and report final
   progress. Close only live streams owned by that session.
2. Cancel old account requests, image tasks, polls and subscriptions. Reject
   late responses using an account/session generation identifier.
3. Clear user-specific in-memory UI and image caches, search state, requests,
   support replies, recommendations, announcements and recap state.
4. Activate and validate the chosen account, then load its own Home. No frame
   may show the previous user's private rows while loading.

Key saved identities by canonical server origin/base path plus Jellyfin user
ID, never display name. Maintain stable, correctly scoped device identity and
test token issuance/revocation behavior for two users on the same device.
Never save passwords. Mask tokens and private URLs in logs and errors.

### Native Apple clients

Replace the single-session Keychain slot with per-account records and migrate
the existing valid session without forcing a logout. Keep one explicit active
account reference and a separate non-secret account index. Migration must be
recoverable and must not delete the legacy record before the new record is
verified. Authentication failure for one account cannot erase another account.

### Browser and web-based clients

Integrate with the deployed Jellyfin client's ConnectionManager/session storage
contract rather than maintaining competing active tokens. Audit cross-tab
behavior before selecting the storage strategy. Browser storage has the same
origin trust boundary as existing remembered sign-in; it is not equivalent to
Keychain. Do not claim that encryption with a key stored alongside the token
protects against scripts running in that origin.

Respect explicit remembered-account choices, standard server permissions,
logout semantics and account-scoped extension requests. Verify the actual
storage and cache behavior of each supported wrapper/version.

## Platform coverage and limits

| Surface | Planned integration and evidence needed |
| --- | --- |
| Native Zorofin iOS/iPadOS | Own SwiftUI chooser and Keychain migration; simulator tests then physical-device acceptance |
| Native Zorofin tvOS | Same account model, TV composition, Quick Connect and native remote focus; hardware acceptance |
| Desktop and mobile Zorofin browser | Shared customized web UI with responsive layouts; narrow viewport and cross-tab tests |
| Jellyfin Mobile for iOS | Retain its account flow; verify server-delivered Zorofin web integrations and account switching in the wrapper |
| Other Jellyfin web-based apps | Test supported server-delivered features, storage and account switching in each wrapper |
| Swiftfin and other independently rendered native Jellyfin clients | Own their UI; Zorofin features require an explicit client integration |
| Future Zorofin LG webOS app | Reuse the TV flow/contract; validate packaged-client storage, remote focus and server integration on actual hardware |

Sources checked on 2026-10-16:

- [Jellyfin Web](https://github.com/jellyfin/jellyfin-web) identifies its browser
  and mobile-client frontend roles.
- [Jellyfin iOS FAQ](https://github.com/jellyfin/jellyfin-ios) distinguishes the
  web-wrapper Jellyfin Mobile client from Swiftfin.
- [Swiftfin](https://github.com/jellyfin/Swiftfin) documents its native iOS/tvOS
  client, which owns its UI independently.
- [Jellyfin Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/)
  documents authorization from an already signed-in supported client.

## Implementation and release gates

Owner approval applies first to the chooser, add/sign-in and account-management
flow. Implement native account storage and shared web integration in scoped
feature commits after design approval. Do not deploy this proposal.

Acceptance must cover server-first entry, changing servers, account-list and
credential isolation between servers, server capabilities and account permissions,
zero/one/multiple accounts; valid/expired/revoked/offline
sessions; duplicate adds; cancel and failed sign-in; session-only access; migration;
removing the current and another account; signout isolation; restart persistence;
late responses; old-user image/cache removal; playback progress attribution;
Quick Connect cancellation/expiry/wrong-user approval; and browser tab isolation.

Verify phone at 320px and larger, desktop layout, keyboard and screen reader
labels, Dynamic Type, reduced motion, and TV remote focus/Back. Client build
success does not establish physical-device or third-party-client compatibility.
Use test identities and staging before approved production rollout, preserve
the running media services, and retain a rollback path.
