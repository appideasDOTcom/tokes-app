# Follow-ups

Open items only. Each says what it is, why it is not done, and what "done"
looks like, so it can be picked up cold. Anything that closed has moved to
`retired/` or into the doc that describes current behaviour — this file is not
a history.

**Status, verified 2026-08-20 (evening):** repo is **1.4.2 / `CFBundleVersion`
6**; version record **1.4.2 / PREPARE_FOR_SUBMISSION**; suite green at **377
direct (2 skipped) / 374 App Store**; App Store bundle audits **31 passed /
0 failed**.

**Build 6 is the one to attach** — uploaded 2026-08-20, delivery UUID
`2d02fed4-dbc0-4fdc-a839-0822ddd597be`. It is the first build that an ordinary
user can actually connect (`docs/CREDENTIALS.md`). **Builds 1–5 are superseded;
do not attach any of them** — build 5 in particular ships a Demo mode that was
removed from the source the same day. Next upload needs `CFBundleVersion` **7**.

**Version numbering during the testing loop:** the marketing version stays
**1.4.2** and only `CFBundleVersion` moves (6, 7, …), so each iteration costs
one integer. **1.4.4 is the final release version.** A letter suffix such as
`1.4.2b` is not possible — App Store Connect requires both version fields to be
period-separated non-negative integers and rejects the upload outright.

The live App Store Connect state and the release runbook are in
`.private/APP-STORE-SUBMISSION.md`, not duplicated here.

---

## Before submission

- [ ] **Finish the TestFlight pass on build 6.** This is the only claim in the
      compliance story that static analysis cannot reach: a MAS-signed bundle
      **cannot launch on this Mac** (`launchd` POSIX 163 — a Mac App Store
      profile authorises no devices), so everything else proven so far is either
      the ad-hoc build or static analysis of the signed one. TestFlight is the
      first time the *actual submitted artifact* ever runs.

      **Verified 2026-08-20 (evening)** against the installed
      `/Applications/Tokes.app` (build 6, `_MASReceipt` present, sandboxed),
      by reading its container while it ran:

      - [x] **It runs and polls.** Both providers reporting — container history
            carries `session`, `weekly_all`, `weekly_scoped:Fable` and
            `copilot_premium` on a 2-minute cadence.
      - [x] **Copilot connects through the GitHub device flow.** The container
            has no `copilotCredentialSource` key, so it is on the App Store
            flavor's registered default (`githubApp`), and the value it reports
            is fractional (`45.77…%`) — the billing-report arithmetic, not the
            old integer endpoint. This is the sanctioned path working in the
            submitted artifact.
      - [x] **Claude connects through the guided export.** Container shows
            `credentialSource = importedFile` with a live
            `claudeCredentialFileBookmark`, and the Claude series are updating —
            so the security-scoped bookmark survives real launches, on a real
            install, not just the throwaway probe bundle.
      - [x] **The sandbox holds.** Debug logging is on (`debugLogging = 1`) and
            the log is at
            `~/Library/Containers/com.appideas.tokes/Data/tmp/tokes-debug.log`.
            `/tmp/tokes-debug.log` exists but is stale (13:47, written by the
            direct build) — the sandboxed build cannot write `/tmp` at all,
            which is what makes that file a usable tripwire.
      - [x] **History is in the container**, and `~/Library/Application
            Support/Tokes` is the direct build's, untouched by this one.

      **Still unverified — all of it needs eyes on the screen:**

      - [ ] Menu bar item renders (three faint grey bars; `LSUIElement` means no
            Dock icon and no window — that is correct, not a failure).
      - [ ] Hover opens the popover (0.15 s dwell), click pins it, right-click
            gives Refresh Now / Settings… / Quit Tokes.
      - [ ] **Manual OAuth token end to end** — Settings → Claude Connection →
            *Manual OAuth token* → paste → Save Token → Test Connection → bars
            fill. **This is the reviewer's path**, so it matters more than its
            usage share suggests.
      - [ ] Imported file survives a *rotation* — replace it atomically (new
            inode) and confirm the new token is picked up. Proven under a
            throwaway sandbox bundle, never on a real install.
      - [ ] The percentage appears **only after** setting Behavior → *Show in
            menu bar*. (The container here reads `menuBarLabel = session`
            because the operator set it — that is not a test of the default.)
            If it shows by default, the review notes and the screenshots
            disagree with the build.
      - [ ] Settings footer reads `Tokes 1.4.2 (App Store)` — confirms the right
            artifact and that the flavor gate is live.
      - [ ] The icon looks right in the menu bar and in Applications — the
            `.icns` and `Assets.car` in a real install rather than under
            `ictool`.

