#!/bin/bash
# Builds Tokes and assembles build/Tokes.app. Pass --run to (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Tokes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tokes "$APP/Contents/MacOS/Tokes"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Tokes 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched Tokes"
fi
