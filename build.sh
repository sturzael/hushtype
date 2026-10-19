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
# Signing: HUSHTYPE_SIGN_IDENTITY if set, else a self-signed "Hushtype Dev" cert if one is in the keychain, else ad-hoc.
# A stable identity (even self-signed and untrusted) keeps the Accessibility/Microphone grants across rebuilds.
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Hushtype Dev"'; then IDENTITY="Hushtype Dev"; fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
mkdir -p ~/Applications
rm -rf ~/Applications/Hushtype.app
cp -R "$APP" ~/Applications/Hushtype.app
echo "Installed ~/Applications/Hushtype.app (signed: ${IDENTITY:-ad-hoc})"
