# Follow-ups

Open items carried out of the App Store compliance work. Each says what it is,
why it is not done, and what "done" looks like — so it can be picked up cold by
a later session.

**Status, verified 2026-08-20 (evening):** repo is **1.4.2 / `CFBundleVersion`
6**, version record **1.4.2 / PREPARE_FOR_SUBMISSION**.

**Build 6 (`1.4.2`, `CFBundleVersion` 6) is the one to attach — uploaded
2026-08-20, audit 31/0, delivery UUID `2d02fed4-dbc0-4fdc-a839-0822ddd597be`.**
It is the first build carrying the credential-gap fix: GitHub device-flow
sign-in (verified live by the operator — connected, correct counts) and the
guided Claude export walkthrough (verified live by the operator). Pending
TestFlight re-test as an ordinary user, then submission.

**Builds 1–5 are all superseded; do not attach any of them.** Build 5 shipped
a Demo mode that was removed from the source the same day (it disguised the
credential blocker as solved) and predates the fix entirely. Build 4 carries
the flavor-gated unauthorized message; build 3 lacks it; build 2 is a `1.4.0`
artifact. Next upload needs `CFBundleVersion` 7.

**Version numbering during the testing loop, decided 2026-08-20:** the marketing
version stays **1.4.2** and only `CFBundleVersion` moves (5, 6, 7 …), so
TestFlight shows `1.4.2 (5)` and each iteration costs one integer. **1.4.4 is
the final release version.** A letter suffix such as `1.4.2b` was considered and
is not possible: App Store Connect requires both version fields to be
period-separated non-negative integers and rejects the upload outright.
listing text pushed, **build 2 uploaded, `VALID`, and attached to the version
record**. Build 1 (v1.2.0) is also `VALID` and permanently orphaned — leave it.
Nothing submitted for review. The remaining blockers are all web-UI answers and
live in `.private/APP-STORE-SUBMISSION.md` rather than being duplicated here. The privacy
policy URL and the revised promotional text were pushed 2026-08-20.

---

## ⛔ BLOCKER: the App Store build cannot be connected by a normal user

**Read `docs/HANDOFF-credential-gap.md` before any further release work.**
Found 2026-08-20 by installing build 5 from TestFlight as an ordinary user: the
default credential source is a file that does not exist on a modern Claude Code
install, and the only alternative needs a terminal command for a token that
expires in ~1.5 h. **Do not submit 1.4.2.**

**Plan of record, decided 2026-08-20 (operator-approved):** research established
that GitHub offers a fully sanctioned path (documented per-user billing
endpoints + GitHub App device flow, "Plan: read" only) while **Anthropic
explicitly forbids third-party OAuth/login for subscriptions**
(code.claude.com/docs/en/legal-and-compliance, "Authentication and credential
use", 2026-02-19) and offers no usage API. So:

- **Copilot half — LANDED 2026-08-20.** `githubApp` credential source: device
  flow, self-refreshing tokens in Tokes' own keychain item, usage from
  `/users/{u}/settings/billing/{ai_credit,premium_request}/usage`, plan-picker
  allowances, org-seat empty state. Default source for the App Store flavor.
  Registered 2026-08-20 as "Dev Tokes" (App ID 4666350); the client ID is in
  `GitHubAppConfig.clientID` and the device flow verified live — see
  `docs/github-app-setup.md`. Remaining: one interactive end-to-end sign-in
  (operator enters the code in a browser).
- **Claude half — interim workaround LANDED 2026-08-20 (Phase B):**
  first-run onboarding around the powerbox import. macOS Claude Code is
  keychain-only with no file/no override (confirmed in docs), so Settings'
  imported-file source now walks the user through the export: copy-paste
  command (`ClaudeCodeExport.exportCommand` → `~/.claude/tokes-credentials.json`,
  chmod 600) plus an optional Claude Code `SessionStart` hook
  (`ClaudeCodeExport.hookSnippet`) that re-exports on every session — only on a
  *successful* keychain read, so a signed-out session can't truncate a working
  export, and under `umask 077` so even a hook-created file is owner-only.
  Hook verified end-to-end against a real Claude Code session via `--settings`.
  An imported token whose recorded `expiresAt` has passed fails at load with
  guidance (`CredentialError.importedExpired`), not the server's bare 401.
  First launch ever (persistent-domain check, `AppDelegate.isFirstRun`)
  auto-opens Settings; a setup error in the popover shows an "Open Settings…"
  button. Tokes stays a passive reader throughout.
  `claude setup-token` is a dead end (`user:inference` scope → 403 on usage).
  Note for the auditor: the foreign keychain strings are now legitimate UI
  copy, so `verify-appstore.sh` pins them at the *source* level instead
  (allowed only in `ClaudeCodeExport.swift` + `CredentialsProvider.swift`).
- **Claude half — sanctioned endgame:** permission request
  (`docs/.private/anthropic-permission-request.md`) **sent by the operator
  2026-08-20** via Anthropic's contact form, "Contact sales" path (the route
  the legal page names). Awaiting a reply; no timeline known. Watch the paused
  Agent SDK subscription-credit program — the likeliest home for an official
  usage surface.


