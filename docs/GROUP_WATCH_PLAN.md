# Group watching: feasibility and return plan

Updated October 27, 2026. Status: web module deployed; native source implementation
on the feature branch with build-only validation. Playback trials were declined
by the owner. No native distribution or store release has been performed. This document contains no private
deployment addresses, user identities, credentials, or usage counts.

## Scope and UI recommendation

Add **Watch together** as an option in web and native iOS using the connected
Jellyfin server's existing SyncPlay infrastructure. The owner clarified that
placement and a simple flow are the main questions, and selected **Profile as
the only entry point** so the feature does not cover browsing or playback.

Withdraw the earlier 3–6 day estimate for this request: it bundled a browser
pilot and broad device qualification. The audience uses browsers, phones, and
TVs, but qualifying every TV client is follow-up work rather than a prerequisite
for adding the web/iOS option.

| Surface | Web | iOS |
| --- | --- | --- |
| Profile | **Watch together** row after Quick Connect, before Display; opens group management within Profile. | The same row and order; opens a native Profile destination. |
| While grouped | The Profile row can show the group name; reopening it shows participants and Leave group. | The same state inside Profile. |

All group actions live under **Profile → Watch together**: start, find, join,
view participants, and leave. Use the existing Profile row styling and group
icon, fonts, focus treatment, and 48-point phone targets. Movie/episode details,
Home navigation, and player controls receive no additional group actions,
floating controls, participant badges, or persistent banners.

```text
Profile (web and iOS)
  Quick Connect
  Watch together                                  >
  Display
```

## Group management inside Profile

The Profile row opens **Watch together** as a Profile destination, using normal
content space on web and native navigation on iOS. Back returns to Profile;
group management does not remain over the library or video.

- List available groups with **Join**. Show media/participant details only when
  provided by the existing contract. Joining follows that group's current item;
  it does not replace its current media.
- Show available groups first. Starting an empty group uses the
  existing flow, then returns to the library so the viewer can choose a title.
  No separate media picker is needed.
- Empty list: **No groups right now**, with Start a group available.
- Already grouped: show the group name, participants, and **Leave group** when
  returning to this Profile destination. Do not offer duplicate group creation.
- Disable a pending operation and show errors/Retry in place. Restore focus to
  the initiating control when the surface closes.

After starting a group, return to the existing library and use the ordinary Play
action to choose media for the group. Group membership survives navigation to
the player and back to Profile. Leaving playback and leaving the group are
separate actions: group management remains available through Profile.

## Original feasibility findings, before implementation

| Finding | Evidence and consequence |
| --- | --- |
| The installed server is Jellyfin 12.2.0; existing accounts permit creating and joining SyncPlay groups. | Read-only server/version and user-policy inspection. No broad permission change is needed to begin a pilot. |
| SyncPlay is still installed. | The installed web bundle contains its player, queue, settings, and time-synchronization modules. Presence does not prove working playback. |
| An older customization hides its entry point globally. | `branding/zorofin-live-tv.js`, `isHeaderShortcutLabel()` and `hideHeaderShortcuts()`, hides buttons labelled SyncPlay even outside Live TV. The enabled installed Injector entry contains the same rule. |
| The current Profile integration cannot recover that hidden button. | `branding/zorofin-shell.js`, `headerControls()` excludes `[hidden]`; `profile()` builds shortcuts from that filtered list. The installed core bundle contains these rules too. |
| Existing shell tests miss this combination. | `support-agent/tests/ui-shell-browser.test.cjs` expects a Profile SyncPlay shortcut but does not load `zorofin-live-tv.js`. |
| Native Zorofin Apple clients need additional work. | Source inspection found AVPlayer playback/reporting in `apps/apple/App/NativePlayer.swift` and `apps/apple/Core/Sources/ZorofinCore/`, but no SyncPlay or WebSocket implementation. Restoring a web button cannot enable the native app. |

An isolated offline browser experiment reproduced the control interaction:
shell alone produced one Profile SyncPlay shortcut; shell plus Live TV produced
none, with the native button hidden, in both load orders. All page network
requests were blocked and the temporary browser was closed afterward. This is
DOM behavior evidence, not a live room or media synchronization test.

