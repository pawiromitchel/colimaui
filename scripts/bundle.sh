#!/bin/bash
# Builds ColimaUI and wraps it in build/ColimaUI.app (ad-hoc signed).
#   VERSION=1.2.3          version written to Info.plist (default 0.1.0)
#   BUILD_NUMBER=42        CFBundleVersion (default 1)
#   ARCHS=universal        arm64 + x86_64 in one binary (default: this Mac's architecture)
#   CONFIG=debug           build configuration (default release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-host}"
MIN_OS=14.0

APP=build/ColimaUI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$ARCHS" = "universal" ]; then
  # `swift build --arch a --arch b` needs Xcode's build system; building each slice and merging works anywhere.
  SLICES=()
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --triple "$arch-apple-macosx$MIN_OS"
    SLICES+=("$(swift build -c "$CONFIG" --triple "$arch-apple-macosx$MIN_OS" --show-bin-path)/ColimaUI")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/ColimaUI"
else
  swift build -c "$CONFIG"
  cp "$(swift build -c "$CONFIG" --show-bin-path)/ColimaUI" "$APP/Contents/MacOS/ColimaUI"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# The icon is drawn in code (Sources/ColimaUI/LlamaArt.swift), so the app and the icon share one design.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swiftc -parse-as-library -O -o build/make-icon scripts/IconTool.swift Sources/ColimaUI/LlamaArt.swift
build/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/ColimaUI"))"