- [ ] **One store asset needs re-cutting.** The connect screenshot depicts the
      pre-build-6 Settings; the credential UI has changed materially (GitHub
      sign-in phases, the Claude export walkthrough). Operator is handling this
      in a separate phase with `appideas-designer`. Re-rendering any frame means
      rebuilding the whole set — all six share one fixture, and figures that
      differ between screenshots read as mocked up.

## Waiting on someone else

- [ ] **Anthropic outreach — sent 2026-08-20, no reply.**
      `.private/anthropic-permission-request.md` asks for a sanctioned
      authentication method for read-only usage display, via the "contact sales"
      route the legal page itself names. Until something comes back, the Claude
      path is the guided export and its one real limitation stands: the refresh
      hook fires on Claude Code *SessionStart*, so a user who doesn't open
      Claude Code before the token expires sees stale data
      (`docs/CREDENTIALS.md`). Watch the paused Agent SDK subscription-credit
      program — the likeliest home for an official usage surface.

      Do **not** revive Tokes-does-its-own-Claude-OAuth while waiting. The
      2026-02-19 policy forbids it independently of whether it works; the
      reasoning and the dead CIMD probe are recorded in
      `retired/credential-gap-2026-08-20.md`.

## Product observations (not defects, not scheduled)

- [ ] **The menu bar bars under-report every value by 15.6 percentage points.**
      Found 2026-08-20 while rendering store-frame material at 12×
      magnification, by `appideas-designer`; the arithmetic is ours. `makeIcon`
      draws a 5pt-wide fill with a 2.5pt corner radius — the radius is exactly
      half the width, so the top cap is a full semicircle and the eye reads the
      level where the shape is still full width, at `h - 2.5` rather than `h`.
      On a 16pt track that is a constant `perceived% = pct - 15.625`. Three
      regimes: below 18.75% the `max(3, …)` floor makes every value draw
      identical pixels; between 18.75% and 31.25% the fill is shorter than its
      own cap diameter and has no readable level; above that it reads 15.6
      points low. Verified against an independent measurement: 41% was read off
      a render as "about 25%", and the formula gives 25.4%.
      **Deliberately not fixed.** It is cosmetic, it affects the build being
      submitted, and changing bar geometry now would invalidate the store frames
      composed against it. Revisit after the first approval — the honest fix is
      drawing the fill's cap flat, or insetting the track so the readable range
      matches the value range.

## Housekeeping

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
- [ ] **Two orphan sandbox containers** —
      `~/Library/Containers/com.appideas.tokes.{sandboxprobe,powerboxprobe}` from
      verification harnesses, both still present. `containermanagerd` protects
      them from `rm` even as the owner; deletable from Finder. Harmless.
- [ ] **A stale `demoMode = 0` key sits in the real container**, left by build 5.
      No code reads it any more. Harmless, and it will disappear if the
      container is ever reset; not worth a migration.

## Channel contracts

Both current as of 2026-08-20 — **call `get_contract` rather than trusting this
line.** `assets.app_icon` v2 (designer) and `build.app_icon` v3 (ours); the
icon artifact and invariants did not change at v3, only the record. The two
findings that landed in it — the store listing icon being extracted from
`Tokes.icns` at 256×256, and `Assets.car` not being byte-reproducible — are in
`CLAUDE.md` where they will actually be read.

`assets.appstore_listing` was **dropped**: the designer owns the equivalent
ground as `assets.store_frames`, settled on the channel. Their entry owns the
frames and their standards; what the app *renders inside* them stays in
`build.app_icon`, where the strip geometry lives.
