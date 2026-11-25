# SiteLock

Password-protected site blocking for Firefox on macOS 13+.

## Install

```bash
curl -fsSL https://github.com/AlikhanSharapov01/SiteLock/releases/latest/download/SiteLock.zip -o /tmp/SiteLock.zip && rm -rf /Applications/SiteLock.app && ditto -x -k /tmp/SiteLock.zip /Applications && rm /tmp/SiteLock.zip && open /Applications/SiteLock.app
```

Then click **Install** in the app and set your SiteLock password.
Updates: **Check for Updates…** in the app (or run the command again).

## Use

- `youtube.com` blocks YouTube and its subdomains; `www.youtube.com` leaves `music.youtube.com` open.
- Unblock a site for a set time; it is blocked again automatically.
- Firefox restarts after each change to load the new list.

## Uninstall

**Uninstall SiteLock…** in the app (needs your SiteLock password), or:

```bash
sudo /Library/PrivilegedHelperTools/sitelockd uninstall
```

Works in Firefox only. Anyone with admin rights can remove it.
