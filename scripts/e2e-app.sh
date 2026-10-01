#!/bin/bash
# End-to-end check of the packaged app against the real Colima:
#   1. builds the .app bundle and verifies its structure and signature
#   2. launches it headless (--dump-state) and validates what it read from Docker
#   3. renders the main window to a PNG (--snapshot)
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
run_with_timeout() { # seconds, command...
  local secs=$1; shift
  "$@" & local pid=$!
  for _ in $(seq 1 "$secs"); do kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }; sleep 1; done
  kill "$pid" 2>/dev/null || true; return 124
}

./scripts/bundle.sh
APP=build/ColimaBar.app
EXE="$APP/Contents/MacOS/ColimaBar"

[ -x "$EXE" ] || fail "missing executable"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "invalid Info.plist"
codesign --verify --strict "$APP" || fail "signature check failed"
echo "ok  bundle structure and signature"

STATE=build/e2e-state.json
rm -f "$STATE"
run_with_timeout 60 "$EXE" --dump-state "$STATE" || fail "app did not exit cleanly in time"
[ -s "$STATE" ] || fail "app wrote no state"

python3 - "$STATE" <<'PY'
import json, subprocess, sys
state = json.load(open(sys.argv[1]))
assert state["toolMissing"] is None, f"tool missing: {state['toolMissing']}"
assert state["profiles"], "no Colima profiles read"
running = [p for p in state["profiles"] if p["status"] == "running"]
assert running, "no running profile; start Colima first"
assert not state["errors"], f"errors: {state['errors']}"

# Cross-check against docker itself.
docker_ids = set(subprocess.run(["docker", "ps", "-aq"], capture_output=True, text=True, check=True).stdout.split())
app_ids = {c["id"] for c in state["containers"]}
assert {i[:12] for i in docker_ids} == {i[:12] for i in app_ids}, f"container mismatch: docker={docker_ids} app={app_ids}"
total = sum(g["total"] for g in state["groups"])
assert total == len(state["containers"]), "groups do not cover all containers"
# Dashboard data: disk breakdown must match docker, VM disk must be read from the Docker data mount.
df = {r["Type"]: r for r in map(json.loads, subprocess.run(
    ["docker", "system", "df", "--format", "{{json .}}"], capture_output=True, text=True, check=True).stdout.splitlines())}
usage = {e["type"]: e for e in (state["diskUsage"] or [])}
assert usage, "dashboard has no disk usage"
assert usage["images"]["count"] == int(df["Images"]["TotalCount"]), "image count differs from docker system df"
assert state["vmDisk"] and state["vmDisk"]["total"] > 0 and state["vmDisk"]["used"] > 0, "no VM disk reading"
assert state["vmDisk"]["used"] <= state["vmDisk"]["total"], "VM disk used exceeds total"
assert state["historySamples"] >= 1, "no sparkline samples"
print(f"ok  dashboard: vm disk {state['vmDisk']['used']//2**30}/{state['vmDisk']['total']//2**30} GiB on {state['vmDisk']['mount']}, "
      f"{len(state['attention'])} attention item(s)")
print(f"ok  app read {len(state['containers'])} containers in {len(state['groups'])} groups, "
      f"{state['images']} images, {state['volumes']} volumes, {state['networks']} networks")
PY

PNG=build/e2e-snapshot.png
rm -f "$PNG"
run_with_timeout 60 "$EXE" --snapshot "$PNG" || fail "snapshot timed out"
[ -s "$PNG" ] || fail "no snapshot written"
python3 -c "
import struct,sys
d=open('$PNG','rb').read(32)
assert d[:8]==b'\x89PNG\r\n\x1a\n','not a PNG'
w,h=struct.unpack('>II',d[16:24]); assert w>=800 and h>=500,(w,h)
print(f'ok  snapshot {w}x{h}')"
# Launch the real GUI (window + menu bar item) and make sure it stays up.
pkill -x ColimaBar 2>/dev/null || true
sleep 1
open -n "$APP"
sleep 6
pgrep -x ColimaBar >/dev/null || fail "app crashed on launch"
pkill -x ColimaBar || true
echo "ok  packaged app launched and stayed running"
echo "e2e passed"
