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
# The data is synthetic and deterministic (no RNG), so re-running produces the
# same images and no real account usage is published to the listing.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

OUTDIR="$ROOT/build/appstore/screenshots"
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
        $SRC packaging/appstore/screenshots/main.swift' 2>&1 | grep -E "^error:" && exit 1

/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open('scripts/Info.plist', 'rb'))
d['CFBundleExecutable'] = 'ScreenshotGen'
d['CFBundleIdentifier'] = 'com.appideas.tokes.screenshotgen'
plistlib.dump(d, open(sys.argv[1], 'wb'))
PY

rm -f "$OUTDIR"/*.png
OUT="$OUTDIR" "$APP/Contents/MacOS/ScreenshotGen"

# The harness gets its own defaults domain from its bundle id; don't leave it behind.
rm -f "$HOME/Library/Preferences/com.appideas.tokes.screenshotgen.plist"

echo ""
echo "Screenshots in $OUTDIR"
