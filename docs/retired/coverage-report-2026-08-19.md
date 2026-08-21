# Coverage report — Tokes

Date: 2026-08-19 · measured at `a25b04b`; §9 records the work done in response

> **Superseded for current state** by `coverage-report-2026-08-20.md`, a
> standalone re-measurement. This file remains the submission baseline and
> the work log of how the gaps were closed.

**This is the Mac App Store submission baseline.** It is the measurement the
first release gets compared against, and the first coverage report this repo has
had — so there is no prior report to disposition, and nothing below is a
re-litigation of an earlier finding.

> **Read §11 first, then §10.** §1–§8 are the audit as measured, and are left
> as written; §9 disposes of ranked items 1–6, **§10 closes the rest in three
> phases**, and **§11 tests the interaction layer itself** (ViewInspector,
> live hosted Settings, a real status item) and accounts for every remaining
> uncovered region by name. Two audit claims were wrong and are corrected
> there: §4.12's doubled-poll prediction (§10.1) and §6's reading of
> `testPopoverViewRendersErrorBanner` (§10.3).
>
> **§1–§8 are the audit as measured, and are left as written.** Ranked items
> 1–6 and all three decisions in §8 were acted on in the same session; **§9 is
> the disposition and the re-measurement**, and is the section to read for the
> current state. Findings §4.1, §4.2 (partly), §4.3, §4.4, §4.5, §4.7, §4.10,
> §4.11, §5.2, §5.3 and §5.4 are closed there.

**Method.** Every number came from a run made for this report: `swift test
--enable-code-coverage` in *both* build configurations (default and
`-DTOKES_APP_STORE`), `llvm-cov export`, and a per-region extraction that
resolves each uncovered path to a file, line and column. Sixteen targeted probe
tests were written, run, and deleted — every behavioral claim in §5 and §6 that
is not a coverage number is backed by one of those runs, not by reading the
code. Every gap claimed here was confirmed by reading the source at the
uncovered location and grepping `Tests/` for the control that would reach it.

Two measurement notes that matter for reading the numbers:

- **Swift emits no branch-coverage data.** `llvm-cov`'s Branches column is `-`
  for every file. *Region* coverage is the honest substitute and is what this
  report uses throughout; it counts each distinct control-flow region, including
  both arms of a ternary and each `??` fallback, so it is strictly harsher than
  line coverage.
- **A region appears in more than one function record** (default-argument
  thunks, specializations). Reading any single record produces false zeros —
  `AppDelegate.swift:31` reads as uncovered that way and is in fact executed
  twice. Every figure below takes the *maximum* count across records.

## 1. Topline

| Metric | Direct build | App Store build | Union |
|---|---|---|---|
| Tests | **179**, 0 failures, 15.6 s | **176**, 0 failures, 14.8 s | — |
| Regions | **64.09%** (571/891) | **66.86%** (569/851) | 64.65% (576/891) |
| Functions | 62.79% (216/344) | 64.29% (216/336) | — |
| Lines (llvm-cov) | 71.42% (1917/2684) | 73.65% (1915/2600) | — |
| Source files instrumented | 15 | 15 | — |
| Branches | *not emitted by Swift* | *not emitted* | — |

The App Store configuration reads *higher* because `-DTOKES_APP_STORE` removes
40 regions of foreign-credential-reader code that the direct build has and never
executes. That is the flag working, not extra testing.

**The aggregate is misleading in one specific direction, and it is worth
correcting before reading any further.** Two files — `StatusItemController.swift`
(127 regions) and `Views/SettingsView.swift` (167) — hold **207 of the 320
uncovered regions**, i.e. 65% of the total miss, and both are AppKit/SwiftUI
surfaces that a headless `swift test` cannot drive without either a real event
loop or a UI driver. Excluding those two plus `main.swift`:

> **Everything else: 485/592 regions = 81.93%.**

That second number is the one that describes the tested-and-testable core. The
first number is the one that describes what a regression could get past the
suite, which is why both are here.

**Lines is the metric to distrust.** For SwiftUI files llvm-cov counts each
`body` expansion, so `PopoverView.swift` reads 99.68% *lines* against 98.15%
*regions* on a file that has never had a button pressed. Region is the number to
quote.

## 2. By file

Sorted by uncovered regions, which is the quantity that matters, not percentage.

| File | Direct | App Store | Uncovered (direct) | What the miss is |
|---|---|---|---|---|
| `Views/SettingsView.swift` | **33.53%** (56/167) | 36.36% (60/165) | **111** | Every button action; both Test Connection paths |
| `StatusItemController.swift` | **24.41%** (31/127) | 24.41% | **96** | The controller is never instantiated |
| `CredentialsProvider.swift` | **51.61%** (32/62) | 73.81% (31/42) | **30** | `loadToken()` routing + the Claude Code readers |
| `CopilotCredentialsProvider.swift` | **56.36%** (31/55) | 70.27% (26/37) | **24** | `loadToken()` routing + the `gh` reader |
| `UsagePoller.swift` | 83.54% (66/79) | 83.54% | 13 | Timer and observer lifecycle |
| `ImportedCredentialFile.swift` | 77.36% (41/53) | 77.36% | 12 | Open panel; the plain-bookmark fallback |
| `Distribution.swift` | 75.00% (21/28) | 75.00% | 7 | The code-signature entitlement reader |
| `main.swift` | 0.00% (0/5) | 0.00% | 5 | Process entry point |
| `HistoryStore.swift` | 81.82% (18/22) | 81.82% | 4 | UTF-8 `guard`s; the default directory |
| `CopilotClient.swift` | 90.48% (38/42) | 90.48% | 4 | `NumberFormatter` fallbacks |
| `Views/UsageChart.swift` | 86.21% (25/29) | 86.21% | 4 | `dashed` default; the "Collecting history…" overlay |
| `AppDelegate.swift` | 63.64% (7/11) | 63.64% | 4 | `applicationDidFinishLaunching` / `WillTerminate` |
| `Models.swift` | **96.74%** (89/92) | 96.74% | 3 | Three `?? ""` arms on `defaults.string` |
| `UsageClient.swift` | **96.92%** (63/65) | 96.92% | 2 | `.shared` default; the non-HTTP response guard |
| `Views/PopoverView.swift` | **98.15%** (53/54) | 98.15% | 1 | `@AppStorage` default |
| **TOTAL** | **64.09%** | **66.86%** | **320** | |

Two cells are worth attributing:

- **`CredentialsProvider` 51.61% → 73.81% under the App Store flag.** Not better
  testing: `loadClaudeCodeToken()` and `securityCLIFallback()` are `#if`-excluded,
  so 20 uncovered regions cease to exist. Same for Copilot's `ghCLIToken()`.
- **`Distribution` reads 75% in both, but not on the same regions.** `case
  .direct: return "Direct"` is uncovered in the App Store build and `case
  .appStore` is uncovered in the direct build. The union closes it — the only
  place in the codebase where reading the two configurations as a union is the
  correct reading.

## 3. What the residual actually is

320 uncovered regions, every one resolved to a file, line and column, then
classified:

| Class | Regions | What it is |
|---|---|---|
| Needs a real AppKit host or event loop | **106** | `StatusItemController`'s hover/click/window machinery (96), `runImportPanel` (5), `main.swift` (5) |
| The two connection testers | **36** | `testConnection` and `testCopilotConnection` entire, unreachable without an injectable client — §4.7 |
| SwiftUI declarations never re-evaluated | ~35 | `@AppStorage` / `@State` default-value initializers, `if let testResult` arms, the saved/error label variants. `.onAppear` **does** fire (measured: 38 executions); nothing else in the view lifecycle does |
| Button action closures never pressed | ~28 | Save Token ×2, Choose File…, Forget, launch-at-login register/unregister, all four `.onChange` handlers — §4.9 |
| Reads a store the test process must not touch | **36** | `loadClaudeCodeToken` + `securityCLIFallback` (18), `ghCLIToken` + `loadEditorToken`'s fallback (13), `SandboxAudit.sandboxEntitlement` (5) |
| Bypassed by the test seam | **23** | Both `loadToken()` routers and their `accessToken()` callers — §4.1 |
| Timer / observer lifecycle | **13** | `UsagePoller.start`, `schedule`, `didWake`, `defaultsChanged` — §4.12 |
| Unreachable by construction | 4 | The `#if TOKES_APP_STORE` `sourceUnavailable` throws (normalization removes the case before it can be hit) and the two `response as? HTTPURLResponse` guards (URLSession cannot deliver a non-HTTP response to an HTTPS request) |
| Defensive `??` / `guard` behind a stated invariant | ~22 | `HistoryStore`'s UTF-8 decoding guards, `NumberFormatter` fallbacks, `defaults.string(...) ?? ""` |
| **Everything else** | **~17** | §4.8, §4.13 |

