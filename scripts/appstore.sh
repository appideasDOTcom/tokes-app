#!/bin/bash
# Builds, signs, packages, validates and uploads the Mac App Store submission.
#
#   scripts/appstore.sh                # build + sign + audit -> .pkg
#   scripts/appstore.sh --validate     # ...then validate against App Store Connect
#   scripts/appstore.sh --upload       # ...then upload it
#   scripts/appstore.sh --build-status # what Apple has done with what we sent
#
# Credentials and signing identities are discovered, not passed: API keys come
# from packaging/appstore/asc-credentials.env (git-ignored, see the .example),
# and the two signing identities are found in the login keychain. Overrides
# exist for every one of them, but the zero-argument form is the intended one —
# nothing here should ever need a secret pasted into a terminal or a prompt.
#
# Prerequisites, all produced by scripts/appstore-certs.py:
#   * Apple Distribution + 3rd Party Mac Developer Installer certificates
#   * packaging/appstore/embedded.provisionprofile
#
# This is a different artifact from scripts/release.sh, which produces the
# notarized .zip the Homebrew cask consumes. Both pipelines stay working.
set -euo pipefail
cd "$(dirname "$0")/.."

CREDS=packaging/appstore/asc-credentials.env
# shellcheck disable=SC1090
[[ -f "$CREDS" ]] && source "$CREDS"

APP_IDENTITY="${ASC_SIGN_APP:-}"
PKG_IDENTITY="${ASC_SIGN_PKG:-}"
KEY_ID="${ASC_KEY_ID:-}"
ISSUER_ID="${ASC_ISSUER_ID:-}"
P8="${ASC_P8:-}"
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign-app) APP_IDENTITY="$2"; shift 2 ;;
        --sign-pkg) PKG_IDENTITY="$2"; shift 2 ;;
        --key-id) KEY_ID="$2"; shift 2 ;;
        --issuer) ISSUER_ID="$2"; shift 2 ;;
        --p8) P8="$2"; shift 2 ;;
        --validate) ACTION=validate; shift ;;
        --upload) ACTION=upload; shift ;;
        --build-status) ACTION=status; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

# ------------------------------------------------------------- credentials --
need_api() {
    [[ -n "$KEY_ID" && -n "$ISSUER_ID" && -n "$P8" ]] || die \
"App Store Connect credentials not found.
Copy $CREDS.example to $CREDS and fill it in, or pass --key-id/--issuer/--p8."
    [[ -f "$P8" ]] || die "API key file not found: $P8"
}

# altool writes the JWT to stderr, after a banner line.
jwt() {
    xcrun altool --generate-jwt --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID" \
        --p8-file-path "$P8" 2>&1 | grep -E '^ey[A-Za-z0-9_-]+\.' | head -1
}

# curl globs [ and ], which silently mangles filter[...] query parameters.
asc() { curl -sg -H "Authorization: Bearer $(jwt)" "https://api.appstoreconnect.apple.com/v1/$1"; }

# ------------------------------------------------------------- build status --
if [[ "$ACTION" == status ]]; then
    need_api
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' scripts/Info.plist)
    APP_RESOURCE=$(asc "apps?filter[bundleId]=$BUNDLE_ID" \
        | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")')
    [[ -n "$APP_RESOURCE" ]] || die "no App Store Connect record for $BUNDLE_ID"
    asc "builds?filter[app]=$APP_RESOURCE&limit=20" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
if not data:
    print("No builds yet. Apple takes a few minutes to process an upload.")
for b in data:
    a = b["attributes"]
    print("  build %-8s %-24s uploaded %s  expired=%s"
          % (a.get("version"), a.get("processingState"),
             (a.get("uploadedDate") or "")[:19], a.get("expired")))
'
    exit 0
fi

# ------------------------------------------------------ identity discovery --
find_identity() {
    local pattern="$1" label="$2" found count
    found=$(security find-identity -v | grep -oE "\"$pattern[^\"]*\"" | tr -d '"' | sort -u)
    count=$(grep -c . <<<"$found" || true)
    [[ -n "$found" ]] || die \
"no \"$label\" certificate in the login keychain.
Run: scripts/appstore-certs.py   (it creates both certificates and the profile)"
    [[ "$count" -eq 1 ]] || die \
"$count \"$label\" identities in the keychain — pick one explicitly:
$(sed 's/^/  /' <<<"$found")"
    printf '%s' "$found"
}

[[ -n "$APP_IDENTITY" ]] || APP_IDENTITY=$(find_identity "Apple Distribution: " "Apple Distribution")
[[ -n "$PKG_IDENTITY" ]] || PKG_IDENTITY=$(find_identity "3rd Party Mac Developer Installer: " "3rd Party Mac Developer Installer")

PROFILE=packaging/appstore/embedded.provisionprofile
[[ -f "$PROFILE" ]] || die \
"$PROFILE is missing.
Run: scripts/appstore-certs.py   (it downloads the profile to that path)"

echo "Signing app with: $APP_IDENTITY"
echo "Signing pkg with: $PKG_IDENTITY"
echo ""

# ------------------------------------------------- build-number pre-flight --
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)

if [[ "$ACTION" == upload ]]; then
    need_api
    # App Store Connect rejects a duplicate CFBundleVersion, and it rejects it
    # *after* the upload — which is a full build, sign and transfer wasted.
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' scripts/Info.plist)
    APP_RESOURCE=$(asc "apps?filter[bundleId]=$BUNDLE_ID" \
        | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d[0]["id"] if d else "")')
    if [[ -n "$APP_RESOURCE" ]]; then
        CLASH=$(asc "builds?filter[app]=$APP_RESOURCE&limit=200" | /usr/bin/python3 -c "
import json, sys
want = '$BUILD'
print('yes' if any(b['attributes'].get('version') == want
                   for b in json.load(sys.stdin).get('data', [])) else '')
")
        [[ -z "$CLASH" ]] || die \
"CFBundleVersion $BUILD has already been uploaded for $BUNDLE_ID.
Bump it in scripts/Info.plist and run again — every upload needs a new build
number, even when CFBundleShortVersionString ($VERSION) is unchanged."
    fi
fi

# ------------------------------------------------------------ build + sign --
./scripts/build.sh --app-store --sign "$APP_IDENTITY"

# Refuse to package something that fails the compliance audit. A submission that
# reaches App Review with an out-of-container credential reader in it costs days.
echo ""
./scripts/verify-appstore.sh --static-only || die "compliance audit failed — not packaging"

APP=build/appstore/Tokes.app
PKG="build/appstore/Tokes-$VERSION.pkg"

rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" "$PKG"

echo ""
echo "Submission artifact: $PKG  (version $VERSION, build $BUILD)"

case "$ACTION" in
    validate|upload)
        need_api
        echo ""
        xcrun altool "--$ACTION-app" -f "$PKG" -t macos \
            --api-key "$KEY_ID" --api-issuer "$ISSUER_ID" --p8-file-path "$P8"
        if [[ "$ACTION" == upload ]]; then
            echo ""
            echo "Uploaded. Apple processes the build before it appears in App Store Connect:"
            echo "  scripts/appstore.sh --build-status"
            echo ""
            echo "This does NOT submit for review — the build waits under the app's"
            echo "Builds section until you submit it there. Bump CFBundleVersion in"
            echo "scripts/Info.plist ($BUILD -> $((BUILD + 1))) before the next upload."
        fi
        ;;
    "")
        echo ""
        echo "Next: scripts/appstore.sh --validate    (then --upload)"
        echo "Or open $PKG in Transporter.app."
        ;;
esac
