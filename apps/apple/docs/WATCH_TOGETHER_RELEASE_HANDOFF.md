# Watch together: handoff to the Apple release task

Updated October 27, 2026. The owner approved the Profile-only design and requested
integration into the upcoming iOS/iPadOS and Apple TV release. The web feature
is deployed as module version `5a8d4e1c4043`, preserving the current installed
UI. Asset/configuration readback passed with zero service restarts; playback
testing was skipped. Native release integration belongs to the existing release task.

## Find the implementation without disrupting the release checkout

Repository: `Zoraz01/yams-media-server`.
Feature branch: `codex/profile-watch-together`.
Draft PR: [20](https://github.com/Zoraz01/yams-media-server/pull/20), currently
targeting `codex/group-watch-plan` to exclude unrelated earlier parent changes.
The initial native implementation is commit `e4011c3`; `c2a1d6a` contains later
native state/command fixes alongside web changes. Subsequent commits on the
feature branch include deployment/documentation work, so inspect the latest diff.

```sh
git fetch origin codex/profile-watch-together
git show origin/codex/profile-watch-together:apps/apple/docs/WATCH_TOGETHER_RELEASE_HANDOFF.md
git diff origin/codex/group-watch-plan...origin/codex/profile-watch-together -- apps/apple
```

Keep the release task's current branch and work intact. Compare/import the native
changes or resolve a deliberate merge; do not reset that checkout or blindly
merge all parent/web/operational changes. Preserve existing version/build numbers,
signing, entitlements, privacy declarations, release materials, and newer fixes.
Read the release checkout's `AGENTS.md` and its current Apple release documentation.

## Approved behavior

- **Profile → Watch together** is the only entry on both platforms, after Quick
  Connect and before Display. Use a regular Profile destination, not an overlay
  on the library or video. No extra Home, title-page, or player group controls.
- Show available groups and Join, or Start a group with a group-name field.
  After creation, Browse library returns to normal browsing; the existing Play
  action chooses the group media. Joining follows the existing group's queue.
- An active group shows its name, participants, Continue watching, and Leave
  group inside Profile. Closing playback retains membership but releases the
  device from the group's waiting barrier. Leaving restores solo behavior.
- Use the signed-in Jellyfin server/account and standard SyncPlay REST and
  WebSocket messages. No Zorofin server extension, custom room backend, fixed
  server address, account signup, invitation service, or Apple SharePlay.
- Ordinary Jellyfin servers are the target. Other clients on the same server
  can interoperate only if they implement SyncPlay; this is not universal native
  Jellyfin app support and has not been verified by a mixed-client playback test.

## Native files to integrate and review

- `apps/apple/Core/Sources/ZorofinCore/SyncPlay.swift`: group/queue/command types,
  create/list/join/leave and playback requests, UTC clock exchange, authenticated
  same-server socket, redirect rejection, bounded messages, heartbeat support.
- `apps/apple/Core/Sources/ZorofinCore/Models.swift`: optional `syncPlayAccess`
  in `ViewerPolicy`, retaining compatibility with older stored viewers.
- `apps/apple/App/WatchTogetherModel.swift`: device/session-scoped group state,
  socket acknowledgements, permissions, queue changes, scheduled commands,
  readiness/buffering, clock offset, drift correction, and cleanup.
- `apps/apple/App/WatchTogetherView.swift`: Profile group-management screen.
- `apps/apple/App/AppModel.swift`: group model installation/reset with accounts.
- `apps/apple/App/Shell.swift`: Profile entry, ordinary navigation destination,
  browse request, and incoming group-playback presentation.
- `apps/apple/App/NativePlayer.swift`: AVPlayer group adapter and command intent,
  remote-command feedback suppression, panel/background pauses, rate restoration,
  queue transitions, and cleanup. No new visible player controls.
- `apps/apple/Zorofin.xcodeproj/project.pbxproj`: references/build membership for
  the two new App files. Integrate these narrowly; the generator can rewrite
  unrelated project/plist formatting and release settings must be retained.

Group playback follows the server queue. Local per-viewer automatic-next-episode
expansion is suppressed while grouped to avoid conflicting queues; explicitly
choosing an episode changes the group queue. Server-provided multi-item queues
advance using NextItem.

## Apple TV work still required

The Profile row is currently inside `#if os(iOS)` in `Shell.swift`. **Apple TV
does not expose Watch together yet.** Shared model/player code exists, but do
not label tvOS support complete without enabling its Profile entry and adapting
the destination to the current TV navigation/focus system.

Use the release's existing 10-foot typography, action targets, visible focus,
D-pad flow, and remote Back behavior. Keep group management within Profile and
restore focus when returning. Check the create/name-entry, empty/error, group
list, participant, and leave states for TV composition; do not add player badges
as a shortcut around Profile navigation.

## Validation and release boundary

Swift core and iOS simulator-target compilation passed in the feature task.
The owner declined testing here: no automated tests, simulator launch, device
installation, or live/mixed-client playback trial was performed. tvOS compilation
and physical remote acceptance were not performed in this feature task.

Compile both release targets after integration and preserve the release task's
existing acceptance/authorization decisions. Keep omitted checks explicit;
source, builds, screenshots, and the web deployment do not establish native
synchronization, device behavior, TestFlight, or App Store acceptance.
No iOS/tvOS archive/upload or distribution was performed by this task.

The portable build commands and web deployment/rollback procedure are in
[`docs/GROUP_WATCH_PLAN.md`](../../../docs/GROUP_WATCH_PLAN.md). Update the
release task's existing validation record when integration/build work is done.

## Release integration follow-up — October 27, 2026

The feature history is integrated into `release/zorofin`, preserving the current
release settings and player sizing gesture. Profile now exposes the destination
on tvOS with TV typography, focus grouping and layered Back behavior. Both generic
device Release targets compile with Xcode 27.1; no simulator/device was launched.
Physical iOS and Apple TV synchronization/input validation remains pending.
See the combined release record for
reproducible build/web tests, integration boundaries and current evidence.
