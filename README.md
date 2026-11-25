# SiteLock

Blocks distracting sites in Firefox behind a password of your own (not your Mac password).
A background service keeps the block in place, puts it back if it is removed, and re-blocks
sites after a timed unblock. macOS 13 or later, Apple silicon and Intel.

## Install

```bash
curl -fsSL https://github.com/AlikhanSharapov01/SiteLock/releases/latest/download/SiteLock.zip -o /tmp/SiteLock.zip && rm -rf /Applications/SiteLock.app && ditto -x -k /tmp/SiteLock.zip /Applications && rm /tmp/SiteLock.zip && open /Applications/SiteLock.app
```

In SiteLock: **Install** (asks for your Mac admin password once) → set your SiteLock password.

Downloaded `SiteLock.zip` from [Releases](https://github.com/AlikhanSharapov01/SiteLock/releases/latest)
in a browser instead? On first open, allow it once in System Settings → Privacy & Security →
**Open Anyway**.

## Use

Open SiteLock and enter your password.

- **Add** a site: `youtube.com` blocks YouTube and all its subdomains (`music.youtube.com` too);
  `www.youtube.com` blocks only YouTube itself. Pasted URLs are reduced to the host.
- **Unblock** for 5–120 minutes or a custom time; it is blocked again automatically.
  **Re-block now** ends it early.
- **Edit** (pencil) or **remove** (trash) an entry.
- **Change Password…** next to Lock.

Firefox only reads the list when it starts, so SiteLock restarts Firefox after each change.
Turn on Firefox → Settings → *Open previous windows and tabs* to keep your tabs.

## Update

Run the install command again and open SiteLock; it shows **Update** when the background
service is older. Your password and list are kept.

## Uninstall

In SiteLock (unlocked): **SiteLock → Uninstall SiteLock…** in the menu bar, then restart Firefox
and move the app to the Trash. Without the app:

```bash
sudo /Library/PrivilegedHelperTools/sitelockd uninstall
```

## Limitations

- Firefox only.
- It is an impulse barrier: anyone with admin rights can remove it.
- Forgotten password: `sudo rm "/Library/Application Support/SiteLock/auth.json" && sudo launchctl kickstart -k system/local.sitelock.daemon`,
  then set a new one in the app.

## Development

```bash
swift test              # unit tests
./scripts/build.sh      # universal build/SiteLock.app
```

Release: set the same version in `SiteLockVersion.current` (`Sources/SiteLockCore/IPC.swift`) and
`Resources/Info.plist`, merge, then push a tag `vX.Y.Z`; CI publishes `SiteLock.zip`.
