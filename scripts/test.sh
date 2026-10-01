#!/bin/bash
# Runs the test suite.
# With only the Command Line Tools installed, SwiftPM can't find the Swift Testing framework that ships
# with them, so its path is passed explicitly. With full Xcode (CI) plain `swift test` just works.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$DEV/Frameworks/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F"$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi
exec swift test "$@"
