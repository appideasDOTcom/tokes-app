## Tokes - An AI Token Monitor for macOS

A tiny menu bar app (in the spirit of [stats](https://github.com/exelban/stats)) that shows your
Claude plan usage at a glance: the three limits Claude Code reports — **Session (5 hr)**,
**Weekly (7 day)**, and the **weekly model-scoped** limit (currently "Fable"). Optionally it
also tracks **GitHub Copilot premium requests** (credits used of your monthly allowance).

- **Menu bar icon**: three vertical bars (Session · Weekly · Model), filled bottom-up and
  colored by severity (green → orange ≥ 60% → red ≥ 85%). Optional text label with the
  highest percentage. With Copilot enabled, its bar appears behind a thin divider so the
  provider groups read separately.
- **Hover** the icon to drop down a popover with a line chart per limit (session chart shows
  the last 6 hours, weekly/monthly charts the last 7 days), current percentage, and reset
  countdowns. When both providers report, sections are grouped under **Claude** /
  **GitHub Copilot** headings and Copilot's chart line is dashed so the two are easy to
  tell apart. **Click** to pin the popover; click outside or click the icon again to dismiss.
- **Right-click** for Refresh / Settings / Quit.
- **Settings** (gear in the popover): credential sources, Copilot on/off, refresh interval,
  launch at login, menu bar text label.

### How it gets the numbers

Tokes polls `https://api.anthropic.com/api/oauth/usage` — the same endpoint the Claude Code
VS Code extension uses for its Account & Usage panel — and reads the `limits` array
(`session`, `weekly_all`, `weekly_scoped`). By default it authenticates with the OAuth
credentials Claude Code already maintains, tried in order:

1. `~/.claude/.credentials.json` (if present)
2. The `Claude Code-credentials` keychain item (via `/usr/bin/security` first, whose
   keychain approval survives rebuilds of an ad-hoc-signed app, then the Security framework)

macOS will ask you to allow keychain access on first use — choose **Always Allow**.
Alternatively, paste a token manually in Settings (stored in Tokes' own keychain item).

With Copilot monitoring enabled, Tokes also polls
`https://api.github.com/copilot_internal/user` — the endpoint editor Copilot plugins use for
their quota display — and reads `quota_snapshots.premium_interactions` (credits used of the
monthly entitlement) plus `quota_reset_date`. It authenticates with the GitHub token your
tooling already maintains, tried in order:

1. `~/.config/github-copilot/apps.json` (current Copilot plugins)
2. `~/.config/github-copilot/hosts.json` (older plugins)
3. `gh auth token` from the GitHub CLI

Or paste a GitHub token manually in Settings (stored in Tokes' own keychain item).

The APIs only report *current* utilization, so Tokes records a local sample on every poll
(`~/Library/Application Support/Tokes/history.jsonl`, pruned to 8 days) to draw the charts.
Charts fill in as the app runs.

### Install via Homebrew

```sh
brew install appideasDOTcom/tap/tokes
```

Until builds are notarized, right-click Tokes.app → Open on first launch (or add
`--no-quarantine` to the install command).

### Build & run

Requires Xcode (Swift 6 toolchain), targets macOS 14+.

```sh
./scripts/build.sh --run    # builds build/Tokes.app and (re)launches it
```

To install permanently:

```sh
cp -R build/Tokes.app /Applications/
```

Then enable "Launch at login" in Settings.

### Tests

```sh
swift test
```

The suite lives in `Tests/TokesTests/`, fully separated from app code. It covers the API
response mapping and date parsing for both providers (Claude usage and Copilot
entitlement), the HTTP layers (via a mock `URLProtocol` — no network), history
persistence/pruning (temp directories), credential parsing/caching for both Claude Code
and Copilot config files plus the manual keychain item (a test-only service, never the
real one), poller behavior (retry-on-401, 429 backoff, staleness gating, in-flight
coalescing, dual-provider merging with stale carry-forward — via injected mocks), the
menu bar icon (including rasterized pixel checks of severity colors and the provider
divider), chart downsampling, settings defaults, and hosting-controller smoke tests of
the SwiftUI views. Tests touch no live credentials and make no network calls.

### Development notes (hard-won)

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
  and backs off opportunistic refreshes for 90 s (the timer cadence continues).
