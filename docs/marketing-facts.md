# Tokes — verified facts for marketing copy

Written for `appideas-designer` (channel task 54) as the source of truth for the
appideas.com landing page. Everything here was read out of the source at commit
`2ad2677` (marketing version **1.4.2**, `CFBundleVersion` **6**) on 2026-08-20,
not from memory or from the README.

**Do not source claims from `README.md`.** Its "How it gets the numbers" section
predates build 6 and still describes the old credential story (Claude Code
keychain first, Copilot via `copilot_internal/user`). Those code paths still
exist in the direct build, but they are no longer how the product is meant to be
described — see §6. This file supersedes it for copy purposes.

Every claim below carries the file it came from so it can be re-checked cold.

---

## 1. What the app is

A menu bar utility for macOS that shows how much of your AI coding plan you have
left, without opening anything. It monitors two independent services — an
Anthropic **Claude account plan** and a **GitHub Copilot** seat — and it is the
same app either way; each is optional in the sense that Copilot is off until you
turn it on, and Claude is simply not connected until you connect it.

- Agent/accessory app: `LSUIElement = true` (`scripts/Info.plist`) — **no Dock
  icon, no app window** other than Settings. It exists in the menu bar only.
- Bundle id `com.appideas.tokes`; app name **Tokes**; the Mac App Store listing
  title is **Dev Tokes** (plain "Tokes" was taken). The app calls itself Tokes
  everywhere in its own UI.
- Category: Developer Tools. Price: free, no IAP, no paid tier, no accounts.
- Direct build measures **4.6 MB** on disk (universal, arm64 + x86_64).

## 2. What it monitors — Claude

Three buckets, read from the `limits` array of Anthropic's OAuth usage endpoint
(`Sources/Tokes/UsageClient.swift`):

| Bucket | Label the app draws | Notes |
|---|---|---|
| `session` | `Session (5 hr)` | the rolling 5-hour window |
| `weekly_all` | `Weekly (7 day)` | all models |
| `weekly_scoped` | `Weekly <Model>` (e.g. `Weekly Fable`) | per-model weekly cap; not every plan reports one; can be hidden in Settings |

Three precision points that matter for copy:

- **These are Claude *account plan* limits, not Claude Code limits.** claude.ai
  and the Claude apps draw down the same buckets. In this product the phrase
  "Claude Code" names a *credential source* only. Calling them Claude Code
  limits is wrong on the facts and is explicitly ruled out in the store listing
  (`packaging/appstore/listing.md`).
- **The model name is whatever the API reports** (`scope.model.display_name`),
  so the scoped row's label follows Anthropic's naming rather than ours. Today
  that reads "Fable".
- If a plan reports two scoped buckets, the menu bar number and the deduplicated
  row are always the **highest** of them — the one nearest exhaustion is never
  hidden (`MenuBarLabel.weeklyScoped`, `UsageClient.mapLimits`).

## 3. What it monitors — GitHub Copilot

Off by default; one toggle in Settings turns it on.

- Row label is **`Copilot Credits`** when the account is on GitHub's AI-credits
  meter, **`Copilot Premium`** on the legacy premium-requests meter
  (`CopilotBillingClient.swift`). AI credits replaced premium requests on
  2026-06-01; only grandfathered annual plans still have rows on the old meter.
- Caption under the row reads e.g. `412 of 1,500 AI credits used`, plus billed
  overage in dollars when GitHub reports one.
- Resets at **00:00 UTC on the 1st** of each month — derived, because GitHub's
  reports don't state it.
- **The percentage is measured against a plan allowance the user picks**, not
  one GitHub reports: Copilot Pro 1,500 / Pro+ 7,000 / Max 20,000 AI credits
  (300 / 1,500 / 1,500 premium requests), plus a custom-allowance escape hatch.
  GitHub's per-user billing reports carry raw quantities only and entitlement is
  not queryable. Settings says this in as many words. If copy implies Tokes
  "knows your allowance", it will generate support mail.
- **An organization-provided Copilot seat has no per-user billing data at all** —
  that seat is billed to the org and GitHub exposes nothing per user. Tokes says
  so explicitly rather than showing 0%. This is a GitHub limitation, not a bug,
  and it is worth *not* promising Copilot support to enterprise seat holders.

## 4. What the user actually sees

### Menu bar item (`StatusItemController.swift`)

- **Three vertical bars** — Session · Weekly · Model-scoped — 5pt wide on a 16pt
  track, filled bottom-up, colored by severity: **green below 60%, orange at
  60–84%, red at 85%+** (`SeverityColor`). Slots are reserved so the item does
  not jitter in width as buckets appear.
- With Copilot on, its bar sits **behind a thin vertical divider** so the two
  services read as separate groups at a glance.
