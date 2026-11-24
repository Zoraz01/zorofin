# Zorofin R5 branding

The owner approved **R5 Corsair** and its displayed green on October 25, 2026.
`R5/master.png` is the authoritative transparent emblem: asymmetric bandana and
left knot, angular left eye, play-shaped right eye and compact jaw. It replaces
the older sword/splatter artwork across native and web exports. The sampled
primary is **#21BB62**, with **#0C100F** icon backgrounds and **#F2F5F1** light
wordmark text. The master preserves its subtle tonal variation. This is the
approved R5 preview green, not the earlier jade proposal or legacy forest green.

See [identity values](R5/identity.json) and [preparation provenance](R5/PROMPT.md).

## Rebuild

From the repository root on macOS:

```sh
swift apps/apple/tools/generate_icons.swift
python3 apps/apple/tools/generate_release_materials.py
```

The native and browser exports now use one Core Graphics/Core Text renderer;
`python3 branding/make-assets.py` delegates to the same renderer. It does not open
a browser or generate new artwork. Keep module/build caches on the configured
development volume. Project regeneration is unnecessary for an artwork-only
update; existing asset names, bundle identities and signing settings are retained.

Outputs include:

- iPhone/iPad: opaque 1024 × 1024 sRGB icon; corners supplied by the system.
- Apple TV: 400 × 240 / 800 × 480 Home Screen layers; 1280 × 768 store layers.
- Top Shelf fallback: 1920 × 720 and 2320 × 720 at 1x and 2x.
- Matching `HeaderLogo` assets on both platforms and the bundled `wordmark.png`.
- Shared browser mark, wordmark, splash, social card, touch icons and favicon.
- Public-site header/footer lockup, hero mark, favicon and social preview.
- Existing web account-page image locations; no account/billing behavior changes.

`pirate-icon-approved.png` and `pirate-icon-foreground.png` are generated R5
compatibility outputs for older tooling, not alternative masters. `Previews/`
contains actual 120px iOS and composited 800 × 480 TV exports.

## Validation and distribution

Image decoding, dimensions, iOS opacity, asset-catalog file references, SVG
parsing and identical native/browser wordmark bytes were checked. The 120px iOS
and 800 × 480 TV exports were visually reviewed. Website checks cover 320, 390,
768 and 1280px widths, live HTTPS pages and source-matching artwork.

Native resources are packaged in the signed **0.9.0 (10)** iOS/iPadOS and tvOS
archives uploaded October 25. Both builds are assigned to the existing beta
groups and waiting for Apple's beta review; external availability is not yet
confirmed. See build 10. No new device
installation or physical-device test was performed. Asset and archive checks do
not establish device or App Review acceptance. The website release is recorded
in PUBLIC_SITE.md.
