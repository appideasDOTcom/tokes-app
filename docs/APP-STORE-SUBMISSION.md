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
| Version record | **1.4.2**, `PREPARE_FOR_SUBMISSION` (operator bumped it 2026-08-20) |
| Uploaded build | **build 3** (`1.4.2`), uploaded 2026-08-20 — attach it once Apple finishes processing |
| Listing text | pushed — description, subtitle, keywords present in `en-US` |
| Privacy policy URL | set — `https://appideas.com/privacy-policy/`, pushed 2026-08-20 |
| Screenshots | **6 uploaded**, `APP_DESKTOP`, all `COMPLETE`, order pinned |
| Age rating | **done** — `FOUR_PLUS` (Brazil `L`), verified via API 2026-08-20 |
| App Privacy | **done** — validated by the operator directly, more than once |
| `whatsNew` | unset — not needed for a first release |
| Submitted for review | **no** |

Build 1 (v1.2.0) is also `VALID` and will never attach. Leave it.

**Build 2 is the wrong artifact — do not submit with it.** The version record was
bumped to `1.4.2` in place, so `build 2` (a `1.4.0` artifact) is attached to a
record it does not match. App Store Connect did not detach it, but a build and
its version record are expected to agree, and `--sync-version` exists precisely
because a mismatch makes a build invisible to the picker with no error saying
why. **Build 3 (`1.4.2`, `CFBundleVersion` 3) was built and uploaded 2026-08-20**
— audit 32/0 static — and replaces it. Attach build 3, not build 2.

Next upload needs `CFBundleVersion` **4**; it is monotonic across the whole app
and never resets when the marketing version changes.

---

## Blocking the first submission

**One item left: the review notes, which need a live token generated on the
day.** Everything else is done.

*Closed 2026-08-20: the **privacy policy URL**, which is required to submit and
had never been pushed. It was found by reading the live API rather than the
repo — `appInfoLocalizations` reported `privacyPolicyUrl: None` while
`packaging/appstore/listing.md` had specified it all along. The cause is worth
keeping: that field lives on `appInfoLocalizations`, not the version
localization, and `scripts/appstore-metadata.py` was pushing only `name` and
`subtitle` there, so every run reported success while a required field stayed
empty. **A clean run of that script proves nothing about fields it does not
name.** Script fixed and both it and the new promotional text are now live.*

- [x] **Screenshots — done 2026-08-20.** Six frames at 2880×1800, uploaded with
      `scripts/appstore-screenshots.py`, verified `COMPLETE` with no errors and
      display order pinned explicitly. The frames are authored by
      `appideas-designer`; `packaging/appstore/screenshots-source.txt` records
      the path and the rule that we pull and never write into it. Our raw
      material comes from `scripts/screenshots.sh --states`.

      Three things worth keeping:
      - **No alpha channel, ever.** App Store Connect rejects a macOS screenshot
        that carries one, and the error does not say so. The uploader checks
        every file before sending a byte.
      - **Upload is reserve → transfer → commit.** Skip the commit
        (`uploaded: true` plus the file's MD5 as `sourceFileChecksum`) and the
        asset stays half-created: present in the API, absent from the web UI.
      - **One fixture across all six frames** — session 88 resetting in 1h 12m,
        weekly 46, Weekly Fable 62, Copilot 57. Re-rendering any capture on
        different values means rebuilding the whole set, not one frame.
- [x] **Age rating — done.** `appStoreAgeRating` reads `FOUR_PLUS` and
      `brazilAgeRating` reads `L`. Verified against the API, not taken on
      report. Note for whoever probes this next: `ageRatingDeclaration` hangs
      off **`appInfos`**, not off `appStoreVersions` — querying the version
      relationship returns `PATH_ERROR` and reads like the API doesn't support
      it at all.
- [x] **App Privacy questionnaire — done.** *Data Not Collected*, every category
      answered; validated by the operator directly, more than once. Note for
      anyone tempted to re-check it programmatically: **there is no API path** —
      `appDataUsages` and `appDataUsagesPublishState` both return `PATH_ERROR`
      against this app. Absence of an API check is not absence of the answer.
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
> launch, its icon appears at the right end of the macOS menu bar as three faint
> grey bars with no number. Hovering it opens a panel reading "Tokes — waiting
> for usage data"; that is the correct unconfigured state, not an error.
>
> To see live data:
> 1. Right-click the menu bar icon and choose **Settings…**
> 2. Under **Claude Connection → Credentials**, select **Manual OAuth token**.
>    (The default selection is "Import a Claude Code credentials file"; you do
>    not need a file.)
> 3. Paste the token below into **OAuth access token**, click **Save Token**,
>    then **Test Connection**.
> 4. Close Settings. The bars fill on the next refresh — every 1 minute by
>    default — or right-click the icon and choose **Refresh Now**.
>
> Test token: <paste>
>
> Tokes reads the signed-in user's own Anthropic account usage. It collects no
> data, has no server, and transmits nothing to us.

**Three details verified against the source 2026-08-20; each one strands a
reviewer if the notes omit it.**

- **The Claude credential source defaults to `importedFile`, not manual.** In the
  App Store build `CredentialSource.available` is `[importedFile, manual]` and
  the default is the first, so a reviewer opening Settings finds a file-import
  path selected for a file they do not have. Step 2 must say *select*.
- **`menuBarLabel` defaults to `.off`** — there is no percentage beside the icon
  on first run, though the store frames deliberately show one (they depict a
  configured app, with "Show in menu bar: Highest value"). So notes and copy must
  present the percentage as **optional**, never as something that appears by
  itself. Saying it is on by default contradicts the build; saying it does not
  exist contradicts the screenshots.
- **Do not tell a reviewer that either service alone is enough.** It is true —
  a Copilot-only poll succeeds — but Claude reserves its three bar slots
  regardless, so the strip renders as three empty tracks, a divider, and one
  lone coloured bar. That reads as a broken app, which is the exact rejection
  these notes exist to prevent. Supply both tokens.

The Copilot half, if used: **GitHub Copilot → "Also monitor Copilot premium
requests"** (off by default) → **"Manual GitHub token"** (this source also
defaults to import-a-file). Say nothing about `gh` — the CLI path is compiled
out of this build.

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

**The operator presses the final button, always.** Costmo submits to Apple
himself; everything an agent does stops at *pending*. Pushing metadata, pushing
listing text, uploading a build and attaching it are all fine and none of them
submit anything — but `Submit for Review` is his, and a relayed authorisation
from another agent is not a substitute for his own word.

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
