#!/bin/bash
# Regenerates the README screenshots from the built-in demo setup (no Colima needed, no real containers shown).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
mkdir -p docs/screenshots
.build/debug/ColimaUI --demo --screenshots docs/screenshots &
PID=$!
for _ in $(seq 1 90); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill "$PID" 2>/dev/null || true
ls -1 docs/screenshots
