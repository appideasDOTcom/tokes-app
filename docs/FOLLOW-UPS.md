# Follow-ups

Open items carried out of the App Store compliance work. Each says what it is,
why it is not done, and what "done" looks like — so it can be picked up cold by
a later session.

**Status, verified against App Store Connect 2026-08-20:** repo is now
**1.4.2 / `CFBundleVersion` 3**, version record **1.4.2 / PREPARE_FOR_SUBMISSION**.
The only uploaded builds are 1 (`1.2.0`) and 2 (`1.4.0`) — **no artifact exists
at 1.4.2 yet**, so a build/upload/attach cycle is now a release blocker.
listing text pushed, **build 2 uploaded, `VALID`, and attached to the version
record**. Build 1 (v1.2.0) is also `VALID` and permanently orphaned — leave it.
Nothing submitted for review. The remaining blockers are all web-UI answers and
live in `APP-STORE-SUBMISSION.md` rather than being duplicated here. The privacy
policy URL and the revised promotional text were pushed 2026-08-20.

---

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
submission day — is tracked in `APP-STORE-SUBMISSION.md`, which also carries the current App Store Connect
state. What remains here is the one item that is neither a web form nor a code
change:

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