- **Optional percentage text** beside the icon. **Off by default.** In Settings
  it can be set to the highest limit, or to one specific measurement (Session,
  Weekly, model-scoped weekly, Copilot). If the chosen measurement isn't in the
  current snapshot, Tokes shows the icon alone rather than substituting another
  limit's number.
- The percentage turns **red at 100%** (you are blocked) and **orange while
  polls are failing** (numbers may be stale).
- **Tooltip** on the item lists every limit and its percentage, e.g.
  `Claude usage — Session (5 hr): 62% · Weekly (7 day): 41%`.

### Popover (`PopoverView.swift`)

- Opens on **hover** after a 0.15 s dwell; **click pins it**; click outside or
  click the item again dismisses. 320pt wide.
- Per limit: severity dot, label, big percentage, a **line chart**, a reset
  countdown (`resets in 1d 2h`), and for Copilot the credits caption.
- When both services report, rows are grouped under **CLAUDE** / **GITHUB
  COPILOT** headings and **Copilot's chart line is dashed** so the two are
  distinguishable at a glance. Popover title is "Claude Usage" while only Claude
  reports, "Usage" when both do.
- Header carries Refresh / Settings / Quit buttons. Footer reads "Updated N ago".
- Failures show an inline amber banner and **keep the last known numbers on
  screen** rather than blanking. If nothing has ever been polled, the banner
  also grows an **"Open Settings…"** button — an error before any data is a
  setup problem, and the fix is put in front of the user rather than behind the
  gear.
- **Right-click** the menu bar item: Refresh Now / Settings… / Quit Tokes.

### Charts and history (`HistoryStore.swift`, `UsageChart.swift`)

- **The usage APIs report only the current instant — no history whatsoever.**
  Tokes records a local sample on every poll and keeps **8 days**, which is the
  only reason a trend line exists. This is genuinely something the vendors' own
  surfaces do not give you.
- Session chart shows the **last 6 hours**; weekly/monthly charts the **last 7
  days**. Y axis is always 0–100%.
- Storage: `~/Library/Application Support/Tokes/history.jsonl` (direct build) or
  the equivalent path inside the app container (App Store build). JSONL, pruned
  and compacted on launch.
- A fresh install reads **"Collecting history…"** until three points exist. Copy
  should not promise instant charts.

### Settings (`SettingsView.swift`)

Four sections: **Claude Connection**, **GitHub Copilot**, **Behavior**, and a
version footer that reads e.g. `Tokes 1.4.2 (App Store)`.

- Both connection sections have a **Test Connection** button that resolves
  credentials, performs a real fetch, and reports pass/fail inline.
- Behavior: refresh interval (30 s / 1 min / 2 min / 5 min / 15 min), *Show in
  menu bar* picker, *Show model-specific weekly limit* toggle, *Launch at login*
  (real `SMAppService` login item, not a hack).

### First run

A fresh install has nothing to poll, so **the first launch ever opens Settings
by itself** — the first thing a new user sees is the way in, not a menu bar item
reporting a credentials error (`AppDelegate.applicationDidFinishLaunching`).

## 5. Behavior a user notices under stress

- **Refresh interval** default **60 s**, floored at 10 s.
- Opening the popover refreshes if data is stale, but with its own rate floor, so
  brushing past the menu bar repeatedly does not hammer the endpoint.
- **HTTP 429**: Tokes keeps the last snapshot, shows a banner, and stops polling
  Claude entirely until the backoff passes — `Retry-After` when present (clamped
  to 30 s…15 min), otherwise 90 s doubling per consecutive 429, capped at 15 min.
  Copilot polling continues independently.
- **One provider failing never takes the other down.** The snapshot carries the
  healthy provider's fresh numbers plus the failed one's last-known values, and
  "Updated N ago" is stamped with the age of the **oldest** data in it, so the
  freshness claim is never overstated.
- Polls on **wake from sleep** (3 s after, so the network can reconnect), and
  re-polls immediately when settings change.
- 401 is retried once with re-resolved credentials, in case the owning tool
  rotated the token in between.

## 6. How a user connects — and why the two paths are different

This asymmetry is deliberate and is a *credibility* asset, not a wart:
**GitHub sanctions third-party access to a user's own usage; Anthropic does
not.** Full detail in `docs/CREDENTIALS.md`.

### GitHub Copilot — real sign-in, mouse only

- **"Sign in with GitHub"** in Settings: RFC 8628 device flow against **Tokes'
  own GitHub App ("Dev Tokes")**, with **exactly one fine-grained permission —
  Account → Plan: read**. Nothing else. It cannot see code, repos, or issues.
- Usage comes from GitHub's **documented per-user billing usage reports**.
- Tokes stores the token pair in its **own** keychain item and refreshes it
  itself, so this path stays connected indefinitely with no further user action.

