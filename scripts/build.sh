#!/bin/bash
# Builds universal (arm64 + x86_64) binaries into ./build:
#   build/sitelockd       – the root LaunchDaemon
#   build/SiteLock.app    – the GUI
# Run as your normal user (not sudo). Needs Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $EUID -eq 0 ]]; then
  echo "Run build.sh as your normal user, not with sudo." >&2
  exit 1
fi

# Two single-architecture builds + lipo work with the Command Line Tools alone
# (a single multi-arch `swift build` would require full Xcode).
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --build-path ".build/$arch"
done
bin() { swift build -c release --arch "$1" --build-path ".build/$1" --show-bin-path; }
ARM=$(bin arm64)
X86=$(bin x86_64)

rm -rf build
APP=build/SiteLock.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM/sitelockd" "$X86/sitelockd" -output build/sitelockd
lipo -create "$ARM/SiteLock" "$X86/SiteLock" -output "$APP/Contents/MacOS/SiteLock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signatures: no Apple Developer account needed; Apple silicon requires a signature to run.
codesign --force --sign - --identifier local.sitelock.daemon build/sitelockd
codesign --force --sign - "$APP"

lipo -info build/sitelockd "$APP/Contents/MacOS/SiteLock"
echo "Built ./build/sitelockd and ./build/SiteLock.app. Next: sudo ./install.sh"
