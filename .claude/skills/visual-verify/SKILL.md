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
  swiftc -o "'"$SCRATCH"'/VisualVerify" $SRC "'"$SCRATCH"'/demo/main.swift"'
```

Three things that bite:

- **Wrap the compile in `bash -c`.** zsh does not word-split an unquoted `$SRC`,
  so `swiftc $SRC` passes every filename as one argument and fails with
  `error opening input file 'Sources/Tokes/AppDelegate.swift\nSources/...'`.
- **Exclude `Sources/Tokes/main.swift`** — it's the app's entry point and would
  collide with the harness.
- **Never name the output binary `Demo`.** APFS is case-insensitive, so it
  collides with the `demo/` harness directory and the link fails with
  `errno=21 (Is a directory)` — an error that doesn't name either path.
  `VisualVerify` above is chosen to collide with nothing. (Its defaults domain
  is then `~/Library/Preferences/VisualVerify.plist` — see cleanup below.)

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

`SettingsView` is a fixed **`460x620`** and scrolls internally, so a taller
window will **not** reveal the Behavior section. Find the `NSScrollView` in the
hosting view's subtree and scroll it before capturing:

```swift
scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentView.bounds.height)))
scroll.reflectScrolledClipView(scroll.contentView)
```

### The credential sections are state machines, not static forms

Since the onboarding work, most of Settings' height is conditional, and a
screenshot only ever shows one branch. What renders depends on state the harness
must set up deliberately:

- **GitHub Copilot → Sign in with GitHub** renders one of five phases from
  `GitHubConnectModel.phase` (`idle`, `requesting`, `awaitingUser`, `connected`,
  `failed`). The model is a `@StateObject`, so drive it by setting
  `githubModel.keychainService` to a **test** service and seeding a
  `GitHubAppTokens` there — never the real slot, which holds the operator's
  live session.
- **Claude → Import a Claude Code credentials file** renders the export
  walkthrough (command + hook disclosure) only while `claudeImportPath == nil`,
  and switches to the refresh-commands disclosure once a file is imported. So
  the walkthrough is invisible in any harness whose bookmark defaults already
  carry an import.

Both branches are cheaper to assert textually — the strings come from
`ClaudeCodeExport`, and `PopoverView.offersSettingsShortcut` is a pure static
func — than to photograph. Reach for a capture only when the question is
genuinely about layout.

## Which render path — and what each one silently breaks

Two ways to capture SwiftUI off-screen. They are **not** interchangeable, and a
view with both a grouped `Form` and symbol buttons cannot be captured correctly
at high resolution by either. Pick knowing what you're buying:

| | `ImageRenderer` | hosted view + `cacheDisplay` |
|---|---|---|
| Real resolution at the requested scale | **yes** | **no** — 1x rasterisation, upscaled |
| Grouped `Form` (`SecureField`/`Toggle`/`Picker`) | **blank page** | renders |
| `Image(systemName:)` in a `.buttonStyle(.borderless)` button | **yellow placeholder plate** | renders correctly |
| Scrollable content | can't scroll it | can (see above) |

**The placeholder trap shipped in two App Store screenshots** and survived four
review passes, because it sat in the window chrome while everyone checked
content. It is *not* "ImageRenderer can't do SF Symbols" — measured, all of
these render fine: bare `Image(systemName:)`, `.imageScale`, `Label(systemImage:)`,
`Image(nsImage:)`, and `.buttonStyle(.plain)`. **Only `.borderless` breaks.**

`scripts/appstore-screenshots.py` now refuses any frame containing one. If you
render popovers here, check for it the same way — saturated yellow, safe against
brand orange and the severity colours:

```python
r > 200 and g > 170 and b < 90 and abs(r - g) < 70
```

**Controls always draw inactive.** An `.accessory` harness never activates, so
`Toggle(isOn: true)` captures **grey, not accent blue**. Five approaches all
measured at zero accent pixels — overriding `isKeyWindow`/`isMainWindow`,
`.environment(\.controlActiveState, .key)` and `.active`, swizzling
`-[NSApplication isActive]`, and `window.makeKey()`. Only `NSApp.activate(...)`
works and that steals focus. Don't re-litigate this; supply the state at
composition time if it's needed.

`ImageRenderer` is main-actor isolated — wrap probe code in
`MainActor.assumeIsolated { }` or it won't compile.

## Measuring a render instead of eyeballing it

Two techniques that answered questions a screenshot couldn't, both cheap:

- **Is this render blank / does it contain X?** Count pixels differing from the
  modal (background) colour, plus distinct colour count. A blank `ImageRenderer`
  page reads 0.00% non-background and 1 colour; a working control render reads
  ~3.6% and 300+ colours. Always look at the image too — a first detector here
  counted a red severity dot as a placeholder plate.
- **Where are the section boundaries?** Classify each pixel row as grouped-`Form`
  card (light grey) vs page (white) by sampling a few x positions clear of text,
  then print the runs as percentages of height. That located every Settings
  section boundary to the point, which is what the designer needed to re-derive
  a store-frame crop — and it agreed with their independent edge detection to
  within 0.1%.

No PIL or numpy on this machine. For stdlib-only pixel work, `sips -s format bmp`
then parse the header and slice raw rows — no decompression, no PNG un-filtering.
Sample a full-resolution grid rather than downscaling first, or a small feature
gets averaged away into its surroundings.

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