### Claude — a guided export the user runs, then imports

- macOS Claude Code keeps its sign-in **in the keychain only**, and Anthropic's
  policy (Authentication and credential use, 2026-02-19) states third parties may
  not offer Claude.ai login or route requests through subscription credentials.
  **So Tokes never touches Anthropic's or Claude Code's credential store on the
  user's behalf — the user is the actor at every step.**
- Settings walks them through it: run one `security …` command in Terminal to
  export their own sign-in to `~/.claude/tokes-credentials.json`, then **pick
  that file in a standard open panel**. Tokes re-reads it on every poll through a
  security-scoped bookmark, so a rotated token keeps working.
- **Optional**: a one-line `SessionStart` hook merged into `~/.claude/settings.json`
  re-exports the token every time Claude Code starts, which is what keeps the
  file fresh. Settings gives the exact JSON with a Copy button.
- **Honest limitation to not paper over**: the hook fires on session start, so a
  user who doesn't open Claude Code before the exported token expires sees Claude
  data go stale, with a message telling them what to do. This closes only if
  Anthropic ever sanctions something; an outreach asking exactly that was sent
  2026-08-20 with no reply yet. Copy should not imply Claude stays connected
  automatically the way Copilot does.
- **Manual OAuth token** paste is available for either service (stored in Tokes'
  own keychain item). It works, but Claude tokens pasted this way last hours —
  it is a fallback, not the path to advertise.
- The direct (non-App Store) build additionally offers automatic sources — read
  Claude Code's own store, or the Copilot plugin config / `gh` CLI — because it
  is unsandboxed and those installs already exist. **These are compiled out of
  the App Store build entirely.** I'd keep them out of landing-page copy: they
  are legacy convenience for existing users, and the guided paths above are what
  the product is.

### First-run defaults

| Setting | Default |
|---|---|
| Refresh interval | 60 s |
| Menu bar percentage | **Off** (icon only) |
| Model-scoped weekly row | Shown |
| Copilot monitoring | **Off** |
| Claude credential source | direct: Claude Code sign-in · App Store: import a file |
| Copilot credential source | direct: editor/gh · App Store: **Sign in with GitHub** |
| Copilot plan | Pro (1,500 credits) |
| Launch at login | Off |

## 7. Privacy — stated precisely

This is the strongest section of the story and every clause is checkable.

- **No account, no analytics, no telemetry, no server, no crash reporting.**
  There is no appideas.com endpoint in the app at all.
- **The complete list of hosts the app ever contacts** (grep of `Sources/`, every
  URL in the binary):
  - `https://api.anthropic.com/api/oauth/usage` — Claude usage
  - `https://api.github.com/users/{login}/settings/billing/{meter}/usage` — Copilot billing report
  - `https://api.github.com/copilot_internal/user` — legacy editor-token path only
  - `https://github.com/login/device/code` and `/login/oauth/access_token`, and
    `https://api.github.com/user` — GitHub sign-in only
  That is the entire list. Nothing is sent anywhere else, including to us.
- **What is transmitted**: a bearer token in an `Authorization` header to the
  service that issued it, and nothing else. No request bodies, no identifiers, no
  prompt content — Tokes never sees or handles conversations, code, or prompts of
  any kind.