Counts marked bold are exact; the two `~` rows split `SettingsView`'s 111
between declaration-shaped and gesture-shaped regions and are approximate at the
margin. The classification is not an excuse list — six of these classes contain
findings, and "unreachable by construction" is the only one that contains none.

## 4. Findings

Ordered by consequence: (probability a real user hits it) × (damage).

### 4.1 The credential router has never executed, in either build

`CredentialsProvider.loadToken()` and `CopilotCredentialsProvider.loadToken()`
both report **0 executions in both configurations** — verified directly:

```
$s5Tokes19CredentialsProviderC9loadToken...:
   92|      0|    private func loadToken() throws -> (String, Date?) {
   93|      0|        switch source {
   94|      0|        case .manual:
   99|      0|        case .importedFile:
  101|      0|        case .claudeCode:
```

Every test in `TokenCachingTests` and `CopilotTokenCachingTests` sets
`loadTokenOverride`, which is checked *before* `loadToken()` in `accessToken()`.
So the seam built to make caching testable bypasses precisely the code that
decides where a token comes from.

What that leaves unproven: that selecting **Manual OAuth token** reads
`com.appideas.tokes`/`oauth-token` rather than some other slot; that selecting
**Import a credentials file** reaches `importedFile`; that an empty manual token
produces `manualMissing` rather than an empty `Bearer` header. In the App Store
build those two sources are the *only* ones that exist.

Both halves are separately excellent — `ManualTokenKeychainTests` proves the
keychain round-trip, `ImportedCredentialFileTests` proves the bookmark layer, and
`CredentialSourceDefaultsTests` proves `current(in:)` normalizes. Nothing joins
them.

**Blocker, and it is small.** `private var source` reads
`CredentialSource.current()` with no argument, so it is hard-wired to
`UserDefaults.standard`. Adding `var defaults: UserDefaults = .standard` to both
providers (the enums already take `in defaults:`) makes the whole router
testable in about eight assertions.

### 4.2 The menu bar is never drawn by a test

`StatusItemController` is **never instantiated** — `init` and `updateButton` are
both 0-execution. `makeIcon` and `makeTitle` are thoroughly tested (15 tests,
including rasterized pixel checks), but they are the two pieces that were
*already* lifted out as pure statics. The composition around them is dark:

- **The tooltip has no test at all.** Both branches — `"Tokes — waiting for
  usage data"` and the `"Usage — "` / `"Claude usage — "` prefix switch plus the
  `label: N%` join — are unexecuted. The tooltip is the only place the full set
  of numbers is readable without opening the popover.
- **The `showScopedWeekly` filter is tested for the popover and not for the icon.**
  `ViewSmokeTests.testPopoverViewHidesScopedWeeklyWhenDisabled` proves the
  popover half. `updateButton`'s `filter { showScoped || !$0.isScopedWeekly }`
  and the `claudeTracks: showScoped ? 3 : 2` that must move with it are
  unexecuted. `makeIcon(claudeTracks: 2)` is tested in isolation; that the
  setting *selects* it is not.
- **The Combine wiring is unexecuted** — the `$snapshot.combineLatest($errorMessage)`
  sink and the `UserDefaults.didChangeNotification` sink. A refactor that dropped
  either would leave a menu bar item that never updates, and the suite would stay
  green.
- The hover/pin state machine, `repositionPopoverWindow()` (the macOS 26 fix
  CLAUDE.md calls out), and `openSettings()` are all unexecuted.

`visual-verify` exists for this, and it is the right tool for the pixels — but it
is a manual screenshot skill, not a gate, and it does not assert a tooltip string.

**Cheapest fix with the best return:** lift the tooltip and the limit filter into
static pure functions beside `makeTitle`, exactly as the icon and title already
were. That converts the two highest-value untested behaviors into unit tests
without an event loop.

### 4.3 `Retry-After` is trusted without bounds, in both directions

Measured, not inferred. A probe that ticks six times against a 429 carrying
`Retry-After: 0`:

```
PROBE fetches after 6 ticks with retryAfter=0: 6
```

Six ticks, six requests. The backoff CLAUDE.md documents — *"skips Claude polls
entirely until the backoff passes: `Retry-After` header when present, else 90 s
doubling per consecutive 429 (cap 15 min)"* — does not hold when the server keeps
saying zero. `rateLimitStreak` still increments, but `retryAfter ?? min(90 *
pow(2, …), 900)` short-circuits before the doubling schedule is ever consulted,
so the cap protects only the *absent*-header case.

The same expression is unbounded upward. Parsed values, probed:

| Header | `Double.init` | Effect |
|---|---|---|
| `0` | `0.0` | no backoff — poll again next tick |
| `-1` | `-1.0` | no backoff |
| `1e9` | `1000000000.0` | Claude polling parked ~31 years (in memory only; a relaunch clears it) |
| `Wed, 21 Oct 2015 07:28:00 GMT` | `nil` | falls back to doubling — correct, since the HTTP-date form is not parsed |
| `  30  ` (padded) | `nil` | falls back to doubling — safe |

The existing test is what makes this easy to miss: `testExpiredRetryAfterResumes
PollingAndClearsBackoff` uses `retryAfter: 0` deliberately, to prove recovery,
and asserts exactly 2 fetches over 2 ticks. The value that defeats the backoff
entirely is the value a passing test depends on, so the pathological case reads
as the tested case.

**Fix:** `min(max(retryAfter, 30), 900)`, and a test that ticks more than twice.

### 4.4 A second model-scoped weekly bucket is unhandled and untested

No test anywhere feeds two `weekly_scoped` entries. A probe that does:

```
PROBE ids: ["session", "weekly_all", "weekly_scoped:Opus", "weekly_scoped:Fable"]
PROBE weeklyScoped picks: weekly_scoped:Opus
PROBE icon width 4 claude: 31.0
```

Three consequences, none of them pinned:

1. **`MenuBarLabel.weeklyScoped.limit(in:)` is `limits.first { $0.isScopedWeekly }`.**
   The Settings option reads "Weekly (model-specific)"; what it actually means is
   "whichever model the API happened to list first". The user has no way to choose,
   and the choice can change between polls.
2. **Display order is not contractual.** `mapLimits` sorts by a rank that returns
   `2` for every scoped bucket, and `Array.sorted(by:)` carries no stability
   guarantee. It is stable in the current standard library, so today the order is
   the API's; nothing says it has to stay that way.
3. **The menu bar item grows** from 23 pt to 31 pt (a fourth Claude bar). That is
   correct behavior — `claudeSlots` is `max(claude.count, claudeTracks)` — but the
   three-track reservation exists precisely so the item does *not* resize, and
   nothing asserts what happens when it does.

Plans that meter more than one model are the reason `weekly_scoped` is an array.

### 4.5 The model's display name is part of the history key

`weekly_scoped:\(model)` is both the `UsageLimit.id` and the `UsageSample.v`
dictionary key. A probe over a rename:

```
PROBE chart series after rename — samples in store: 2  matching new id: 1
```

When Anthropic changes a model's `display_name`, every historical sample for that
bucket becomes unreachable: the chart drops to a single point and renders
"Collecting history…" with no explanation, while the old rows sit in
`history.jsonl` for eight days doing nothing. The scoped id in the codebase today
is literally `weekly_scoped:Fable`.

This is as much a decision as a test — keying on the model name may be the right
call, and there is a reasonable argument that a renamed model *is* a different
bucket. But it is invisible in the code as a decision and nothing pins it.

### 4.6 A Copilot plan reporting `entitlement: 0` surfaces as a parse error

Probed:

```
PROBE zeroEnt threw: decode("no usable quota fields in response")
```

