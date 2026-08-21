## Tokes - An AI Token Monitor for macOS

A tiny menu bar app (in the spirit of [stats](https://github.com/exelban/stats)) that shows your
Claude and GitHub Copilot plan usage at a glance: the three limits your **Claude account plan**
carries — **Session (5 hr)**, **Weekly (7 day)**, and the **weekly model-scoped** limit
(currently "Fable"). These are plan-wide, not Claude Code's: claude.ai and the Claude apps
draw down the same buckets. Optionally it also tracks your **GitHub Copilot** usage —
AI credits (or premium requests, on a grandfathered plan) against your monthly allowance.

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
  rather than another limit's number. The **first launch ever** opens Settings by itself —
  a fresh install has nothing to poll, so the way in comes first.

### How it gets the numbers

`docs/CREDENTIALS.md` is the authority on everything in this section — the current
mechanism for both providers, the invariants, and the designs already eliminated by
measurement. What follows is the summary.

**The two providers connect by completely different mechanisms, and the asymmetry is the
design: GitHub sanctions third-party access to a user's own usage, and Anthropic
explicitly forbids it.**

#### Claude

Tokes polls `https://api.anthropic.com/api/oauth/usage` — the same endpoint the Claude Code
VS Code extension uses for its Account & Usage panel — and reads the `limits` array
(`session`, `weekly_all`, `weekly_scoped`).

There is no sanctioned way for a third party to authenticate, so **you are the actor at
every step and Tokes never reads another application's credential store on your behalf.**
macOS Claude Code keeps its sign-in in the keychain — there is no credentials file on a
current install — so Settings walks you through three steps:

1. **Export.** Copy one `security find-generic-password …` command out of Settings and run
   it in Terminal. It writes your own sign-in to `~/.claude/tokes-credentials.json`.
2. **Import.** Pick that file in the open panel Settings opens for you. Tokes re-reads it on
   every poll through a security-scoped bookmark, so a rotated token keeps working.
3. **Optional, and the one that makes this livable:** merge the `SessionStart` hook Settings
   gives you into `~/.claude/settings.json`. Every new Claude Code session then re-exports
   the current token, which is what keeps the file fresh.

The limitation, stated plainly: that hook fires on session *start*, so if you don't open
Claude Code before the exported token expires, Claude data goes stale until you do. Tokes
says so at load rather than surfacing a bare 401.

You can also **paste an OAuth access token** manually (stored in Tokes' own keychain item).
It works, but tokens obtained that way last hours and do not refresh.

The direct build additionally offers **Use Claude Code sign-in (automatic)**, which reads
the store Claude Code owns — `~/.claude/.credentials.json` if present, otherwise the
`Claude Code-credentials` keychain item (via `/usr/bin/security` first, whose keychain
approval survives rebuilds of an ad-hoc-signed app, then the Security framework). macOS
asks you to allow keychain access on first use — choose **Always Allow**. It remains the
direct build's default so existing installs don't break; it is compiled out of the App
Store build entirely, and the guided export above is the path the product is built around.

#### GitHub Copilot

**Sign in with GitHub**, in the app — RFC 8628 device flow against Tokes' own GitHub App
("Dev Tokes"), which holds exactly one fine-grained permission: *Account → Plan: read*. It
cannot see your code, repositories, or issues. Tokes stores the token pair in its own
keychain item and refreshes it itself, so this path stays connected with no further action.

Usage comes from GitHub's documented per-user billing reports,
`GET /users/{login}/settings/billing/{meter}/usage` — the `ai_credit` meter first, falling
back to the legacy `premium_request` meter. Three consequences of those reports carrying
raw quantities only:

- **The allowance is not queryable and neither is your plan**, so you pick it in Settings
  (Pro 1,500 / Pro+ 7,000 / Max 20,000 AI credits; 300 / 1,500 / 1,500 premium requests;
  or a custom figure) and the percentage is measured against that choice. If the percentage
  looks wrong, check the plan picker before suspecting the arithmetic.
- **The reset date is derived**: both meters reset at 00:00 UTC on the 1st.
- **An organization-provided Copilot seat has no per-user billing data at all** — that seat
  is billed to the organization and GitHub exposes nothing per user. Tokes says so in as
  many words rather than showing 0%.

Both builds also offer **importing a Copilot config file** in an open panel or **pasting a
GitHub token** manually. The direct build additionally offers **editor sign-in / gh CLI**,
which reads `~/.config/github-copilot/apps.json`, then `hosts.json`, then `gh auth token`,
and polls `https://api.github.com/copilot_internal/user` (the endpoint editor Copilot
plugins use) instead of the billing reports. It is that build's default, and it is compiled
out of the App Store build.

#### History

The APIs only report *current* utilization, so Tokes records a local sample on every poll
(`~/Library/Application Support/Tokes/history.jsonl`, or the equivalent inside the app's
container in the App Store build, pruned to 8 days) to draw the charts. Charts fill in as
the app runs, and read "Collecting history…" until there are enough points.

### Two builds

Tokes ships as a Homebrew/direct build and a Mac App Store build, from one
codebase. The App Store build is sandboxed, and App Review Guideline 2.5.2 does
not allow a sandboxed app to read data outside its container — so the sources
that read Claude Code's and Copilot's own credential stores are compiled out of
it entirely, leaving the GitHub sign-in, the imported file, and the manual
token. Everything else is the same app. `docs/APP-STORE-COMPLIANCE.md` has the
details, the measurements behind them, and how it is verified.

Both are free, and the source is the same either way.

### Install via Homebrew

```sh
brew install appideasDOTcom/tap/tokes
```

**Not published yet** — the tap repo exists but has no cask in it, so this
command does not work today. Build from source (below) or grab a zip from
[Releases](https://github.com/appideasDOTcom/tokes-app/releases) meanwhile.

Until builds are notarized, right-click Tokes.app → Open on first launch (or add
`--no-quarantine` to the install command).

### Build & run

**Requires Xcode 26 or newer** — only its `actool` can compile the `.icon`
package, so an older toolchain aborts the build rather than shipping a bundle
with no icon. Swift 6 toolchain; targets macOS 14+; both flavors build universal
(arm64 + x86_64).

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
persistence/pruning (temp directories), the GitHub device-flow sign-in end to end (device
code, polling, token rotation persisted before use, and a dead session surfacing as
"not connected"), the guided Claude export (its command, hook snippet, and the expiry a
stale export raises), credential parsing/caching for both Claude Code
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
refresh must not downgrade a scoped grant to a plain one). The interaction layer
is tested for real via ViewInspector (a test-only dependency): Settings' toggles,
buttons, and `onChange` handlers are driven against the live view hosted in a
windowless controller, and the status item controller is exercised against a
real `NSStatusItem` — subscriptions redrawing the actual button, hover
scheduling proven never to show a popover, and the context menu wired to a real
poll. Tests touch no live credentials and make no network calls; every class
uses a UUID in its `UserDefaults` suite name, but the suite is still not safe
under `swift test --parallel` — the keychain test service and the standard
defaults behind `@AppStorage` are shared across worker processes.

`scripts/test.sh` runs the suite twice, because the App Store configuration
compiles with `-DTOKES_APP_STORE` and that removes whole functions — the default
configuration alone would leave half the code unbuilt.

### License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Chris Ostmo / appideas.com.

Both distributions are the same MIT-licensed source; neither build adds
proprietary components. The one third-party dependency,
[ViewInspector](https://github.com/nalexn/ViewInspector), is also MIT and is a
**test-only** dependency — it is linked into the test target alone and ships in
no build, so the shipped binaries carry no third-party code.
