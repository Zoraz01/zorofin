# Current UI contract

The owner confirmed on October 16 that the current UI update was made for the
native conversion. Preserve it. Baseline: `codex/zorofin-ui-implementation` at
`d7ff866`, browser release `f799e97b15fb`. Root documentation's older navigation
is superseded for this work. Browser reference inspection was read-only; no
playback, account setting or request was changed.

## Apple TV contextual menus — November 3, 2026, build 43

- Size options to their content up to the scrolling height cap. Keep the header
  at the top without a fixed-height blank area; use one Audio/Subtitles selector
  without repeating the selected category as a heading.
- Initial focus belongs to the current track/quality, season dropdown, channel
  search, or Playback info content. Fall back to a useful first option when the
  stored selection is absent. Close remains reachable; Back still dismisses.
  Request focus once when content is ready, not after every selection change.
- Use a native season dropdown on both platforms, shared between details and
  the player. Opening it must not expand the episode panel or start playback.

- Preserve native AVKit transport. Use separate Audio & subtitles, Quality and
  Playback info actions for on-demand video; omit the app's track action on Live
  TV. Hide playback speed in both modes; preserve native enhanced-audio controls.
- Compact options sit above the native transport using its unobscured-content
  guide with an 8-point gap and no screen-height minimum. Episodes span the available width within TV edge
  margins, with a season chooser and short artwork carousel. Keep focus, scrolling,
  selection and Back/Close accessible. Library/detail cards retain their layout.
- The avatar opens an anchored account switcher, not a settings-shortcut list.
  Show real saved viewers directly, with the current viewer checked and server
  labels to distinguish accounts. Reuse the existing authenticated account-switch
  operation; expired sign-ins use the saved-account recovery flow. Cancel pending
  switches when dismissed; account changes reset the shell by generation.
- Below accounts, keep Change server, Quick Connect and permitted Watch together.
  Pin Settings at the bottom. Other settings/admin/legal options stay on Settings.
  Return focus to the avatar on Close and the preceding tab on Settings Back.
- Apple track-button visibility is system-controlled: subtitle filtering does not
  guarantee icon removal. Keep subtitle Off functional and do not force captions
  or modify private AVKit views to hide controls.
- Builds/install evidence is separate from physical navigation/playback
  acceptance. The owner authorized direct device installation and testing for 1.2;
  see the release handoff for current results.

## App ratings

- Profile includes Rate Zorofin on both platforms. iOS opens the App Store review
  link; tvOS opens the product page because StoreKit's in-app review API is
  unavailable there. Never render a custom star selector or preselect a rating.
- iOS may request Apple's standard prompt after returning from playback: at least
  three sessions with five minutes of active foreground playback, seven days of
  use, once per marketing version and at least 120 days between requests. Skip
  demo, playback errors, background scenes, other presentations and active Watch
  together. Keep only device-local counts and request dates, without media or
  account details. Apple decides whether the prompt appears; no result is inferred.

## Live TV guide

- Live TV opens the native channel/time guide. Keep the TV channel column and
  half-hour header visible, show a quiet current-time line, and preview the
  focused program without opening video. Short programs remain correctly timed;
  full titles and schedules are available in details.
- Use a vertical agenda on narrow windows or at accessibility text sizes. Keep
  channel search, favorites, date selection and Now visible with native controls.
- Program selection opens details; Watch live is an explicit action for the
  channel's current broadcast. Do not imply future-program playback or DVR.
- Missing schedules and failed reads are different states. Preserve channel
  access when guide reads fail, and never fill gaps with invented program data.
  See [the guide contract](LIVE_TV_GUIDE.md) for API/isolation and validation.

## Shared design

| Token | Current browser value | Native interpretation |
| --- | --- | --- |
| Shell background | `#111513` | Full-screen graphite/green background |
| Panel | `#1b211e` | Cards and contained settings |
| Border | `#39423c` | Subtle structural separation |
| Text | `#f5f7f5` | Primary text |
| Muted | `#bbc5bd` | Metadata |
| Jade | `#72e79b` | Section accents, states and profile identity |
| Avatar | `#24543e` / `#e6ffef` | Single initial in a circle |
| Typography | Inter with system fallbacks | Bundle official Inter; support readable text sizes |
| Shapes | Capsule navigation/actions; rounded artwork | Preserve silhouette and spacing |