For `{"entitlement": 0, "credits_used": 0, "unlimited": false}` the user sees
**"Could not parse Copilot response (no usable quota fields in response)"** as a
standing banner. That reads as a Tokes bug; it is a plan shape. The `entitlement
> 0` guard exists to avoid dividing by zero, and the `else` lands in the same
arm as "the body had no numbers at all", which is the case
`testUnusableQuotaFieldsThrowsDecode` actually covers (`{"unlimited": false}`).

Adjacent, and correct: overage clamps properly (`credits_used: 150,
entitlement: 100` → 100%, `percent_remaining: -50` → 100%). Untested, but right.

### 4.7 Neither "Test Connection" button has ever run — and neither can

`testConnection()` and `testCopilotConnection()` are 0-execution in both
configurations, including their `#if TOKES_APP_STORE` `sourceUnavailable` arms.
This is the app's only self-diagnostic, and for an App Store user who has just
imported a credentials file it is the first thing they will press.

It is also **untestable as written**. Both construct `UsageClient()` /
`CopilotClient()` inline, which takes the default `.shared` session. The
injectable `session` property exists — every HTTP test uses it — and this call
site is the one place that ignores it. One parameter (or hoisting the client to a
property) makes the whole function reachable with `MockURLProtocol`.

Note what that means for the coverage number: `UsageClient.swift:30`
(`var session: URLSession = .shared`) shows as uncovered because *no test ever
takes the default*, which is exactly right and exactly why the button can't be
tested.

### 4.8 The imported file's plain-bookmark fallback is untested, and under the sandbox it degrades silently

`ImportedCredentialFile.store()` catches a security-scoped bookmark failure and
falls back to a plain bookmark with `securityScoped: false`. That `catch` arm has
**0 executions**, and so do both `securityScoped == false` ternary arms in
`resolve()` (`:115`, `:125`).

The consequence under the sandbox is specific: with `securityScoped == false`,
`resolve()` sets `opened = true` *without* calling
`startAccessingSecurityScopedResource()`, so the `guard opened` passes and the
failure lands later, at `Data(contentsOf:)`, as `unreadable(path)`. The user gets
"Could not read the imported file (…). Import it again in Settings." — actionable,
but pointing at the wrong cause.

Worse is the refresh path. `resolve()` handles a stale bookmark with
`try? store(url)` while the scope is open. If *that* re-creation hits the same
failure, a working security-scoped grant is silently downgraded to a plain
bookmark and stops working at the next launch. The stale-refresh branch **is**
covered (`testRereadSurvivesAnAtomicReplacement` drives it); the failing-refresh
branch is not.

In the App Store build this file is the only automatic credential source there
is.

### 4.9 Every Settings button is unexecuted; the import flow has no test at any level

Uncovered, all of them: **Save Token** (Claude and Copilot), **Choose File…**,
**Forget**, the `path == nil ? "Choose File…" : "Choose Another File…"` title, the
imported-path `Label`, and the error `Text`.

The layer beneath is well covered — 13 tests in `ImportedCredentialFileTests`
including rotation and atomic replacement. What is missing is the join: that the
button reaches `runImportPanel`, that `Forget` calls `clear()`, that
`onCredentialsChanged()` fires afterwards so the poller re-resolves, and that
`Save Token` writes the account the *Copilot* provider reads
(`CopilotCredentialsProvider.manualAccount`) rather than Claude's.

That last one is a real crossing hazard: `SettingsView:223` passes `account:
CopilotCredentialsProvider.manualAccount` and `SettingsView:186` omits it. Two
call sites, one defaulted parameter, no test on either.

For the App Store build, this is the entire onboarding path.

### 4.10 The App Store normalization runs but is never asserted

In the App Store configuration, `SettingsView`'s `.onAppear →
normalizeCredentialSources()` fires (38 renders) *and* takes the write branch —
`:299` and `:301` are covered there and uncovered in the direct build, which is
exactly the expected asymmetry. So the guard works.

Nothing checks it. `ViewSmokeTests` asserts `fittingSize.width == 460` and
nothing else, so the mechanism that stops a `defaults` domain carried in from the
Homebrew build leaving the App Store build pointed at `claudeCode` — a reader it
does not ship — is *executed but unproven*. One `XCTAssertEqual` on the defaults
after the render closes it, and it belongs in the suite that already sets
`claudeCode` deliberately.

### 4.11 A partial poll failure resets the "Updated" clock

Probed: Claude limits two hours old, Claude fails, Copilot succeeds.

```
PROBE claude limits are 7200s old; snapshot.fetchedAt age is now 0s
PROBE claude percent still: 7.0
```

`tick()` initializes `fetchedAt = Date()` and only overwrites it from a *Claude*
success, so a Copilot-only success stamps the whole merged snapshot as fresh. The
popover footer reads "Updated 0 seconds ago" over two-hour-old Claude numbers.

The error banner and the orange menu bar label do signal that something is
failing, so this is not silent — but the timestamp is wrong for half the data,
and `testClaudeFailureCarriesForwardClaudeLimits` asserts the carry-forward
without asserting `fetchedAt`. A decision (per-limit freshness, or stamp the
snapshot with the *older* of the two) plus a test.

### 4.12 The poller's timer and observer lifecycle is entirely unexecuted

Thirteen regions: `start()`, `schedule()`, the `Timer` block, `didWake()`, and
`defaultsChanged()` with both of its `if`s. `stop()` is covered only incidentally,
because every `tearDown` calls it.

So nothing proves that changing **Refresh every** reschedules the timer, that
toggling **Copilot** triggers an immediate re-poll, or that waking from sleep
polls after three seconds. All three are user-visible settings behaviors, and
`defaultsChanged` is `@objc` — reachable from a test by posting
`UserDefaults.didChangeNotification` after `start()`, with no event loop needed
beyond a `DispatchQueue.main` drain.

Also unexercised, and worth one assertion while in there: `start()` adds
observers unconditionally, so a second `start()` would double every poll. Not
reachable today (`AppDelegate` calls it once) but nothing says so.

### 4.13 Smaller items, batched

None of these deserves its own test; all fall out of a test written for something
else, and they are recorded so a future audit does not re-derive them.

- **`downsample(_:maxCount: 0)` traps.** `Int(ceil(10 / 0.0))` →
  `Fatal error: Double value cannot be converted to Int because it is either
  infinite or NaN`. Not reachable — the only call site passes the literal 240 —
  but it is a `static` API the tests already drive, and the failure is a trap
  rather than a thrown error. `guard maxCount > 0 else { return pts }`.
- **Out-of-range percents render inconsistently.** Probed: `percent: -5` draws
  `" -5%"` in `.labelColor`, `percent: 420` draws `" 420%"` in red. `makeIcon`
  clamps to 0…100; `makeTitle` does not. Two renderers, one value, one of them
  pinned.
- **Duplicate limit ids survive mapping.** Probed: two `{"kind":"session"}`
  entries produce two `UsageLimit`s with `id == "session"`. `PopoverView` feeds
  those to `ForEach` over an `Identifiable` whose id then repeats — SwiftUI's
  documented undefined behavior — and `UsageSample.v` is a dictionary, so history
  keeps only the last. `mapLimits` has no dedup.
- **`HistoryStore`'s three UTF-8 `guard`s** (`:35`, `:47`, `:60`) and its default
  Application Support directory (`:21`) are unexecuted. The directory one is
  correct by design (every test injects a temp dir).
- **`CopilotClient`'s two `NumberFormatter ?? String(Int(...))` fallbacks** — the
  formatter does not fail for finite doubles.
- **`Distribution.sandboxEntitlement`'s four `return nil` paths** — reachable only
  from an unsigned or unreadable code signature.
- **`UsageChart.dashed`'s default** and the `pts.count < 3` "Collecting history…"
  overlay. The overlay is user-visible on first launch and never rendered by a
  test; `ViewSmokeTests` always seeds 10–20 samples.
- **`UsageChart`'s own window filter has never rejected a sample** (`:28`). Every
  seeded sample is inside the window and carries every limit id, so the `guard
  sample.t >= cutoff, let v = sample.v[limitID]` that keeps a 7-day chart from
  drawing 8-day-old points — and keeps one limit's series out of another's chart —
  has only ever taken its accept arm. One sample outside the cutoff closes it.
- **`AppDelegate.applicationDidFinishLaunching` / `applicationWillTerminate`** and
  `main.swift` — the process entry point, out of reach by construction.

## 5. What the coverage number cannot see

### 5.1 The suite is not safe under `swift test --parallel`

Run for this report. Five tests in `ImportedCredentialFileTests` fail:

```
ImportedCredentialFileTests.swift:90: XCTAssertTrue failed
ImportedCredentialFileTests.swift:91: threw error "notImported("test credentials")"
ImportedCredentialFileTests.swift:150: threw error "unreadable("test credentials")"
ImportedCredentialFileTests.swift:57: ...TokesTests-setUp()-97C0825C... is not equal to
                                       ...TokesTests-setUp()-D95EBEB1...
