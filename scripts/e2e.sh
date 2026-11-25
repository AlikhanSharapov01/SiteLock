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

step "Live reload: one running Chrome follows list changes without a restart"
DEBUG_PROFILE=$(mktemp -d)
CDP_PY=$(mktemp)
DEBUG_CHROME_PID=""
trap '[[ -n "$DEBUG_CHROME_PID" ]] && kill "$DEBUG_CHROME_PID" 2>/dev/null || true' EXIT
# Minimal DevTools client (stdlib only, no WebSocket module): opens a fresh tab in the running
# Chrome, navigates to the URL, waits 3 s and prints "<document.title>|<location.href>".
cat >"$CDP_PY" <<'PYEOF'
import base64, json, os, socket, struct, sys, time, urllib.parse, urllib.request

def http(method, path):
    req = urllib.request.Request("http://127.0.0.1:9222" + path, method=method)
    return json.load(urllib.request.urlopen(req, timeout=10))

class WS:
    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.more()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise Exception("websocket handshake failed: " + head.decode(errors="replace"))
    def more(self):
        d = self.s.recv(65536)
        if not d:
            raise Exception("connection closed")
        return d
    def take(self, n):
        while len(self.buf) < n:
            self.buf += self.more()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out
    def send(self, text):
        data = text.encode()
        n = len(data)
        head = b"\x81" + (bytes([0x80 | n]) if n < 126 else b"\xfe" + struct.pack(">H", n) if n < 65536 else b"\xff" + struct.pack(">Q", n))
        mask = os.urandom(4)
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
    def recv(self):  # next complete text message (server frames are unmasked)
        msg = b""
        while True:
            b0, b1 = self.take(2)
            n = b1 & 0x7F
            if n == 126: n = struct.unpack(">H", self.take(2))[0]
            elif n == 127: n = struct.unpack(">Q", self.take(8))[0]
            payload = self.take(n)
            op = b0 & 0x0F
            if op == 8: raise Exception("websocket closed")
            if op in (0, 1):
                msg += payload
                if b0 & 0x80: return msg.decode()
    def call(self, i, method, params=None):
        self.send(json.dumps({"id": i, "method": method, "params": params or {}}))
        while True:
            m = json.loads(self.recv())
            if m.get("id") == i:
                if "error" in m: raise Exception(str(m["error"]))
                return m["result"]
    def value(self, i, expr):
        return self.call(i, "Runtime.evaluate", {"expression": expr, "returnByValue": True})["result"].get("value")

# usage: cdp.py URL  ->  prints "<title>|<href>" of a fresh tab in the running Chrome
target = http("PUT", "/json/new?about:blank")
try:
    ws = WS(target["webSocketDebuggerUrl"])
    ws.call(1, "Page.navigate", {"url": sys.argv[1]})
    time.sleep(3)
    print(f"{ws.value(2, 'document.title')}|{ws.value(3, 'location.href')}")
finally:
    try: urllib.request.urlopen("http://127.0.0.1:9222/json/close/" + target["id"], timeout=5).read()
    except Exception: pass
PYEOF

"$CHROME" --headless=new --remote-debugging-port=9222 --user-data-dir="$DEBUG_PROFILE" \
  --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
DEBUG_CHROME_PID=$!
wait_for 30 curl -sf http://127.0.0.1:9222/json/version >/dev/null || fail "debugging Chrome did not start"

cdp_page() { python3 "$CDP_PY" "$SITE" 2>&1 || true; }
is_loaded() { [[ "$1" == "Example Domain|"* ]]; }
# Re-navigates for up to 15 s until the page is (want=loaded) or is not (want=blocked) example.com.
wait_page() {
  local want=$1 out
  for _ in 1 2 3 4 5; do
    out=$(cdp_page); echo "  -> $out" >&2
    if is_loaded "$out"; then [[ $want == loaded ]] && return 0; else [[ $want == blocked ]] && return 0; fi
  done
  return 1
}

LIVE_OK=1
page=$(cdp_page); echo "initial: $page"
if is_loaded "$page"; then fail "running Chrome loads $SITE although it is blocked"; fi

request "{\"command\":\"remove\",\"password\":\"$PASSWORD\",\"domain\":\"example.com\"}" >/dev/null
if wait_page loaded; then echo "PASS: live unblock (Chrome was not restarted)"; else echo "FAIL: live unblock: running Chrome still blocks $SITE" >&2; LIVE_OK=0; fi
kill -0 "$DEBUG_CHROME_PID" 2>/dev/null || { echo "FAIL: the daemon quit the debugging Chrome" >&2; LIVE_OK=0; }

request "{\"command\":\"add\",\"password\":\"$PASSWORD\",\"domain\":\"example.com\"}" >/dev/null
if wait_page blocked; then echo "PASS: live re-block (Chrome was not restarted)"; else echo "FAIL: live re-block: running Chrome still loads $SITE" >&2; LIVE_OK=0; fi

kill "$DEBUG_CHROME_PID" 2>/dev/null || true
DEBUG_CHROME_PID=""
rm -rf "$DEBUG_PROFILE" "$CDP_PY"
[[ $LIVE_OK == 1 ]] || fail "live reload check failed"

step "Uninstall needs the password"
if printf 'wrong-password\n' | sudo "$DAEMON" uninstall; then fail "uninstall accepted a wrong password"; fi
printf '%s\n' "$PASSWORD" | sudo "$DAEMON" uninstall
! sudo launchctl print system/local.sitelock.daemon >/dev/null 2>&1 || fail "LaunchDaemon still loaded"
for f in /Library/PrivilegedHelperTools/sitelockd /Library/LaunchDaemons/local.sitelock.daemon.plist \
         "/Library/Application Support/SiteLock" "$CHROME_PLIST"; do
  if sudo test -e "$f"; then fail "$f left behind"; fi
done
! sudo plutil -p "$FIREFOX_PLIST" 2>/dev/null | grep -q WebsiteFilter || fail "Firefox policy left behind"

step "Chrome loads $SITE again"
chrome_page | grep -q "Example Domain" || fail "page still blocked after uninstall"

echo; echo "e2e passed"
