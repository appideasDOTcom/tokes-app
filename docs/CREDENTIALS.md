# How a user connects Tokes

The two providers are connected by completely different mechanisms, for a
reason that is not obvious from the code: **GitHub sanctions third-party
access to a user's own usage and Anthropic explicitly forbids it.** Everything
below follows from that asymmetry, so read this before changing any credential
path — several designs that look obviously better are already eliminated at the
bottom of this file.

| | Copilot | Claude |
|---|---|---|
| Mechanism | GitHub App device-flow sign-in | User-run export, then powerbox import |
| User actions | Mouse only | One terminal command, once |
| Stays fresh | Yes — Tokes refreshes its own tokens | Only via the optional Claude Code hook |
| Sanctioned | Yes, documented endpoints | No — nothing is; the user is the actor |
| Default source (App Store) | `githubApp` | `importedFile` |
| Default source (direct) | `editor` | `claudeCode` (keychain) |

Both flavors offer both paths. The direct build keeps its automatic sources as
defaults so existing installs don't break; the App Store build has those
compiled out (`docs/APP-STORE-COMPLIANCE.md`).

---

## Copilot: "Sign in with GitHub"

`CopilotCredentialSource.githubApp` — the sanctioned path, and the only one in
the app that is permanent and needs no terminal.

**Registration.** A GitHub App named **"Dev Tokes"** (App ID 4666350, registered
2026-08-20), with exactly one fine-grained permission: *Account → Plan: read*.
The client ID `Iv23lipdHFpNL7ZW67E4` lives in `GitHubAppConfig.clientID` and is
**public by design** — the device flow uses no client secret, and *refreshing* a
device-flow token needs none either, which is what makes a secret-free desktop
app possible at all. Re-registration steps are in
`docs/.private/github-app-setup.md`.

**Sign-in.** RFC 8628 device flow, driven by `GitHubConnectModel` (state machine)
and rendered by `SettingsView.githubSignInControls` (phases only). Settings shows
a user code, the user enters it at github.com/login/device, Tokes polls until
GitHub answers, then stores a `GitHubAppTokens` JSON blob in **Tokes' own**
keychain item — service `com.appideas.tokes`, account `github-app-oauth`. A
sandboxed app owns its own keychain items, so this is fine in both flavors.

**Staying connected.** `GitHubBillingFetcher` refreshes on expiry *and* retries
once on a 401, because an access token can die between the check and the
response. Two non-obvious invariants, both load-bearing:

- **The rotated pair is persisted before it is used.** A refresh rotates the
  refresh token, so a lost write is a lost session — not a retryable error.
- **A dead session surfaces as `notConnected`**, never as a transport error,
  because that is the one error Settings answers with a sign-in button.

**Usage numbers.** `GET /users/{login}/settings/billing/{meter}/usage` — the
documented per-user billing reports. Tokes tries `ai_credit` first and falls
back to `premium_request`; AI credits replaced premium requests on 2026-06-01
and only grandfathered annual plans still have rows on the legacy meter. The
login is captured once at sign-in because the URL addresses the user by name.

Three consequences of the reports carrying *raw quantities only*:

- **The allowance is not queryable and the plan is not either**, so the user
  picks it (`CopilotPlan`: Pro 1,500 / Pro+ 7,000 / Max 20,000 AI credits;
  300 / 1,500 / 1,500 premium requests, plus a custom escape hatch). The
  percentage is measured against that choice — if it looks wrong, the plan
  picker is the first thing to check, not the arithmetic.
- **The reset date is derived, not reported** — both meters reset 00:00 UTC on
  the 1st.
- **The series id stays `copilot_premium` on both meters** so a user's history
  survives their account migrating from premium requests to AI credits. The
  *label* changes; the id must not.

**The one empty state that isn't a bug:** an org-provided Copilot seat is billed
to the organization, and GitHub exposes no per-user billing for it. That is a
GitHub limitation, and `GitHubAuthError.noBillingData` says so in as many words
rather than showing zero.

Tests: `GitHubAppAuthTests`, `CopilotBillingTests`, `GitHubSourceModelTests`,
`UsagePollerGitHubDispatchTests`.

---

## Claude: guided export, then import

There is no sanctioned mechanism to build on, and the shape of this path is
entirely a consequence of that:

- macOS Claude Code stores its sign-in **in the keychain only**. There is no
  credentials file and no supported way to make it write one, so the old
  "import `~/.claude/.credentials.json`" advice pointed at a file that does not
  exist on any current install.
- Anthropic's legal-and-compliance page (*"Authentication and credential use"*,
  2026-02-19) states plainly that third parties may not offer Claude.ai login or
  route requests through subscription credentials. So Tokes cannot do its own
  OAuth, however well it would work.

**So the user is the actor at every step**, and Tokes never touches another
app's credential store. Settings walks them through it:

1. **Export** — `ClaudeCodeExport.exportCommand`, copy-pasted into Terminal:
   `security find-generic-password … > ~/.claude/tokes-credentials.json`,
   `chmod 600`. `security` prompts for nothing when the caller owns the login
   keychain.
