#!/bin/bash
# End-to-end check on a disposable macOS machine (CI runner with passwordless sudo):
# install the built daemon, drive it over its socket like the app does, check the Firefox and
# Chrome policies, tamper repair, real blocking in headless Chrome, and uninstall.
# Never run this on your own Mac: it installs and removes SiteLock system-wide.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${CI:-}" == "true" ]] || { echo "e2e.sh only runs in CI (it changes system state)." >&2; exit 1; }

DAEMON=build/SiteLock.app/Contents/MacOS/sitelockd
PASSWORD=ci-password-1
FIREFOX_PLIST=/Library/Preferences/org.mozilla.firefox.plist
CHROME_PLIST="/Library/Managed Preferences/com.google.Chrome.plist"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SITE=https://example.com

step() { echo; echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# One JSON request per connection, like the app.
request() {
  python3 - "$1" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(60)
s.connect("/var/run/sitelockd.sock")
s.sendall((sys.argv[1] + "\n").encode())
data = b""
while not data.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
reply = json.loads(data)
print(json.dumps(reply))
sys.exit(0 if reply.get("ok") else 1)
EOF
}

# Prints the page Chrome renders for $SITE (fresh profile each time).
chrome_page() {
  local profile; profile=$(mktemp -d)
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$profile" --virtual-time-budget=5000 --dump-dom "$SITE" 2>/dev/null || true
  rm -rf "$profile"
}

wait_for() { # seconds, command...
  local n=$1; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done
  return 1
}

step "Baseline: Chrome loads $SITE"
[[ -x "$CHROME" ]] || fail "Google Chrome is not installed on this runner"
chrome_page | grep -q "Example Domain" || fail "baseline page did not load"

step "Install"
sudo "$DAEMON" install
sudo launchctl print system/local.sitelock.daemon >/dev/null || fail "LaunchDaemon not loaded"
test -x /Library/PrivilegedHelperTools/sitelockd || fail "helper not installed"

step "Set password, add example.com, enable Chrome"
request '{"command":"hello"}'
request "{\"command\":\"setup\",\"password\":\"$PASSWORD\"}"
request "{\"command\":\"add\",\"password\":\"$PASSWORD\",\"domain\":\"example.com\"}"
request "{\"command\":\"setBrowser\",\"password\":\"$PASSWORD\",\"browser\":\"com.google.Chrome\",\"enabled\":true}"
if request '{"command":"list","password":"wrong-password"}' >/dev/null; then fail "wrong password accepted"; fi

step "Policies written"
sudo plutil -p "$FIREFOX_PLIST"
sudo plutil -p "$FIREFOX_PLIST" | grep -q '\*://\*\.example\.com/\*' || fail "Firefox WebsiteFilter missing"
sudo plutil -p "$CHROME_PLIST"
sudo plutil -p "$CHROME_PLIST" | grep -q '"example.com"' || fail "Chrome URLBlocklist missing"

step "Tamper repair"
sudo rm -f "$CHROME_PLIST" "$FIREFOX_PLIST"
wait_for 10 sudo test -f "$CHROME_PLIST" || fail "Chrome policy not restored"
wait_for 10 sudo test -f "$FIREFOX_PLIST" || fail "Firefox policy not restored"
echo "both policy files restored"

step "Chrome blocks $SITE"
PAGE=$(chrome_page)
echo "$PAGE" | grep -o 'ERR_[A-Z_]*' | sort -u || true
if echo "$PAGE" | grep -q "Example Domain"; then
  fail "Chrome still loads $SITE: the Managed Preferences policy is not honoured"
fi
echo "blocked"

site_reachable() { curl -s --max-time 10 -o /dev/null "$SITE"; }
hosts_block_has() { # SiteLock block in /etc/hosts contains the given line
  sed -n '/^# BEGIN SiteLock/,/^# END SiteLock/p' /etc/hosts | grep -qxF "$1"
}

step "Safari: /etc/hosts block"
request "{\"command\":\"setBrowser\",\"password\":\"$PASSWORD\",\"browser\":\"com.apple.Safari\",\"enabled\":true}"
grep -A100 '^# BEGIN SiteLock' /etc/hosts
hosts_block_has "0.0.0.0 example.com" || fail "/etc/hosts lacks 0.0.0.0 example.com"
hosts_block_has "0.0.0.0 www.example.com" || fail "/etc/hosts lacks 0.0.0.0 www.example.com"
if site_reachable; then fail "curl still reaches $SITE with the hosts block in place"; fi
echo "blocked"

step "Safari: hosts tamper repair"
sudo sed -i '' '/example\.com/d' /etc/hosts
! hosts_block_has "0.0.0.0 example.com" || fail "test could not remove the block lines"
wait_for 10 hosts_block_has "0.0.0.0 example.com" || fail "/etc/hosts block not restored"
echo "block restored"

step "Safari off removes the block"
request "{\"command\":\"setBrowser\",\"password\":\"$PASSWORD\",\"browser\":\"com.apple.Safari\",\"enabled\":false}"
! grep -q 'BEGIN SiteLock' /etc/hosts || fail "/etc/hosts block left after disabling Safari"
site_reachable || fail "curl cannot reach $SITE after disabling Safari"
echo "unblocked"
request "{\"command\":\"setBrowser\",\"password\":\"$PASSWORD\",\"browser\":\"com.apple.Safari\",\"enabled\":true}"
wait_for 10 hosts_block_has "0.0.0.0 example.com" || fail "/etc/hosts block not written on re-enable"

step "Uninstall needs the password"
if printf 'wrong-password\n' | sudo "$DAEMON" uninstall; then fail "uninstall accepted a wrong password"; fi
printf '%s\n' "$PASSWORD" | sudo "$DAEMON" uninstall
! sudo launchctl print system/local.sitelock.daemon >/dev/null 2>&1 || fail "LaunchDaemon still loaded"
for f in /Library/PrivilegedHelperTools/sitelockd /Library/LaunchDaemons/local.sitelock.daemon.plist \
         "/Library/Application Support/SiteLock" "$CHROME_PLIST"; do
  if sudo test -e "$f"; then fail "$f left behind"; fi
done
! sudo plutil -p "$FIREFOX_PLIST" 2>/dev/null | grep -q WebsiteFilter || fail "Firefox policy left behind"

! grep -q 'BEGIN SiteLock' /etc/hosts || fail "/etc/hosts block left behind"

step "Chrome loads $SITE again"
chrome_page | grep -q "Example Domain" || fail "page still blocked after uninstall"

echo; echo "e2e passed"