## Open: does Anthropic accept a third-party CIMD `client_id`?

**Probe attempted 2026-08-20 — inconclusive at the HTTP layer.** Both the CIMD
URL and Claude Code's own client_id get a Cloudflare bot challenge (403 "Just a
moment…") from `curl`, so the authorize endpoint's answer is only reachable
from a real browser session. Lower priority than it reads below: the 2026-02-19
policy text forbids offering Claude.ai login regardless of whether CIMD works
mechanically, so the outreach draft above is the real path; a browser probe is
still worth one minute for the outreach's technical framing.

**Untested — one unauthenticated GET decides it, and the payoff is large.**

App Store users must currently re-paste an OAuth token every ~1.5 h, because
Tokes has no refresh path. Refresh itself is viable — the token response carries
`refresh_token_expires_in` and the refresh token rotates, so a chain renews
indefinitely (see `docs/HANDOFF-credential-gap.md`). The blocker is *identity*: Anthropic
publishes no `/.well-known/oauth-authorization-server` on `api.anthropic.com`,
`claude.ai`, or `console.anthropic.com`, so there is no registration endpoint,
and the only known client is Claude Code's own Client ID Metadata Document.

Using **that** `client_id` would make the consent screen read "Claude Code" in
an app named Dev Tokes — misrepresents the app to the user, collapses both
grants into one revocable entry, and is revocable upstream. Not acceptable.

**But `client_id` being a URL is the CIMD pattern, which exists precisely so
third parties need no registration endpoint.** If the authorize endpoint
resolves an arbitrary CIMD URL, APPideas hosts its own document, the consent
screen reads "Dev Tokes", the chain is independent of Claude Code, and sign-in
becomes permanent and mouse-clicks-only — the whole problem closed.

The probe (nothing is authorized by loading it):

```
https://claude.ai/oauth/authorize?response_type=code
  &client_id=https%3A%2F%2Fappideas.com%2Ftokes%2Foauth-client-metadata
  &redirect_uri=http%3A%2F%2F127.0.0.1%2Fcallback
  &code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
  &code_challenge_method=S256&scope=user%3Aprofile&state=probe
```

- `invalid_client` / unknown client → hardcoded allowlist; third-party CIMD is
  out, and the re-paste burden stands until Anthropic offers registration.
- an error about *fetching* the metadata document → generic CIMD support, and
  the remaining work is hosting a JSON file plus an auth-code + PKCE flow.

This is now the release blocker, not a follow-up — it is the same question as
`docs/HANDOFF-credential-gap.md` and should be answered first.


## 1. `build.app_icon` → v3 — **DONE 2026-08-20**

Set as v3 and noticed on the channel as msg 644 (a version bump alone is not
notice, per playbook §5). `assets.app_icon` was **not** bumped — no icon
artifact or invariant changed, so `consumes` still points at the designer's v2.

Two findings landed in it that were measured while writing, not carried over:

- **`store_listing_icon`** — the Mac App Store listing icon is extracted from
  `Tokes.icns` inside the uploaded bundle at 256×256. Build 1 and build 2 both
  carry an `iconAssetToken` naming it; the 1.4.0 `appStoreVersions` record has
  no icon relationship at all. There is no separate upload, so the designer cuts
  nothing, and 256px is the ceiling on the mark anywhere in the store.
- **`reproducibility`** — `Tokes.icns` is byte-identical across both flavors and
  across repeated actool runs. **`Assets.car` is not reproducible at all**: two
  runs over identical inputs with identical arguments differ in ~296 of
  1,922,344 bytes (the two shipped flavors differ in 350). Size is invariant and
  the differing bytes are scattered metadata clusters, never image payload.
  **Never verify the icon pipeline by hashing or diffing `Assets.car`** — it
  fails spuriously and reads as an icon regression. Hash `Tokes.icns` instead.
  No current test does this; do not add one.

## 2. `assets.appstore_listing` — **DROPPED 2026-08-20**

