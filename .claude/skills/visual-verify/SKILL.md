---
name: visual-verify
description: Screenshot Tokes' menu bar item or Settings window driven by synthetic usage data, to prove a UI change actually renders. Use when a change affects the status item icon/label or SettingsView and you need visual proof rather than only unit tests — especially when the live usage API is unavailable (429/offline) so the real app shows nothing.
---

# Visually verifying a Tokes UI change

Unit tests cover the pure functions (`StatusItemController.makeIcon`/`makeTitle`,
`MenuBarLabel`), but they can't show that the real status item or Settings form
renders. The app also can't demonstrate itself when the usage endpoint is
rate-limiting — there's no snapshot to draw.

The technique: compile the app's own sources together with a throwaway
`main.swift`, inject a synthetic `UsageSnapshot`, and `screencapture` the result.
This drives the *real* `StatusItemController` / `SettingsView`, not a stand-in.

## Compiling a harness

Put the harness in the scratchpad, in a file named exactly `main.swift`
(top-level code is only legal in that filename), then:

```bash
SCRATCH=<your scratchpad>
mkdir -p "$SCRATCH/demo"   # harness lives at $SCRATCH/demo/main.swift

cd /path/to/tokes
bash -c 'SRC=$(ls Sources/Tokes/*.swift Sources/Tokes/Views/*.swift | grep -v "main.swift"); \
  swiftc -o "'"$SCRATCH"'/Demo" $SRC "'"$SCRATCH"'/demo/main.swift"'
```

Two things that bite:

- **Wrap the compile in `bash -c`.** zsh does not word-split an unquoted `$SRC`,
  so `swiftc $SRC` passes every filename as one argument and fails with
  `error opening input file 'Sources/Tokes/AppDelegate.swift\nSources/...'`.
- **Exclude `Sources/Tokes/main.swift`** — it's the app's entry point and would
  collide with the harness.

Expect deprecation warnings from the app sources; filter with `grep -E "error:"`.

## Keeping the harness out of real user data

- `HistoryStore(directory:)` takes an override — point it at the scratchpad so
  the real Application Support history is untouched.
- Construct `UsagePoller` but **never call `start()`**: `StatusItemController`
  requires a poller, and an unstarted one makes no network calls.
- An unbundled `swiftc` binary gets its own defaults domain named after the
  executable. Clean up afterwards or they linger:
  `rm -f ~/Library/Preferences/<ExecutableName>.plist`
- Verify the real domain is untouched: `defaults read com.appideas.tokes`

## Menu bar item

`pkill -x Tokes` first so only the harness's icon is in the bar, and relaunch the
real app with `./scripts/build.sh --run` when done.

Set `UserDefaults.standard` keys, build the controller, then assign
`state.snapshot`. To re-render after changing a default in-process, post the
notification the controller subscribes to:

```swift
defaults.set(MenuBarLabel.session.rawValue, forKey: SettingsKeys.menuBarLabel)
NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
```

Capture a screen region with `screencapture -x -R<x>,<y>,<w>,<h> out.png`.
`-R` is in **points from the top-left of the screen** — not AppKit's bottom-left
origin, which is the easy way to photograph your wallpaper instead. Status items
sit at the right end of the menu bar; capture wide first, then narrow the region
once you can see where the icon landed. `sips -z <h> <w>` upscales for reading.

## Settings window

`screencapture -x -o -l<CGWindowID(window.windowNumber)> out.png` captures one
window directly and avoids the coordinate problem entirely.

`SettingsView` is a fixed `460x560` and scrolls internally, so a taller window
will **not** reveal the Behavior section. Find the `NSScrollView` in the hosting
view's subtree and scroll it before capturing:

```swift
scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
scroll.reflectScrolledClipView(scroll.contentView)
```

## Asserting a Picker's options (better than a screenshot)

A SwiftUI `Picker` in a `Form` is backed by an `NSPopUpButton`, but **its
`itemTitles` are empty until the menu opens** — so searching the view tree for a
button whose titles contain a known option silently finds nothing. Locate it by
index among the popups instead, `performClick(nil)`, then read the titles a
moment later:

```swift
picker = popUpButtons(hosting.view)[1]   // e.g. 2nd popup in Behavior
picker?.performClick(nil)
// ...later: print(picker?.itemTitles.joined(separator: " | "))
```

This prints the live option list, which is stronger evidence than a photo of an
open menu and doesn't depend on window coordinates.

## Don't steal focus

`NSApp.activate(ignoringOtherApps:)` yanks focus from whatever the user is doing,
and they may be working in another session on the same machine. It's needed to
open a popup menu, but call it once and keep harness runs short — don't iterate
on a broken harness while it repeatedly raises windows. Prefer the textual
assertions above where they'd answer the question.