The home hero has a **white** Play pill. The detail page has a wide **green**
Play pill. A series hero resolves the signed-in account’s next/resumable episode
before opening playback; a series or season record must never be sent as a video.
Direct movies/episodes retain their own resume position and track choices.
Do not flatten the Home and detail actions into a single style. Artwork is content,
not decoration: preserve poster versus landscape distinctions.

## Connection flow

New connections use two separate pages: server URL and **Next**, followed by
account sign-in after the server responds successfully. Keep the selected
server visible on the sign-in page, with native Back and Change server. Password
and Quick Connect controls must not appear on the server URL page. Keep pending
network operations cancellable, and clear entered credentials when changing
servers. Existing saved-session restoration is unchanged in this increment.

The server field starts empty and accepts a bare hostname using HTTPS. Zorofin
is presented only as a client: no suggested server, hosted-account copy or signup
link. The local HTTP opt-in appears for explicitly entered HTTP addresses;
public servers still require HTTPS. A bare local-network address with no
scheme (for example `192.168.1.20:8096`, a `.local` name, a Tailscale
`100.64.0.0/10` address or an IPv6 unique-local/link-local address) tries HTTPS
first and, only if that cannot connect, retries once over HTTP. The sign-in
page then shows the `http://` address that was reached. Saved-server reauthentication retains the
user's selected address. After sign-in, capabilities advertised by that server
control Requests, Support, Notifications and optional rows/settings. There is
no setup toggle for advertised extras and no hostname-based feature selection.
The planned optional direct Seerr connection is separate from this automatic flow.

Home has no persistent refresh-app/library button. A failed load may offer Retry.
This applies to compact, expanded and TV Home layouts.

## Phone and iPad