```

Cause: the class uses a **fixed** defaults suite (`com.appideas.tokes.tests.
importedfile`) and a **fixed** bookmark key (`"testBookmark"`). Under `--parallel`
each test runs in its own *process* but they share that one plist on disk, so
worker A's `setUp` wipes worker B's bookmark mid-test. The temp directories are
already unique, which is why the failure surfaces as "the bookmark resolves to
someone else's directory".

`AppDelegateTests` and `MenuBarLabelTests` already do this correctly, with a UUID
in the suite name. Applying the same pattern to `ImportedCredentialFileTests`,
`CredentialSourceDefaultsTests`, and the `UserDefaults.standard` writes in
`ViewSmokeTests` / `UsagePollerCopilotTests` would make the obvious speedup safe.
As it stands, someone reaching for `--parallel` gets five failures that read as
bugs in the bookmark code.

### 5.2 The test process reads the app's real keychain items

`ViewSmokeTests` renders `SettingsView` **38 times**, and `.onAppear` fires every
time — measured, not assumed:

```
  136|     38|            manualToken = CredentialsProvider.readManualToken() ?? ""
  137|     38|            copilotToken = CredentialsProvider.readManualToken(
  138|     38|                account: CopilotCredentialsProvider.manualAccount) ?? ""
```

That is **76 `SecItemCopyMatching` reads per run** against service
`com.appideas.tokes`, accounts `oauth-token` and `copilot-token` — the exact slot
CLAUDE.md's Rules section declares off-limits to tests, and the thing README:129
says the suite does not do.

It is read-only and harmless in effect. It is still a stated rule the suite
breaks silently, and on a machine where the keychain item's ACL does not already
trust the test binary it is an interactive prompt in the middle of a headless
run — including on a CI runner, where the item does not exist and the read simply
returns nil, which is why it has never been noticed.

Fix: inject the service/account into `SettingsView`, or gate the `onAppear` read
behind an injected reader. Either way, §7 says which docs to correct.

### 5.3 CI runs on tags only

`.github/workflows/release.yml` is the only workflow, and it triggers on
`push: tags: ["v*"]`. Nothing runs on a branch push or a pull request.

So between releases, `scripts/test.sh` and `scripts/verify-appstore.sh` are
developer discipline. For a project whose own comment says *"The compliance gate
is a build artifact, so it regresses like one"*, the audit that catches the
regression currently runs only **after** the version has been tagged — at which
point the fix requires a new tag.

A second workflow on `push` / `pull_request` running `scripts/test.sh` and
`build.sh --app-store && verify-appstore.sh --static-only` is the single highest-
leverage change in this report that is not a test.

### 5.4 The compliance auditor has no self-test, and two soft spots

`verify-appstore.sh` is the only thing standing between a refactor and a
Guideline 2.5.2 violation, it is shell, and it has no test. CLAUDE.md already
records two traps that silently turned its checks into passes. Two more soft
spots exist today:

1. **`/usr/bin/gh` is not in the forbidden list.**
   `CopilotCredentialsProvider.swift:141` tries three paths —
   `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, `/usr/bin/gh`. The first two are
   in `FORBIDDEN`; the third is not. A refactor that dropped the Homebrew paths
   would audit clean while still shipping a `gh` invocation. (The `Foundation.
   Process` symbol check would still catch it — but that is a second line of
   defense doing the first line's job, and the string list is the one that names
   the offense.)