- **What is stored, and where**: tokens in the keychain (Tokes' own items, or the
  user's existing store which it only reads); usage history as a local JSONL
  file; settings in the app's preferences domain. The App Store build keeps all
  of it inside its sandbox container.
- **App Store build sandbox entitlements — exactly three**
  (`packaging/appstore/Tokes.entitlements`): app sandbox, outbound network
  client, and **read-only** access to files the user picks in an open panel.
  No file-system access beyond that, no ability to write to a user-picked file.
- App Privacy declaration on the store listing: **Data Not Collected**, every
  category answered No.
- Nothing here is a promise about Anthropic's or GitHub's own data practices —
  copy should not imply Tokes changes those.

## 8. Distribution, updates, requirements

- **Two flavors from one MIT-licensed codebase**: a direct/Homebrew build and a
  Mac App Store build. The App Store build is sandboxed and has every
  foreign-credential reader compiled out (`-DTOKES_APP_STORE`), verified by a
  committed audit script. Everything else is identical.
- **System requirements: macOS 14 (Sonoma) or later.** Universal binary — Apple
  silicon and Intel, both native.
- **Update mechanism: there is no in-app updater** (no Sparkle, no auto-update).
  Updates arrive through the App Store, through Homebrew, or by downloading a new
  release. Don't promise automatic updates.

### What is *not* true yet — do not publish these as available

Flagging these because a landing page is exactly where they would be claimed
prematurely. All three are operator calls, not mine:

1. **The Mac App Store listing is not live.** Build 6 is uploaded and the version
   record sits at PREPARE_FOR_SUBMISSION. There is no store URL to link and no
   "Download on the Mac App Store" badge that would work.
2. **`brew install appideasDOTcom/tap/tokes` does not work today.** The tap repo
   exists but is empty — no cask has ever been pushed. The README documents the
   command as though it worked; that is a known open item.
3. **No notarized Developer ID build has ever shipped.** The two GitHub releases
   (v1.0.0, v1.2.0) are unsigned, so a direct download today needs the
   right-click → Open dance on first launch. A page promising a frictionless
   direct download would be wrong until notarization happens.

   What *is* available right now: the public GitHub repo, buildable from source,
   plus those two older release zips.

## 9. Open source facts

- **MIT**, © 2026 Chris Ostmo / appideas.com. `LICENSE` in the repo.
- Repo: **https://github.com/appideasDOTcom/tokes-app** (public).
- **The shipped binaries contain no third-party code at all.** The one
  dependency, ViewInspector (also MIT), is a *test-only* dependency linked into
  the test target and present in no build.
- Both distributions are built from the same public source; neither adds
  proprietary components.
- The test suite is committed and substantial (377 tests in the direct
  configuration, 374 under the App Store flag as of 2026-08-20), including
  rasterized pixel checks of the menu bar icon, and it makes **no network calls
  and touches no real credentials** by construction.

## 10. What I'd call genuinely differentiating

My read from the code side; weigh it against your research.

1. **It monitors two vendors in one item, with the visual vocabulary to keep them
   apart** (divider in the menu bar, grouped sections, dashed chart line). Most
   look-alikes are single-vendor.
2. **Local history the APIs do not provide.** Both endpoints are instantaneous —
   whatever trend line any tool shows, it recorded itself. Tokes keeps 8 days and
   says so, and the charts are the app's most-screenshotted surface.
3. **It monitors the *plan*, not one client.** The Claude buckets are account-wide,
   so what it shows is what claude.ai and the desktop apps are also spending.
4. **The credential story is an argument, not an apology.** One read-only GitHub
   permission (Plan: read — it cannot see your code), and for Claude a path where
   *the user* exports their own credential and Tokes never reads a foreign store.
   Open source is what makes that checkable rather than a claim. Anyone tempted
   to compete here has to either do the same work or quietly read a store they
   shouldn't.
5. **It degrades honestly.** Rate limits back off instead of hammering; a failed
   provider keeps its last numbers with an accurate age rather than pretending;
   "Updated N ago" reflects the oldest data present. Small, but it is the
   difference between a monitor you trust and one you double-check.
6. **It costs nothing and takes nothing**: free, no account, no telemetry, no
   server, ~4.6 MB, no Dock icon.

## 11. Cosmetic caveats you may notice in captures

Neither is a defect to fix before launch (both are recorded in
`docs/FOLLOW-UPS.md`), but you'll see them and should not build copy on them:

- **Menu bar bar fills read ~15.6 percentage points low** at magnification: the
  fill's 2.5pt corner radius on a 5pt-wide bar makes the cap a full semicircle,
  so the eye reads the level at `h - 2.5`. Deliberately unfixed for this
  submission because changing bar geometry invalidates the composed store frames.
  Consequence for copy: don't write anything that asks the reader to read a
  *value* off the bars — they are a severity signal, and the number is the text.
- **"Premium requests" and "Credits" both appear**: the Settings toggle says
  "Also monitor Copilot premium requests" while the row can say "Copilot
  Credits". Frozen deliberately — the toggle string is quoted in App Review notes
  and depicted in the store frames.

## 12. Copy constraints I'd ask you to honor

These come from App Review work and are cheap to respect:

- **Never "Claude Code limits"** — they are Claude account plan limits (§2).
- **Always "GitHub Copilot"**, never bare "Copilot", at least on first and
  prominent uses; the non-affiliation line quotes the full trademark.
- **Non-affiliation belongs on the page**: Tokes is independent, not affiliated
  with, endorsed by, or sponsored by Anthropic or GitHub; "Claude" and "GitHub
  Copilot" are their owners' trademarks, used only to describe what Tokes
  monitors.
- **Requires the user's own active Claude subscription and/or GitHub Copilot
  seat.** Tokes does not provide, resell, or include either service.
- Store-listing fields deliberately avoid brand names in name/subtitle/keywords
  (Guideline 5.2.1 risk). That constraint is Apple's field-level one and does
  **not** bind a landing page — naming both services on the site is fine and is
  the reason someone finds it.
- Existing URLs the store listing already points at, so the page needs to live
  at the first one: support/marketing `https://appideas.com/tokes/`, privacy
  policy `https://appideas.com/privacy-policy/`.
