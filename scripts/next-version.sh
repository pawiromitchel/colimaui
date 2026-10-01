#!/bin/bash
# Prints the next release version, or "skip".
#   next-version.sh <latest-tag-or-empty> <newline-separated PR labels>
# Patch bump by default; label `minor` or `major` bumps those; label `skip-release` publishes nothing.
set -euo pipefail
latest="${1:-}"
labels="${2:-}"

if grep -qx 'skip-release' <<<"$labels"; then echo skip; exit 0; fi
if [ -z "$latest" ]; then echo "0.1.0"; exit 0; fi

IFS=. read -r major minor patch <<<"${latest#v}"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || { echo "bad tag: $latest" >&2; exit 1; }

if grep -qx 'major' <<<"$labels"; then major=$((major + 1)); minor=0; patch=0
elif grep -qx 'minor' <<<"$labels"; then minor=$((minor + 1)); patch=0
else patch=$((patch + 1)); fi
echo "$major.$minor.$patch"
