#!/bin/bash
# Runs the test suite. Swift Testing ships with the Command Line Tools but
# SwiftPM doesn't add its framework path, so we pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$DEV/Frameworks/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F"$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi
exec swift test "$@"
