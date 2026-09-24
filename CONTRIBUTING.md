# Working on mdr

mdr keeps the reading surface quiet and the source document intact. Contributions should preserve both. Bugs and small, focused improvements are welcome; use fictional documents when sharing a reproduction.

## Development

Use macOS 14+, Xcode 26+ selected with `xcode-select`, Node.js 24+, and Python 3. Clone the repository anywhere; no absolute development paths are required.

```sh
npm ci
npm run build:web
npm test
python3 scripts/test-feedback-cli.py
npx playwright install chromium
npm run test:ui

# Real AppKit/WebKit integration, including PDF export and file watching.
MDR_INTEGRATION_TEST_DIR="$PWD/work/qa/native" .build/debug/mdr
MDR_LINK_TEST_DIR="$PWD/work/qa/links" .build/debug/mdr
MDR_LIVE_TEST_DIR="$PWD/work/qa/live" .build/debug/mdr

npm run build
python3 scripts/test-distribution.py
```

Generated assets, builds, reports, local feedback, and scratch files belong in the ignored directories. Keep scratch work in `work/`. `npm run build:web` bundles JavaScript, licenses, the agent guide, and skill into the Swift resources; run it before Swift-only builds from a clean checkout.

The test suite covers source preservation, Unicode and Markdown source mapping, source changes, conservative reattachment, concurrent writers, saved drafts, editable threads, precise code review, relative links, PDF pagination, and standalone app/CLI/skill installation. Native integration tests require a logged-in macOS GUI session. The CI workflow runs on a GitHub-hosted Mac.

## Code map

| Location | Responsibility |
| :--- | :--- |
| `Sources/MDRCore` | Review format, source versions, anchors, locking, persistence, tool installation |
| `Sources/MDRApp` | AppKit windows and menus, file watching, PDF export, CLI, WebKit bridge |
| `web` | Markdown rendering, source mapping, review interactions, autosave |
| `Sources/MDRApp/Resources/Web` | Static styles and generated offline reader bundle |
| `skills/mdr` | Portable agent skill; `AGENT-REVIEW.md` is the complete protocol guide |
| `scripts` | Build, install, package, demo capture, distribution verification |

The interface uses the macOS system WebKit engine inside a native AppKit shell. The shipped app contains no Node.js or Electron runtime. App and agent review mutations go through `MDRCore` so file integrity rules are shared.

## Demo images

The README uses `examples/export-service.md`, a fictional API proposal. To regenerate its screenshots from the actual native reader:

```sh
bash scripts/capture-demo.sh
```

The demo harness creates its own source and feedback under `work/demo`, uses fictional reviewer identities, and captures the actual native reader. The framing script adds a Mac window surround and shadow for the README, without capturing a desktop. Images go into `docs/images`. Never use an actual user's review file, recent-document list, desktop, or terminal history in published images.

## Release

1. Update the version in `package.json`, the root version entries in `package-lock.json`, and `scripts/Info.plist`. Increment `CFBundleVersion` too.
2. Update `docs/RELEASE-NOTES.md`, run the checks, and commit to `main`.
3. Wait for **Build and test** to pass.
4. Tag the tested commit, for example `git tag v0.3.0`, then `git push origin v0.3.0`.

The **Release** workflow builds from that tag, runs tests, checks the packaged commands from a different directory, and publishes the universal app ZIP, drag-to-Applications DMG, skill ZIP, and checksums. It first creates a draft with all assets, then publishes it. For a retry before publication, remove the incomplete draft release and rerun the workflow on the same tag; do not move an already published release tag.

You can package locally with `bash scripts/package-release.sh v0.3.0` after a build. The script rejects a tag that does not match the app version. GitHub Actions needs only its repository-scoped token with `contents: write` in the release job. No personal tokens are committed or required as workflow secrets.

Current releases use an ad hoc signature. **They are not notarized.** To add notarization later, use an Apple Developer ID Application certificate and a temporary CI keychain, sign with the hardened runtime and secure timestamp, submit with `xcrun notarytool`, and staple the accepted ticket before packaging. Store credentials in GitHub Actions secrets, never in the repository. Follow [Apple's distribution documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Until that is configured and verified, retain the first-open instructions in the README and release notes.

## Sharing changes

Use a focused pull request with the user-visible problem, the change, and relevant validation. Keep review fixtures synthetic. Review files hold full source text and local paths; they are ignored to keep accidental personal data out of commits. New dependencies must have compatible licenses and bundled notices. The build checks that every bundled JavaScript dependency has a license notice.
