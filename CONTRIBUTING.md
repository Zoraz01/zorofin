# Contributing to Zorofin

Thanks for helping. Bug reports, fixes, translations, accessibility work and new
ideas are all welcome, and you don't need to be an expert in every platform:
most contributors only ever touch one app folder.

## Ways to help

- **Report a bug** with the bug form. Say which app and version, your Jellyfin
  version, and the steps that make it happen. Screenshots help a lot (blur
  anything personal).
- **Suggest a feature** with the feature form, or start a thread in
  Discussions if it's still an idea.
- **Fix something.** Issues labelled `good first issue` are small and well
  described. `help wanted` issues are bigger but the maintainer would welcome a
  pull request.
- **Test on your device** and say what works in an issue or discussion,
  especially on TVs we don't own.

## Before you write code

- For anything bigger than a bug fix, open an issue first so we can agree on the
  approach before you spend time on it. Comment on an issue to claim it.
- Zorofin aims for the same features on every platform. A new feature usually
  starts on one app and is then ported, so describe how it should work
  everywhere, not just on your device.
- Keep one change per pull request, with tests for new behavior where the app
  has tests.

## Project layout and checks

| Folder | Set up | Checks to run before a pull request |
| --- | --- | --- |
| `apps/apple` | macOS, current Xcode | `swift test --package-path apps/apple/Core`, then build `Zorofin-iOS` and `Zorofin-tvOS` |
| `apps/tv` | Flutter (version in `.github/workflows/tv.yml`) | `flutter analyze` and `flutter test` in `apps/tv` |
| `apps/roku` | Node 20+ | `npm ci && npm run validate && npm run lint && npm test` in `apps/roku` |
| `apps/legacy-tv` | Node 20+ | `npm ci && npm test` in `apps/legacy-tv` |

The same checks run automatically on every pull request, only for the folders
you changed. A maintainer has to approve the first run for new contributors.

You need a Jellyfin server to test against. Use your own, a throwaway server
from `apps/apple/demo-server`, or the apps' built-in preview mode.

## Privacy rules

Never put real server addresses, account names, API keys, tokens or personal
media in code, tests, logs or screenshots. Use `example.com` hosts, the example
LAN address `192.168.1.20`, made-up ids, and the Blender sample films for
screenshots.

## Sign your commits (DCO)

Every commit must carry a `Signed-off-by` line. Add it with `git commit -s`.
It certifies the [Developer Certificate of Origin](https://developercertificate.org/):
that you wrote the change or have the right to submit it under this project's
license (MPL-2.0). By contributing, you agree that your contribution is licensed
under that license. A check on each pull request tells you if a sign-off is
missing; `git commit --amend -s` or `git rebase --signoff main` fixes it.

## AI-assisted contributions

Zorofin is built largely with AI coding assistants, and AI-assisted
contributions are welcome. You are responsible for every line you submit:
review it, test it on a real device or simulator, and say in the pull request
which parts an AI tool wrote.

## What happens after you open a pull request

1. Automated checks run for the folders you changed.
2. The maintainer reviews, usually within a week. Expect questions or small
   change requests; that's normal and not a rejection.
3. Once approved and green, the maintainer merges it with a squash merge.
4. Your change ships in the next store release for that platform, and you're
   credited in the release notes.

Store builds are signed and uploaded by the maintainer. Contributors never need
store accounts or signing keys.

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
