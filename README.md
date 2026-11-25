# SiteLock

Block distracting sites in Firefox behind a password of your own. SiteLock is an **impulse
barrier**: it makes "just one quick look" cost a password and a deliberate unblock, but anyone
with admin rights on the Mac can still remove it (see [Known limitations](#known-limitations)).

- Your own SiteLock password (not the Mac login password). Only a salted PBKDF2 hash is stored,
  in a root-only directory.
- Add or remove any number of sites. An entry blocks that host and all its subdomains, never its
  parent or siblings: `youtube.com` blocks `www.youtube.com` and `music.youtube.com`, while
  `www.youtube.com` blocks YouTube but leaves `music.youtube.com` open.
- Unblock a domain for N minutes (for example LinkedIn for 15 minutes); it is blocked again
  automatically when the time is up.
- A background service starts at boot, has no Dock icon and no popups, and puts the Firefox
  policy back if it is deleted or edited.
- The SiteLock app is only needed when you want to change the list.

Requirements: macOS 13 or later and Firefox. One universal app for Apple silicon and Intel
Macs; nothing else to install.

## Install

Paste into Terminal (downloads the latest release into /Applications and opens it):

```bash
curl -fsSL https://github.com/AlikhanSharapov01/SiteLock/releases/latest/download/SiteLock.zip -o /tmp/SiteLock.zip && rm -rf /Applications/SiteLock.app && ditto -x -k /tmp/SiteLock.zip /Applications && rm /tmp/SiteLock.zip && open /Applications/SiteLock.app
```

Or download `SiteLock.zip` from the [latest release](https://github.com/AlikhanSharapov01/SiteLock/releases/latest),
unzip it and drag **SiteLock** to Applications (see [Gatekeeper](#gatekeeper-no-paid-apple-developer-account)
for the one-time "Open Anyway").

Then in SiteLock: **Install** (macOS asks for your administrator password once) → set your
SiteLock password. To update, replace the app and open it: it shows **Update** when the
installed service is a different version; the password and the list are kept.

The same command updates SiteLock. Without the app's button, installing also works in Terminal:
`sudo /Applications/SiteLock.app/Contents/MacOS/sitelockd install`.

SiteLock.app carries everything; installing puts only these on the system:

| What | Where |
|---|---|
| Background service (root-owned copy of `sitelockd`) | `/Library/PrivilegedHelperTools/sitelockd` |
| Starts it at boot, restarts it if killed | `/Library/LaunchDaemons/local.sitelock.daemon.plist` |
| Password hash and list (root only, created on first run) | `/Library/Application Support/SiteLock/` |

There is no log file: the service logs to the macOS system log
(`log show --last 1h --predicate 'subsystem == "local.sitelock"'`).

macOS shows a system notification ("Background Items Added"), and `sitelockd` appears in
System Settings → General → Login Items → *Allow in the Background*. That is macOS's own notice,
not a SiteLock popup.

### Gatekeeper (no paid Apple Developer account)

SiteLock is ad-hoc signed, not notarized. Files fetched with `curl` (the command above) or built
yourself carry no quarantine flag, so Gatekeeper does not ask. An app downloaded in a browser
does carry it; on first open macOS says it cannot verify the app. Once:

- System Settings → Privacy & Security → **Open Anyway** (macOS 15 and later), or right-click
  the app → **Open** → **Open** (macOS 13–14), or
- `xattr -dr com.apple.quarantine /Applications/SiteLock.app`.

## Use

1. Open SiteLock and enter your SiteLock password.
2. **Add**: type a host (`instagram.com`, `www.youtube.com`), or paste a URL like
   `https://www.youtube.com/feed`, which is reduced to `www.youtube.com`, and press Add.
   The host is kept as typed; it and its subdomains are blocked:

   | Entry | Blocked | Not blocked |
   |---|---|---|
   | `youtube.com` | `youtube.com`, `www.youtube.com`, `music.youtube.com`, `m.youtube.com` | — |
   | `www.youtube.com` | `www.youtube.com` (and `youtube.com`, which redirects there) | `music.youtube.com`, `m.youtube.com` |
   | `store.google.com` | `store.google.com` | `google.com`, `mail.google.com` |
3. **Unblock for a while**: on the row, choose *Unblock* → 5/15/30/60/120 minutes or *Custom…*
   (1 minute to 24 hours). The row shows *Unblocked until 14:35*. *Re-block now* ends it early.
4. **Remove**: the trash button (asks for confirmation).
5. **Change Password…**: enter the current password and the new one twice. The new password is
   hashed the same way and replaces the old hash; wrong current passwords count toward the lockout.
6. **Lock** or close the window. Closing the window quits the app; blocking continues.

Firefox reads its policies only when it starts. So every change to what is blocked **quits
Firefox**, and the app reopens it if it was running. When a temporary unblock expires, the
service quits Firefox without reopening it, so the site is blocked from the next launch. To get
your tabs back, set Firefox → Settings → General → *Open previous windows and tabs*.

**Editing an entry.** The pencil button on a row changes that entry, for example
`youtube.com` → `www.youtube.com`. The new value is checked like a new entry (valid host, not
already in the list), and the edited entry starts blocked: a running temporary unblock ends.

## Uninstall

In the app, unlock it and choose **SiteLock → Uninstall SiteLock…** in the menu bar. Or in
Terminal (also works if the app is already deleted):

```bash
sudo /Library/PrivilegedHelperTools/sitelockd uninstall
```

Both need your SiteLock password and remove nothing if it is wrong. It removes the service and
the stored data, and deletes the keys SiteLock set in
`/Library/Preferences/org.mozilla.firefox.plist` (`EnterprisePoliciesEnabled`, `WebsiteFilter`,
`BlockAboutConfig`). If you had other Firefox policies in that file, set
`EnterprisePoliciesEnabled` again. Restart Firefox afterwards and move SiteLock.app to the Trash.

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

### Why a classic LaunchDaemon, not SMAppService + XPC

`SMAppService.daemon(plistName:)` with an XPC service is Apple's preferred design. Without a
paid Developer ID, though, the app can only be ad-hoc signed. Daemon registration and the
code-signing checks that make XPC trustworthy both depend on a real signing identity (Team ID),
and ad-hoc signing does not give one. So SiteLock uses a classic root LaunchDaemon that
`sitelockd install` sets up once with admin rights, plus a local socket authenticated by the SiteLock password, which does not
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
- **Forgotten password.** There is no recovery inside SiteLock. An admin can delete
  `/Library/Application Support/SiteLock/auth.json` (`sudo rm …`) and restart the service
  (`sudo launchctl kickstart -k system/local.sitelock.daemon`); the app then asks for a new password.
- **First-launch race.** Until a password is set, any local user who opens the app first can set
  it. Set it right after installing.
- **Other policy sources.** A configuration profile (`/Library/Managed Preferences`) outranks
  `/Library/Preferences`. A profile that sets `WebsiteFilter` would replace SiteLock's list.
- **Older Firefox versions.** The precedence above was checked in the current Firefox source.
  Very old Firefox releases may rank the user's own preferences file differently.
- **Not notarized.** See [Gatekeeper](#gatekeeper-no-paid-apple-developer-account).

## Manual test checklist (Firefox)

Run after installing. Expected results in *italics*.

1. Open SiteLock → set password `test-pass-1` (and confirm). *List view appears.*
2. Run `sudo defaults read /Library/Preferences/org.mozilla.firefox`.
   *Shows `EnterprisePoliciesEnabled = 1`, `BlockAboutConfig = 1`, `WebsiteFilter` with an empty `Block`.*
3. Add `instagram.com`. *Firefox quits and reopens if it was open.*
4. In Firefox open `https://instagram.com`, `https://www.instagram.com`,
   `https://help.instagram.com`. *All three show Firefox's "blocked page" error.*
   `https://example.com` still loads.
5. Open `about:policies`. *Status "Active"; WebsiteFilter lists `*://*.instagram.com/*`.*
6. Open `about:config`. *Blocked.*
7. Add `linkedin.com`. LinkedIn is blocked.
8. Add `https://www.youtube.com/feed`. *Row shows `www.youtube.com`.* `https://www.youtube.com`
   and `https://youtube.com` are blocked; `https://music.youtube.com` still loads.
9. Unblock linkedin.com → Custom… → 2 minutes. *Firefox restarts; linkedin.com loads; row shows
   "Unblocked until hh:mm".*
10. Wait 2–3 minutes. *Firefox quits on its own; after reopening, linkedin.com is blocked; the
   app row shows "Blocked".*
11. Unblock linkedin.com for 5 minutes, then *Re-block now*. *Firefox restarts; LinkedIn blocked.*
12. Tamper: `sudo defaults delete /Library/Preferences/org.mozilla.firefox WebsiteFilter`, wait
    3 s, read it again. *The key is back.* `log show --last 5m --predicate 'subsystem == "local.sitelock"'` shows
    "Firefox policy missing or modified; re-applying".
13. Tamper: `sudo rm /Library/Preferences/org.mozilla.firefox.plist`, wait 3 s.
    *The file exists again with SiteLock's keys.*
14. Persistence: `sudo killall sitelockd`. *`pgrep sitelockd` shows a new PID within seconds.*
15. Reboot. *Without opening the app, instagram.com is still blocked in Firefox.*
16. Wrong password in the app 5 times. *"Too many wrong passwords…" for 60 seconds.*
17. Remove instagram.com. *Firefox restarts; instagram.com loads.*
18. Update Firefox (Firefox → About Firefox) if an update is available. *Blocking still works.*
19. Replace the app with a build of another version and open it. *An Update banner appears;
    Update asks for the admin password, then the app connects again.*
    `sudo /Library/PrivilegedHelperTools/sitelockd uninstall` with a wrong password.
    *"wrong password; nothing was removed".*
20. In the app: SiteLock → Uninstall SiteLock… (or the command above with the right password),
    restart Firefox. *The app shows "SiteLock was removed"; sites load; `about:policies`
    shows no active policies (unless you have others).*

## Development

Build from source (needs Xcode or the Command Line Tools, `xcode-select --install`):

```bash
git clone https://github.com/AlikhanSharapov01/SiteLock.git
cd SiteLock
./scripts/build.sh                     # as your normal user; builds ./build/SiteLock.app
ditto build/SiteLock.app /Applications/SiteLock.app
```

Release: bump `SiteLockVersion.current` and `CFBundleShortVersionString` in `Resources/Info.plist`
(a test keeps them equal), merge, then push a tag `vX.Y.Z` on `main`. CI builds, checks the tag
against the app version and publishes `SiteLock.zip` as the release asset the install command
downloads.

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
`codesign --verify` on a macOS runner, on pull requests, version tags and manual runs (Actions tab,
*Run workflow*).
