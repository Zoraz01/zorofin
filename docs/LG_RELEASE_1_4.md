# LG 1.4 public release

The owner authorized LG 1.4 publication on November 12, 2026, confirmed personal
TV testing/human review of the installed 1.4 baseline, and explicitly selected
fixing a newly detected Catch Up focus problem before publication.

## Frozen source and package

- Baseline: `a3820e72cf3da90c781a240ac1426209f8bf3733`.
- Corrected source: `0cbf921bf81e0df45cf6f6c4e91155c30b1244ef`, private branch
  `fix/lg-catch-up-release-1.4`. It binds `focus` from ZoroUI in extras.js.
- Test corrections allow independent capability refreshes without weakening the
  exact Home-row refresh assertion, and await the bridge microtask before
  checking duplicate Like submissions. Normal `npm test`: 134 passed, 0 failed.
  The retained baseline run had 130 passed/4 failed and is not called a pass.
- Production identity/version: `org.zorofin.tv` / `1.4.0`.
- Final IPK: 2,000,618 bytes, SHA-256
  `a1c78155e6bbfdf0991d2eb3bf470961ae49c0155a1ce86845aa4eeedd504133`.
- Clean build with the existing pinned CLI 3.2.6 and Flutter/Dart bridge toolchain.
  No final-package physical installation or playback test ran in this task.

The release deliberately freezes the installed 1.4 UX baseline plus its focused
correction. Later unbuilt Sports/notification-read source on the separate
`feature/app-updates-1.4` development lane is not part of this IPK. Carry the
focus/test correction forward before producing a later LG candidate; do not
merge unrelated paused mobile changes as an incidental release step.

## Public distribution

- Release: https://github.com/Zoraz01/zorofin-lg-releases/releases/tag/lg-v1.4.0
- Guide: https://zorofin.app/lg-tv
- Catalog submission: https://github.com/webosbrew/apps-repo/pull/333
- The public binary repository contains no application source/private history.
  Its SOURCE.json identifies the original application source; its Git tag
  identifies the release documentation. Actions remain disabled.
- Catalog metadata pins the reviewed versioned manifest, preventing a later
  unrelated Latest release from silently changing the reviewed package.
- Preserve the 1.2.0 release and all existing artwork/licenses/credits. Screenshot
  provenance remains historical 1.2.0; it is not relabeled as a 1.4 capture.
- Public package records and release reproduction steps live in the separate
  release repository's RELEASING.md and validation/lg-1.4.0/.

## Validation and remaining gates

All 16 release assets passed anonymous HTTPS download and exact byte/hash
comparisons. Current upstream apps-repo `72513e1beee74070119cb21b8f5f3b24184f79b9`
validators passed catalog metadata, public IPK identity/hash and static declared
compatibility. Official toolbox 0.10.0-1 reports ES2020/runtime compatibility for
10.2.0/11.2.0 under `webosRelease >=10.2.0`; it is not a physical model matrix.

The owner-confirmed TV-tested baseline is separate from automated validation of
the correction. Homebrew/rooted installation, cross-store upgrades, other models,
HDR/endurance and a fresh final-package physical retest remain separate. The
Homebrew PR was updated to 1.4; only its maintainers can establish catalog
acceptance. No LG Store submission/version/approval was changed by this task.

Website publication uses apps/apple/release/site-product.json's independent
lg_version/lg_download_url fields. Do not bump Apple's version or unrelated
platform availability for an LG-only update. PUBLIC_SITE.md records deployment,
canonical delivery verification and rollback.
