# Handoff — 2026-11-21

## Goal
SiteLock v1: macOS 13+ app that blocks user-chosen domains (and subdomains) in Firefox via
enterprise policies, behind a custom password; root LaunchDaemon enforces, repairs tampering and
re-blocks after timed unblocks; SwiftUI app edits the list.

## Decisions (and why)
- Policy via `/Library/Preferences/org.mozilla.firefox.plist` (system CFPreferences domain), not
  `distribution/policies.json` — outside the app bundle so it survives Firefox updates; Firefox
  source (`EnterprisePoliciesParent.sys.mjs` `_buildProvider`) ranks the macOS provider above JSON.
- WebsiteFilter is read only at Firefox startup (`Policies.sys.mjs`, `onBeforeUIStartup`) → the
  daemon quits Firefox (pkill -TERM, then -KILL after 10 s) whenever the effective list changes;
  the app relaunches it if it was running.
- Root LaunchDaemon installed by `install.sh` + Unix socket authenticated by the SiteLock password,
  instead of SMAppService + XPC — those need a real signing identity (Team ID); only ad-hoc signing
  is available.
- Universal build = two single-arch `swift build` + `lipo -create` (works with CLT only).
- Commits authored as `AlikhanSharapov01 <account email>` via `git -c`, no AI attribution.
- CI on macOS runner, `workflow_dispatch` + `pull_request` only (user's choice, saves minutes).

## Current state
- Works and verified (Linux, `swift:6.0-noble` Docker): SiteLockCore builds with no warnings,
  21/21 tests pass; scripts pass `bash -n`; plists parse.
- Done but NOT verified: everything macOS-only — `sitelockd`, the SwiftUI app,
  `UnixSocket.swift`, `PasswordHasher.swift` + its 6 tests, `build.sh`, `lipo -info`,
  install/uninstall, real Firefox behaviour. Reviewed by reading only.
- Branch `feat/v1` has 2 local commits; NOT pushed — the GitHub repo is empty (no `main`), and
  pushing first would make `feat/v1` the default branch. User will create `main` first.

## Exact next steps
1. User creates `main` on GitHub (add README in web UI) → `git ls-remote origin` shows it.
2. Push: `git -c push.negotiate=true push -u origin feat/v1` → verify: `git ls-remote origin`.
3. User runs Actions → "macOS build and test" → Run workflow on `feat/v1` → verify: tests pass,
   `lipo -info` shows `x86_64 arm64` for both binaries.
4. On the Mac: `./scripts/build.sh`, `sudo ./install.sh`, then README "Manual test checklist".

## Key files
- `Sources/SiteLockCore/` — Domain, BlockState (unblock timing), FirefoxPolicy, PasswordHasher, IPC, UnixSocket, Enforcer
- `Sources/sitelockd/Daemon.swift` — socket server, 2 s tick (expiry + tamper repair), auth/throttle
- `Sources/sitelockd/FirefoxEnforcer.swift` — CFPreferences write + file fallback, Firefox quit
- `Sources/SiteLock/` — AppModel + Views
- `install.sh`, `uninstall.sh`, `scripts/build.sh`, `.github/workflows/macos.yml`

## Open questions
- Does `pkill -TERM firefox` give a clean quit with session restore on current Firefox for macOS?
- Does SwiftUI fire both `.onSubmit` and the default button on Return (guarded either way)?