- Zorofin floating capsule: **Home, Search, Requests, Profile**.
  Current builds omit Requests unless the server advertises it. The planned
  [direct Seerr provider](SERVER_COMPATIBILITY.md#optional-native-seerr-connection--implementation-decision)
  may also supply Requests after explicit optional setup in Profile. Plain Jellyfin
  requires no Seerr setup and uses Home, Search and Profile.
  Keep 48-point minimum targets and position it above the home indicator.
  Use a bottom safe-area inset so its measured height reserves space throughout
  the app; avoid overlay-only navigation and fixed 110-point spacer workarounds.
  Accessibility text sizes may require a larger dock instead of clipping labels.
- Each screen owns its header; no fixed shared brand/server bar on iPhone/iPad.
  Home has one scrolling header: approved image-only logo at left, then Support,
  Notifications and Search at right. No duplicate Home title or customize button.
  Movies, Shows and Live TV category pills lead to their own catalogue screens.
  Portrait hero with artwork, bottom title/metadata, white Play and circular
  detail/favorite controls.
- Home includes Support/headphones and Notifications/bell only when the connected
  server advertises support and reply notifications. The jade badge counts unread
  replies for this account. Keep 48-point touch targets. No Home refresh button.
- Support opens an issue report sheet; send only on the user's explicit action.
  Confirm receipt with the returned ticket reference. Uncertain delivery must
  not automatically retry. Notifications lists unread support replies with an
  explicit Mark as read action; merely opening the list does not acknowledge it.
  Poll only in the foreground. APNs push and other notification types are separate
  work. Clear drafts, replies, capabilities and pending work on account changes.
- Pin populated rows in this order: Continue Watching, My requests, Live TV.
  Mix remaining rows with a 3-to-1 selection weight for deliberate shelves over
  generated ones. Preserve their order while browsing; append new pages without
  reshuffling existing rows. Landscape Continue Watching (no separate Next Up),
  portrait library shelves; jade section marker, white heading. Never make trailers autoplay as a side
  effect of browsing.
- Movie detail: poster on the left, title/metadata on the right; green full-width
  Play underneath; equal-width labeled Favorite, Watched and (when resumable)
  Start over buttons with 12-point gaps. At larger text sizes these actions stack
  into full-width rows. Audio and Subtitles use full-width bordered controls with
  an always-visible label, selected value and menu indicator. Never rely on the
  system menu picker's hidden label. Season selection uses a compact named dropdown shared with the player.
  Follow with tagline/synopsis, cast and one More Like This heading. Keep a Back
  control above the content. Detail actions and track rows share a 760-point
  maximum width on expanded layouts, and all controls have at least 48-point
  touch targets.
- Episode detail: landscape still and episode title; preserve series/season
  context. Series, season and episode pages share Seasons & episodes, with a
  jump button near playback actions. Start on the current episode/season, or the
  most recently played season for a series (using its season number if its ID is absent/stale, then first regular season). Include
  Specials. Center the current episode, including when it is beyond page one.
  Horizontal 16:9 thumbnail cards show episode number/title, runtime, synopsis,
  Current/Watched state and watch progress. Episode cards are flat, with no permanent card border; only remote focus has a ring. Detail cards open episode details;
  selecting a season never starts playback. View series returns to show details.
- The player exposes Episodes beside its close/control buttons. Opening it pauses
  playback; Close returns to the previous playing/paused state. Choosing another
  episode explicitly plays/resumes it after reporting/cleaning up the old session.
  Browsing seasons never changes the playing episode. Player controls retain
  compact 48-point phone targets; large text uses an accessible icon for Episodes.
- Season/episode pages use account-scoped metadata/artwork caches, paged lazy
  cards, explicit retry and More episodes. Cancelled or superseded requests cannot
  overwrite the current season. Returning to an interrupted browser resumes its
  selected season; playback/watch-state revisions refresh its metadata.
- Search owns its title and one search field. Avoid a duplicate wordmark/header.
  An empty or whitespace-only query shows Recommended with tappable movie/show
  poster cards, using the existing artwork cache and detail navigation. Typing
  immediately replaces recommendations with debounced library search results;
  clearing the field restores the retained recommendations. Never mix recommendation
  cards or a previous query's matches into typed results. Requests remains separate.
- Profile follows the current live `#/mypreferencesmenu` (checked October 16):
  a 64-point rounded-square gradient avatar beside the 28-point viewer name;
  no extra Profile heading or connection panel. Use 28-point horizontal margins,
  53-point minimum rows, green icons and subtle bottom dividers on phones.
  Order: Servers & accounts, Account, Quick Connect, Display, Your teams,
  Playback, Subtitles, Controls, then Storage & app. Viewer preferences use native
  pages; the web-only Enhanced settings link is removed. Your teams is capability-gated; native Home rows otherwise apply
  automatically with no customization menu. Administration adds
  Dashboard and Metadata Manager only after fresh authenticated permission
  evidence for the same viewer. Advertised admin Account approvals, Support,
  Notification settings and Notifications follow; end with Sign Out.
  All optional rows remain capability-gated. Do not infer
  administration rights from the username, server address or cached session.
- Profile Quick Connect authorizes the entered six-digit code for the current
  account only on an explicit tap. Account, Display, Playback, Subtitles, Controls,
  Storage & app and advertised notification settings are native, with explicit
  Save, busy/error states and discard confirmation. Account preferences stay on
  the selected server; device preferences persist per server/viewer. Support and
  Notifications reuse the Home flows. On iPhone/iPad, Dashboard opens the server's
  full Jellyfin web UI in a full-screen, ephemeral browser. Its separate Quick
  Connect login never shares the native token and is revoked on dismissal; servers
  without Quick Connect show in-app sign-in. Navigation stays on the selected
  server/base path. Metadata Manager and Account approvals remain native. Recheck
  admin permissions on open and on return to the app. Server/account changes
  dismiss administration. Apple TV points administrators to the iPhone/iPad app.
  See [Native settings](NATIVE_SETTINGS.md) for each control's behavior and limits.

## TV layouts

- TV: profile control at the left, centered **Home, Movies, TV Shows, Live TV,
  Requests** navigation, search/support/reply utilities and wordmark as space
  allows. Zorofin keeps its included destinations; generic servers hide unavailable
  extras. The selected destination is a white pill. Focus gets its own clear
  outline/scale, distinct from selection.
- TV shelves scroll horizontally with native focus; the page scrolls vertically.
  Returning from details restores the focused card. Remote Back unwinds the
  current screen/player before leaving the app.
- Hero and details use a wide artwork/text composition with safe screen margins.
  Focused artwork must not be clipped by the row container.
- Expanded iPad uses the wide navigation/composition adapted to touch; it does
  not pretend to be a remote-driven television.
- Expanded Profile has a centered 720-point content column, rounded panel rows
  with 8-point gaps and 58-point minimum heights. TV uses at least 66-point rows,
  24-point labels and an explicit focus outline; retain the same menu order.

## Navigation motion

- iPhone/iPad dock presses compress immediately, then spring back. The selected
  capsule travels between tabs, and the selected icon lifts slightly with a small
  bounce. The Home tab remains selected inside Movies, TV Shows and Live TV.
  Labels and touch targets keep their layout; selection does not wait for an
  animation to finish. Retapping the active tab keeps the existing root identity.
- Apple TV navigation uses a small spring lift on remote focus and compression
  on Select. A jade focus ring with a dark gap remains distinct from the white
  selected destination. Moving focus does not change the destination; Select does.
  Profile, Search and server switching share the navigation press/focus feedback.
- Screen changes use a short fade and 8-point phone / 12-point TV entrance. The
  screen spring is deliberately quieter than the dock; no full-screen zoom or
  swipe. NavigationStack, library caches, scroll-position storage and playback
  ownership are unchanged. There are no animation timers, delayed navigation or
  extra fetches introduced by the motion layer.
- Either system Reduce Motion or Profile → Display → Reduce motion removes the
  spatial effects and transition. Selection, press dimming and TV focus outlines
  remain visible. Animation constants live in `NavigationMotion` in `Theme.swift`.
- Reference: Apple's [spring animation](https://developer.apple.com/documentation/swiftui/animation/spring(duration:bounce:blendduration:)),
  [matched geometry](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:))
  and [accessible appearance](https://developer.apple.com/documentation/swiftui/accessible-appearance).

## Parity accounting

Visual similarity and feature completeness are separate acceptance checks.
Track each feature as implemented, fixture-tested, real-server-tested and
physical-device-accepted. Empty optional-service states must clearly say what is
available; do not present nonfunctional buttons as finished features.

The full target includes Requests discovery/activity, curated recommendations,
Live TV guide/events, support and reply notifications, announcements, recaps and
account preferences. The initial Apple implementation can establish core
viewing first, but must record omissions rather than silently substitute a
generic media-client design. Normal playback uses the AVKit adaptation. The
[custom player candidate](CUSTOM_PLAYER.md) has a desktop parity inventory,
interaction contract and opt-in Debug implementation; it is not the default.
The offline development preview is available under Profile → Storage & app.


### Live TV custom-player candidate

The custom player shares Zorofin's cinematic controls on iPhone/iPad and TV.
Show the channel and verified current programme; Channels & guide adds the next
programme and searchable channels. Browsing channels leaves the broadcast running.
Selecting another channel releases the current owned stream before opening another.
Live playback stays at 1×. Track/quality changes reconnect at live and say so.

Use an actual moving seekable window for rewind, a behind-live timestamp and Go
Live. A programme's start/end time is wall-clock context, never a rewind range or
permission to start over. No measurable window means no timeline or skip buttons.
Debug settings expose an offline Live TV preview and a comparison switch that
defaults on. Release always uses the custom player following the owner's
October 22, 2026 approval; its selection does not depend on the Debug preference.

## Approved player and Requests refinement — October 23, 2026

The player uses the approved Cinema overlay: opaque full-width options, two flat
Audio/Subtitles columns in wide layouts and stacked columns for narrow/accessibility
layouts. Selected tracks use a leading jade checkmark and stronger text. Additional
track metadata is retained only to distinguish same-language variants. Quality
offers supported ceilings up to 40 Mbps; playback information uses real runtime
facts. There are no speed controls in this overlay.

Track/quality selections are staged together and applied on returning to playback,
preserving absolute position and play/pause intent. Backgrounding clears automatic
resume intent. TV Back closes the nearest season list/options layer first. A season
choice restores focus to its pill; controls behind the overlay are disabled.
The shared episode browser uses episode-specific 16:9 artwork, short descriptions,
runtime and a thin jade progress line. Season browsing itself never starts playback.

Requests uses Split seasons and one request type, without a Standard/4K choice.
Available seasons have watch actions, existing requests have explicit statuses,
and missing seasons have checkboxes. Current status opens inline and refreshes
quietly. Discovery includes the viewer's own request-status preview. See
[Requests behavior](NATIVE_REQUESTS.md) for receipt and retry semantics.