2. **The entitlement-count check is a `warn`, not a `fail`.** A fourth
   `com.apple.security.*` entitlement prints a yellow `!`, leaves `FAIL` at zero,
   and therefore passes both CI and `appstore.sh`'s `verify-appstore.sh
   --static-only || die` gate. That check is the most likely one to catch a
   compliance regression introduced by a future feature.

### 5.5 Swift 6 concurrency is unmeasured

`Package.swift` pins `.swiftLanguageMode(.v5)` for both targets, so no
concurrency diagnostics run. The shared mutable state that would be flagged:
`DebugLog.fileURL` (a `static var` mutated by `DebugLogTests`),
`MockURLProtocol.handler`, and `UsagePoller.currentInterval` — written on main
via `DispatchQueue.main.async` from `schedule()`, read in `defaultsChanged()` on
whatever thread posted the notification.

Nothing here is a known live bug, and `tick()` is correctly `@MainActor`. But it
is *unmeasured*, and the measurement is one flag away. Worth doing before the
next feature, not before the submission.

### 5.6 Harness fidelity — where the tests and the app differ

1. **`NSHostingController` + `layoutSubtreeIfNeeded()` fires `.onAppear` and
   nothing else.** No `.onChange` handler and no `Button` action has ever run
   (§4.9). SwiftUI tests here cover construction and first appearance only, which
   is a real tier — it catches a crash-on-render and a layout regression — but it
   is narrower than "hosting-controller smoke tests of the SwiftUI views" implies.
2. **The poller is always driven through `tick()` directly**, never through the
   timer. The timer is a stub in every test (§4.12).
3. **`MockURLProtocol` answers synchronously.** Nothing exercises the 15 s
   `timeoutInterval` or a transport error. A `URLError` is not mapped to a
   `UsageError`, so it reaches the banner as Foundation's own copy ("The Internet
   connection appears to be offline.") — decent copy, arrived at by accident,
   untested. Offline is the most common failure mode this app has.
4. **`SMAppService.mainApp.status` is read against the test runner's bundle** at
   `SettingsView` init. The register/unregister path (`:112–121`) is
   0-execution and cannot be driven from a unit test at all.
5. **Keychain tests use a real keychain** (test-only service). Genuine I/O and
   good fidelity — this is the harness doing better than a mock would.
6. **`Raster` compares channel *ordering*, not exact values**, and derives scale
   from the produced `cgImage`. Robust against a display-scale difference; it
   would not catch a wrong-but-still-reddish color.

## 6. Assertion quality

Spot-read of every suite for tautologies, mock-testing, and checks that can pass
on an empty scan. The result is better than the coverage number suggests.

- **The repo-reading tests are protected the right way.** `IconPipelineTests`
  guards both of its parsers against a silent empty result —
  `XCTAssertFalse(radii.isEmpty)` before the wall-thickness assertion, and
  `icnsTypeCodes` compared against a four-element literal so a broken `.icns`
  walk reads `[]` and fails. This is the class of test that rots into a tautology
  without anyone touching it; no change needed, and the guards should not be
  "simplified" away.
- **Nothing asserts a mock.** `MockUsageClient.gate` in
  `testConcurrentTicksCoalesce` is the only tricky construction, and it is the
  right one — the continuation holds the first tick open so the second genuinely
  arrives in flight, which is the only way to see the `inFlight` guard.
- **The negative cases are real negatives.** `testAbsentMeasurementDrawsNoTitle
  RatherThanAnotherLimit` loops all six `MenuBarLabel` cases against an empty
  snapshot with a per-case message; `testMissingMeasurementSelectsNothing` does
  the same at the model layer. Both would fail loudly on a fallback-to-first
  regression.
- **`DistributionTests` is written against explicit `Distribution` values, not
  `.current`**, with a separate test that pins `.current` to the compile flag.
  That is the correct shape and it is why the compliance assertions hold in both
  configurations rather than half-running in each.
- **One assertion is weaker than it reads.** `testPopoverViewRendersErrorBanner`
  asserts `withError.height > plain.height - 60` — a banner that rendered at zero
  height would still pass. Its siblings use the same tolerance idiom correctly
  (`hidden < full - 60` is a real inequality); this one is the wrong direction
  for what it is trying to prove.

## 7. Docs accuracy

Four claims are stale or wrong. Everything else in `docs/` was swept and holds —
`RELEASING.md`, `APP-STORE-SUBMISSION.md` and `FOLLOW-UPS.md` are current, and
`FOLLOW-UPS.md`'s pre-submission checklist is not duplicated here.

1. **`docs/APP-STORE-COMPLIANCE.md:95`** — "178 tests direct, 175 App Store".
   Actual today: **179 and 176**. The parenthetical is still right: the three
   fewer are `CopilotEditorTokenLookupTests`, guarded out with the reader they
   cover.
2. **`README.md:129`** — "Tests touch no live credentials and make no network
   calls." The second half is true and well engineered. The first half is false:
   76 reads per run of the real `com.appideas.tokes` keychain items (§5.2).
3. **`README.md:119`** — "the manual keychain item (a test-only service, never
   the real one)". True of `ManualTokenKeychainTests`, which is scrupulous about
   it; false of the suite as a whole, for the same reason.
4. **`CLAUDE.md:121`** — "Tests must make no network calls (use `MockURLProtocol`)
   and never touch real credentials." This is the authoritative statement and the
   one to make true rather than to soften. Fixing §5.2 fixes all three of the
   above.

One thing worth *adding* rather than correcting: nothing in the docs says the
suite cannot run under `--parallel` (§5.1), and the natural reading of
`scripts/test.sh` is that `swift test` is interchangeable with any of its flags.

## 8. Ranked recommendations

By (probability × damage), with the tier. Items 1–5 are where this report earns
its keep.

1. **Bound `Retry-After`** (§4.3) — one expression, one test. The documented 429
   protection currently does not exist for a server that answers `0`, and Tokes
   hammering Anthropic's endpoint every 30 s during an outage is the failure mode
   most likely to have an outside consequence.
2. **Make `loadToken()` reachable and test the router** (§4.1) — add `var
   defaults: UserDefaults = .standard` to both providers. Eight assertions cover
   the source dispatch that currently has none, including both paths the App
   Store build ships.
3. **Add a CI workflow on push and pull_request** (§5.3) — `scripts/test.sh` plus
   `build.sh --app-store && verify-appstore.sh --static-only`. Not a test, but the
   thing that makes every other test load-bearing between releases.
4. **Stop the suite reading the real keychain, then fix the three docs claims**
   (§5.2, §7) — a rule the project states plainly and breaks 76 times per run.
5. **Lift the tooltip and the menu bar limit filter into pure statics, and test
   them** (§4.2) — the largest untested surface in the app, reduced to the part
   that does not need an event loop. Also add the `updateButton` composition test
   for `showScopedWeekly` → `claudeTracks`.
6. **Give `testConnection()` / `testCopilotConnection()` an injectable client,
   then test all six source paths** (§4.7) — the App Store user's first
   interaction, currently unreachable by any test.
7. **Two scoped weeklies, and the decision behind `weekly_scoped:<model>`**
   (§4.4, §4.5) — one mapping test plus a written-down decision about what
   happens when a model is renamed. Both are cheap; the second is a decision as
   much as a test.
8. **Cover the Settings import/forget flow and assert the App Store
   normalization** (§4.9, §4.10) — including the Copilot `account:` argument that
   distinguishes two otherwise identical Save Token buttons.
9. **`entitlement: 0` should not read as a parse failure** (§4.6) — one branch,
   one test, and better copy for a plan shape that exists.
10. **The plain-bookmark fallback** (§4.8) — at minimum a test for
    `securityScoped: false` resolution; ideally, `store()` should not silently
    downgrade a previously security-scoped grant during a stale refresh.
11. **Decide what "Updated N ago" means on a partial failure** (§4.11) — the
    footer currently reads "just now" over data that can be hours old. Either
    stamp the snapshot with the older of the two fetch times or carry freshness
    per limit; either way, assert `fetchedAt` in the carry-forward tests that
    already exist.
12. **Poller lifecycle: interval change, Copilot toggle, wake** (§4.12) — three
    tests via `NotificationCenter`, no event loop required.
13. **Auditor hardening** (§5.4) — add `/usr/bin/gh` to `FORBIDDEN`; make the
    entitlement-count check a `fail`.
14. **Make the suite `--parallel`-safe** (§5.1) — UUID suite names in three
    classes.
15. **The §4.13 batch and the `testPopoverViewRendersErrorBanner` inequality**
    (§6) — no dedicated work; take them where a neighbouring test is already
    being written.
16. **Measure Swift 6 language mode** (§5.5) — after the submission, before the
    next feature.

**Does any of this block the App Store submission?** No. Nothing here is a
correctness failure in a path the reviewer will walk, the compliance boundary is
enforced by a mechanism (`-DTOKES_APP_STORE` + `verify-appstore.sh`) that is
independent of this suite, and 179/176 tests pass in both configurations.

What it does say is that the submitted build's **onboarding path** — import a
file, press Test Connection, see the menu bar update — is the least-tested part
of the app, and that items 1, 3 and 6 are worth closing before the *second*
submission regardless of what happens to the first.

## 9. Disposition — what was closed, and the re-measurement

Ranked items 1–6 and all three decisions were done in the same session as the
audit. Numbers below come from a fresh instrumented run in both configurations
after the work, by the same method as §1.

### 9.1 Topline, before and after

| Metric | Before | After | Δ |
|---|---|---|---|
| Tests (direct) | 179 | **237** (2 skipped) | +58 |
| Tests (App Store) | 176 | **234** | +58 |
| Regions, direct | 64.09% (571/891) | **70.81%** (650/918) | +6.72 |
| Regions, App Store | 66.86% (569/851) | **74.03%** (650/878) | +7.17 |
| Regions, union | 64.65% | **71.57%** (657/918) | +6.92 |
| Regions, excl. the two AppKit surfaces | 81.93% (485/592) | **85.23%** (525/616) | +3.30 |

The region *total* grew by 27 (the new backoff function, the menu bar content
type, the two extracted connection testers), so the percentage moved on covered
count rather than on shrinking denominators: 571 → 650 covered regions.

| File | Before (direct) | After (direct) | After (App Store) |
|---|---|---|---|
| `CredentialsProvider.swift` | 51.61% | **67.69%** | **95.56%** |
| `CopilotCredentialsProvider.swift` | 56.36% | **74.14%** | **95.00%** |
| `Views/SettingsView.swift` | 33.53% | **48.21%** | **52.41%** |
| `StatusItemController.swift` | 24.41% | **34.88%** | 34.88% |
| `CopilotClient.swift` | 90.48% | 92.86% | 92.86% |
| `UsagePoller.swift` | 83.54% | 83.33% | 83.33% |

Two of those need reading carefully:

- **The provider files are now ~95% in the App Store build**, which is the build
  being submitted. What is left uncovered there is nothing; what is left in the
  *direct* build is exactly the foreign-store readers — `loadClaudeCodeToken`,
  `securityCLIFallback`, `ghCLIToken` — which a test must not exercise. That is
  now the entire residual in those two files, which is the right shape.
- **`UsagePoller` reads flat at 83%** while gaining 14 covered regions, because
  it also gained 17 new ones. The uncovered set is now almost entirely the
  timer/observer lifecycle (§4.12, ranked 12 and not done).

### 9.2 Decisions, as implemented

| Decision | Resolution | Pinned by |
|---|---|---|
| Two scoped weeklies (§4.4) | `MenuBarLabel.weeklyScoped` picks the **highest** scoped bucket, not the first. Order-independent, and it cannot silently hide the model nearest exhaustion | `testScopedWeeklyPicksTheHighestOfSeveralModels`, `testTwoScopedWeekliesBothSurviveWithDistinctIds` |
| Snapshot freshness (§4.11) | `fetchedAt` is the **oldest** contributing fetch. Per-provider times are tracked in `lastFetch`; a carried-forward provider contributes its own age, not "now" | `testPartialFailureKeepsTheOlderTimestamp`, `testBothSucceedingUsesTheOlderOfTheTwoFetches`, `testRecoveryRestoresAFreshTimestamp`, `testABackedOffTickDoesNotRefreshTheTimestamp` |
| History key (§4.5) | **Kept** as `weekly_scoped:<display name>`; a renamed model starts a new series. Written down on `UsageSample` with the reasoning, including why a stable key is not an option (it would collapse two metered models into one line) | `UsageSampleKeyingTests` |

The freshness change has one deliberate side effect, documented at
`refreshIfStale`: because it reads the same `fetchedAt`, a provider outage now
means every popover opening retries. The 429 window still suppresses it.

### 9.3 Ranked items 1–6

1. **`Retry-After` bounded** (§4.3) — clamped to 30…900 s in a new pure
   `UsagePoller.backoffDelay(retryAfter:streak:)`. `BackoffDelayTests` pins all
   six columns of the table in §4.3 plus the doubling schedule and its cap; a
   new `UsagePoller.now` clock seam lets `testZeroRetryAfterStillBacksOff`,
   `testConsecutiveRateLimitsWidenTheWindow` and
   `testSuccessResetsTheBackoffSchedule` walk real windows without sleeping.
   The old `testExpiredRetryAfterResumesPollingAndClearsBackoff` — which
   depended on `retryAfter: 0` producing no backoff, the exact pathology — was
   rewritten against the clock.
2. **The credential router is reachable and tested** (§4.1) — both providers
   gained `defaults`, `manualService` and `manualAccount`. `loadToken()` went
   from **0 executions in both configurations** to fully driven:
   `ClaudeCredentialDispatchTests` and `CopilotCredentialDispatchTests` cover
   manual (present, absent, removed mid-session), imported file (present,
   absent, wrong shape), that the unselected source is never consulted, and
   that a stored `claudeCode`/`editor` selection carried in from the Homebrew
   build resolves to the imported file **in the App Store build** — the
   compliance behavior, tested end to end for the first time.
3. **CI on push and pull request** (§5.3) — `.github/workflows/ci.yml` runs
   `scripts/test.sh` plus `build.sh --app-store && verify-appstore.sh
   --static-only` on `main`/`develop` and every PR, with `cancel-in-progress`.
   The audit no longer runs for the first time *after* a tag exists.
4. **The suite no longer reads the real keychain** (§5.2) — `SettingsView` took
   `keychainService` and `bookmarkDefaults`; `ViewSmokeTests` points both at
   test-only values. 76 reads per run of `com.appideas.tokes`/`oauth-token` and
   `/copilot-token` → zero. The three stale docs claims (§7) are corrected, and
   CLAUDE.md now names `SettingsView`'s `onAppear` as the trap, since the read
   is invisible at the call site.
5. **The menu bar composition is testable** (§4.2) — `StatusItemController
   .content(for:showScopedWeekly:)` returns a `MenuBarContent` (limits,
   `claudeTracks`, tooltip) with no AppKit involved, and `updateButton` is now
   three lines over it. `MenuBarContentTests` covers the tooltip's three forms
   and its rounding against `makeTitle`, the scoped-weekly filter in both
   directions, that the reserved bar count moves with the filter, that Copilot
   is unaffected by it, and that every scoped bucket hides together.
6. **Both Test Connection buttons are reachable** (§4.7) — extracted to
   `SettingsView.claudeTestOutcome` / `copilotTestOutcome`, taking an injected
   `URLSession`. `ConnectionTestTests` (17 tests) covers success per source, the
   token actually sent, an empty paste short-circuiting before any request, a
   401, a 500, offline, a missing import, an unusable import, and — in the App
   Store build — the `sourceUnavailable` arms, which had never executed in
   either configuration.

Two smaller things were taken while adjacent: `verify-appstore.sh` gained
`/usr/bin/gh` in `FORBIDDEN` and its entitlement-count check was promoted from
`warn` to `fail` (§5.4), and the dead `?? ""` on
`UsageError.rateLimited(...).localizedDescription` was removed.

`scripts/verify-appstore.sh` was re-run against a fresh `build.sh --app-store`:
**31 passed, 0 failed**, including both hardened checks.

### 9.4 Still open

Unchanged and still worth doing, in the order they were ranked:

- **§4.12 / rank 12** — the poller's timer and observer lifecycle. Now the
  dominant share of `UsagePoller`'s residual.
- **§4.6 / rank 9** — a Copilot plan with `entitlement: 0` still surfaces as
  "Could not parse Copilot response".
- **§4.8 / rank 10** — the imported file's plain-bookmark fallback, and the
  silent downgrade during a stale refresh.
- **§4.9 / rank 8** — the Settings import/forget buttons. The `Save Token`
  half moved (the keychain slot is now injectable and asserted through the
  dispatch tests), but no test presses a button.
- **§5.1 / rank 14** — `--parallel` safety. Now *documented* in README and
  CLAUDE.md rather than fixed; `ImportedCredentialFileTests` and
  `CredentialSourceDefaultsTests` still use fixed suite names.
- **§4.13, §5.5, §5.6, §6** — the batch, Swift 6 mode, harness fidelity notes,
  and the `testPopoverViewRendersErrorBanner` inequality.

Nothing in that list blocks the submission, and the four items that most
directly protect the App Store build's onboarding path — the router, the
connection testers, the normalization assertion, and the CI gate — are closed.

## 10. Phased close-out of §9.4

The remaining items were worked in three phases grouped by subsystem rather
than by rank, so that no phase reopens a previous phase's diff. Each phase ends
with `scripts/test.sh` in both configurations plus a coverage check narrowed to
the files it touched; the full re-measurement is at the end, in §10.4.

### 10.1 Phase A — the poller's timer and observers (§4.12, rank 12)

`UsagePollerLifecycleTests`, 12 tests, no event loop beyond what `wait(for:)`
already drains. Three seams were added to `UsagePoller` to make it reachable:

| Seam | Why |
|---|---|
| `private(set) var timer` | so a test can prove a settings change produced a *new* timer at the new interval, and invalidated the one it replaced |
| `defaults: UserDefaults = .standard` | so a lifecycle test drives an interval or Copilot change in its own suite instead of the process-wide domain another class is reading |
| `var wakeDelay: TimeInterval = 3` | the wake catch-up delay. Nothing in the app changes it; a test that waited the real three seconds would be the slowest in the suite |

Covered: the immediate poll and the scheduled interval (including `tolerance`),
the scheduled timer's own block actually polling, rescheduling on an interval
change, *not* rescheduling on an unrelated one, an immediate re-poll when
Copilot is toggled on and again when toggled off, no poll for a settings change
that touches neither, waking from sleep, and `stop()` silencing the timer and
both observers.

`UsagePoller.swift`: **83.33% → 97.94%** regions (2 missed). Both survivors are
unreachable by construction — `stamp(nil)`'s early return and `oldest ?? now()`'s
fallback are defensive, and every path that reaches them passes a non-nil date.

**Every one of the 12 tests was mutation-checked**: with the reschedule, the
re-poll, the wake registration or the observer removal disabled, the tests that
should fail do, and the two false-arm tests fail when their `if` is made
unconditional. Two of them initially passed under a combined mutant that masked
them, which is why the observer-removal mutation was then run on its own.

**One §4.12 claim was wrong, and only trying it showed it.** The audit predicted
that a second `start()` would double every poll, because `addObserver` does not
deduplicate. The premise holds — probed directly, a repeated
observer/selector/name pair is delivered twice — but the conclusion does not:
the second `refreshNow()` lands while the first `tick()` is still in flight, so
the existing `inFlight` guard swallows it. `start()` now resets itself via
`stop()` anyway, which is correct hygiene, but it is **not** a fix for an
observed bug and the test says so rather than claiming a regression it cannot
detect.

Suite: **237 → 249 direct** (2 skipped), **234 → 246 App Store**, 0 failures.

### 10.2 Phase B — Settings import/forget and the imported file (§4.9 rank 8, §4.8 rank 10)

Grouped because they are the same code path: the button writes the bookmark the
provider reads.

**Behavior change — a stale refresh no longer downgrades a scoped grant.**
`resolve()` refreshes the bookmark when the resolver reports it stale, which is
what lets an imported file survive the atomic replacement a credential rotation
performs. That refresh called the same `store()` a first import calls, and
`store()` falls back to a plain bookmark when a security-scoped one cannot be
created. A first import may legitimately land there; a refresh may not — it
trades access that survives relaunch for access that does not, and the failure
appears much later as an unreadable file with nothing to connect it to. The
refresh now requires the scope it already had, and on failure the error
propagates into `resolve()`'s existing `try?`, leaving the old bookmark in place:
stale but still scoped, which is strictly better than fresh but unscoped.

**Extraction — action bodies only.** `importOutcome(picked:into:)` and
`forget(_:)` are static and take their inputs explicitly; the view keeps its
layout and `@State`, and each button is now the modal call plus a three-line
switch. `runImportPanel` returns the chosen `URL` instead of storing it and
returning a path, so everything after the modal returns is reachable. The modal
itself stays out of reach, permanently.

Two seams on `ImportedCredentialFile` were needed and are documented as such:
`makeBookmark` (an unsandboxed test process is granted a security-scoped
bookmark for any file it can read, so the fallback arm is otherwise unreachable)
and `beginAccess` (the revoked-grant arm).

New tests: `ImportedFileBookmarkScopeTests` (6) and `SettingsImportTests` (9).
Between them: a first import falling back to a plain bookmark and still reading,
a plain bookmark never trying to open a scope it never had, a stale refresh
refusing to downgrade, a stale refresh rewriting the bookmark when it can and
the replacement still working on a fresh instance, a revoked grant, a file that
resolves but cannot be read, import → the provider polls that token, forget →
the provider returns an error that names Settings, cancel, a failed import
keeping the working one, re-import replacing, and the Copilot button writing to
the Copilot slot only.

All 15 were mutation-checked: restoring the downgrade, making `forget` a no-op,
and making `importOutcome` report success on cancel and on failure each fail
exactly the tests that claim to cover them.

| File | Before | After |
|---|---|---|
| `ImportedCredentialFile.swift` | 77.36% | **91.67%** |
| `Views/SettingsView.swift` | 48.21% | **50.29%** |

**SettingsView barely moved, and that is the honest result.** Its 87 remaining
uncovered regions are `@State`/`@AppStorage` property-wrapper initializers,
button action closures, `.onChange` handlers, and view branches that depend on
state a hosting controller cannot change — the §5.6 harness limit, not missing
tests. The logic those buttons *invoke* is now covered; what is left is SwiftUI
plumbing that only a UI test could execute.

**A measurement note, learned the hard way twice.** §3 records that a region
appears in several function records and that reading one produces false zeros.
There is a second form: `llvm-cov export <source-file>` also *filters out*
function records whose primary file is elsewhere, which SwiftUI generates
constantly. It reported `normalizeCredentialSources` as 0-execution when
`llvm-cov show` puts it at 34. Export the whole binary and filter in the
consumer; never pass the source path to `export`.

Suite: **249 → 264 direct** (2 skipped), **246 → 261 App Store**, 0 failures.

### 10.3 Phase C — the §4.13 batch and four small decisions

Four behavior changes, each one branch wide, each decided rather than assumed.

| Change | Decision |
|---|---|
| Copilot `entitlement: 0` (§4.6) | A real plan shape — some org seats and free accounts carry no premium allowance. Reads **0% with "Plan includes no premium requests"** instead of "Could not parse Copilot response", which blamed Tokes for the user's plan |
| `makeTitle` out-of-range percent | **Clamped to 0…100**, the way `makeIcon` already clamped its bars. One value drew a full red bar beside the text " 420%" |
| Duplicate limit ids in `mapLimits` | **Keep the highest, drop the rest** — the same rule `MenuBarLabel.weeklyScoped` uses, so the number nearest exhaustion is never the one hidden. Previously both survived into a `ForEach` over a repeated `Identifiable` |
| `downsample(_:maxCount: 0)` | **Guard and return unchanged.** It trapped on `Int(ceil(10 / 0.0))` — unreachable from the app, reachable from the tests that drive the static API |

`UsageChart.points` became a static function taking its clock, which is what
makes the window filter assertable: it drops samples older than the window *and*
keeps one limit's series out of another's chart, and before this it had only ever
taken its accept arm because every seeded sample was in-window and carried every
limit id. `EdgeCaseTests` (18) covers all of the above; all four changes were
mutation-checked, including the `downsample` guard, whose mutant takes the whole
run down with it.

**A correction to the audit's own assertion-quality finding.** §6 called
`testPopoverViewRendersErrorBanner`'s `> plain - 60` "the wrong direction". It is
worse than that: the two states it compared are not comparable at all. With no
snapshot the banner *replaces* the "Connecting…" block, so the error state is
legitimately 35pt **shorter**, and the tolerance was hiding a number pointing the
other way. Fixing the direction alone would have turned it red. It now compares
against a state that keeps its limits, where the banner is purely additive, and
asserts a strict inequality plus a longer message wrapping taller; a second test
pins the swap so the next reader does not repeat the mistake. Also added: the
chart at 0–3 samples, the "Collecting history…" state a new user sees on first
launch, which no test had ever rendered.

### 10.4 Re-measurement

Instrumented run in both configurations, union taken per region across the two.

| Metric | Audit (§1) | After §9 | **After §10** |
|---|---|---|---|
| Tests (direct) | 179 | 237 | **284** (2 skipped) |
| Tests (App Store) | 176 | 234 | **281** |
| Regions, direct | 64.09% | 70.81% | **74.26%** (704/948) |
| Regions, App Store | 66.86% | 74.03% | **77.53%** (704/908) |
| Regions, union | 64.65% | 71.57% | **75.00%** (711/948) |
| Excl. the two AppKit surfaces | 81.93% | 85.23% | **88.82%** |

| File | Audit | After §9 | After §10 (direct / App Store) |
|---|---|---|---|
| `UsagePoller.swift` | 83.54% | 83.33% | **97.94%** / 97.94% |
| `ImportedCredentialFile.swift` | 77.36% | 77.36% | **91.67%** / 91.67% |
| `UsageClient.swift` | 94.44% | 94.44% | **97.22%** / 97.22% |
| `CopilotClient.swift` | 90.48% | 92.86% | **93.62%** / 93.62% |
| `Views/UsageChart.swift` | 90.63% | 90.63% | **96.88%** / 96.88% |
| `Views/SettingsView.swift` | 33.53% | 48.21% | **50.29%** / 54.34% |
| `StatusItemController.swift` | 24.41% | 34.88% | 34.88% / 34.88% |
| `CredentialsProvider.swift` | 51.61% | 67.69% | 67.69% / **95.56%** |
| `CopilotCredentialsProvider.swift` | 56.36% | 74.14% | 74.14% / **95.00%** |

Nine of the fifteen source files are now above 90% in the shipping
configuration, and the two that are not — `StatusItemController` and
`SettingsView` — hold 171 of the 244 uncovered regions between them.

### 10.5 What is left, and why

Everything remaining is one of four kinds, and none of them is a missing test
someone could sit down and write:

1. **Out of reach by construction.** `main.swift`, `AppDelegate`'s launch and
   terminate hooks, `runImportPanel`'s modal, `SMAppService` register/unregister,
   `RealHome`'s `getpwuid` fallback, and `Distribution.sandboxEntitlement`'s
   `nil` paths (an unsigned or unreadable signature).
2. **SwiftUI plumbing.** `SettingsView`'s 87 and most of `StatusItemController`'s
   84: property-wrapper initializers, button action closures, `.onChange`
   handlers, and view branches keyed on `@State` a hosting controller cannot
   change. `NSHostingController` fires `.onAppear` and nothing else (§5.6). Only
   a UI test reaches these; the logic behind every one of those buttons is now
   covered by a static that a unit test drives.
3. **Forbidden to touch.** The Claude Code keychain reader, `security` CLI
   fallback, and `gh` CLI token in the direct build. These are the entire
   residual of the two provider files there, and covering them would mean a test
   reading another app's credential store.
4. **Defensive and unreachable.** `UsagePoller`'s `stamp(nil)` guard and
   `oldest ?? now()` fallback; `CopilotClient`'s two `NumberFormatter` fallbacks;
   `HistoryStore`'s UTF-8 guards.

Still genuinely open, unchanged from §9.4 and deliberately so:

- **`swift test --parallel`** (§5.1, rank 14) — half done. `ImportedCredentialFileTests`
  now uses a UUID suite name, as do all three classes added in §10;
  `CredentialSourceDefaultsTests` still uses a fixed one. Nothing in `test.sh`
  or CI passes `--parallel`.
- **Swift 6 language mode** (§5.5, rank 16) — unmeasured, and correctly deferred
  until after the submission.
- **`ImportedFileError.unreadable`'s two arms disagree about their argument** —
  bookmark resolution failure passes `describing` ("Claude Code credentials"),
  a revoked grant passes the file path. Both render into "Could not read the
  imported file (%@)". Cosmetic, and a copy decision rather than a test gap.

## 11. The interaction layer, tested for real

§10.5 ended with an honest ceiling: the logic behind every Settings button was
covered, but the buttons themselves — the closures, the `.onChange` handlers,
the live `@State` flows — could not be pressed, because `NSHostingController`
fires `.onAppear` and nothing else. This section removes that ceiling instead
of re-labeling it.

### 11.1 What changed

**ViewInspector 0.10.3** (test-only dependency; the app target never imports
it, and the shipping binary was re-audited to confirm zero symbols leak).
Three mechanics, chosen deliberately:

- **Unhosted inspection** for anything backed by `@AppStorage` or injected
  closures: toggles write straight through their bindings to defaults, and
  `callOnChange` fires the real handler closures.
- **Hosted live inspection** for `@State` flows. The library's own
  `ViewHosting` was *rejected* — it calls `makeKeyAndOrderFront`, and this
  machine runs parallel sessions. Instead `SettingsView` gained a dormant
  `Inspection` notice hook (one Combine subscription, never signaled by the
  app) and tests host the view in a windowless `NSHostingController`. Every
  visit hands the test the *live* view: fields populated by `onAppear`, a
  Save button that enables when the field is non-empty, async Test Connection
  verdicts arriving from a `MockURLProtocol` fetch.
- **One new seam**: the Launch at login toggle now goes through
  `setLaunchAtLogin` / `launchAtLoginStatus`, so a test flipping it cannot
  register the test runner as a real login item. The `SMAppService` calls
  live in the seam's default and are the only part left unexecuted.

**`SettingsInteractionTests` (19 tests)**: both save-token flows end-to-end
into the keychain test service, forget for both providers, all four
form-level `onChange` handlers, launch-at-login through the seam including
the failure re-read, popover toolbar buttons, menu-bar-label normalization
from real toggle taps, unknown stored source values falling back to manual
without network traffic, onAppear normalization rewriting bogus stored
values, and four async Test Connection verdicts (Claude and Copilot, success
and failure) polled from the live view. Six mutants, each run isolated, all
killed — including `save-token-does-nothing` and `test-connection-unwired`.

**`StatusItemControllerLiveTests` (12 tests)** against a *real*
`NSStatusItem` (skipped automatically where no window server hands one out):
init wiring (target, action, tracking area), the `@objc(mouseEntered:)`
selector-export regression pinned at class level, both Combine subscriptions
redrawing the actual button (snapshot → tooltip and title; error → orange;
defaults change → scoped bucket leaves the tooltip and the icon loses its
third track), hover-in/hover-out sampled continuously to prove no popover
ever appears, and the context menu's wiring — including
`performActionForItem` driving a real poll through the mock client. Three
extractions made the rest assertable as pure functions: `popoverFrame` (the
macOS 26 mispositioning workaround, with both edge clamps), `isOutsideClick`
(the pinned-popover close rule, including the nil-window global-monitor
case), and `contextMenu()` (built apart from the `performClick` that pops
it). Seven mutants, all killed — the last one only after the no-popover
assertion was changed from a single end-check to continuous sampling,
because a popover that flashed open and was closed again by the hide pass
slipped past the end-check. That test can detect a shown popover; the mutant
run proved it by showing one.

### 11.2 Re-measurement

|  | audit (§1) | §9 | §10 | **§11** |
|---|---|---|---|---|
| Tests, direct | 179 | 237 | 284 | **315** (2 skipped) |
| Tests, App Store | 176 | 234 | 281 | **312** |
| Regions, direct | 60.60% | — | 74.26% | **82.71%** |
| Regions, App Store | 66.14% | — | 77.53% | **85.87%** |
| Regions, union | 64.65% | 71.57% | 75.00% | **83.02%** |
| Union excl. StatusItemController, SettingsView, main.swift | — | — | 88.82%¹ | **89.58%** |

¹ §10's exclusion row did not exclude `main.swift`; the §11 figure does, which
is why the two exclusion rows are not directly comparable. The comparable
statement: the two AppKit surfaces went from 45/129 and 131/180 regions to
**76/132 and 145/180**, while everything else rose too.

App Store audit after the changes: **31 passed, 0 failed**, and
`verify-appstore.sh`'s bundle shows no ViewInspector linkage.

### 11.3 The residual, named — all 163 union-uncovered regions

Every uncovered region in the union now falls in one of five categories, each
checked line-by-line:

1. **Needs a popover on screen, app activation, or real OS events (56,
   all in `StatusItemController`).** `showPopover`/`closePopover`'s shown-arm,
   `statusButtonClicked` (calls `NSApp.activate`), `popoverHoverChanged`'s
   activation dance, `openSettings` (orders a window front), the click
   monitors (need real out-of-process mouse events), `showContextMenu`'s
   `performClick`, and `repositionPopoverWindow`'s caller (needs the shown
   popover whose geometry static is now tested instead). Testing these means
   stealing focus from a parallel session; the decision logic they wrap is
   covered as pure functions.
2. **Forbidden by policy: reads another app's credential store or mutates
   real login items (43).** `loadClaudeCodeToken`, the `security` CLI
   fallback, the editor/`gh` CLI Copilot readers (direct flavor only — the
   App Store flavor compiles them out, which is why its own number is
   higher), the two Settings arms that call them, and the `SMAppService`
   register/unregister bodies behind the new seam.
3. **Modal and process lifecycle (22).** `runImportPanel` (blocks on
   `NSOpenPanel.runModal`), the Choose File… closure that wraps it (its
   post-modal half is the extracted, tested `importOutcome`), `main.swift`,
   and `AppDelegate`'s launch/terminate hooks.
4. **Default-value expressions only the real app evaluates (~26).**
   Property-wrapper initializers and default arguments — `= .standard`,
   `= .shared`, `CredentialsProvider.manualService` — that tests *must not*
   evaluate, because injecting their replacements is exactly what keeps tests
   off the real keychain slot and real defaults. `Models.swift`'s three
   `current(in:)` functions show the pattern: every visible arm is tested,
   and the zero-count region is the `= .standard` thunk.
5. **Defensive-unreachable (~16).** UTF-8 guards on Swift strings, non-HTTP
   response guards behind `MockURLProtocol`, `NumberFormatter` nil fallbacks,
   `UsagePoller`'s two §10 survivors, and `Distribution`'s cross-flavor
   mismatch arms — those run only in a mis-built artifact, and
   `verify-appstore.sh` exercises the real bundle instead.

### 11.4 Still open, and why

- **`swift test --parallel`** — the §10.5 half (fixed suite names) is now
  fully done: `CredentialSourceDefaultsTests` and both credential-dispatch
  classes use UUID names. A `--parallel` probe run then surfaced the *other*
  two blockers, previously masked: the keychain test service
  (`com.appideas.tokes.tests`) is machine-global, so classes in separate
  processes race on it, and the `@AppStorage`-backed view tests share the
  test runner's standard defaults through `cfprefsd`. Serial remains the
  documented and enforced mode; nothing in `test.sh` or CI passes
  `--parallel`.
- **Swift 6 language mode** — unchanged, deferred until after submission.
- **`ImportedFileError.unreadable`'s two arms** — unchanged, a copy decision.
- **True end-to-end** — built after all, as `scripts/e2e-smoke.sh`: an
  on-demand script (never `swift test`, never CI — it steals focus and moves
  the mouse) that launches the built app, finds its status item by
  accessibility *hit-testing for the pid*, clicks it with real CGEvents,
  reads the popover's texts from the AX subtree under the item, and clicks
  again to close. Its first run passed against a live 429, rendering the
  rate-limit banner beside a working Copilot section. Three macOS 26 facts
  it embeds, each found the hard way: AppleScript's `click` (AXPress) on the
  status item is a silent no-op; with the installed Tokes also running, both
  instances share the bundle's preferred-position slot so the AX-reported
  position can be the *other* instance's pixels; and the open popover is
  invisible to `windows of proc` and `CGWindowList` — only the system-wide
  hit-test below the item finds it. Diagnosing this added three permanent
  `DebugLog` lines (hover, click, show) to `StatusItemController` after
  §11.2's measurement; they land in §11.3's categories 1 and 5 and move the
  totals by noise.
