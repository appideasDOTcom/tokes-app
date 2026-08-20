# App Store submission runbook

What is left to get Tokes into the Mac App Store, and how to do each release
after that. The code side is finished and audited — see `APP-STORE-COMPLIANCE.md`
for what is already proven, so you don't re-litigate it here.

The one-time account setup (App ID, certificates, provisioning profile, App
Store Connect record) is **done**; its record is
`retired/appstore-account-setup-2026-08-19.md`.

## Where things stand

Verified against App Store Connect on 2026-08-20:

| | |
|---|---|
| App record | `Dev Tokes`, app id `6803324238`, bundle `com.appideas.tokes` |
| Version record | **1.4.0**, `PREPARE_FOR_SUBMISSION` |
| Attached build | **build 2** (v1.4.0), `VALID`, uploaded 2026-08-19 21:41 |
| Listing text | pushed — description, subtitle, keywords present in `en-US` |
| Screenshots | **none uploaded** (0 sets) — blocks submission |
| Age rating | **unanswered** — blocks submission |
| App Privacy | **unanswered** — blocks submission |
| `whatsNew` | unset — not needed for a first release |
| Submitted for review | **no** |

Build 1 (v1.2.0) is also `VALID` but will never attach to a 1.4.0 version
record. Leave it.

---

## Blocking the first submission

Four items, all answered in the App Store Connect web UI, none of which a
script can supply.

- [ ] **Screenshots.** `scripts/screenshots.sh` renders three at 2880×1800 into
      `build/appstore/screenshots/`, driving the real views compiled as the App
      Store flavor, on synthetic deterministic data — no real account usage is
      published. At least one screenshot is required to submit. The generated
      three are submittable as-is if the design pass slips; see `FOLLOW-UPS.md`
      §3 for the framed versions.
- [ ] **App Privacy questionnaire** — *Data Not Collected*, every category
      answered. It must be answered, not skipped.
- [ ] **Age rating** — 4+.
- [ ] **Review notes** — text below. Needs a live OAuth token, valid on the day
      of submission.

## Review notes (short, but skipping it costs a rejection cycle)

Two things will get Tokes rejected if unstated, and both are cheap to prevent.

1. **It is a menu bar app.** `LSUIElement` means no Dock icon and no window at
   launch. Reviewers routinely reject such apps as "the app does not launch" or
   "we were unable to locate any functionality". Say so in the first line.
2. **It needs an account the reviewer doesn't have.** Paste a live OAuth token
   and check it is still valid on submission day — expect a resubmission if a
   review round-trip outlives it.

Suggested text:

> Tokes is a menu bar utility. It has no Dock icon and no main window — after
> launch, its icon appears at the right end of the macOS menu bar. Hover the icon
> for the usage popover; right-click it for Refresh / Settings / Quit.
>
> To see live data: right-click the menu bar icon → Settings → under "Claude
> Connection" choose "Manual OAuth token", paste the token below, click Save
> Token, then Test Connection.
>
> Test token: <paste>
>
> Tokes reads the signed-in user's own Anthropic account usage. It collects no
> data, has no server, and transmits nothing to us.

---

## Every upload, from here on

### 1. Bump the build number

Increment `CFBundleVersion` in `scripts/Info.plist` for **every** upload,
including a re-upload after a failed validation. App Store Connect rejects a
duplicate even when `CFBundleShortVersionString` is unchanged. It is monotonic
across the whole app and is never reset when the marketing version changes.

`scripts/appstore.sh --upload` checks this against the builds already in App
Store Connect and stops *before* building, so forgetting costs a second rather
than a full build-sign-transfer cycle.

### 2. Build, validate, upload

The pipeline needs no arguments and no secrets: signing identities are found in
the login keychain and API credentials are read from
`packaging/appstore/asc-credentials.env` (git-ignored; the `.example` documents
it). Never ask an operator to paste a key or an identity string.

```sh
scripts/appstore.sh                 # build, sign, compliance audit, .pkg
scripts/appstore.sh --validate      # ...then validate against App Store Connect
scripts/appstore.sh --upload        # ...then upload
scripts/appstore.sh --build-status  # what Apple has done with it
scripts/appstore.sh --sync-version  # push CFBundleShortVersionString to the version record
```

`appstore.sh` runs `verify-appstore.sh` and refuses to package if the audit
fails. Transporter.app also works — drag `build/appstore/Tokes-<version>.pkg`
in — and needs no API key, just an Apple ID sign-in.

**Never redirect or pipe `build.sh --app-store`.** Twice it has exited 141
(SIGPIPE) after printing "Build complete!", leaving a half-assembled,
`linker-signed` bundle that the auditor scores 14 failed — which reads as a
compliance regression rather than a broken build. Run it bare and read the exit
status.

### 3. Attach the build and submit

**Uploading is not submitting.** An uploaded build sits under the app's Builds
section in App Store Connect indefinitely. Nothing reaches App Review until a
human attaches the build to the version record, fills in the metadata above, and
presses *Submit for Review*.

`--sync-version` matters here: `CFBundleShortVersionString` and the App Store
Connect version record must agree or the build never appears in the version's
build picker, with no error saying why.

---

## After the first approval

- **Revisit keywords and subtitle.** Both are deliberately brand-free, which is
  the right first-submission call and a real discoverability cost — nobody
  searching for a Claude usage monitor types `usage,quota,limits`. Adding
  `claude,copilot` is the highest-value and highest-risk single edit in the
  listing (Guideline 5.2.1 is enforced in those fields, not the description).
  Worth trying with an approval already banked.
- **`whatsNew`** becomes required for updates. `scripts/appstore-metadata.py`
  does not currently push it.
- **Copilot contingency.** If review objects under 5.2.2 to
  `api.github.com/copilot_internal/user`, dropping Copilot from the App Store
  build is a one-line change to `CopilotCredentialSource.available(for:)` plus
  the `copilotEnabled` default. The direct build keeps it.
