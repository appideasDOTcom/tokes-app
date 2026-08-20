# Follow-ups

Open items carried out of the App Store compliance work (2026-08-19). Each says
what it is, why it is not done, and what "done" looks like — so it can be picked
up cold by a later session.

Status at the time of writing: version **1.4.0**, `CFBundleVersion` **2**, App
Store Connect version record **1.4.0 / PREPARE_FOR_SUBMISSION**, listing text
pushed, build 1 (v1.2.0) uploaded and `VALID` but orphaned. Nothing submitted
for review.

---

## 1. `build.app_icon` → v3 (blocked: channel is quiet)

**The item Costmo flagged.** This is a contract *this repo owns* and the
designer's process depends on, and it went stale the moment the App Store work
landed.

`build.app_icon` v2 (owner `tokes-developer`, consumes `assets.app_icon` v2)
carries this field:

```
"not_covered": "App Store submission pipeline (sandbox entitlement, MAS cert,
                provisioning profile, .pkg), universal binary, and App Store
                screenshots. All out of scope here and Costmo-gated."
```

Every one of those six now exists. Leaving it is worse than never having written
it: another agent reading the contract would conclude the App Store path is
unbuilt and either duplicate it or design around a gap that closed.

**What v3 needs to say.** Not a rewrite — the icon build integration itself is
unchanged, so v1/v2 consumers of *that* remain correct. The delta is:

- **`not_covered`** — remove the six items that now exist. What genuinely remains
  out of scope for this contract: App Review outcomes, listing copy and
  screenshots (those belong in `assets.appstore_listing`, see §2), and the
  Developer ID / notarization path for Homebrew.
- **`build_step`** — `scripts/build.sh` now takes `--app-store`, builds universal
  by default, and for a real signing identity embeds the provisioning profile and
  merges two team-scoped entitlements derived from it. The `actool` invocation is
  unchanged; note that it runs for *both* flavors so the icon ships identically
  in each.
- **`outputs`** — add `build/appstore/Tokes.app/Contents/Resources/{Assets.car,
  Tokes.icns}` alongside the existing direct-build path. Same bytes, second
  location.
- **New field, `distribution_flavors`** — the fact a consumer would actually
  break on: there are two artifacts from one source, the App Store one compiles
  with `-DTOKES_APP_STORE`, and an ad-hoc build is deliberately account-free so
  it can launch for auditing while a submission-signed build cannot launch at all.
- **`toolchain_requirement`** — unchanged (Xcode 26+, CI pinned `macos-26`), but
  worth restating that it now also gates the App Store pipeline, not just the icon.
- **`tests`** — `IconPipelineTests` unchanged; add that `scripts/test.sh` runs the
  suite in both build configurations and CI audits the App Store build on every
  tagged release.
- **`changelog`** — v3 entry describing the above and stating explicitly that no
  icon artifact or invariant changed, so `assets.app_icon` needs no bump.

**Do not** bump `assets.app_icon`. It is the designer's contract, nothing about
the mark changed, and touching another team's contract is not ours to do.

**Notice is required, not optional.** The playbook is explicit that a version
bump alone is not notice — after `set_contract`, broadcast a message naming
`appideas-designer` in the body (never `to:`), pointing at v3 and saying what
changed. Surface the message id in the chat reply.

## 2. `assets.appstore_listing` contract (blocked: channel is quiet)

New contract, not yet written. Covers the screenshot/listing interface between
design and this repo. Durable facts a consumer depends on:

- `packaging/appstore/asset-standards.md` is the binding compliance standard;
  assets failing it are refused, and that is a gate rather than an opinion.
- App pixels come from `scripts/screenshots.sh` at 2880×1800 and are never
  redrawn — the designer owns the frame around them.
- The App Store build's UI differs from the Homebrew build's: the automatic
  credential sources are compiled out, so a screenshot showing them would
  misrepresent the submitted app.
- Copy lives in `packaging/appstore/listing.md` and is pushed by
  `scripts/appstore-metadata.py`; App Store Connect is a render target, not a
  place to author.

## 3. Task: screenshot frame assets (blocked: channel is quiet)

Ask the designer for the frame work — background art per size, type scale,
headline/subhead copy, ordering and safe areas. Per playbook §4, state the goal
and point at reference material; do **not** hand over a finished spec. Point at
`packaging/appstore/asset-standards.md` and the current generated screenshots as
the reference, and state the escalation path: if they find a real gap, open a
task back rather than guessing at a shape.

Until this lands, `appScreenshotSets` in App Store Connect is empty. **At least
one screenshot is required to submit.** The current generated three are
submittable as-is if the design pass slips.

---

## Before submission

- [ ] **TestFlight end-to-end run.** The one claim not backed by the test
      harness. A MAS-signed bundle cannot launch locally (`launchd` POSIX 163),
      so everything verified so far is either the ad-hoc build or static analysis
      of the signed one. Upload build 2, install via TestFlight, and confirm the
      sandboxed app polls, imports a credentials file through the powerbox, and
      draws the menu bar item. Until then, do not describe the submission build
      as verified end to end.
- [ ] **App Privacy questionnaire** — "Data Not Collected", every category
      answered. Web UI; blocks submission.
- [ ] **Age rating** — 4+.
- [ ] **Screenshots uploaded** — see §3.
- [ ] **Review notes** — draft in `docs/APP-STORE-SUBMISSION.md`. Needs a live
      OAuth token, valid on the day of submission, and must lead with "this is a
      menu bar app with no Dock icon".
- [ ] **Upload build 2** at 1.4.0 so a build actually attaches to the version
      record. Build 1 is v1.2.0 and will never attach.

## After the first approval

- [ ] **Revisit keywords and subtitle.** Both are deliberately brand-free, which
      is the right first-submission call and a real discoverability cost —
      nobody searching for a Claude usage monitor types `usage,quota,limits`.
      Adding `claude,copilot` is the highest-value and highest-risk single edit
      in the listing (Guideline 5.2.1 is enforced in those fields, not the
      description). Worth trying with an approval already banked.
- [ ] **Copilot contingency.** If review objects under 5.2.2 to
      `api.github.com/copilot_internal/user`, dropping Copilot from the App Store
      build is a one-line change to `CopilotCredentialSource.available(for:)`
      plus the `copilotEnabled` default. The direct build keeps it.

## Housekeeping

- [ ] **Homebrew cask is stale** — `packaging/homebrew/tokes.rb` still says
      `version "1.0.0"` with a placeholder sha256. Update at the next Homebrew
      release, not before.
- [ ] **Developer ID signing has never been exercised.** `scripts/release.sh`
      supports `--sign`/`--notarize` but no notarized build has shipped, which is
      why the cask still carries its `caveats` block. Separate certificate from
      the App Store ones; `scripts/appstore-certs.py` does not create it.
- [ ] **Two orphan sandbox containers** —
      `~/Library/Containers/com.appideas.tokes.{sandboxprobe,powerboxprobe}` from
      verification harnesses. `containermanagerd` protects them from `rm` even as
      the owner; deletable from Finder. Harmless.
- [ ] **`whatsNew`** is unset — not needed for a first release, required for
      updates. `scripts/appstore-metadata.py` does not currently push it.
