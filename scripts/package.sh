#!/bin/bash
# Builds a universal, versioned release archive in dist/:
#   dist/ColimaUI-<version>.zip and dist/ColimaUI-<version>.zip.sha256
# Usage: VERSION=1.2.3 ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, for example VERSION=1.2.3}"
ARCHS=universal VERSION="$VERSION" ./scripts/bundle.sh

mkdir -p dist
ZIP="dist/ColimaUI-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent build/ColimaUI.app "$ZIP"
(cd dist && shasum -a 256 "ColimaUI-$VERSION.zip" > "ColimaUI-$VERSION.zip.sha256")
echo "Packaged $ZIP"
cat "$ZIP.sha256"
