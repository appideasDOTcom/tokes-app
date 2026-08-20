# Coverage report — Tokes

Date: 2026-08-20 · measured at `48154e6` (clean tree)

A standalone re-measurement and fresh analysis. The predecessor,
`coverage-report-2026-08-19.md`, is the submission baseline plus the work log
that closed it out; this report is the current state, derived from scratch —
every number is from runs made today, and every uncovered region was re-read
in source rather than carried over.

**Method.** `swift test --enable-code-coverage` in both configurations
(default and `-DTOKES_APP_STORE`), `llvm-cov export` over the whole test
binary (never a per-file export — it silently drops records), maximum
execution count taken across function records per region, union taken per
region across the two configurations. The extraction is checked in as
`scripts/coverage-regions.py`, so a future re-measurement is two `swift test`
runs plus that script. Swift emits no branch data; *region*
coverage is used throughout because it is the harshest metric available —
llvm-cov's line metric flatters SwiftUI and is not quoted here.

One finding is new to this measurement and changes how the residual should be
read: **some "uncovered" regions are provably executed** (§3.1). The 164
uncovered count is therefore an upper bound on genuinely unexecuted code.

## 1. Topline

| Metric | Direct build | App Store build | Union |
|---|---|---|---|
| Tests | **315**, 2 skipped, 0 failures | **312**, 0 failures | — |
| Regions | **82.62%** (794/961) | **85.78%** (790/921) | **82.93%** (797/961) |
| Union excl. `StatusItemController` + `SettingsView` + `main.swift` | — | — | **89.58%** (576/643) |
| App Store compliance audit | — | **38 passed, 0 failed** | — |

- **The 2 skips are deliberate self-skips**, not environment flakes: the two
  App-Store-only connection-test arms skip themselves in the direct build,
  because running them there would read Claude Code's and the Copilot
  plugin's real stores.
- The App Store column reads higher because `-DTOKES_APP_STORE` removes the
  foreign-credential readers a test must never execute (§3.3). That is the
  flag working, not extra testing.
- Drift from the 2026-08-19 §11 numbers (union 83.02% → 82.93%) is exactly
  the three permanent `DebugLog` lines added to `StatusItemController` after
  that measurement; no test changed.
- The audit's three warnings are all expected in a local run: no provisioning
  profile (only required to upload), and two notes about the operator's own
  running Tokes instance, which the auditor deliberately leaves alone.

## 2. By file

Union figures; the App Store denominators differ where the flag compiles
readers out. Sorted by uncovered regions — the quantity that matters.

| File | Union | Direct | App Store | Miss (union) |
|---|---|---|---|---|
| `StatusItemController.swift` | 57.14% (76/133) | 57.14% | 57.14% | **57** |
| `Views/SettingsView.swift` | 80.56% (145/180) | 79.44% | 81.46% | **35** |
| `CredentialsProvider.swift` | 67.69% (44/65) | 67.69% | 95.56% (43/45) | **21** |
| `CopilotCredentialsProvider.swift` | 74.14% (43/58) | 74.14% | 95.00% (38/40) | **15** |
| `Distribution.swift` | 78.57% (22/28) | 75.00% | 75.00% | 6 |
| `ImportedCredentialFile.swift` | 91.67% (55/60) | 91.67% | 91.67% | 5 |
| `main.swift` | 0.00% (0/5) | 0.00% | 0.00% | 5 |
| `AppDelegate.swift` | 63.64% (7/11) | 63.64% | 63.64% | 4 |
| `HistoryStore.swift` | 81.82% (18/22) | 81.82% | 81.82% | 4 |
| `CopilotClient.swift` | 93.62% (44/47) | 93.62% | 93.62% | 3 |
| `Models.swift` | 96.77% (90/93) | 96.77% | 96.77% | 3 |
| `UsageClient.swift` | 97.22% (70/72) | 97.22% | 97.22% | 2 |
| `UsagePoller.swift` | 97.94% (95/97) | 97.94% | 97.94% | 2 |
| `Views/PopoverView.swift` | 98.15% (53/54) | 98.15% | 98.15% | 1 |
| `Views/UsageChart.swift` | 96.88% (31/32) | 96.88% | 96.88% | 1 |
| `Inspection.swift` | 100% (4/4) | 100% | 100% | 0 |

