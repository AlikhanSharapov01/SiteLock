# Contributing

Bug reports and ideas: [open an issue](https://github.com/AlikhanSharapov01/SiteLock/issues/new/choose).

## Requirements

macOS 13+ and Xcode or the Command Line Tools.

## Build and test

- Build: `./scripts/build.sh` (as a normal user, never sudo). Result: `build/SiteLock.app`.
- Test: `swift test`
- Core only, on Linux: `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --build-path /tmp/b`
  (password-hashing tests need CommonCrypto and run only on macOS)

## CI

Pull requests run unit tests, a universal build and an end-to-end test on a macOS runner.
`scripts/e2e.sh` changes system state and refuses to run outside CI. Never run it on your own Mac.

## Layout

- `Sources/SiteLockCore/`: portable logic. Put new request logic in `Service.swift` with tests.
- `Sources/sitelockd/`: the root daemon.
- `Sources/SiteLock/`: the SwiftUI app.
- `Tests/SiteLockCoreTests/`: unit tests.
- `Resources/`: Info.plist and icon.

## Pull requests

- One change per PR.
- Add or update tests for logic changes.
- CI must be green.
- No new dependencies.
- Keep the README minimal.

## Trying a build safely

Install with the **Install** button in the app, or `sudo /Applications/SiteLock.app/Contents/MacOS/sitelockd install`.
Remove it with **Uninstall SiteLock…** in the app, or `sudo /Library/PrivilegedHelperTools/sitelockd uninstall`.
Anyone with admin rights can remove SiteLock, so you cannot lock yourself out for good.
