#!/bin/bash
# Checks the release tooling that otherwise only runs when a pull request merges.
set -uo pipefail
cd "$(dirname "$0")/.."
failures=0
expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

expect "first release"                     "0.1.0" "$(./scripts/next-version.sh "" "")"
expect "patch by default"                  "1.4.3" "$(./scripts/next-version.sh v1.4.2 "")"
expect "unrelated labels still patch"      "1.4.3" "$(./scripts/next-version.sh v1.4.2 $'bug\ndocs')"
expect "minor label"                       "1.5.0" "$(./scripts/next-version.sh v1.4.2 "minor")"
expect "major label"                       "2.0.0" "$(./scripts/next-version.sh v1.4.2 "major")"
expect "major wins over minor"             "2.0.0" "$(./scripts/next-version.sh v1.4.2 $'minor\nmajor')"
expect "skip-release wins"                 "skip"  "$(./scripts/next-version.sh v1.4.2 $'major\nskip-release')"
expect "double digit versions"             "0.10.0" "$(./scripts/next-version.sh v0.9.9 "minor")"
expect "label must match exactly"          "1.4.3" "$(./scripts/next-version.sh v1.4.2 "not-a-minor-change")"
./scripts/next-version.sh "vNext" "" >/dev/null 2>&1; expect "rejects a malformed tag" "1" "$?"

SHA=$(printf 'x' | shasum -a 256 | cut -d' ' -f1)
cask=$(./scripts/render-cask.sh 2.3.4 "$SHA")
expect "cask has the version"              "1" "$(grep -c 'version "2.3.4"' <<<"$cask")"
expect "cask has the checksum"             "1" "$(grep -c "sha256 \"$SHA\"" <<<"$cask")"
expect "cask has no placeholders left"     "0" "$(grep -c '__' <<<"$cask")"
expect "cask is valid ruby"                "Syntax OK" "$(ruby -c <<<"$cask" 2>&1)"
./scripts/render-cask.sh 1.0.0 "not-a-hash" >/dev/null 2>&1; expect "cask rejects a bad checksum" "1" "$?"

# Two releases finishing back to back: the second run's checkout predates the first run's cask commit.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/scripts"
cp scripts/render-cask.sh scripts/colimaui.rb.tmpl scripts/update-cask.sh "$tmp/seed/scripts/"
( cd "$tmp/seed" && git checkout -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm seed && git push -q origin main )
git clone -q "$tmp/remote.git" "$tmp/first" && git clone -q "$tmp/remote.git" "$tmp/second"   # both predate any cask commit
for d in first second; do git -C "$tmp/$d" config user.name t; git -C "$tmp/$d" config user.email t@t; done
SHA1=$(printf 'one' | shasum -a 256 | cut -d' ' -f1); SHA2=$(printf 'two' | shasum -a 256 | cut -d' ' -f1)
( cd "$tmp/first" && ./scripts/update-cask.sh 0.1.1 "$SHA1" >/dev/null 2>&1 ); expect "first release updates the cask" "0" "$?"
( cd "$tmp/second" && ./scripts/update-cask.sh 0.1.2 "$SHA2" >/dev/null 2>&1 ); expect "stale checkout still updates the cask" "0" "$?"
remote_cask=$(git --git-dir="$tmp/remote.git" show main:Casks/colimaui.rb)
expect "remote cask is at the newest version" "1" "$(grep -c 'version "0.1.2"' <<<"$remote_cask")"
expect "remote cask has the newest checksum"  "1" "$(grep -c "sha256 \"$SHA2\"" <<<"$remote_cask")"
expect "no duplicate cask commits"            "2" "$(git --git-dir="$tmp/remote.git" log --oneline main -- Casks/colimaui.rb | wc -l | tr -d ' ')"
( cd "$tmp/first" && ./scripts/update-cask.sh 0.1.1 "$SHA1" >/dev/null 2>&1 )
expect "an older release never downgrades"    "1" "$(git --git-dir="$tmp/remote.git" show main:Casks/colimaui.rb | grep -c 'version "0.1.2"')"
( cd "$tmp/second" && ./scripts/update-cask.sh 0.1.2 "$SHA2" >/dev/null 2>&1 )
expect "re-running the same release is a no-op" "2" "$(git --git-dir="$tmp/remote.git" log --oneline main -- Casks/colimaui.rb | wc -l | tr -d ' ')"

[ "$failures" -eq 0 ] && echo "release tooling ok" || { echo "$failures failure(s)"; exit 1; }
