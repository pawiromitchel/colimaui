#!/bin/bash
# Commits the Homebrew cask for a release to main.   Usage: update-cask.sh <version> <sha256> [remote] [branch]
#
# The cask is a generated file, so this always starts from the newest main instead of merging. Two releases
# that finish close together (each run checked out main before the other's cask commit) would otherwise
# conflict on the same lines. It also never moves the cask backwards.
set -euo pipefail
VERSION="${1:?version}"
SHA="${2:?sha256}"
REMOTE="${3:-origin}"
BRANCH="${4:-main}"

for attempt in 1 2 3 4 5; do
  git fetch -q "$REMOTE" "$BRANCH"
  git reset -q --hard "$REMOTE/$BRANCH"

  current=$(sed -n 's/^  version "\(.*\)"$/\1/p' Casks/colimaui.rb 2>/dev/null | head -n1 || true)
  if [ -n "$current" ] && [ "$current" != "$VERSION" ] \
     && [ "$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -n1)" = "$current" ]; then
    echo "Cask is already at $current, newer than $VERSION; leaving it alone."
    exit 0
  fi

  mkdir -p Casks
  ./scripts/render-cask.sh "$VERSION" "$SHA" > Casks/colimaui.rb
  git add Casks/colimaui.rb
  if git diff --cached --quiet; then echo "Cask is already at $VERSION."; exit 0; fi
  git commit -q -m "Update Homebrew cask to $VERSION"
  if git push -q "$REMOTE" "HEAD:$BRANCH"; then echo "Cask updated to $VERSION."; exit 0; fi
  echo "Push failed (attempt $attempt), retrying from the latest $BRANCH..." >&2
  sleep $((attempt * 2))
done
echo "Could not update the cask." >&2
exit 1