Not ours to write. The designer is authoring **`assets.store_frames`** covering
the same interface, and we settled the boundary on the channel (msgs 644/646):
**their entry owns the frames and their standards; what the app *renders inside*
them stays in `build.app_icon`**, where the strip geometry already lives. They
will reference our numbers rather than restate them, so a moved number breaks
loudly instead of agreeing with a stale copy.

They have not set it yet — it bumps on our menu bar widget vocabulary (now
frozen), but the frames themselves are still Costmo-gated and the entry should
describe something real.

## 3. Screenshot frames — **designer is leading, not ours to open**

Costmo moved the designer onto the listing/frames phase and asked them to lead
it (msg 642), so this is no longer a task for us to open. What we owed them is
delivered (msgs 643/647): the strip geometry is frozen and verified unchanged
since the Copilot divider landed, `scripts/screenshots.sh` already provides the
fixed-value capture harness, and the live listing metadata plus full description
are on the channel for them to diff.

**Guideline 5.2.1 is settled — `decisions/0015`, Costmo's ruling.** Indexed
fields stay brand-free; the description and the *screenshot display type* name
Claude Code plainly. Our name/subtitle/keywords posture is unchanged and nothing
needs resubmitting. Two limits to hold to: frame type may set the words, never
logos, wordmarks or trade dress; and the residual risk is recorded rather than
eliminated, since screenshots share the enforcement surface.

**Done 2026-08-20:** six frames uploaded and verified `COMPLETE`. Closed.

---

## Before submission

The one remaining blocker — review notes, which need a token generated on
submission day — is tracked in `.private/APP-STORE-SUBMISSION.md`, which also carries the current App Store Connect
state. What remains here is the one item that is neither a web form nor a code
change:

- [ ] **TestFlight end-to-end run — unblocked; build 3 (`1.4.2`) is uploaded.**

      This is the only claim in the whole compliance story with no evidence
      behind it. A MAS-signed bundle **cannot launch on this Mac** (`launchd`
      POSIX 163 — a Mac App Store profile authorises no devices), so everything
      proven so far is either the ad-hoc build or static analysis of the signed
      one. `verify-appstore.sh` says so itself: it skips its entire runtime
      section for a submission-signed bundle. TestFlight is the first time the
      **actual submitted artifact** ever runs.

      What to check, in the order that makes a failure cheapest to diagnose.
      Items 1–5 are the ones static analysis cannot reach:

      1. **It launches and there is a menu bar item.** `LSUIElement` means no
         Dock icon and no window — that is correct, not a failure. Three faint
         grey bars, no number.
      2. **`/tmp/tokes-debug.log` is NOT written.** Turn debug logging on
         (`defaults write com.appideas.tokes debugLogging -bool true`, which for
         a sandboxed app resolves to the container) and confirm the log lands
         **inside** `~/Library/Containers/com.appideas.tokes/Data/`. A file in
         `/tmp` means the sandbox is not doing what the audit claims.
      3. **History goes into the container**, and
         `~/Library/Application Support/Tokes` is **not** created or touched.
      4. **Manual OAuth token works end to end** — the exact path a reviewer
         takes: Settings → Claude Connection → select *Manual OAuth token* →
         paste → Save Token → Test Connection → bars fill. The keychain item is
         written inside the container.
      5. **Powerbox import survives a relaunch and a rotation.** Pick a
         credentials file in the open panel; quit and relaunch and confirm it
         still reads (the security-scoped bookmark carries the grant, not the
         panel); then replace the file atomically (new inode) and confirm the
         new token is picked up. This was proven under a throwaway sandbox
         bundle but never on a real install.
      6. **Copilot manual token** — the frames and the review notes both depict
         Copilot enabled, so the reviewer may well try it.
      7. **Hover opens the popover** (0.15 s dwell), click pins it, and
         right-click gives Refresh Now / Settings… / Quit Tokes.
      8. **The percentage appears only after** setting Behavior → *Show in menu
         bar*. If it shows by default, the review notes and the screenshots
         disagree with the build.
      9. **Settings footer reads `Tokes 1.4.2 (App Store)`** — confirms the
         right artifact is installed, and that the flavor gate is live.
     10. **The icon looks right** in the menu bar and in the Applications
         folder — the `.icns` and `Assets.car` in a real install rather than
         under `ictool`.

      Until every one of these passes, do not describe the submission build as
      verified end to end.

*Done 2026-08-19:* build 2 uploaded at 1.4.0 and attached to the version record.

## After the first approval

