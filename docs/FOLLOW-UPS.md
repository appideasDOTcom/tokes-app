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

- [ ] **One store asset needs re-cutting — frame 05, "Your credential stays
      yours".** `appideas-designer` is leading it (channel msgs 679/680, answered
      in 681/683). State material re-rendered 2026-08-20 into
      `build/appstore/states/`. What was measured for them, so it isn't
      re-derived:

      - **What moved:** exactly one thing — the Copilot `Credentials` radio list
        gained `Sign in with GitHub (recommended)` at the top, so everything
        below shifted one row (~23 pt @1x). Nothing was removed; `Test
        Connection` and both other Copilot sources are still there.
      - **Their 91% crop is now wrong.** The Copilot card runs 50.5–93.6% of
        the render height (313–580 pt); 91% cuts *into* it, 2.6 points above
        its bottom edge.
      - **The fixture is untouched** — Settings renders no usage value, so the
        other five frames don't rebuild on that account.
      - **`ImageRenderer` is still blank for `SettingsView`** — measured, not
        assumed: 0.00% non-background / 1 colour, against a `PopoverView`
        control at 3.59% / 307 colours. The Form gained a fifth `Picker` and
        its first `TextField`, so it moved further from plain SwiftUI. Frame 05
        stays a `cacheDisplay` upscale.
      - **The caption clause that breaks is "No account"**, not "Nothing is read
        automatically" — a *Sign in with GitHub* control is visible inside the
        crop. Reword is the designer's call.

      Our uploader has **no single-slot replace**:
      `scripts/appstore-screenshots.py --replace` deletes the whole set,
      re-uploads every PNG in sorted order, and re-pins display order. So the
      full set ships together regardless.

- [x] **Popover placeholder plates — RESOLVED 2026-08-20 by cropping, not by a
      code change.** `appideas-designer` found three yellow SwiftUI
      unresolvable-image placeholders in the popover header of uploaded frames
      02 and 04. **The app was never affected**: `ImageRenderer` draws
      `Image(systemName:)` inside a `.buttonStyle(.borderless)` button as a
      placeholder, while the `NSHostingController` path an `NSPopover` actually
      uses renders the glyphs correctly (measured: 3036 plate px vs 0 above the
      chart region). Root cause is `.borderless`, **not** SF Symbols — bare
      `Image(systemName:)`, `.imageScale`, `Label`, `Image(nsImage:)` and
      `.buttonStyle(.plain)` all render fine through `ImageRenderer`.

      **Operator ruled: crop the header, leave the app alone. `.borderless`
      stays — do not make the `.plain` change.** The defect was in the
      screenshot tool, not the product, and no user traverses `ImageRenderer`;
      the pixel-identity proof offered for `.plain` covered the static render
      only, with press/hover untested. Cropping cost nothing and carried no
      product risk. It also rendered *better* — `split()` binds on height, so
      the shorter source made 02 and 04 about 12% larger.

      **Consequence for any later capture request (task 56, 2026-08-21):** there
      is no path on this machine that gives correct header chrome *and* more
      than 1x. `ImageRenderer` always draws the plates — that is what the
      `.borderless` trigger means — and the hosting path that draws the glyphs
      correctly rasterises at the layer's backing scale, which is 1.0 on every
      display here. The states harness therefore renders the popovers **both
      ways**: `popover-*-{light,dark}.png` at 9x/6x with plates in the header,
      and `popover-*-hosted-{light,dark}.png` at a true 1x with the header
      correct (measured: 0 plate px, and the three glyphs verified by eye).
      A consumer picks per placement — crop the header off the crisp pair, or
      place the hosted pair. On Retina hardware the hosted pair becomes a real
      2x for free; that is the same note `assets.store_frames` carries for
      Settings.

- [x] **Screenshot set re-uploaded — DONE 2026-08-20, operator-authorised.**
      Six frames from the designer's `handoff/`, replacing the set that carried
      the placeholder plates. Set `0ae1c8c7-eafa-4413-b848-a7c4ade9a796`.
      Verified by reading the API back, not from the uploader's success output:
      exactly one `APP_DESKTOP` set, six screenshots, all `COMPLETE`, all six
      `sourceFileChecksum` values matching the local files, display order
      pinned and correct. Nothing submitted for review.

- [x] **Accent-blue toggle in Settings renders: NOT POSSIBLE without stealing
      focus — closed 2026-08-20, don't retry.** The Settings captures show the
      Copilot toggle grey-with-knob-right rather than accent blue, because
      AppKit draws controls inactive while the app is inactive and the capture
      harness is an `.accessory` app that deliberately never activates. Five
      approaches measured, all 0 accent pixels: overriding `isKeyWindow` /
      `isMainWindow`; `.environment(\.controlActiveState, .key)`; the same with
      `.active`; swizzling `-[NSApplication isActive]` to true; and
      `window.makeKey()`. The toggle renders correctly in every case — right
      shape, knob right, correct label — just grey, so these are real negatives
      and not a broken detector. Only `NSApp.activate(...)` would flip it, and
      that takes focus from whatever the operator is doing.
      **If blue is wanted it is a composition-time recolour**, which is *more*
      faithful rather than less: a user with Settings focused genuinely sees
      blue, and grey is an artifact of capturing with no active app.

- [ ] **Decide whether the review notes and the store frames should agree about
      Copilot.** The notes tell the reviewer Copilot is off by default and they
      need not enable it; frames 01, 04 and 05 all depict it running. That is
      defensible — the frames show a configured app, exactly as with the menu
      bar percentage — but it should be a deliberate choice. Operator's call.
      Note the mechanism: the *entire* Copilot credential UI is inside
      `if copilotEnabled`, so with the toggle off the section collapses to a
      single row and the credential-choice story disappears from the frame.

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

- [ ] **Copilot copy still says "premium requests" in two places that can now
      contradict the row they describe.** GitHub replaced premium requests with
      AI credits on 2026-06-01, and `GitHubBillingFetcher.limit` labels the row
      **`Copilot Credits`** when the account is on the new meter — while the
      Settings toggle reads `Also monitor Copilot premium requests` and
      `MenuBarLabel.copilot.displayName` reads `Copilot Premium`. So a user on
      AI credits sees both vocabularies at once. **Deliberately not changed
      before submission**: the toggle string is asserted in the review notes and
      depicted in the store frames, so changing it now invalidates both. The
      series id `copilot_premium` must **not** change with it — it is what keeps
      history continuous across a meter migration.

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

- [ ] **`product.facts` and `docs/marketing-facts.md` must be updated the moment
      any install path starts working.** Their `availability_status` block says
      the App Store listing is not live, the Homebrew tap is empty, and no
      notarized build exists. Those three lines are consumed by
      `appideas-designer` for the appideas.com landing page, and they fail
      *unsafely*: the day a path starts working, the contract is telling a
      consumer not to publish something that is now true, and (worse, later) a
      consumer who stopped re-reading will publish an install that 404s. So
      whoever publishes the cask, ships the notarized build, or sees the listing
      approved bumps the contract in the same pass and messages the designer —
      a version bump alone is not notice (playbook §5).

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
