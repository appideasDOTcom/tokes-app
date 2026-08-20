## Tokes - An AI Token Monitor for macOS

A tiny menu bar app (in the spirit of [stats](https://github.com/exelban/stats)) that shows your
Claude and GitHub Copilot plan usage at a glance: the three limits Claude Code reports — **Session (5 hr)**,
**Weekly (7 day)**, and the **weekly model-scoped** limit (currently "Fable"). Optionally it
also tracks **GitHub Copilot premium requests** (credits used of your monthly allowance).

- **Menu bar icon**: three vertical bars (Session · Weekly · Model), filled bottom-up and
  colored by severity (green → orange ≥ 60% → red ≥ 85%). Optional text label showing one
  percentage — either the highest of them, or a specific limit you pick in Settings. With
  Copilot enabled, its bar appears behind a thin divider so the provider groups read
  separately.
- **Hover** the icon to drop down a popover with a line chart per limit (session chart shows
  the last 6 hours, weekly/monthly charts the last 7 days), current percentage, and reset
  countdowns. When both providers report, sections are grouped under **Claude** /
  **GitHub Copilot** headings and Copilot's chart line is dashed so the two are easy to
  tell apart. **Click** to pin the popover; click outside or click the icon again to dismiss.
- **Right-click** for Refresh / Settings / Quit.
- **Settings** (gear in the popover): credential sources, Copilot on/off, refresh interval,
  launch at login, and **Show in menu bar** — off, the highest value, or one specific
  measurement (Session, Weekly, the model-scoped weekly, or Copilot Premium). The
  model-scoped and Copilot entries are offered only while those are switched on; if the
  measurement you picked isn't in the current snapshot, the menu bar shows the icon alone
  rather than another limit's number.

### How it gets the numbers

Tokes polls `https://api.anthropic.com/api/oauth/usage` — the same endpoint the Claude Code
VS Code extension uses for its Account & Usage panel — and reads the `limits` array
(`session`, `weekly_all`, `weekly_scoped`). By default it authenticates with the OAuth
credentials Claude Code already maintains, tried in order:

1. `~/.claude/.credentials.json` (if present)
2. The `Claude Code-credentials` keychain item (via `/usr/bin/security` first, whose
   keychain approval survives rebuilds of an ad-hoc-signed app, then the Security framework)

macOS will ask you to allow keychain access on first use — choose **Always Allow**.

Two other sources are available in Settings and work in every build: **import a
credentials file** (pick `~/.claude/.credentials.json` in an open panel — Tokes
re-reads it on each refresh, so a rotated token keeps working) or **paste a token
manually** (stored in Tokes' own keychain item).

With Copilot monitoring enabled, Tokes also polls
`https://api.github.com/copilot_internal/user` — the endpoint editor Copilot plugins use for
their quota display — and reads `quota_snapshots.premium_interactions` (credits used of the
monthly entitlement) plus `quota_reset_date`. It authenticates with the GitHub token your
tooling already maintains, tried in order:

1. `~/.config/github-copilot/apps.json` (current Copilot plugins)
2. `~/.config/github-copilot/hosts.json` (older plugins)
3. `gh auth token` from the GitHub CLI

Or import the config file yourself in an open panel, or paste a GitHub token
manually in Settings (stored in Tokes' own keychain item).

The APIs only report *current* utilization, so Tokes records a local sample on every poll
(`~/Library/Application Support/Tokes/history.jsonl`, pruned to 8 days) to draw the charts.
Charts fill in as the app runs.

### Two builds

Tokes ships as a Homebrew/direct build and a Mac App Store build, from one
codebase. The App Store build is sandboxed, and App Review Guideline 2.5.2 does
not allow a sandboxed app to read data outside its container — so the sources
that read Claude Code's and Copilot's own credential stores are compiled out of
it entirely, leaving the imported file and the manual token. Everything else is
the same app. `docs/APP-STORE-COMPLIANCE.md` has the details, the measurements
behind them, and how it is verified.

Both are free, and the source is the same either way.

### Install via Homebrew

```sh
brew install appideasDOTcom/tap/tokes
```

Until builds are notarized, right-click Tokes.app → Open on first launch (or add
`--no-quarantine` to the install command).

### Build & run

Requires Xcode (Swift 6 toolchain), targets macOS 14+.

```sh
./scripts/build.sh --run          # builds build/Tokes.app and (re)launches it
./scripts/build.sh --app-store    # sandboxed build -> build/appstore/Tokes.app
./scripts/verify-appstore.sh      # audits that build against the App Store rules
```

The App Store build needs no Apple certificates to build or audit locally — it
is ad-hoc signed with the real sandbox entitlements, so the sandbox is genuinely
on.

The app icon is built from `packaging/icon/Tokes.icon` (an Icon Composer package)
by `actool`, which derives both the macOS 26 layered rendition and the legacy
`.icns` from that single source. See `packaging/icon/README.md`.

To install permanently:

```sh
cp -R build/Tokes.app /Applications/
```

Then enable "Launch at login" in Settings.

### Tests

```sh
./scripts/test.sh    # both build configurations
swift test           # the direct build only
```

The suite lives in `Tests/TokesTests/`, fully separated from app code. It covers the API
response mapping and date parsing for both providers (Claude usage and Copilot
entitlement), the HTTP layers (via a mock `URLProtocol` — no network), history
persistence/pruning (temp directories), credential parsing/caching for both Claude Code
and Copilot config files plus the manual keychain item (a test-only service, never the
real one — including `SettingsView`, whose `onAppear` reads that slot on every render
and is pointed at the test service for exactly that reason), poller behavior (retry-on-401, 429 backoff, staleness gating, in-flight
coalescing, dual-provider merging with stale carry-forward — via injected mocks), the
menu bar icon (including rasterized pixel checks of severity colors and the provider
divider), chart downsampling, settings defaults, hosting-controller smoke tests of
the SwiftUI views, and the app icon build pipeline (the Icon Composer package
compiles under `actool` into both shipping forms, with the plist keys the bundle
needs — all failure modes there are silent ones), and the distribution/capability
layer (which credential sources each build offers, the security-scoped bookmark
round-trip including token rotation and atomic replacement, and the build-vs-runtime
sandbox audit), the credential-source dispatch for both providers, the Test
Connection buttons' resolve-fetch-report path, the poller's timer and observer
lifecycle (a settings change reschedules, a Copilot toggle re-polls, waking from
sleep polls, `stop()` silences all of it), the Settings import/forget flow end to
end into the providers, and the security-scoped bookmark's refresh rule (a stale
refresh must not downgrade a scoped grant to a plain one). Tests touch no live
credentials and make no network calls; most classes now use a UUID in their
`UserDefaults` suite name, but the suite is still not safe under
`swift test --parallel`, which runs each class in its own process against shared
suite files.

`scripts/test.sh` runs the suite twice, because the App Store configuration
compiles with `-DTOKES_APP_STORE` and that removes whole functions — the default
configuration alone would leave half the code unbuilt.

