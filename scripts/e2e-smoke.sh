#!/bin/bash
# On-demand end-to-end smoke test: launches the built app, finds its real
# status item by accessibility hit-testing, clicks it with real mouse events,
# verifies the popover opens under the item and renders, then closes it again.
#
#   scripts/e2e-smoke.sh [path/to/Tokes.app]     # default: build/Tokes.app
#
# This STEALS FOCUS and moves the mouse while it runs. Run it deliberately,
# before a release — never from swift test, never from CI, never while
# unattended parallel sessions matter.
#
# Requires Accessibility permission for the terminal running it. The app polls
# with whatever real credentials the machine has; the assertions accept any
# rendered popover state (limits, connecting, or an error banner), so a 429 or
# a logged-out machine still passes — this tests the UI path, not the API.
#
# Hard-won specifics baked in here (all measured on macOS 26):
# - AppleScript `click` (AXPress) on the status item is a silent no-op; only
#   real CGEvent clicks reach statusButtonClicked.
# - With the installed Tokes also running, both instances share the bundle's
#   preferred-position slot, so the AX-reported *position* of our item can be
#   the other instance's pixels. Ownership comes from hit-testing for our pid.
# - The open popover is invisible to `windows of proc` and CGWindowList; the
#   system-wide AX hit-test just below the item is what finds it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Tokes.app}"
if [ ! -d "$APP" ]; then
    echo "==> $APP missing; building the direct flavor"
    ./scripts/build.sh
fi
BIN="$APP/Contents/MacOS/Tokes"
[ -x "$BIN" ] || { echo "FAIL: no executable at $BIN"; exit 1; }

TMP=$(mktemp -d)
cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/axtool.swift" <<'SWIFT'
import AppKit
import ApplicationServices

let sys = AXUIElementCreateSystemWide()

func hit(_ x: Double, _ y: Double) -> (pid_t, AXUIElement)? {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success,
          let el else { return nil }
    var p: pid_t = 0
    AXUIElementGetPid(el, &p)
    return (p, el)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return v
}

func rect(of el: AXUIElement) -> CGRect {
    var pos = CGPoint.zero, size = CGSize.zero
    if let v = attr(el, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
    if let v = attr(el, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    return CGRect(origin: pos, size: size)
}

func collectTexts(_ el: AXUIElement, into out: inout [String], depth: Int = 0) {
    guard depth < 24 else { return }
    if (attr(el, kAXRoleAttribute) as? String) == kAXStaticTextRole,
       let value = attr(el, kAXValueAttribute) as? String {
        out.append(value)
    }
    if let children = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children { collectTexts(child, into: &out, depth: depth + 1) }
    }
}

let cmd = CommandLine.arguments[1]
switch cmd {
case "trusted":
    print(AXIsProcessTrusted() ? "1" : "0")

case "find":  // find <pid> <hintX> <hintY> -> "cx cy" of OUR item
    let pid = pid_t(CommandLine.arguments[2])!
    let hx = Double(CommandLine.arguments[3])!, hy = Double(CommandLine.arguments[4])!
    for dx in stride(from: 0.0, through: 800.0, by: 8.0) {
        for x in [hx + dx, hx - dx] {
            if let (p, el) = hit(x, hy), p == pid {
                let r = rect(of: el)
                print("\(Int(r.midX)) \(Int(r.midY))")
                exit(0)
            }
        }
    }
    print("NOTFOUND"); exit(1)

case "click":  // click <x> <y>
    let x = Double(CommandLine.arguments[2])!, y = Double(CommandLine.arguments[3])!
    let pt = CGPoint(x: x, y: y)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(60_000)
    }

case "owner":  // owner <x> <y> -> pid at point
    let x = Double(CommandLine.arguments[2])!, y = Double(CommandLine.arguments[3])!
    print(hit(x, y).map { String($0.0) } ?? "NONE")

case "texts":  // texts <pid> <x> <y> -> static texts of pid's element subtree there
    let pid = pid_t(CommandLine.arguments[2])!
    let x = Double(CommandLine.arguments[3])!, y = Double(CommandLine.arguments[4])!
    guard let (p, el) = hit(x, y), p == pid else {
        print("NOTOURS"); exit(1)
    }
    // climb to the top of our subtree, then collect every static text
    var top = el
    while let parent = attr(top, kAXParentAttribute) {
        let parentEl = parent as! AXUIElement
        var pp: pid_t = 0
        AXUIElementGetPid(parentEl, &pp)
        if pp != pid { break }
        if (attr(parentEl, kAXRoleAttribute) as? String) == kAXApplicationRole { break }
        top = parentEl
    }
    var texts: [String] = []
    collectTexts(top, into: &texts)
    for t in texts { print(t) }

default:
    print("unknown command"); exit(2)
}
SWIFT
swiftc -O -o "$TMP/axtool" "$TMP/axtool.swift" 2>/dev/null
AX="$TMP/axtool"

if [ "$("$AX" trusted)" != "1" ]; then
    echo "FAIL: accessibility permission missing. Grant it to this terminal in"
    echo "      System Settings > Privacy & Security > Accessibility, then rerun."
    exit 1
fi

"$BIN" &
PID=$!
echo "==> launched $APP (pid $PID)"

# The item's AX-reported rect is only a *hint* (see header); ownership is
# established by hit-testing. Retry while the app finishes starting up.
HINT=""
for _ in $(seq 1 25); do
    HINT=$(osascript -e "tell application \"System Events\"
        set proc to first application process whose unix id is $PID
        repeat with mb in (every menu bar of proc)
            if (count of menu bar items of mb) > 0 then
                set p to position of menu bar item 1 of mb
                set sz to size of menu bar item 1 of mb
                return \"\" & ((item 1 of p) + (item 1 of sz) div 2) & \" \" & ((item 2 of p) + (item 2 of sz) div 2)
            end if
        end repeat
        return \"\"
    end tell" 2>/dev/null) || true
    [ -n "$HINT" ] && break
    sleep 0.4
done
[ -n "$HINT" ] || { echo "FAIL: status item never appeared"; exit 1; }

read HX HY <<< "$HINT"
CENTER=$("$AX" find "$PID" "$HX" "$HY") || { echo "FAIL: no element on the bar is owned by pid $PID"; exit 1; }
read CX CY <<< "$CENTER"
echo "==> status item found at $CX,$CY (owned by our pid)"

"$AX" click "$CX" "$CY"
sleep 1.2

# The popover anchors with its top flush under the menu bar, centered on the
# item — probe just below the item for an element we own.
PX=$CX; PY=$((CY + 45))
TEXTS=$("$AX" texts "$PID" "$PX" "$PY") || {
    echo "FAIL: nothing of ours under the status item — popover did not open where it should"
    exit 1
}
echo "==> popover rendered:"
printf '%s\n' "$TEXTS" | sed 's/^/    /'
MATCHES=$(printf '%s\n' "$TEXTS" | grep -cE 'Claude Usage|^Usage$|Session \(5 hr\)|Connecting|Usage API|rate-limited|Not authorized' || true)
if [ "$MATCHES" -eq 0 ]; then
    echo "FAIL: popover text matches no known state (limits, connecting, or error)"
    exit 1
fi

# Second click unpins and closes.
"$AX" click "$CX" "$CY"
sleep 1.0
AFTER=$("$AX" owner "$PX" "$PY")
if [ "$AFTER" = "$PID" ]; then
    echo "FAIL: popover still open after the closing click"
    exit 1
fi

kill "$PID"
wait "$PID" 2>/dev/null || true
PID=""
echo "PASS: status item present, popover opened under it, rendered a known state, and closed"
