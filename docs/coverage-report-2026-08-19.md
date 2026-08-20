# Coverage report — Tokes

Date: 2026-08-19 · measured at `a25b04b`; §9 records the work done in response

**This is the Mac App Store submission baseline.** It is the measurement the
first release gets compared against, and the first coverage report this repo has
had — so there is no prior report to disposition, and nothing below is a
re-litigation of an earlier finding.

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
