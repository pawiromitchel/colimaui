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

# The icon is drawn in code (Sources/ColimaBar/LlamaArt.swift), so the app and the icon share one design.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swiftc -parse-as-library -O -o build/make-icon scripts/IconTool.swift Sources/ColimaBar/LlamaArt.swift
build/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
