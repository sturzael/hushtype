#!/bin/bash
# Builds Hushtype.app into ./dist and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -3
APP=dist/Hushtype.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hushtype "$APP/Contents/MacOS/Hushtype"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Bundle resources WhisperKit's dependencies may ship.
for b in .build/release/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
IDENTITY="${HUSHTYPE_SIGN_IDENTITY:-}"
# Optional: export HUSHTYPE_SIGN_IDENTITY="Developer ID Application: …" (or any trusted identity) so macOS keeps permissions across rebuilds.
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
mkdir -p ~/Applications
rm -rf ~/Applications/Hushtype.app
cp -R "$APP" ~/Applications/Hushtype.app
echo "Installed ~/Applications/Hushtype.app (signed: ${IDENTITY:-ad-hoc})"
