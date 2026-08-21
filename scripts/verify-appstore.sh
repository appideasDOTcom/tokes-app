#!/bin/bash
# Audits build/appstore/Tokes.app against the rules the Mac App Store build has
# to meet, and proves the sandbox is actually on by running the thing.
#
#   scripts/build.sh --app-store && scripts/verify-appstore.sh
#   scripts/verify-appstore.sh --static-only     # skip the launch
#
# Why this exists: the compliance boundary is App Review Guideline 2.5.2, not
# the sandbox kernel, and those are not the same set. Measured on a real
# sandboxed bundle, the kernel denies reads of ~/.claude/.credentials.json and
# ~/.config/github-copilot/apps.json but *allows* both spawning /usr/bin/security
# and SecItemCopyMatching against Claude Code's keychain item. Tokes declines
# those anyway. Nothing enforces that but this script.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=build/appstore/Tokes.app
BIN="$APP/Contents/MacOS/Tokes"
BUNDLE_ID=com.appideas.tokes
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data"
STATIC_ONLY=""
[[ "${1:-}" == "--static-only" ]] && STATIC_ONLY=1

PASS=0
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [[ ! -d "$APP" ]]; then
    echo "Missing $APP — run scripts/build.sh --app-store first." >&2
    exit 1
fi

# ---------------------------------------------------------------- signature --
head2 "Code signature and entitlements"

if codesign --verify --strict --deep "$APP" 2>/dev/null; then
    pass "signature verifies (--strict --deep)"
else
    fail "signature does not verify"
fi

# Dump entitlements to a real plist. Not `plutil -extract`: it reads dots as
# keypath separators, so every com.apple.security.* key looks absent.
ENT_PLIST=$(mktemp -t tokes-entitlements).plist
codesign -d --entitlements "$ENT_PLIST" --xml "$APP" 2>/dev/null \
    || codesign -d --entitlements - "$APP" 2>/dev/null >"$ENT_PLIST"
plutil -convert xml1 "$ENT_PLIST" 2>/dev/null
trap 'rm -f "$ENT_PLIST"' EXIT

has_ent() { [[ $(/usr/libexec/PlistBuddy -c "Print :$1" "$ENT_PLIST" 2>/dev/null) == "true" ]]; }

# 2.4.5(i) — Mac App Store apps must be sandboxed.
has_ent "com.apple.security.app-sandbox" \
    && pass "com.apple.security.app-sandbox is set" \
    || fail "com.apple.security.app-sandbox is MISSING — this is not an App Store build"

has_ent "com.apple.security.network.client" \
    && pass "com.apple.security.network.client is set (outbound HTTPS)" \
    || fail "com.apple.security.network.client is missing — polling will fail"

has_ent "com.apple.security.files.user-selected.read-only" \
    && pass "com.apple.security.files.user-selected.read-only is set (file import)" \
    || fail "user-selected.read-only is missing — the import source cannot work"

# A temporary exception is Apple's escape hatch for apps that cannot be
# sandboxed honestly. Using one would contradict the entire design.
if [[ $(grep -c "temporary-exception" "$ENT_PLIST") -gt 0 ]]; then
    fail "a temporary-exception entitlement is present"
    grep -o 'com.apple.security.temporary-exception[^<]*' "$ENT_PLIST" | sed 's/^/      /'
else
    pass "no temporary-exception entitlements"
fi

# Counts only com.apple.security.* — a real submission also carries
# com.apple.application-identifier and com.apple.developer.team-identifier,
# derived from the provisioning profile at signing time, and those are expected.
# A fail, not a warn: this is the check most likely to catch a compliance
# regression introduced by a future feature, and appstore.sh gates packaging on
# this script's exit status — a warning would sail straight through it.
ENT_COUNT=$(grep -c '<key>com\.apple\.security' "$ENT_PLIST")
[[ "$ENT_COUNT" -eq 3 ]] \
    && pass "exactly 3 com.apple.security entitlements, no more" \
    || fail "$ENT_COUNT com.apple.security entitlements (expected 3) — review packaging/appstore/Tokes.entitlements"

# ------------------------------------------------------------------- binary --
head2 "Binary contains no out-of-container credential readers"

