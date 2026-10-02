#!/bin/bash
# Regenerates the screenshots from the built-in sample setup (no Colima needed, no real containers shown):
#   docs/screenshots/        light set, used by the landing page (plus dashboard-dark.png for its dark mode and share preview)
#   docs/screenshots/dark/   dark set, used by the README and the portfolio
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
mkdir -p docs/screenshots
.build/debug/ColimaUI --screenshots docs/screenshots &
PID=$!
for _ in $(seq 1 180); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill "$PID" 2>/dev/null || true
ls -1 docs/screenshots docs/screenshots/dark
