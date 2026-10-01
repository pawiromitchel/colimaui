#!/bin/bash
# Builds ColimaUI and wraps it in build/ColimaUI.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ColimaUI"

APP=build/ColimaUI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ColimaUI"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn in code (Sources/ColimaUI/LlamaArt.swift), so the app and the icon share one design.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swiftc -parse-as-library -O -o build/make-icon scripts/IconTool.swift Sources/ColimaUI/LlamaArt.swift
build/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
