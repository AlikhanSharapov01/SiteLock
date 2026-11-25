# SiteLock

<!-- Global working rules live in ~/.claude/CLAUDE.md. Keep this file to project facts and
     deliberate overrides. Delete any section that does not apply. -->

## What it is
macOS app that blocks user-chosen domains in Firefox via Firefox enterprise policies, guarded by
a custom password; a root LaunchDaemon enforces the policy and handles timed unblocks.

## Stack
Swift 5.9+ (SwiftPM, `swift-tools-version:5.9`), SwiftUI, macOS 13+. No external dependencies.
Universal binaries (arm64 + x86_64), ad-hoc signed.

## Commands
- Build (universal `build/SiteLock.app`, daemon inside at `Contents/MacOS/sitelockd`): `./scripts/build.sh` (as the normal user, never sudo)
- Test: `swift test`
- Test the core on Linux: `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --build-path /tmp/b`
- CI: `.github/workflows/macos.yml` (manual `workflow_dispatch` + pull requests)
- Install / uninstall: `sudo …/sitelockd install`, `sudo /Library/PrivilegedHelperTools/sitelockd uninstall` — the user runs these, never an agent

## Layout
- `Sources/SiteLockCore/` — platform-independent logic: domains, block state + unblock timing, Firefox policy, password hashing, IPC messages
- `Sources/sitelockd/` — root LaunchDaemon (macOS only): socket server, policy enforcer, Firefox restart
- `Sources/SiteLock/` — SwiftUI app (macOS only)
- `Tests/SiteLockCoreTests/` — unit tests (password hashing tests run on macOS only)
- `Resources/` — app `Info.plist` (version must equal `SiteLockVersion.current`), `AppIcon.icns`
- `AGENTS.md`, `.claude/agents/` — multi-agent roles

## Conventions
- Keep testable logic in `SiteLockCore`; macOS-only code stays thin. Time-dependent functions take `now`.
- `Package.swift` adds the `sitelockd` and `SiteLock` targets only on macOS.

## Do not touch
- Never run `sitelockd install` / `uninstall`, `launchctl`, or `defaults write` on the user's machine.
