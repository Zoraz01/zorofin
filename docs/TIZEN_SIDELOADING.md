# Tizen sideload distribution

The owner authorized public TPK downloads, a zorofin.app sideload guide, and an
Apps2Samsung submission on November 9, 2026. The scope was narrowed to
Apps2Samsung; no awesome-jellyfin or TizenBrew submission is part of this task.

## Release contract

- Experimental native .NET/Flutter TPK, `org.zorofin.tv`, version 1.3.0.
- Targets Tizen API 6.0, normally Samsung 2021+ models. This is a target, not a
  successful-device compatibility claim. Samsung's 2026 SDK/library compatibility
  requirements also need a device/release pass before broad support is claimed.
- Requires the installer to re-sign for the target TV with Samsung certificates
  covering its DUID. The packaged distributor certificate is an SDK test signer,
  not authorization for a retail TV. Never distribute signing keys or passwords.
- No Samsung TV/emulator installation or playback pass has been performed.
- The public repository contains only release information and binary release
  assets, never this private repository's source, history or runtime data.
- Apps2Samsung catalog inclusion is not Samsung store acceptance. Submit as a
  draft while the catalog's requested device/emulator evidence is missing.

## Reproduce

Read [SAMSUNG_TIZEN.md](SAMSUNG_TIZEN.md) for SDK setup and Samsung signing.
Use flutter-tizen revision `22bcec9058fbe1e0943e6c6fda21792f24868e91`
(Flutter 3.47.5), .NET 8.0.427 and the installed Tizen SDK 10.0/GCC 9.2 toolchain.
The build script pins video_player_tizen 2.6.0 and shared_preferences_tizen 2.3.5.
The staged dependency lock is retained with the release source. LG and Android
keep their own shared lock and toolchain.

```sh
# Point this at a dedicated build directory on the mounted NVMe drive.
export ZOROFIN_TIZEN_BUILD_DIR=/path/to/nvme/tizen-build
apps/tv/tool/tizen/build_tpk.sh --release --build-name 1.3.0 --build-number 2 \
  --obfuscate --split-debug-info="$ZOROFIN_TIZEN_BUILD_DIR/symbols"
python3 apps/tv/tool/tizen/prepare_sideload.py \
  --input "$ZOROFIN_TIZEN_BUILD_DIR/tizen/org.zorofin.tv-1.3.0.tpk" \
  --output apps/tv/release/tizen
```

The build strips .NET debug symbols, maps build paths and gives the generated
Dart entrypoint a package URI so absolute workstation paths are absent from the
public payload. Keep the Dart symbols private. The packager checks app identity,
minimum API, privileges, notices, archive integrity and the absence of keys and
PDBs. Separately scan decompressed package members for private origins, account
records and workstation paths before publication. Never change a signed payload
without re-signing it.

Update `tizen_package_sha256` in `apps/apple/release/site-product.json` from
`apps/tv/release/tizen/package.json` whenever the artifact changes. The tracked
TPK is the sole source for both the public GitHub release and the website.
`generate_release_materials.py` copies it into ignored `release-site/downloads/`;
the public packager allowlists that exact filename and verifies its SHA-256.
It remains below Cloudflare Pages' 25 MiB per-file limit.

```sh
python3 apps/apple/tools/generate_release_materials.py
python3 -m unittest discover -s apps/apple/tools -p test_public_site.py
python3 apps/apple/tools/package_public_site.py --output /tmp/zorofin-site.zip
```

Publication and rollback use PUBLIC_SITE.md.
After publication, use `verify_public_site.py` to compare every public file,
including the binary download, against source with normal HTTPS verification.
Keep the download URL stable only for the same immutable package. New package
versions get new filenames, checksums and versioned GitHub releases.

## Public destinations