Two upstream findings remain relevant to focused playback checks: a historical
waiting-state defect was closed as fixed in 12.1, and an episode queue mismatch
was reported with different autoplay preferences on a 12.2 server. These do not
require a new backend or a broad rollout project.
[Jellyfin issue 17864](https://github.com/jellyfin/jellyfin/issues/17864),
[Jellyfin Web PR 8690](https://github.com/jellyfin/jellyfin-web/pull/8690).

## Implementation scope

Use Jellyfin's existing groups, permissions, server APIs, events, and web
synchronization. No room backend, new plugin, invitation service, custom sync
protocol, social system, or SharePlay integration is proposed.

Web exposes the existing room workflow through its explicit Profile destination.
The native global shortcut remains hidden; the Live TV script's suppression can
stay in place because the new row no longer depends on relocating that control.
The scoped module preserves the installed shell/theme and playback engine.

Native iOS source now connects SyncPlay group state/commands to AVPlayer and
playback reporting through a single Profile destination. Native release
integration is pending in the existing Apple release task.
Relevant surfaces are Profile in `apps/apple/App/Shell.swift` and playback
handling in `NativePlayer.swift`, with server handling in ZorofinCore. The player
integration adds no visible group control.

Use the current signed-in account and its permissions. Show controls when the
server/account/player supports them. Do not imply invite-only room privacy or
host-only controls unless the existing server enforces those behaviors.

## Focused verification and delivery

1. Add the web option and verify the combined shell/Live TV scripts no longer
   remove the Profile action. Verify the Profile entry, Back/focus, empty list,
   busy/error states, and leaving. Verify that no group controls or persistent
   overlays appear on title pages, Home, or the player.
2. Add the same flow in iOS and connect it to the existing server protocol.
3. Check one web and one iOS participant creating/joining, starting media,
   pausing/seeking, and leaving. Check a denied operation, failed join, and solo
   playback afterward. Include an episode start/transition before claiming
   episode support. Do not operate another viewer's playback during tests.

Use the existing scoped/versioned release process and preserve rollback. Update
branding/Live TV documentation when behavior is implemented. Broader TV client
qualification, larger groups, and extended reliability runs can follow without
expanding this first change.

## Implementation and continuation record

The approved Profile-only design is implemented in source:

- Web: `branding/zorofin-watch-together.js` and `.css`; the shell mounts the row
  after Quick Connect and uses a query on the existing Profile route for the
  group destination. The versioned UI builder includes these in its core/theme.
  No overlay, new title action, or new player button is introduced.
- Web playback remains Jellyfin's native SyncPlay implementation. A small
  adapter locates the already-loaded core by its exports in the web bundle's
  module registry, without numeric module IDs. It checks the native manager's
  current API client before acting and fails with an in-page error if the
  client contract is unavailable. This client-internal adapter should be checked
  when upgrading Jellyfin web; the group REST/WebSocket protocol is standard.
- Native: `Core/Sources/ZorofinCore/SyncPlay.swift` contains the protocol DTOs,
  APIs, UTC-clock exchange, and same-server socket with authenticated headers,
  no token in its URL, bounded messages, and rejected redirects.
  `App/WatchTogetherModel.swift` handles session-scoped group/queue state,
  scheduled commands, ready/buffering reports, heartbeat, and drift correction.
  `WatchTogetherView.swift` is a normal Profile navigation destination.
- The existing AVPlayer accepts group commands and relays local pause/seek
  intent. Panel/background pauses are kept distinct from group commands. Closing
  the player releases this device from waiting but retains membership; leaving
  or changing account clears group state and restores the solo playback rate.
- Native group playback follows the server queue. Independent per-viewer
  next-episode autoplay is suppressed while grouped to avoid queue conflicts;
  choosing an episode explicitly changes the shared queue. An existing
  multi-item queue can advance using Jellyfin's NextItem contract.
- Permission evidence comes from the current viewer, not optional Zorofin server
  extensions. Ordinary Jellyfin servers and other SyncPlay-capable clients on
  that same server can use the protocol. This is not a claim that every native
  Jellyfin client implements SyncPlay, or that mixed-client playback was tested.

### Reproducible build checks

Use Node.js, Python 3 for project generation, Swift 6, and Xcode with the iOS
SDK. Set a writable build directory outside tracked source. No Codex tool or
private agent skill is required:

```sh
node --check branding/zorofin-watch-together.js
node --check branding/zorofin-shell.js
node --check tools/build-ui-release.cjs
git diff --check
swift build --package-path apps/apple/Core --scratch-path "$WATCH_TOGETHER_BUILD_ROOT/core" -j 2
xcodebuild -project apps/apple/Zorofin.xcodeproj -scheme Zorofin-iOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$WATCH_TOGETHER_BUILD_ROOT/ios" -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

The Xcode project already references the new app files. If sources are added
later, its existing `apps/apple/tools/generate_project.py` is the project
generator; review generated changes and retain signing/release settings.

Swift core and iOS simulator-target compilation passed. No simulator was launched,
no user group was created, and no playback or automated tests were run for this
increment, per the owner's request. Runtime interoperability, reconnection on
devices, physical-device behavior, distribution, and store acceptance remain
unverified. A compiled application is not evidence of any of those outcomes.

### Web deployment and rollback

Prefer `tools/deploy-watch-together.cjs` when the installed core/theme has moved
ahead of this feature's parent. It adds one authenticated, content-hashed module
to the installed runtime and preserves the existing native index, Branding,
core, theme, and unrelated Injector entries. The module mounts itself on Profile
and also supports the updated shell hooks. Supply a private persistent runtime
directory for snapshots, outside temporary managed worktrees:

```sh
node tools/deploy-watch-together.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --state-dir "$PRIVATE_ROLLBACK_ROOT"
node tools/deploy-watch-together.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --state-dir "$PRIVATE_ROLLBACK_ROOT" --apply
node tools/deploy-watch-together.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --rollback "$ROLLBACK_DIRECTORY"
node tools/deploy-watch-together.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --rollback "$ROLLBACK_DIRECTORY" --apply
```

Its plan is read-only; apply verifies the served asset before changing the single
entry and checks protected state afterward. Rollback restores only that entry,
preserves concurrent changes to other features, and keeps immutable assets for
open tabs. It does not restart services or create/play a group. For a future full
UI release incorporating the feature in core/theme, retire the standalone
`Zorofin Watch together` entry through a scoped concurrent-state check so two
different versions are not active.

The broader release CLI below is for a deliberately reviewed full core/theme
update, not an alternative way to overwrite a newer installed UI.

Use the existing versioned release CLI from a clean feature checkout containing
current remote main. Provide the deployment's existing web directory, private
operator environment file, and installed UI version through operator-local
values. Do not put their values or credentials in this document.

```sh
node tools/deploy-ui-release.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --from-version "$INSTALLED_UI_VERSION"
node tools/deploy-ui-release.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --from-version "$INSTALLED_UI_VERSION" --apply
```

The first command is a read-only deployment plan. The second snapshots the
configuration, writes versioned assets, checks readback, and records rollback
data without restarting services. Group/user/media policy is unchanged.
Rollback uses the receipt's private snapshot directory and refuses to overwrite
concurrent configuration changes:

```sh
node tools/deploy-ui-release.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --rollback "$ROLLBACK_DIRECTORY"
node tools/deploy-ui-release.cjs --web-root "$JELLYFIN_WEB_ROOT" \
  --env-file "$OPERATOR_ENV" --rollback "$ROLLBACK_DIRECTORY" --apply
```

Native delivery uses the existing Xcode/signing and beta/store release process.
No App Store upload, device installation, or production UI deployment is implied
by this source implementation. Continue from the feature branch, review this
record, and use the commands above; private chat state is unnecessary.

The upcoming Apple release task has a separate
[iOS and Apple TV integration handoff](../apps/apple/docs/WATCH_TOGETHER_RELEASE_HANDOFF.md).
In particular, the iOS Profile entry is implemented, but the tvOS row is still
excluded by `#if os(iOS)` and must be enabled/adapted in that release task.

### Web deployment record — October 27, 2026

- Installed UI version `67a324945f0d` was newer/different from the feature's
  parent. A full core/theme replacement was deliberately not applied.
- Scoped feature version `5a8d4e1c4043` is active through the single authenticated
  `Zorofin Watch together` Injector entry and a served content-hashed module.
- Served bytes and configuration readback matched. Native index, Branding,
  installed core/theme/runtime, and unrelated Injector entries were preserved.
  Services restarted: zero. No active playback was present before or after.
- The first attempt exposed server-added `Src`/`Module` defaults in readback.
  It was rolled back, the deployer was corrected to normalize those defaults,
  and the next attempt completed with verified readback. Private receipts and
  rollback data are retained in the deployment's persistent runtime directory.
- This is asset/configuration deployment evidence. No group was created and no
  live playback or browser interaction test was run. Existing web clients need
  a full reload/reopen to load the new authenticated module.


### Desktop layout correction — October 27, 2026

The owner reproduced Profile administration/support rows above the group page and
an oversized Refresh action. The original browser fixtures did not cover late
shell shortcut replacement or assert compact Refresh geometry. Two root causes:

- The group screen hid only the children present during its last render. Shell
  shortcuts arriving/replacing themselves later remained visible; an unchanged
  group state correctly skipped rendering, so those siblings were never hidden.
- The compact Refresh rule had the same specificity as the generic group-button
  rule and appeared earlier. The later full-width rule won the cascade.

An active mode on the Profile content host now hides every sibling of the group
page, including future shell children. Back/route/account changes restore Profile,
and replacing the native host clears the old mode. Refresh has a more-specific
selector and a non-growing flex size. Creation Back is labeled Watch together,
matching the screen it returns to. No new Home/title/player controls were added.

The regression reproduced the late-shortcut leak before the fix. Chromium and
WebKit pass at 390, 768 and 1440 pixels, both independently and with the real
browsing shell loaded. Checks cover late controls, host replacement, compact
heading alignment, Profile restoration, account permissions, keyboard focus and
existing create/join/leave/recovery behavior. All test browsers close themselves.

```sh
node support-agent/tests/watch-together-browser.test.cjs
WATCH_FULL_SHELL=1 node support-agent/tests/watch-together-browser.test.cjs
node --test tools/tests/watch-together-deploy.test.cjs
```

For an immutable-asset/Injector-only layout update, add `--no-session-inspection`
to the scoped deployment command. This omits `/Sessions` requests and personal
session snapshots/counts; the receipt reports that inspection was disabled rather
than claiming playback-session verification. Core/theme, Branding, index and
unrelated Injector entries retain their existing preservation/readback checks.
No service restart or device interaction is required for this web correction.

Published layout module: **caef3e5b927b**, on installed UI **67a324945f0d**.
Scoped Injector/asset readback and the public-route hash match. Protected web
configuration is unchanged; no sessions were inspected and no service restarted.
Existing browser tabs need a full reload to initialize the corrected module.
