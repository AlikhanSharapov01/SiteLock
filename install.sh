#!/bin/bash
# One-time install of SiteLock (asks for your Mac admin password once, via sudo).
#   ./scripts/build.sh        # as your user
#   sudo ./install.sh
# Installs:
#   /Library/PrivilegedHelperTools/sitelockd          root daemon binary
#   /Library/LaunchDaemons/local.sitelock.daemon.plist starts it at boot, keeps it alive
#   /Applications/SiteLock.app                        the GUI
# Data (password hash, list) lives in /Library/Application Support/SiteLock (root only).
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.sitelock.daemon
HELPER=/Library/PrivilegedHelperTools/sitelockd
PLIST=/Library/LaunchDaemons/$LABEL.plist
APP=/Applications/SiteLock.app
SOCKET=/var/run/sitelockd.sock

if [[ "$(uname -s)" != Darwin ]]; then echo "SiteLock runs on macOS only." >&2; exit 1; fi
if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo ./install.sh" >&2; exit 1; fi
if [[ ! -x build/sitelockd || ! -d build/SiteLock.app ]]; then
  echo "Build first, as your normal user: ./scripts/build.sh" >&2
  exit 1
fi

# Replace a previous version (keeps the password and the list).
if launchctl bootout "system/$LABEL" 2>/dev/null; then
  for _ in $(seq 1 20); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.25
  done
fi
rm -f "$SOCKET"

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 build/sitelockd "$HELPER"

rm -rf "$APP"
ditto build/SiteLock.app "$APP"
chown -R root:wheel "$APP"
chmod -R go-w "$APP"

# Gatekeeper: locally built files carry no quarantine flag; clear it in case they were copied in.
xattr -dr com.apple.quarantine "$HELPER" "$APP" 2>/dev/null || true

install -o root -g wheel -m 644 "Resources/$LABEL.plist" "$PLIST"
launchctl enable "system/$LABEL"
launchctl bootstrap system "$PLIST"

for _ in $(seq 1 20); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.5
done
if [[ ! -S "$SOCKET" ]]; then
  echo "sitelockd did not start. See /var/log/sitelockd.log" >&2
  exit 1
fi

echo "SiteLock installed and running."
echo "Open /Applications/SiteLock.app to set your SiteLock password and add sites."
