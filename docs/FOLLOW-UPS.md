# Follow-ups

Open items carried out of the App Store compliance work. Each says what it is,
why it is not done, and what "done" looks like — so it can be picked up cold by
a later session.

**Status, verified against App Store Connect 2026-08-20:** version **1.4.0**,
`CFBundleVersion` **2**, version record **1.4.0 / PREPARE_FOR_SUBMISSION**,
listing text pushed, **build 2 uploaded, `VALID`, and attached to the version
record**. Build 1 (v1.2.0) is also `VALID` and permanently orphaned — leave it.
Nothing submitted for review. The blockers are all web-UI answers; they live in
`APP-STORE-SUBMISSION.md` rather than being duplicated here.

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

The four web-UI blockers (App Privacy, age rating, screenshots, review notes)
are tracked in `APP-STORE-SUBMISSION.md`, which also carries the current App
Store Connect state. What remains here is the one item that is neither a web
form nor a code change:

- [ ] **TestFlight end-to-end run.** The one claim not backed by the test
      harness. A MAS-signed bundle cannot launch locally (`launchd` POSIX 163),
      so everything verified so far is either the ad-hoc build or static analysis
      of the signed one. Build 2 is uploaded and attached; install it via
      TestFlight and confirm the sandboxed app polls, imports a credentials file
      through the powerbox, and draws the menu bar item. Until then, do not
      describe the submission build as verified end to end.

*Done 2026-08-19:* build 2 uploaded at 1.4.0 and attached to the version record.

## After the first approval

Both items — the keyword/subtitle revisit and the Copilot 5.2.2 contingency —
are recorded in `APP-STORE-SUBMISSION.md` under "After the first approval",
where whoever is doing the next release will actually be reading.

## Housekeeping

- [ ] **`debugLogging` is on in the operator's real preference domain.**
      `~/Library/Preferences/com.appideas.tokes.plist` carries
      `debugLogging => true`, set 2026-08-20 00:09, and the running Tokes is
      still appending to `/tmp/tokes-debug.log`. The 2026-08-20 coverage report
      claimed this was cleaned up during its run; it was not — the plist has not
      been written since 00:09, so the delete never landed. **This is the second
      time a cleanup here was recorded without being read back.** Clear it with
      `defaults delete com.appideas.tokes debugLogging` and then
      `defaults read com.appideas.tokes debugLogging`, which must report the key
      does not exist. Left set deliberately for now — the operator may be
      watching the current run of 429s.
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
- [ ] **`verify-appstore.sh`'s entitlement-count failure message prints an empty
      count.** Fed a bundle with zero `com.apple.security` entitlements it reads
      `"  com.apple.security entitlements (expected 3)"`. The check fails
      correctly; only the message is wrong. Cosmetic.