- Guide: https://zorofin.app/samsung-tv
- TPK: https://zorofin.app/downloads/zorofin-tizen-1.3.0.tpk
- Release repository: https://github.com/Zoraz01/zorofin-tizen-releases
- Release tag: `tizen-v1.3.0-preview.1` (GitHub prerelease).
- Apps2Samsung manifest: `packages/Zoraz01__zorofin-tizen-releases.json`.
  Use `flags: [closed-source]`, `category: media`, a release asset matching
  `\.tpk$`, and the author's public redistribution permission in the release
  README. Do not claim a real-TV or emulator test in its submission.

## Acceptance still needed

On a Samsung TV: Developer Mode connection, DUID certificate creation, custom
TPK signing/install, launch, ordinary Jellyfin sign-in, remote focus/Back, movie
and episode playback, seek/resume, audio/subtitles, Live TV if available, and a
repeat install using the same signing identity. Preserve any failure and its
exact TV model, firmware and Tizen version. Only then promote the catalog draft
and decide whether the website can remove its experimental label.

## November 9 validation

The current-main Dart source plus the integrated Tizen runner built successfully.
The artifact is 11,025,663 bytes, SHA-256
`709652fc6f7989d9fa1a93d70a28d4d8c914b7c718d05a760114b2d9b8e46d59`.
All 91 staged TV tests and 12 website guardrails passed. The newer Tizen Flutter
analyzer reports four informational diagnostics: three existing `cacheExtent`
deprecations and the SDK-generated registrant's internal import; no errors or
warnings. Archive and manifest checks, private-path/origin/key/PDB scans, and
localhost download hash comparison passed. Browser visual QA was unavailable:
the computer-use environment exposed no browser surfaces. No TV or emulator was
installed/launched. The public release is a prerelease; store state is preserved.

## Publication record

Published November 9, 2026 (03:18 UTC November 10) from merged source
`a2c7d6a5b0ba818a168577ff6ca47848789c7dbb` through
[feature PR #147](https://github.com/Zoraz01/yams-media-server/pull/147) and
[production workflow 42748540133](https://github.com/Zoraz01/yams-media-server/actions/runs/42748540133).
The shared-TV regression job also passed analysis, tests and signed APK/AAB builds.

Production: https://850b8770.zorofin-client.pages.dev, canonical
https://zorofin.app. All 38 public HTTP assets, including the 11 MB TPK, matched
reviewed source with normal HTTPS, CSP, nosniff and no-transform protections.
The allowlisted ZIP contains 39 files (including the non-served `_headers`),
SHA-256 `d3a685c33b33e1bc6fe436c42d8ef67f0f15b2236252329cb2c38c738f7b390f`.
`PUBLIC_SITE_MANIFEST.json` records the canonical delivery hashes.

The release-only public repository and
[prerelease](https://github.com/Zoraz01/zorofin-tizen-releases/releases/tag/tizen-v1.3.0-preview.1)
are published. Its downloaded TPK matched the same reviewed SHA-256.
The public release repository's permanent checkout is in the owner's dedicated
NVMe Code workspace; it contains no private application history or source.

[Apps2Samsung draft PR #239](https://github.com/Apps2Samsung/tizen-community-packages/pull/239)
is open. Its upstream `changes` and `validate` checks passed. It remains a draft
pending Samsung TV/emulator evidence and maintainer acceptance; it is not yet an
accepted catalog listing. The Custom WGT / TPK route works independently of a
catalog listing, subject to TV-specific signing and actual device acceptance.

Rollback target: previous production `4ea749d0-2be9-41d6-bd82-7704d59e6fa1`,
https://4ea749d0.zorofin-client.pages.dev (source `43da262a248b1678ecd27d1e3359c0e6c7f13035`).
Use the existing Pages rollback procedure. No media services were restarted.
The owned local preview server was stopped; no browser surface was available.

## One-hour tester handoff

Use the standalone Codex test script for an
actual Samsung TV. It covers 56 cases with a strict 60-minute elapsed-time cap,
prioritizes the tester's existing complaints, and reserves the final five minutes
for a sanitized findings/coverage report and cleanup. Optional unavailable
features and scope-limited writes are reported separately from observed failures.
Preparing or sending this handoff is not evidence that the device checks passed.