# Each of these strings exists only if the code path that uses it was compiled
# in. Descriptive UI copy is deliberately NOT on this list: the App Store build
# still says "~/.claude/.credentials.json" in the import help text and opens the
# panel there, which is the feature working, not a container escape. For the
# same reason "find-generic-password" and "Claude Code-credentials" are no
# longer here: since the Claude export walkthrough (ClaudeCodeExport.swift)
# they are command text shown for the *user* to run in their own terminal.
# What still proves no reader is compiled in: the absolute /usr/bin/security
# path below (only the shell-out reader has it), the Process/NSTask symbol
# check (no subprocess execution at all), and the source tripwire after this
# loop that pins where the foreign service name may appear.
FORBIDDEN=(
    "/usr/bin/security"          # shells out to read Claude Code's keychain item
    "/opt/homebrew/bin/gh"       # shells out to the GitHub CLI
    "/usr/local/bin/gh"          # ...same reader, second path it tries
    "/usr/bin/gh"                # ...and the third. All three, or a refactor
                                 #    that drops the first two audits clean.
    "/tmp/tokes-debug.log"       # a write outside the container
)
# grep -c, never grep -q: under `set -o pipefail` an early-exiting grep leaves
# the producer with SIGPIPE, and the pipeline then reports failure on a *match* —
# which silently turns every check here into a pass. Counting reads all input.
for pattern in "${FORBIDDEN[@]}"; do
    hits=$(strings -a "$BIN" | grep -cF -- "$pattern")
    if [[ "$hits" -gt 0 ]]; then
        fail "binary references \"$pattern\" (${hits} occurrences)"
    else
        pass "no reference to \"$pattern\""
    fi
done

# The source tripwire that replaces the two strings dropped from FORBIDDEN:
# the foreign keychain service name may appear in exactly two files — the
# reader that is #if'd out of this build, and the walkthrough copy. A third
# file naming it means someone is reintroducing a foreign-store reader, which
# a binary strings scan can no longer distinguish from the legitimate copy.
SERVICE_HITS=$(grep -rlF "Claude Code-credentials" Sources | sort | tr '\n' ' ')
SERVICE_EXPECTED="Sources/Tokes/ClaudeCodeExport.swift Sources/Tokes/CredentialsProvider.swift "
if [[ "$SERVICE_HITS" == "$SERVICE_EXPECTED" ]]; then
    pass "foreign service name confined to ClaudeCodeExport.swift + CredentialsProvider.swift"
else
    fail "foreign service name appears in unexpected sources: $SERVICE_HITS"
fi

for arch in $(lipo -archs "$BIN"); do
    hits=$(nm -arch "$arch" "$BIN" 2>/dev/null | grep -ciE 'Foundation7Process|_NSTask')
    if [[ "$hits" -gt 0 ]]; then
        fail "[$arch] links Foundation.Process / NSTask — subprocess execution is compiled in"
    else
        pass "[$arch] no Foundation.Process / NSTask symbols"
    fi
done

# macOS 14 still runs on Intel; an arm64-only build is listed as incompatible
# for those users rather than simply unavailable.
ARCHS=$(lipo -archs "$BIN")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] \
    && pass "universal binary ($ARCHS)" \
    || warn "not universal ($ARCHS) — Intel Macs on macOS 14+ cannot run this"

# --------------------------------------------------------------- Info.plist --
head2 "Info.plist keys App Store Connect validates"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion \
           LSMinimumSystemVersion LSApplicationCategoryType ITSAppUsesNonExemptEncryption \
           DTXcode DTXcodeBuild DTSDKName DTSDKBuild DTPlatformName DTPlatformVersion \
           DTPlatformBuild DTCompiler BuildMachineOSBuild; do
    value=$(plist "$key")
    [[ -n "$value" ]] && pass "$key = $value" || fail "$key is missing"
done

if [[ -f "$APP/Contents/embedded.provisionprofile" ]]; then
    pass "embedded.provisionprofile present"
else
    warn "no embedded.provisionprofile — fine for a local audit, required to upload"
fi

# ------------------------------------------------------------------ runtime --
# A submission-signed bundle carries a Mac App Store provisioning profile, which
# authorises no devices — launchd refuses it locally with POSIX 163 "Launchd job
# spawn failed". That is correct Apple behaviour, not a fault in the build, so
# the runtime section only means anything for the ad-hoc audit build.
# Detected from the signature, not from the profile: build.sh only embeds a
# profile for a real identity, but reading the authority is the direct question.
# grep -c, not grep -q — see the note above the forbidden-string loop. An
# early-exiting grep under `set -o pipefail` reports failure on a match, which
# would pin this to "submission-signed" forever.
ADHOC=$(codesign -dvv "$APP" 2>&1 | grep -c "Signature=adhoc")
SUBMISSION_SIGNED=1
[[ "$ADHOC" -gt 0 ]] && SUBMISSION_SIGNED=""

