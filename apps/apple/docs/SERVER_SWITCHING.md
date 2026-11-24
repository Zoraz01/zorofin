# Saved servers and accounts in the Apple app

Implemented on `codex/zorofin-server-switcher`, 2026-10-17, following the owner's
request for multiple servers and easy switching. This is native Apple client
work; the broader browser/Jellyfin-wrapper account-picker proposal still needs
its own approval and implementation. No media-server rollout is required.

## Viewer flow

- On iPhone Home, tap the server icon beside Search. On iPhone, iPad or Apple TV,
  open **Profile > Servers & accounts**. Apple TV also has a header shortcut.
- **Your servers** groups saved viewers under the server name and full address.
  Tap a viewer to validate that saved login and open their library. Switching
  retains the other saved sign-ins. The current account is marked explicitly.
- **Add server** opens the existing URL page, then **Next**, then sign-in or
  Quick Connect. **Add account** under a server pre-fills that address but still
  verifies it before showing sign-in. Cancel or failed login keeps the current
  server and saved accounts unchanged.
- **Keep this account on this device** is checked by default. Unchecking it
  leaves that new sign-in in memory only, while preserving other saved accounts.
- Cold launch restores the last server when it has one saved account. If that
  server has multiple saved viewers, or there is no active saved sign-in, the
  chooser appears. Normal background/foreground transitions keep the active
  viewer and do not interrupt playback.
- An expired saved token becomes **Sign in again**. An unreachable server keeps
  its token and shows a retryable error. The account menu also offers explicit
  reauthentication. Reauthentication on the same server must return the selected
  user ID, including Quick Connect; another user must use Add account.
- **Sign Out** clears only the current saved credential, retaining its name as a
  sign-in-again placeholder. **Remove from device** confirms removal of one
  account record. Neither deletes server users, libraries or other saved logins.

## Storage and isolation

A versioned Codable registry lives in the existing device-only Keychain item.
It contains server URLs, viewer metadata, tokens and one optional active ID.
Passwords and temporary Quick Connect secrets are never persisted. A single
atomic Keychain update commits both the registry and active selection before
changing the visible session. Failed writes preserve the previous in-memory
selection and the old stored item. Failed reads block writes and offer Retry.

The legacy single-session payload is decoded without changing its token or
Jellyfin device ID. Migration is read-only until the next successful Keychain
update; the legacy item is never deleted ahead of a replacement write.

Identity is canonical server origin plus base path plus Jellyfin user ID.
Default ports and a trailing slash do not duplicate accounts. Distinct paths,
nondefault ports and different users remain separate even if names/IDs match.
Each added login flow has a separate Jellyfin device ID; switching reuses the
stored one, so one account's logout does not intentionally revoke another's
session. The server remains responsible for authentication and permissions.

Switching creates a new client and artwork cache, resets features, Home revision,
streaming quality, support drafts and replies, and replaces the navigation tree.
Async account work is fenced by session generation and view cancellation. Playback
retains its original client/reporter for final progress and owned-stream cleanup;
the chooser is not presented over the full-screen player. Server capabilities
are rediscovered; names such as "Zorofin" never grant optional capabilities.

All token-bearing requests stay bound to the selected server, including its
base path. No production credentials are needed to build or test this flow.

## Validation

- Swift core: 65 tests in 7 suites passed, including 11 saved-server tests for
  legacy migration, restart serialization, duplicate URLs, server/base-path
  separation, independent account tokens, placeholders, removal, visit-only
  selection and malformed storage rejection.
- iOS simulator, signed generic iPhone and tvOS simulator builds passed. The
  signed iPhone app also passed strict code-signature verification. App Intents
  extraction is skipped because the project has no App Intents dependency.
- The unsigned simulator build correctly refused Keychain access. Rebuilding
  with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` supplied the simulator
  application identifier; fixture login and restart persistence then passed.
  Unsigned builds establish compilation only, not secure-storage behavior.
- In one disposable iPhone 17e / iOS 27 simulator, tested two loopback-only
  Jellyfin fixtures with fictional accounts. Confirmed URL-before-login,
  rejected login and cancellation preserving the current account, both saved
  servers surviving app restart, switching without a password, own-library
  content, and an extension-provided Requests tab disappearing on the generic
  server and returning when switching back.
- HTTP 503 kept the current server and both saved credentials. HTTP 401 marked
  only the selected account Sign in again and opened its prefilled server step.
  Two viewers on one server triggered the chooser after a cold launch.
- Account removal required confirmation, removed only the selected viewer and
  sent logout for that viewer. Profile showed the correct server; Sign Out
  retained the current viewer's placeholder. The fixture log recorded 50
  requests, zero foreign-token requests and scoped logout for the two intended
  viewers. No production credentials were used.
- The final signed development build was installed successfully on the owner's
  paired iPhone (`org.zorofin.app`). Installation is confirmed; user validation
  of the actual server, migrated session and playback is still pending.
- The exact temporary fixture process and simulator were stopped/deleted after
  testing. Existing simulators, Device Hub and Docker were preserved.

Physical iPhone/iPad and Apple TV remote/playback acceptance remain release gates.
Storage-write failure injection, real-server multi-user device-token revocation,
wrong-user Quick Connect approval and all playback-switch timing cases still need
integration acceptance. Fixture authentication does not establish those behaviors.
No production server restart, browser-account rollout or store submission was done.
