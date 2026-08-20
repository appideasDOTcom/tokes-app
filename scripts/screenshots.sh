#!/bin/bash
# Renders the Mac App Store screenshots into build/appstore/screenshots/.
#
#   scripts/screenshots.sh
#
# Output is 2880x1800, one of the four sizes App Store Connect accepts for macOS.
#
# These drive the *real* StatusItemController, PopoverView and SettingsView —
# the harness compiles the app's own sources, it does not reimplement the UI. It
# builds with -DTOKES_APP_STORE deliberately: Settings offers different
# credential sources in the two flavors, and a screenshot must show the build
# being submitted.
#
# The data is synthetic (no RNG) and no real account usage is published to the
# listing. `now` is captured once per run, so every frame in a set shares one
# clock — the demo data is identical across the whole set by construction.
#
# Runs are NOT byte-identical across days: the chart's x-axis is
# `weekday(.abbreviated)`, so a set captured Tuesday carries different day labels
# from one captured Thursday. The values are the same; the labels shift. Capture
# a set in one run and do not mix frames between runs.
#
# --states renders the raw material the designer composites the store frames
# from — every app state, light and dark, no canvas or copy — into
# build/appstore/states/. That output keeps its alpha channel deliberately;
# see the header of packaging/appstore/screenshots/states/main.swift.
# It lives in its own directory because Swift only permits top-level
# expressions in a file named exactly main.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

HARNESS=packaging/appstore/screenshots/main.swift
OUTDIR="$ROOT/build/appstore/screenshots"
if [[ "${1:-}" == "--states" ]]; then
    HARNESS=packaging/appstore/screenshots/states/main.swift
    OUTDIR="$ROOT/build/appstore/states"
fi
WORK=$(mktemp -d -t tokes-shots)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"

# The harness is compiled into an .app bundle rather than run loose: SettingsView
# reads CFBundleShortVersionString from Bundle.main, and a bare executable has
# none — the footer would read "Tokes dev" in a shipping screenshot.
APP="$WORK/ScreenshotGen.app"
mkdir -p "$APP/Contents/MacOS"

# bash -c, because zsh does not word-split $SRC and swiftc would receive every
# filename as a single argument.
bash -c 'SRC=$(ls Sources/Tokes/*.swift Sources/Tokes/Views/*.swift | grep -v "Sources/Tokes/main.swift"); \
    swiftc -O -DTOKES_APP_STORE -o "'"$APP"'/Contents/MacOS/ScreenshotGen" \
        $SRC '"$HARNESS"'' 2>&1 | grep -E "^error:" && exit 1

/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open('scripts/Info.plist', 'rb'))
d['CFBundleExecutable'] = 'ScreenshotGen'
d['CFBundleIdentifier'] = 'com.appideas.tokes.screenshotgen'
plistlib.dump(d, open(sys.argv[1], 'wb'))
PY

rm -f "$OUTDIR"/*.png
OUT="$OUTDIR" "$APP/Contents/MacOS/ScreenshotGen"

# The harness gets its own defaults domain from its bundle id; don't leave it
# behind. It must go through `defaults delete`, NOT rm on the plist: cfprefsd
# holds the domain in memory and rewrites the file after an unlink, so the rm
# silently loses and the domain survives every run. Read back to prove it.
defaults delete com.appideas.tokes.screenshotgen 2>/dev/null || true
if defaults read com.appideas.tokes.screenshotgen >/dev/null 2>&1; then
    echo "warning: harness defaults domain survived cleanup" >&2
fi

echo ""
echo "Screenshots in $OUTDIR"