## 3. Every uncovered region, accounted for

164 union-uncovered regions. Each was resolved to file:line:column and read
in source today. They fall into six categories; the counts are exact and sum
to 164. The defense for each category is stated once, concisely.

### 3.1 Measured false zeros — proven executed (18)

Not untested code; untestable *accounting*. Two mechanisms, both verified
directly this run:

- **`AppDelegate.swift:31`, the migration ternary's false arm (1).**
  `testMigrationOfTheOffToggleLeavesTheLabelOff` drives `wasShowing == false`
  and asserts the exact value only that arm can produce — and passes — yet
  `llvm-cov show --show-regions` still prints `^0` on the arm while the line
  count reads 2. Swift mis-attributes ternary-arm counters inside call
  arguments.
- **Property-initializer records (17).** Every `@State`/`@AppStorage`
  default expression in `SettingsView` (15), its `Inspection` hook, and
  `PopoverView`'s `@AppStorage` default live in standalone `…vpfi` function
  records that never tick — even though the interaction tests construct
  these views dozens of times per run and later assert state that *starts*
  from those defaults. The expressions execute; the records don't count.

**Defense:** the behavior is asserted elsewhere and the execution is
demonstrable; only the counter is wrong.

### 3.2 Needs a shown popover, app activation, or real OS events (57 — all of `StatusItemController`'s misses)

The hover/pin state machine, `showPopover`/`closePopover`,
`repositionPopoverWindow`, `statusButtonClicked`, the global/local click
monitors, `openSettings`, and the context-menu presentation — plus a few
defensive guards inside functions that *are* covered (weak-self,
no-button-on-a-headless-runner, a registered-default `?? true`).

**Defense:** executing these from `swift test` means showing a popover,
activating the app, or synthesizing out-of-process mouse events — all of
which raise windows or steal focus, banned on this machine (parallel agent
sessions). The decision logic is extracted and unit-tested as pure functions
(`popoverFrame` with both edge clamps, `isOutsideClick` all four arms,
`contextMenu()` wiring, `MenuBarContent`), the Combine subscriptions are
driven against a real `NSStatusItem` in `StatusItemControllerLiveTests`, and
the full composition — real clicks, real popover, AX-verified content — is
exercised on demand by `scripts/e2e-smoke.sh`, deliberately outside the
suite.

### 3.3 Forbidden by policy (42)

- **The direct build's foreign-store readers (32).**
  `loadClaudeCodeToken`, `securityCLIFallback`, the editor-config and
  `gh` CLI Copilot chain. A test process must never read another app's
  credential store — the repo rule, and the same acts Guideline 2.5.2
  forbids the sandboxed build. The App Store flavor compiles them out
  entirely, which is why its provider files sit at ~95%.
- **The `case .claudeCode` / `case .editor` dispatch arms (2).** Dual
  defense: in the direct build they *are* the forbidden readers above; in
  the App Store build they are `sourceUnavailable` throws documented
  unreachable — `current(in:)` normalizes the source away before dispatch,
  and the normalization is itself tested.
- **`SMAppService` register/unregister bodies (6).** Behind the
  launch-at-login seam; executing them would mutate the operator's real
  login items. The seam, including its failure re-read, is tested.
- **The two direct-only Test Connection arms (2)** that call the forbidden
  readers. Their App Store counterparts (the `sourceUnavailable` arms) are
  tested — those are the two deliberate skips in §1.

### 3.4 Modal and process lifecycle (20)

`main.swift` (5), `applicationDidFinishLaunching` / `WillTerminate` (3),
`runImportPanel` (4), and the Choose File… button closure plus the error
`Text` its `.failed` arm populates (8).

**Defense:** `NSOpenPanel.runModal` blocks on the out-of-process powerbox
and the app entry point cannot run inside a test process. Everything after
each modal returns is extracted and tested (`importOutcome`, `forget`); the
launch hook's interesting call, `SandboxAudit.mismatchDescription`, is
audited on the real bundle instead (§3.6).

### 3.5 Defensive code behind a stated invariant (22)

Each one names its invariant; none is reachable without breaking it.

