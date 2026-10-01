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

[ "$failures" -eq 0 ] && echo "release tooling ok" || { echo "$failures failure(s)"; exit 1; }
