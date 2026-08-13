# Tokes — development notes

Hard-won gotchas from building this app. Read before debugging UI or logging issues.

- **macOS 26 mispositions status item popovers** (top edge above the screen). Tokes
  repositions the popover window explicitly after `show()` — see
  `StatusItemController.repositionPopoverWindow()`.
- **Popover buttons in an inactive accessory app swallow the first click.** SwiftUI's
  internal hit-test views don't accept first mouse, so Tokes activates the app when the
  pointer enters the popover (and on click-to-pin), then hands focus back on close.
- **`NSTrackingArea` owner selectors**: on a plain `NSObject` owner, Swift exports
  `mouseEntered(with:)` as `mouseEnteredWith:` — the tracking area's `mouseEntered:` message
  is dropped silently. The handlers use explicit `@objc(mouseEntered:)` names.
- **Debug logging**: `defaults write com.appideas.tokes debugLogging -bool true` appends to
  `/tmp/tokes-debug.log` (unified log redacts dynamic NSLog content as `<private>`).
- If the usage endpoint returns **HTTP 429**, Tokes keeps the last snapshot, shows a banner,
  and skips Claude polls entirely until the backoff passes: `Retry-After` header when
  present, else 90 s doubling per consecutive 429 (cap 15 min). Copilot polling continues.

## Rules

- Tests must make no network calls (use `MockURLProtocol`) and never touch real
  credentials. Keychain tests use the test-only service `"com.appideas.tokes.tests"`;
  the real manual-token slot (service `"com.appideas.tokes"`, account `"copilot-token"`)
  is off-limits to tests.
- Never run git commit/push/tag — the user handles all of git.
- Build with `./scripts/build.sh --run`; package releases with `scripts/release.sh`
  (version comes from `scripts/Info.plist`).