| Regions | What | Why it cannot fire |
|---|---|---|
| 2 | non-HTTP response guards (`UsageClient:41`, `CopilotClient:38`) | URLSession cannot deliver a non-`HTTPURLResponse` for an https URL |
| 2 | `NumberFormatter` fallbacks (`CopilotClient:97–98`) | the formatter does not fail for finite doubles |
| 3 | `HistoryStore` UTF-8 guards | Swift `String` → UTF-8 cannot fail |
| 2 | `?? "imported file"` (`CredentialsProvider:130`, sibling) | a successful `read()` implies a stored bookmark, which implies `displayPath` |
| 3 | `Models` `?? ""` missing-key fallbacks | `registerDefaults` seeds all three keys at launch; the fallback resolves to the registered default anyway |
| 3 | `Distribution` `return nil` paths (`:96–106`) | require an unsigned or unreadable code signature |
| 1 | `Distribution.isSandboxed` entitlement arm (`:88`) | non-nil only inside a genuinely sandboxed signed process — the real bundle, which the audit launches and asserts (`sandboxed=true`, this run) |
| 2 | `flavorMatchesRuntime` / `mismatchDescription` | the interesting arm requires a mis-built artifact; in-process it is a tautology. The audit checks the real bundle ("no build/runtime flavor mismatch", this run) |
| 2 | `UsagePoller` `stamp(nil)` and `oldest ?? now()` | every caller passes a non-nil date; a success always records a fetch time |
| 1 | `?? "dev"` version fallback (`SettingsView:154`) | fires only outside a bundle with a version string |
| 1 | `RealHome` getpwuid fallback | `getpwuid` succeeds for any real uid |

### 3.6 Defaults nothing takes (5)

`SettingsView`'s `keychainService` / `bookmarkDefaults`, `UsageClient`'s
`= .shared`, and `HistoryStore`'s default directory are injection seams whose
*overriding is the point*: evaluating them from a test would bind the suite
to the real keychain slot, real standard defaults, the real network stack,
and real Application Support — the exact things the test rules forbid. The
fifth, `UsageChart.dashed`'s default, is simply never taken: the sole call
site always passes it.

### 3.7 The honest boundary

"Defensible" is not "impossible". About six of the regions above could be
covered cheaply — the three `Models` `?? ""` one-liners, the tautological
in-process arm of `flavorMatchesRuntime`, a guard or two in §3.5 — but each
such test would assert the invariant rather than protect a behavior, and
they were left uncovered deliberately. If a future gate wants the number,
these are the cheapest regions in the codebase; they buy no risk reduction.

## 4. What the numbers cannot see — re-verified today

- **Compliance:** fresh `build.sh --app-store` and `verify-appstore.sh`:
  **38 passed, 0 failed**, including the runtime sandbox section against the
  launched bundle. No ViewInspector symbols ship (test-only dependency).
- **Suite hygiene invariants** (unchanged, and enforced by construction):
  no network calls (`MockURLProtocol`), keychain access only through the
  test-only service, serial execution only — the two `--parallel` blockers
  remain the machine-global keychain test service and the standard defaults
  shared via `cfprefsd`.
- **End-to-end:** `scripts/e2e-smoke.sh` was *not* run for this report — it
  steals focus and moves the mouse, and is an on-demand pre-release step
  (see `RELEASING.md`). Last validated 2026-08-20 against a live 429.
- **Operational note:** the audit's runtime pass noticed the operator's
  running Tokes writing `/tmp/tokes-debug.log` — the `debugLogging` default
  was still set in the real domain, left over from the 2026-08-19 E2E
  diagnosis (the cleanup recorded that day did not stick). It was deleted
  during this report's run; the flag is read per-write, so logging stopped
  without a relaunch.

## 5. Open items (unchanged from 2026-08-19 §11.4)

- `swift test --parallel` — serial only, blockers named above.
- Swift 6 language mode — deferred until after submission, before the next
  feature.
- `ImportedFileError.unreadable`'s two arms disagree about their argument —
  cosmetic copy decision.

## 6. Verdict

For a regression to get past this suite it would now have to live entirely
inside popover presentation and app activation (§3.2, covered on demand by
the E2E smoke), a blocking modal (§3.4), or code the rules forbid a test to
run (§3.3). Every other uncovered region is either provably executed
(§3.1), behind a named invariant (§3.5), or an injection seam doing its job
(§3.6). That is the "complete" that is actually attainable for a sandboxed
menu-bar app on this machine — and the remaining distance to 100% is listed
above by name, not by hope.
