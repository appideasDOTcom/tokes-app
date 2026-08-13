#!/bin/bash
# Packages a distributable release zip of Tokes.app.
#
# Usage:
#   scripts/release.sh                                              # ad-hoc signed
#   scripts/release.sh --sign "Developer ID Application: Name (TEAMID)"
#   scripts/release.sh --sign "..." --notarize <notarytool-keychain-profile>
#
# Produces build/Tokes-<version>.zip and prints its sha256 (needed by the
# Homebrew cask). Ad-hoc builds work but get Gatekeeper-quarantined on other
# machines; --sign + --notarize makes installs frictionless.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=""
NOTARIZE_PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize) NOTARIZE_PROFILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

./scripts/build.sh

APP=build/Tokes.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)
ZIP="build/Tokes-$VERSION.zip"

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "$NOTARIZE_PROFILE" ]]; then
    [[ -n "$SIGN_IDENTITY" ]] || { echo "--notarize requires --sign" >&2; exit 1; }
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo ""
echo "Release artifact: $ZIP"
shasum -a 256 "$ZIP"