2. **Import** — the standard `NSOpenPanel` + security-scoped bookmark, panel
   opening in `~/.claude` where the export just landed.
3. **Optional hook** — `ClaudeCodeExport.hookSnippet`, merged into the `hooks`
   section of `~/.claude/settings.json`. Every new Claude Code session then
   re-exports the current token, so **the file Tokes watches refreshes itself**.

That third step is what makes this path livable rather than a token that dies in
hours. Three details in `hookCommand` are deliberate and each fixes a real
failure:

- **It only writes on a *successful* keychain read.** A plain `>` redirect would
  truncate a working export to zero bytes the moment the user is signed out,
  turning "token expired" into a mystifying "file doesn't contain a usable token".
- **`umask 077`**, because a redirect into an *existing* file keeps its
  permissions but a fresh creation lands at 644.
- **It ends in `true`**, so a signed-out session never reports a failing hook.

**Every string the user sees comes from `ClaudeCodeExport`** — UI copy, the
command, the hook JSON, and the filename the import panel expects. They cannot
drift apart, and the tests pin them there. Don't hand-write any of them into the
view.

**Tokes is a passive reader on this path.** It re-reads the file each poll and
never refreshes the token itself. That is not laziness — refresh rotates, so two
clients on one chain knock each other out, and the App Store build could not
write a healed credential back to Claude Code's keychain anyway. Keeping Tokes
read-only is what makes sharing the credential safe.

**Residual limitation, stated honestly:** the hook fires on *SessionStart*. A
user who doesn't open Claude Code before the exported token expires sees Claude
data go stale. `CredentialError.importedExpired` catches that at load and says
what to do, instead of surfacing the server's bare 401 — but the limitation is
real, and it closes only if Anthropic ever sanctions something. An outreach
asking exactly that was sent 2026-08-20
(`docs/.private/anthropic-permission-request.md`); no reply yet.

Tests: `ClaudeCodeExportTests`, `ImportedCredentialExpiryTests`,
`SettingsClaudeGuidanceTests`.

---

## First run

A fresh install has nothing to poll and nothing to draw, so **the first launch
ever opens Settings by itself** — the first thing the user sees is the way in,
not a menu bar item reporting a credentials error. A setup error in the popover
also grows an "Open Settings…" button (`PopoverView.offersSettingsShortcut`:
an error with *nothing ever polled* is a setup problem; once data has flowed,
an error is a hiccup and the banner stays compact).

**`AppDelegate.isFirstRun` reads the persistent domain by name, not
`object(forKey:)`.** The registration domain is process-global and volatile:
once anything has called `register(defaults:)`, every key reads as set through
every `UserDefaults` instance and "did the user ever set this?" can no longer be
asked that way. It also treats *any* persisted configuration as evidence of a
prior run, so an upgrade install that predates the marker key is never mistaken
for a fresh one. Both properties are easy to break with an innocent-looking
refactor. Tests: `FirstRunTests`, `PopoverOnboardingTests`.

---

## Dead ends — measured, and not to be re-proposed

Each of these looks like the obvious answer at some point during a session.
They are all closed:

- **Read Claude Code's keychain item automatically.** Forbidden by Guideline
  2.5.2. The sandbox kernel *permits* it, which is exactly why it looks
  available and is not — that gap is the whole subject of
  `docs/APP-STORE-COMPLIANCE.md`.
- **Ship or hand over a credentials file.** A static copy expires exactly like a
  pasted token. The import path only works because something keeps rewriting the
  file — which is what the hook is for.
- **Have the user paste an OAuth access token as the primary path.** Measured
  against a live `max` subscription: hours, no refresh. It remains available as
  a source (and it is the right *reviewer* path, since a reviewer has no Claude
  Code install), but it cannot be how ordinary users connect.
- **A demo / sample-data mode.** Built 2026-08-20, shipped in build 5, and
  removed from the source the same day on the operator's instruction. It worked,
  and that was the problem: it removed *App Review's* dependency on a credential
  while leaving real users with no way to connect, disguising the blocker as
  solved. It will look like an obvious idea again. It is not one.
- **Tokes doing its own Claude OAuth**, including borrowing Claude Code's Client
  ID Metadata Document. Mechanically plausible — refresh tokens rotate and renew
  indefinitely, so a chain never expires — but Anthropic publishes no
  `/.well-known/oauth-authorization-server` on any of its hosts (no registration
  endpoint), and borrowing Claude Code's `client_id` would make the consent
  screen read "Claude Code" inside an app named Dev Tokes. That is an honesty
  objection, not a technical one. **And the 2026-02-19 policy forbids offering
  Claude.ai login regardless of whether it would work**, which settles it. A
  probe of whether the authorize endpoint resolves an arbitrary CIMD URL is
  blocked at the HTTP layer by a Cloudflare challenge and is browser-only;
  worth a minute if the outreach ever needs technical framing, worth nothing
  otherwise.
- **`claude setup-token`.** Its tokens carry `user:inference` scope and get 403
  on the usage endpoint.