if [[ -n "$STATIC_ONLY" ]]; then
    head2 "Runtime checks skipped (--static-only)"
elif [[ -n "$SUBMISSION_SIGNED" ]]; then
    head2 "Runtime checks skipped (submission-signed build)"
    warn "this bundle is signed for the App Store and cannot launch on this Mac"
    warn "rebuild ad-hoc to exercise them: scripts/build.sh --app-store && $0"
else
    head2 "Runtime: the sandbox is genuinely on"

    OTHER=$(pgrep -f "Tokes.app/Contents/MacOS/Tokes" | while read -r pid; do
        ps -o comm= -p "$pid" | grep -q "build/appstore" || echo "$pid"
    done)
    [[ -n "$OTHER" ]] && warn "another Tokes is running; it is left alone"

    launch() {
        open -n "$APP"
        sleep 3
        APP_PID=$(pgrep -f "$PWD/$APP/Contents/MacOS/Tokes" | head -1)
    }
    stop() { [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null; sleep 1; }

    rm -rf "$CONTAINER/Library/Application Support/Tokes" 2>/dev/null
    REAL_SUPPORT="$HOME/Library/Application Support/Tokes"
    REAL_BEFORE=$(stat -f %m "$REAL_SUPPORT" 2>/dev/null || echo none)

    launch
    if [[ -z "${APP_PID:-}" ]]; then
        fail "app did not stay running"
    else
        pass "launched (pid $APP_PID)"
    fi

    [[ -d "$HOME/Library/Containers/$BUNDLE_ID" ]] \
        && pass "sandbox container exists: ~/Library/Containers/$BUNDLE_ID" \
        || fail "no sandbox container — the process is not sandboxed"

    # Turn on debug logging *inside the container* (the sandboxed app reads its
    # preferences from there, not from ~/Library/Preferences) and relaunch.
    stop
    defaults write "$CONTAINER/Library/Preferences/$BUNDLE_ID" debugLogging -bool true
    LOG="$CONTAINER/tmp/tokes-debug.log"
    rm -f "$LOG"
    launch

    if [[ -f "$LOG" ]]; then
        pass "debug log written inside the container, not /tmp"
        if [[ $(grep -c "App Store build, sandboxed=true" "$LOG") -gt 0 ]]; then
            pass "app reports: $(grep -o 'App Store build, sandboxed=true' "$LOG" | head -1)"
        else
            fail "app did not report a sandboxed App Store build: $(tail -1 "$LOG")"
        fi
        if [[ $(grep -cE "running without the app-sandbox|running sandboxed" "$LOG") -gt 0 ]]; then
            fail "build/runtime mismatch reported: $(grep -E 'running without|running sandboxed' "$LOG" | head -1)"
        else
            pass "no build/runtime flavor mismatch"
        fi
    else
        fail "no debug log at $LOG"
    fi

    [[ -d "$CONTAINER/Library/Application Support/Tokes" ]] \
        && pass "history store redirected into the container" \
        || fail "history store not found in the container"

    REAL_AFTER=$(stat -f %m "$REAL_SUPPORT" 2>/dev/null || echo none)
    [[ "$REAL_BEFORE" == "$REAL_AFTER" ]] \
        && pass "real ~/Library/Application Support/Tokes untouched" \
        || fail "the sandboxed app modified data outside its container"

    # Only attributable when nothing else is writing there: a direct build with
    # debugLogging on appends to this same path, and mtime cannot tell us which
    # process did it. The static check above (no /tmp path in the binary) and the
    # container log are the unambiguous evidence.
    if [[ -n "$OTHER" ]]; then
        warn "/tmp write check skipped — another Tokes is writing /tmp/tokes-debug.log"
    elif [[ -f /tmp/tokes-debug.log ]] && [[ -n $(find /tmp/tokes-debug.log -mmin -1 2>/dev/null) ]]; then
        fail "/tmp/tokes-debug.log was written"
    else
        pass "/tmp untouched"
    fi

    stop
fi

# ------------------------------------------------------------------ summary --
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
