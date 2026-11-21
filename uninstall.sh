#!/bin/bash
# Removes SiteLock. Requires sudo AND the SiteLock password (if one was set).
#   sudo ./uninstall.sh
set -euo pipefail

LABEL=local.sitelock.daemon
HELPER=/Library/PrivilegedHelperTools/sitelockd
PLIST=/Library/LaunchDaemons/$LABEL.plist
APP=/Applications/SiteLock.app
DATA="/Library/Application Support/SiteLock"
SOCKET=/var/run/sitelockd.sock

if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo ./uninstall.sh" >&2; exit 1; fi

if [[ -f "$DATA/auth.json" ]]; then
  if [[ ! -x "$HELPER" ]]; then
    echo "$HELPER is missing, so the password cannot be checked. Nothing was removed." >&2
    exit 1
  fi
  read -r -s -p "SiteLock password: " PASSWORD
  echo
  if ! printf '%s\n' "$PASSWORD" | "$HELPER" verify-password; then
    echo "Wrong password. Nothing was removed." >&2
    exit 1
  fi
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true
if [[ -x "$HELPER" ]]; then
  "$HELPER" clear-policy || echo "Could not clear the Firefox policy keys; see README." >&2
fi
rm -f "$PLIST" "$HELPER" "$SOCKET" /var/log/sitelockd.log
rm -rf "$APP" "$DATA"

echo "SiteLock removed. Restart Firefox so it drops the blocklist."
