# App Store submission runbook

Everything in this file needs an Apple account and a human. The code side is
finished and audited — see `APP-STORE-COMPLIANCE.md` for what is already proven
so you don't re-litigate it here.

**Already verified locally, needs nothing from you:** the sandbox is genuinely
on, the binary contains no out-of-container credential reader, every `Info.plist`
key App Store Connect validates is present, the bundle is universal, and
`productbuild` emits a correct installer (`customLocation="/Applications"`,
`hostArchitectures="arm64,x86_64"`, `min os-version 14.0`). The only unproven
links in the chain are the two signatures, because they need certificates that
can only come from a paid account.

---

## Order of operations

Two independent tracks converge at the build:

```
Step 1  App ID  ──►  Step 3  Provisioning profile  ──┐
                                                     ├──►  Step 6  Build → validate → upload
Step 2  Certificates (team-wide, not per-app)  ──────┘

Step 4  App Store Connect record  (needs the App ID; otherwise parallel)
```

Certificates do not depend on the App ID, so Steps 1 and 2 can happen in either
order. Registering a bundle ID is a Mac App Store requirement only — the
Developer ID path the Homebrew cask uses never needs one.

Prerequisite: an active Apple Developer Program membership on the team that will
own the listing.

---

## Step 1 — Register the App ID

Certificates, IDs & Profiles → **Identifiers** → **+** → App IDs → App.

- Description: `Tokes`
- Bundle ID: **Explicit** → `com.appideas.tokes`
- Capabilities: **none**. Sandbox entitlements are not portal capabilities —
  nothing here corresponds to `app-sandbox`, `network.client`, or
  `files.user-selected.read-only`. If you find yourself enabling something, stop.

If `com.appideas.tokes` is rejected as taken, it is registered to another team —
that is a support ticket, so check this early.

---

## Steps 2 & 3 — Certificates and provisioning profile (scripted)

Both are automated. `scripts/appstore-certs.py` creates the two certificates,
imports them into the login keychain, backs each up as a `.p12`, and downloads
the Mac App Store provisioning profile to where the build expects it.

```sh
scripts/appstore-certs.py --key-id <KEY_ID> --issuer <ISSUER_ID> \
    --p8 /path/to/AuthKey_<KEY_ID>.p8 [--dry-run]
```

Needs an App Store Connect API key with **Admin** (or Account Holder) access —
lesser roles cannot create distribution certificates. Create one at App Store
Connect → Users and Access → Integrations → App Store Connect API → Team Keys.
The `.p8` downloads exactly once.

| Certificate | Signs |
|---|---|
| `Apple Distribution` | `Tokes.app` |
| `3rd Party Mac Developer Installer` | the `.pkg` |

Three safety properties, because this runs against a live account with other
shipping apps on it:

- **It never revokes as a side effect.** Revocation is a separate, explicit
  `--revoke <id> <id>` that refuses ids it cannot find. Revoking a distribution
  certificate invalidates every build already signed with it.
- **It reuses before creating**, and only counts a certificate as reusable when
  the matching private key is in *this* keychain. A certificate whose key lives
  on another machine is reported, not replaced.
- **Private keys are generated locally** with `openssl` and never leave the Mac.
  Apple only ever sees a CSR. The `.p12` backups it writes are the only copy —
  lose the keychain without them and the certificate can only be revoked and
  reissued.

Verify afterwards:

```sh
security find-identity -v      # NOT -p codesigning: installer certs don't appear there
```

Doing it by hand instead: Certificates, IDs & Profiles → Certificates → **+** →
*Apple Distribution* and *Mac Installer Distribution* (Xcode → Settings →
Accounts → Manage Certificates → **+** avoids the CSR round-trip), then Profiles
→ **+** → Distribution → **Mac App Store Connect**, saved to
`packaging/appstore/embedded.provisionprofile`.

---

## Step 4 — App Store Connect record

<https://appstoreconnect.apple.com> → Apps → **+** → New App.

- Platform **macOS**, Bundle ID `com.appideas.tokes`, SKU e.g. `tokes-macos`
- Name must be unique across the whole store — check `Tokes` is free before
  committing to it

Then fill in, all of which block submission:

- **Name**: `Dev Tokes` — plain "Tokes" was already taken on the store. The app
  keeps `CFBundleDisplayName = Tokes` and calls itself Tokes everywhere else.
- **Category**: Developer Tools
- **Price**: Free (and it stays free — no IAP, no subscription)
- **Privacy policy URL**: `https://appideas.com/privacy-policy/`
- **Support / marketing URL**: `https://appideas.com/tokes/`
- **App Privacy** questionnaire: *Data Not Collected*. It must be answered, not
  skipped.
- **Screenshots**: `scripts/screenshots.sh` renders three at 2880×1800 into
  `build/appstore/screenshots/`, driving the real views compiled as the App Store
  flavor. Synthetic deterministic data — no real account usage is published.
- Description, subtitle, keywords: ready in `packaging/appstore/listing.md`,
  all fields checked against Apple's character limits.

Export compliance is already handled — `ITSAppUsesNonExemptEncryption=false` is
in `scripts/Info.plist`, so App Store Connect won't ask.

---

## Step 5 — Bump the build number

Increment `CFBundleVersion` in `scripts/Info.plist` for **every** upload,
including a re-upload after a failed validation. App Store Connect rejects a
duplicate even when `CFBundleShortVersionString` is unchanged.

`scripts/appstore.sh --upload` checks this against the builds already in App
Store Connect and stops before building, so forgetting costs a second rather
than a full build-sign-transfer cycle.

---

## Step 6 — Build, validate, upload

One-time: copy `packaging/appstore/asc-credentials.env.example` to
`asc-credentials.env` (git-ignored) and fill in the API key. After that the
pipeline needs no arguments — signing identities are found in the keychain and
credentials are read from that file, so nothing here requires a secret on a
command line or in an agent's prompt.

```sh
scripts/appstore.sh                 # build, sign, compliance audit, .pkg
scripts/appstore.sh --validate      # ...then validate against App Store Connect
scripts/appstore.sh --upload        # ...then upload
scripts/appstore.sh --build-status  # what Apple has done with it
```

`appstore.sh` runs `verify-appstore.sh` and refuses to package if the audit
fails. `--upload` additionally refuses a `CFBundleVersion` that has already been
uploaded, and does so *before* building rather than after the transfer.

Transporter.app also works — drag `build/appstore/Tokes-<version>.pkg` in — and
needs no API key, just an Apple ID sign-in.

**Uploading is not submitting.** An uploaded build sits under the app's Builds
section in App Store Connect indefinitely. Nothing reaches App Review until a
human fills in the metadata and presses *Submit for Review*.

---

## Step 7 — Review notes (short, but skipping it costs a rejection cycle)

Two things will get Tokes rejected if unstated, and both are cheap to prevent.

1. **It is a menu bar app.** `LSUIElement` means no Dock icon and no window at
   launch. Reviewers routinely reject such apps as "the app does not launch" or
   "we were unable to locate any functionality". Say so in the first line.
2. **It needs an account the reviewer doesn't have.** Paste a live OAuth token
   and check it is still valid on submission day.

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