Both items — the keyword/subtitle revisit and the Copilot 5.2.2 contingency —
are recorded in `.private/APP-STORE-SUBMISSION.md` under "After the first approval",
where whoever is doing the next release will actually be reading.

## Product observations (not defects, not scheduled)

- [ ] **The menu bar bars under-report every value by 15.6 percentage points.**
      Found 2026-08-20 while rendering store-frame material at 12×
      magnification, by `appideas-designer`; the arithmetic below is ours.
      `makeIcon` draws a 5pt-wide fill with a 2.5pt corner radius — the radius
      is exactly half the width, so the top cap is a full semicircle and the eye
      reads the level where the shape is still full width, at `h - 2.5` rather
      than `h`. On a 16pt track that is a constant
      `perceived% = pct - 15.625`. Three regimes:
      below 18.75% the `max(3, …)` floor makes every value draw identical
      pixels; between 18.75% and 31.25% the fill is shorter than its own cap
      diameter and has no readable level; above that it reads 15.6 points low.
      Verified against an independent measurement: 41% was read off a render as
      "about 25%", and the formula gives 25.4%.
      **Deliberately not fixed.** It is cosmetic, it affects the build being
      submitted, and changing bar geometry now would invalidate the store frames
      being composed against it. Worth revisiting after the first approval —
      the honest fix is drawing the fill's cap flat, or insetting the track so
      the readable range matches the value range.

## Housekeeping

*Closed 2026-08-20 — and the root cause was not what the two previous reports
said.* **There are two preference domains for `com.appideas.tokes`**, and
`defaults` silently resolves to the wrong one:

| Domain | Path | Reached by |
|---|---|---|
| Sandboxed (App Store) | `~/Library/Containers/com.appideas.tokes/Data/…` | `defaults … com.appideas.tokes` |
| Direct (Homebrew) | `~/Library/Preferences/com.appideas.tokes.plist` | only an **explicit path** |

Because a container exists for that bundle id, `defaults read/delete
com.appideas.tokes` operates on the **container**. Both earlier cleanups deleted
the flag there and both read backs confirmed it gone — true statements about the
wrong plist, while the direct build's flag sat at `true` and kept appending to
`/tmp/tokes-debug.log`. (The sandboxed build cannot write `/tmp` at all, so the
log growing was itself the proof.) Earlier notes blamed a `cfprefsd` race; that
was wrong. Clearing the direct domain needs:

```sh
defaults delete ~/Library/Preferences/com.appideas.tokes debugLogging
```

**Any `defaults` check against this app's real settings is unreliable unless the
path is explicit.** Both domains now read *does not exist*. A already-running
instance may hold the old value until relaunch — the old claim that logging
stops without one was never verified.

- [ ] **The Homebrew tap has never been published.**
      `appideasDOTcom/homebrew-tap` exists and is public but is **empty** — no
      cask was ever pushed — so `brew install appideasDOTcom/tap/tokes` does not
      work today, despite `RELEASING.md` having documented it as if it did. The
      repo's own `packaging/homebrew/tokes.rb` is still the 1.0.0 template with
      a placeholder sha256. Two GitHub releases (v1.0.0, v1.2.0) exist, so only
      the tap side is missing. Do both at the next Homebrew release, not before.
- [ ] **Developer ID signing has never been exercised.** `scripts/release.sh`
      supports `--sign`/`--notarize` but no notarized build has shipped, which is
      why the cask still carries its `caveats` block. Separate certificate from
      the App Store ones; `scripts/appstore-certs.py` does not create it, and
      `security find-identity -v` confirms the keychain holds no Developer ID
      Application identity.
- [ ] **Two orphan sandbox containers** —
      `~/Library/Containers/com.appideas.tokes.{sandboxprobe,powerboxprobe}` from
      verification harnesses, both still present. `containermanagerd` protects
      them from `rm` even as the owner; deletable from Finder. Harmless.
- [ ] **`whatsNew`** is unset — not needed for a first release, required for
      updates. `scripts/appstore-metadata.py` does not currently push it.
      **Check this against the live API, not the script's success output.** The
      privacy policy URL was missing for exactly this reason: it lives on
      `appInfoLocalizations` rather than the version localization, the script
      pushed only `name`/`subtitle` there, and every run reported success while
      a required field stayed empty. Any field the script does not name is
      invisible to it, so a clean run proves nothing about coverage.
- [ ] **`verify-appstore.sh`'s entitlement-count failure message prints an empty
      count.** Fed a bundle with zero `com.apple.security` entitlements it reads
      `"  com.apple.security entitlements (expected 3)"`. The check fails
      correctly; only the message is wrong. Cosmetic.
