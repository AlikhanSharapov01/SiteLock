# SiteLock

Block distracting sites in Firefox behind a password of your own. SiteLock is an **impulse
barrier**: it makes "just one quick look" cost a password and a deliberate unblock, but anyone
with admin rights on the Mac can still remove it (see [Known limitations](#known-limitations)).

- Your own SiteLock password (not the Mac login password). Only a salted PBKDF2 hash is stored,
  in a root-only directory.
- Add or remove any number of domains. Each one is blocked together with all its subdomains
  (`instagram.com` blocks `instagram.com`, `www.instagram.com`, `m.instagram.com`, …).
- Unblock a domain for N minutes (for example LinkedIn for 15 minutes); it is blocked again
  automatically when the time is up.
- A background service starts at boot, has no Dock icon and no popups, and puts the Firefox
  policy back if it is deleted or edited.
- The SiteLock app is only needed when you want to change the list.

Requirements: macOS 13 or later, Firefox, Xcode or the Command Line Tools
(`xcode-select --install`) to build. Apple silicon and Intel Macs are both supported
(universal binary).

## Install

```bash
git clone https://github.com/AlikhanSharapov01/SiteLock.git
cd SiteLock
./scripts/build.sh          # as your normal user; builds ./build/sitelockd and ./build/SiteLock.app
sudo ./install.sh           # one time; asks for your Mac admin password
```

Then open **/Applications/SiteLock.app** and set your SiteLock password.

`install.sh` copies:

| What | Where |
|---|---|
| Background service (root) | `/Library/PrivilegedHelperTools/sitelockd` |
| Starts it at boot, restarts it if killed | `/Library/LaunchDaemons/local.sitelock.daemon.plist` |
| The app | `/Applications/SiteLock.app` |
| Password hash and list (root only, created on first run) | `/Library/Application Support/SiteLock/` |
| Log | `/var/log/sitelockd.log` |

macOS shows a system notification ("Background Items Added"), and `sitelockd` appears in
System Settings → General → Login Items → *Allow in the Background*. That is macOS's own notice,
not a SiteLock popup.

### Gatekeeper (no paid Apple Developer account)

SiteLock is not notarized; binaries are ad-hoc signed by `build.sh`. Because you build it
yourself, the files carry no quarantine flag and Gatekeeper does not block them. If you copy a
built `SiteLock.app` from somewhere else (download, AirDrop) and macOS says it "cannot be opened":

- Right-click (Control-click) the app → **Open** → **Open**, or
- System Settings → Privacy & Security → **Open Anyway**, or
- `xattr -dr com.apple.quarantine /Applications/SiteLock.app` (`install.sh` also does this).

## Use

1. Open SiteLock and enter your SiteLock password.
2. **Add**: type a domain (`instagram.com`, or paste a URL like `https://www.instagram.com/explore`,
   which is reduced to `instagram.com`) and press Add.
3. **Unblock for a while**: on the row, choose *Unblock* → 5/15/30/60/120 minutes or *Custom…*
   (1 minute to 24 hours). The row shows *Unblocked until 14:35*. *Re-block now* ends it early.
4. **Remove**: the trash button (asks for confirmation).
5. **Lock** or close the window. Closing the window quits the app; blocking continues.

Firefox reads its policies only when it starts. So every change to what is blocked **quits
Firefox**, and the app reopens it if it was running. When a temporary unblock expires, the
service quits Firefox without reopening it, so the site is blocked from the next launch. To get
your tabs back, set Firefox → Settings → General → *Open previous windows and tabs*.

## Uninstall

```bash
sudo ./uninstall.sh
```

It asks for your SiteLock password and removes nothing if it is wrong. It removes the service,
the app, the stored data and the log, and deletes the keys SiteLock set in
`/Library/Preferences/org.mozilla.firefox.plist` (`EnterprisePoliciesEnabled`, `WebsiteFilter`,
`BlockAboutConfig`). If you had other Firefox policies in that file, set
`EnterprisePoliciesEnabled` again. Restart Firefox afterwards.

## How it works

```
SiteLock.app (your user) ──password + command──▶ /var/run/sitelockd.sock
                                                         │
                                               sitelockd (root, launchd)
                       ┌─────────────────────────────────┼──────────────────────────────┐
       /Library/Application Support/SiteLock/   /Library/Preferences/            quits Firefox
         auth.json  (salt + PBKDF2 hash)         org.mozilla.firefox.plist        when the list
         state.json (domains, unblock expiry)    (Firefox enterprise policy)      changes
```

**Firefox policy.** The service writes these keys into the system preferences domain
`org.mozilla.firefox` (`/Library/Preferences/org.mozilla.firefox.plist`), owned by root:

```xml
<key>EnterprisePoliciesEnabled</key><true/>
<key>BlockAboutConfig</key><true/>
<key>WebsiteFilter</key>
<dict>
  <key>Block</key>
  <array><string>*://*.instagram.com/*</string></array>
  <key>Exceptions</key><array/>
</dict>
```

Why this file and not `policies.json`:

- Mozilla's macOS instructions (`mozilla/policy-templates`, `mac/README.md`) use this preferences
  domain and require `EnterprisePoliciesEnabled`.
- `policies.json` would have to go inside `Firefox.app/Contents/Resources/distribution/`, and a
  Firefox update replaces the app bundle. The preferences file lives outside the bundle and
  survives updates.
- In the Firefox source (`EnterprisePoliciesParent.sys.mjs`, `_buildProvider`), the macOS
  provider is added after the JSON provider and wins on conflicts. Policies a user puts in their
  own `~/Library/Preferences/org.mozilla.firefox.plist` rank below the system file
  (`macOSPoliciesParser.sys.mjs`, `selectPolicies`).
- `*://*.example.com/*` is a WebExtension match pattern: `*.` covers the domain and all its
  subdomains, and `*://` covers http, https, ws and wss. Firefox reads at most 1000 patterns, so
  the list is capped at 1000 domains.

The service writes through `CFPreferences`, so `cfprefsd`'s cache stays in sync. If the file was
deleted behind `cfprefsd`'s back, the service writes it directly. It leaves other keys in that
file alone.

**Background service.** `sitelockd run` is started by launchd at boot (`RunAtLoad`) and restarted
if it exits (`KeepAlive`). Every 2 seconds it:

1. drops temporary unblocks whose time is up; if any were dropped, it saves the list, applies the
   policy and quits Firefox;
2. checks the policy, both on disk and as served by `cfprefsd`, and re-applies it if it was
   deleted or edited.

Unblock expiry is a wall-clock time stored in `state.json`. If the Mac was asleep or the service
was down when it passed, the site is re-blocked at the next check.

**App ↔ service.** A Unix socket `/var/run/sitelockd.sock` (mode 0666, so the app can connect
without admin rights), one JSON request per connection. Every command except `hello` and the
first-launch `setup` carries the SiteLock password, which the service verifies against the hash.
After 5 wrong passwords in a row, further attempts are refused for 60 seconds. `setup` is only
accepted while no password is stored.

**Password.** PBKDF2-HMAC-SHA256 (CommonCrypto), 600,000 iterations, 16-byte random salt,
32-byte hash, constant-time comparison. `auth.json` is mode 0600 in a root-only 0700 directory.
The app keeps the password in memory only while unlocked.

### Why a LaunchDaemon installed by script, not SMAppService + XPC

`SMAppService.daemon(plistName:)` with an XPC service is Apple's preferred design. Without a
paid Developer ID, though, the app can only be ad-hoc signed. Daemon registration and the
code-signing checks that make XPC trustworthy both depend on a real signing identity (Team ID),
and ad-hoc signing does not give one. So v1 uses a classic root LaunchDaemon installed once with
`sudo ./install.sh`, plus a local socket authenticated by the SiteLock password, which does not
depend on code signing. Moving to SMAppService later only changes installation and transport.
The core logic and the daemon's request handling stay the same.

### Extending to app blocking

Enforcement goes through the `Enforcer` protocol (`Sources/SiteLockCore/Enforcer.swift`). App
blocking would be another enforcer. Note that `NSWorkspace` launch notifications are delivered
only inside a user's GUI session, so that enforcer would run in a per-user LaunchAgent that asks
`sitelockd` for the state, not in the root daemon.

## Known limitations

- **An admin can bypass it.** With `sudo` you can stop the service
  (`launchctl bootout system/local.sitelock.daemon`), delete the files, edit the policy, or turn
  `sitelockd` off in Login Items. This is an impulse barrier, not parental control.
- **Firefox only.** Safari, Chrome and other browsers are not affected in v1. Firefox forks that
  do not read `org.mozilla.firefox` (for example LibreWolf) are not affected either.
- **Changes need a Firefox restart.** SiteLock quits Firefox (SIGTERM, then SIGKILL after 10 s if
  it hangs) whenever the blocked set changes. Unsaved form input in open tabs can be lost.
- **Lockout is global.** After 5 wrong passwords from anyone, the app refuses all passwords
  for 60 seconds, yours included.
- **First-launch race.** Until a password is set, any local user who opens the app first can set
  it. Set it right after installing.
- **Other policy sources.** A configuration profile (`/Library/Managed Preferences`) outranks
  `/Library/Preferences`. A profile that sets `WebsiteFilter` would replace SiteLock's list.
- **Older Firefox versions.** The precedence above was checked in the current Firefox source.
  Very old Firefox releases may rank the user's own preferences file differently.
- **Not notarized.** See [Gatekeeper](#gatekeeper-no-paid-apple-developer-account).

## Manual test checklist (Firefox)

Run after `sudo ./install.sh`. Expected results in *italics*.

1. Open SiteLock → set password `test-pass-1` (and confirm). *List view appears.*
2. Run `sudo defaults read /Library/Preferences/org.mozilla.firefox`.
   *Shows `EnterprisePoliciesEnabled = 1`, `BlockAboutConfig = 1`, `WebsiteFilter` with an empty `Block`.*
3. Add `instagram.com`. *Firefox quits and reopens if it was open.*
4. In Firefox open `https://instagram.com`, `https://www.instagram.com`,
   `https://help.instagram.com`. *All three show Firefox's "blocked page" error.*
   `https://example.com` still loads.
5. Open `about:policies`. *Status "Active"; WebsiteFilter lists `*://*.instagram.com/*`.*
6. Open `about:config`. *Blocked.*
7. Add `https://www.linkedin.com/feed/`. *Row shows `linkedin.com`.* LinkedIn is blocked.
8. Unblock linkedin.com → Custom… → 2 minutes. *Firefox restarts; linkedin.com loads; row shows
   "Unblocked until hh:mm".*
9. Wait 2–3 minutes. *Firefox quits on its own; after reopening, linkedin.com is blocked; the
   app row shows "Blocked".*
10. Unblock linkedin.com for 5 minutes, then *Re-block now*. *Firefox restarts; LinkedIn blocked.*
11. Tamper: `sudo defaults delete /Library/Preferences/org.mozilla.firefox WebsiteFilter`, wait
    3 s, read it again. *The key is back.* `tail /var/log/sitelockd.log` shows
    "Firefox policy missing or modified; re-applying".
12. Tamper: `sudo rm /Library/Preferences/org.mozilla.firefox.plist`, wait 3 s.
    *The file exists again with SiteLock's keys.*
13. Persistence: `sudo killall sitelockd`. *`pgrep sitelockd` shows a new PID within seconds.*
14. Reboot. *Without opening the app, instagram.com is still blocked in Firefox.*
15. Wrong password in the app 5 times. *"Too many wrong passwords…" for 60 seconds.*
16. Remove instagram.com. *Firefox restarts; instagram.com loads.*
17. Update Firefox (Firefox → About Firefox) if an update is available. *Blocking still works.*
18. `sudo ./uninstall.sh` with a wrong password. *"Wrong password. Nothing was removed."*
19. `sudo ./uninstall.sh` with the right password, restart Firefox. *Sites load; `about:policies`
    shows no active policies (unless you have others).*

## Development

The app icon is drawn by `scripts/make-icon.py` (Pillow) into `Resources/AppIcon.icns`; the build
only copies the committed `.icns`. Re-run the script after changing the drawing.

```bash
swift test                  # unit tests (macOS)
./scripts/build.sh          # universal release build + lipo -info
```

The platform-independent core and its tests also build on Linux (the password hashing tests
need CommonCrypto and run on macOS only):

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --build-path /tmp/b
```

CI: `.github/workflows/macos.yml` runs the tests, the universal build, `lipo` checks and
`codesign --verify` on a macOS runner. Start it from the Actions tab (*Run workflow*). It also
runs on pull requests.
