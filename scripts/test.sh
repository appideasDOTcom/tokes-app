#!/bin/bash
# Runs the suite in both build configurations.
#
# The App Store build compiles with -DTOKES_APP_STORE, which removes whole
# functions. Testing only the default configuration would leave that half
# unbuilt — and the guards around it are the compliance mechanism, so a break
# there is a compliance break, not a test break.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== direct build ==="
swift test

echo ""
echo "=== App Store build (-DTOKES_APP_STORE) ==="
swift test --scratch-path .build-appstore-test -Xswiftc -DTOKES_APP_STORE
