# Samsung TV (Tizen) build and release

The Samsung app is the shared Flutter TV app in `apps/tv`, packaged as a
Tizen .NET `.tpk` with [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen).
It targets Tizen 6.0 and later, which is every Samsung TV from 2021 on.
Flutter apps don't run on 2020 or older Samsung TVs; see
[Older Samsung TVs](SAMSUNG_OLDER_TVS.md) for what those viewers can use.

## Tools

| Tool | Version | Notes |
|------|---------|-------|
| flutter-tizen | `git clone https://github.com/flutter-tizen/flutter-tizen` | Bundles its own Flutter (3.47 as of Nov 2026). Put `flutter-tizen/bin` on `PATH`. |
| .NET SDK | 8.0+ | Samsung TVs only run the C# (.NET) runner, not the C++ one. On Ubuntu: `apt install dotnet-sdk-8.0`. |
| Tizen SDK | Tizen Studio 6.1 CLI, or the VS Code Extension for Tizen | From download.tizen.org / samsungtizenos.com. Set `TIZEN_SDK` if it isn't in `~/tizen-studio`. Install the Samsung Certificate Extension and the TV extension through the package manager. |

Check with `flutter-tizen doctor`.

### Apple Silicon Macs

Verified 2026-11-07 on the owner's Mac mini (Tizen SDK 10.0, .NET 8.0.427):

- Install Rosetta 2 first (`sudo softwareupdate --install-rosetta --agree-to-license`).
  Samsung's `tz`, `sdb` and GCC toolchain are Intel-only.
- The Tizen package manager needs Java 8; the Java it bundles is Intel-only,
  so use an ARM JDK 8 (for example Zulu 8). The installer only accepts paths
  inside the home folder, so to keep the SDK on another drive run it with
  `_JAVA_OPTIONS="-Duser.home=<folder>"`.
- Packages: Native CLI, GCC 9.2 toolchain, IoT-Headed-6.0 Native, Samsung
  Certificate Extension.
- Keep the whole toolchain in one build folder (about 9 GB), for example
  `~/zorofin-tizen`. Rebuild there with:

  ```sh
  B=~/zorofin-tizen  # your Tizen build folder
  export TIZEN_SDK=$B/home/tizen-studio DOTNET_ROOT=$B/dotnet _JAVA_OPTIONS="-Duser.home=$B/home" PATH=$B/flutter-tizen/bin:$B/dotnet:$PATH
  cd $B/repo/apps/tv && nice -n 15 tool/tizen/build_tpk.sh --release --build-name 1.3.0 --build-number 1
  ```

  A temporary Tizen test certificate profile `zorofin-test` exists there
  (password in macOS Keychain service `zorofin-tizen-test-cert`). It proves
  the build but can't be used on a real Samsung TV or the store.

## Signing

Samsung TVs and the TV Seller Office need a **Samsung** certificate profile,
not a Tizen one. Create it in Certificate Manager (Tizen SDK) with
"Create Samsung Certificate", signed in with the Vitality Labs Samsung
account.

- Author certificate: one per company, reused for every update. Losing it
  means the store treats the next upload as a different app. Keep the `.p12`
  and its password in the password manager, never in Git.
- Distributor certificate: "Public" privilege level is enough. For testing on
  a TV, add that TV's DUID when you create it.

## Build

```sh
cd apps/tv
tool/tizen/build_tpk.sh --release --build-name 1.3.0 --build-number 1
```

The script copies the app to `build/tizen-stage`, drops the LG-only packages,
adds `video_player_tizen` and `shared_preferences_tizen`, and runs
`flutter-tizen build tpk --device-profile tv`. The signed `.tpk` is copied to
`build/tizen/`. The shared `pubspec.lock` is not touched, because flutter-tizen
resolves packages with a newer Flutter than the LG and Android builds use.

## Testing without a Samsung TV

- The Tizen TV emulator needs x86 hardware virtualization (Intel VT-x or
  AMD-V). It doesn't run in the cloud build container and isn't expected to
  run on Apple Silicon Macs, so emulator testing needs an Intel/AMD PC.
- Samsung's review tests the app on real TVs, but a failed review costs
  weeks, so test on at least one real 2021+ Samsung TV before submitting if
  one can be borrowed (Developer Mode: Apps panel, type 12345 on the remote).

## Store release (TV Seller Office)

1. Sign in at https://seller.samsungapps.com/tv with the Vitality Labs
   Samsung account. Fill in Membership > Group Information. New groups are
   Public Sellers, which can release in the **United States only** (the
   current plan). Other countries need a Partner contract with Samsung.
2. Applications > Create App, type **Tizen .NET Application (TPK package)**.
3. Fill every section until all checks are blue, including the Verification
   Info description file (a document explaining every screen and feature,
   with reviewer server URL and test login).
4. In Distribute > Request New Release, select only **2021 and later** model
   groups.
5. Review usually takes 4 weeks or more.

Nothing is submitted without the owner's typed go. Store account facts go in
the "Zorofin store accounts handoff" doc.

## Public sideload preview

See [Tizen sideload distribution](TIZEN_SIDELOADING.md) for the experimental
TPK, Apps2Samsung submission, exact package checks and website publication.
A successful build does not establish installation or playback on a Samsung TV.
