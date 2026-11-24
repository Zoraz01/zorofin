# Native account picker

## October 17, 2026 cleanup

The shared iOS, iPadOS and tvOS picker uses a simple left-aligned list of avatars,
names and smaller server URLs. Each account is one button without a surrounding
panel, border or ellipsis menu. The address distinguishes the same name on two
servers; it is always taken from that saved connection.

Avatars use the viewer's server photo when available and their initial otherwise.
They render immediately while photos load through the existing account-bound
client. Opening the picker does not fetch library recommendations or start video.
On Apple TV, focus appears around the avatar only, with a small lift that respects
system and app Reduce Motion. The current account has a small checkmark.

**Manage accounts** changes the same list into an editing mode. Choosing an
account there opens Sign in again / Remove from device. Removing still requires
the existing confirmation. Finish editing returns to normal selection. Add
account and Add server stay distinct: adding to the sole saved server goes
straight to its sign-in page; multiple servers offer a choice; a new server
starts with an empty address. Tokens, Keychain persistence and switching logic
are unchanged.

The TV focus scope prefers the current account, or the first saved account at
startup. The full-width header has a focus section so Up from the account list
can reach Done on the right. The footer actions have full-size hit targets and a
visible focus underline. Native remote reachability still requires device review.

## Reference and preview decision

The useful part of Netflix's profile selection is its emphasis on the person:
an avatar, name, direct selection and a separate management action. Zorofin also
needs to distinguish accounts belonging to different Jellyfin servers.

- [Netflix profile switching](https://help.netflix.com/en/node/322532375336036)
- [Netflix profile management](https://help.netflix.com/en/node/10421)
- [TV profile-list and featured-title screenshot](https://www.netzwelt.de/netflix/zusatzmitglied-teilen.html)

Server-specific featured artwork is feasible without a Zorofin backend. A later
increment should use a bounded, cached still from the chosen viewer's authorized
library, preserve the server/viewer cache boundary and remain useful when no
image is available. Shared-device startup must not use another viewer's cached
recommendations before an account is chosen. No bundled server, external catalog
advertising or privileged cross-account metadata is needed.

Actual moving previews are separate: servers may not have playable trailers, and
trailer selection, authentication, muted playback, cancellation and opt-out would
need validation. This cleanup adds neither artwork promotion nor autoplay.

## Validation

- Xcode 27.0 (27A266a): unsigned Debug builds for generic iOS and tvOS devices,
  using the 27.0 SDKs and two compiler jobs, passed.
- All 11 existing saved-server/account-isolation tests passed, including equal
  viewer IDs on different servers, reauthentication, removal and saved selection.
- Build products are under
  a dedicated DerivedData folder (`Zorofin-account-picker`). The NVMe mount and all
  four migrated Xcode symlinks were checked before building. No SYMROOT/OBJROOT
  override bypasses that location.
- The App Intents metadata-extraction warning remains informational; the app
  does not link AppIntents.
- The skill's generic mobile audit recognizes no Swift files, so its empty
  result is not counted as native validation.
- The accompanying in-conversation layout preview uses fictional accounts and
  reserved example domains. Its selection and management interactions are
  visual review aids, not native-device test evidence.
- No simulator, phone installation, Apple TV installation, server change or
  deployment was performed for this increment.

Remaining device checks: navigate every account and footer action with the TV
remote; move Up to Done and back; open and cancel management/sign-in dialogs;
switch two accounts on one server and the same name on two servers; verify long
names, large text, VoiceOver and an unavailable server. Confirm a signed-out
account still reauthenticates on its saved server.
