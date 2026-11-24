# Apple TV Home Screen previews

Zorofin supplies a native TVServices **details carousel** when its icon is
highlighted in the Apple TV Home Screen’s top row/Dock. Open the app and select
an account once to populate it. Swipe up from the icon to browse the preview;
press Select to reveal Play and More Info. Play opens playback and More Info
opens the title page.

The carousel uses real landscape artwork, title, synopsis, genre and runtime.
On tvOS versions that omit the separate title header, the synopsis also begins
with the title so every card remains identifiable.
Up to four Continue Watching titles lead, followed by library movies, with a
maximum of eight cards. Duplicate episodes from a series share one slot. Titles
with missing or unsuitable landscape artwork are skipped, rather than stretching
posters or inserting generic placeholders. Apple controls the Home Screen’s
focus, animations, gradients and button labels. This version supplies still
artwork, not automatic trailers or clips from the movie.

## Account and privacy behavior

- Previews belong to the selected **remembered** server/account. Visit-only
  sessions and the fictional app preview do not publish Home Screen content.
- Settings → Display → Home Screen previews can disable them per account on
  this TV. Existing saved settings keep their values; previews default on.
  TV preferences use the app’s private UserDefaults store, with hashed server/
  viewer keys and a 128 KiB payload budget. iOS keeps its existing file store.
  This fixes the physical TV’s Application Support write-permission failure.
- The app’s authenticated Jellyfin transport fetches artwork. JPEG exports strip
  original image metadata. No token, server address, username, media URL or raw
  API response is written into the shared preview cache or action URLs.
- The extension has no access to the session Keychain. It reads a bounded local
  snapshot from the app group, performs no network requests, and never starts a
  transcode just to show a preview. Standard Jellyfin works without an extension
  or Seerr integration.
- Switching accounts, signing out, removing the active saved account, clearing
  the library cache or disabling previews removes the snapshot and requests a
  system refresh. tvOS owns the timing of clearing its rendered image cache.
- Snapshots expire after six hours. Missing/expired caches and signed-out states
  use the packaged static artwork. Home refreshes regenerate previews after
  library loading; there is no background polling or background credential use.
- Actions carry only an opaque local account UUID, item ID and play/details
  choice. The app checks the selected account, refetches the item, and uses the
  current resume point. It never silently switches accounts. A cold launch with
  multiple saved viewers retains the existing account picker first.

## Xcode setup

The existing `Zorofin-tvOS` scheme builds and embeds `Zorofin-TopShelf.appex`.
Both targets use the same development team and the App Group
`group.org.zorofin.app.tv.shared`. Their bundle identifiers are respectively
`org.zorofin.app` and `org.zorofin.app.tv.topshelf`. The TV app now shares iOS's
bundle ID for one App Store Connect listing. The extension and TV-only App Group
retain their existing identities. Signed Release builds and profile entitlements
were rechecked October 22, 2026. Earlier physical results below used the old
`org.zorofin.app.tv` host; install/sign-in/Top Shelf checks on the new host identity
remain for the next device session.

On a fresh signing setup, select the same team for **both** targets in Signing &
Capabilities. Xcode must register the group and include it in both managed
profiles. If the newly created extension profile has an empty group entitlement,
selecting its team in Xcode refreshes the profile. Do not remove the entitlement
or share the authentication Keychain to work around signing errors.

The deterministic project generator includes the extension, app dependency,
embed phase, URL scheme, entitlements and privacy manifest. Regenerating a live
project replaces local Xcode settings/schemes; preserve local signing edits.
Build output belongs on the mounted NVMe. Do not replace the existing Xcode
storage symlinks.

## Acceptance checks

- [x] Swift tests: URL validation, snapshot expiry, bounded/safe artwork paths,
  missing/symlink artwork, cache replacement and clearing, ordering/deduplication,
  and decoding older native settings.
- [x] Signed tvOS app and embedded extension build with Xcode 27 / tvOS 27 SDK.
- [x] Signed iOS build regression check (shared preference/model code).
- [x] Physical Apple TV: real artwork, remote focus, title/details panel and More Info.
- [x] Physical Apple TV: Play resumes decoded video; pause and Back return to details.
- [x] Physical Apple TV: disable/re-enable and static fallback; previews restored on.
- [ ] Physical Apple TV: account change and signed-out fallback.
- [ ] Cold-launch action through the account picker; stale action/account mismatch.
- [ ] Two independent servers, different viewers and restricted libraries.
- [ ] Overnight expiry, OS cache eviction and offline restart.

These checks do not close the separate iPhone subtitle-switching validation gate.
No simulator or iPhone interaction is required for Top Shelf validation.

Apple references: [Top Shelf design](https://developer.apple.com/design/human-interface-guidelines/top-shelf),
[content provider](https://developer.apple.com/documentation/tvservices/tvtopshelfcontentprovider),
[carousel](https://developer.apple.com/documentation/tvservices/tvtopshelfcarouselcontent).
