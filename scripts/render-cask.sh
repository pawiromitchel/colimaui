#!/bin/bash
# Prints the Homebrew cask for a release.   Usage: render-cask.sh <version> <sha256> [url-override]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version}"
SHA="${2:?sha256}"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "not a sha256: $SHA" >&2; exit 1; }
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" scripts/colimaui.rb.tmpl
