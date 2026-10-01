#!/bin/bash
# Builds ColimaBar and wraps it in build/ColimaBar.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ColimaBar"

APP=build/ColimaBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ColimaBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
if swift scripts/make-icon.swift "$ICONSET" 2>/dev/null && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  :
else
  echo "warning: icon generation failed, continuing without an icon" >&2
fi

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
