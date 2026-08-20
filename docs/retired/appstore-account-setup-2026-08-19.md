# Retired: Mac App Store account setup

**Closed 2026-08-19.** Every step here is done and none of it recurs. Kept as
the record of *how* the account side was set up, because the artifacts it
produced (certificates, a provisioning profile, an App Store Connect record)
outlive the session that made them and the next person to touch them will want
to know what was chosen and why.

The live runbook — bump, build, upload, submit — is `../APP-STORE-SUBMISSION.md`.

## What this produced

| Artifact | Where it lives now |
|---|---|
| App ID `com.appideas.tokes` | Apple Developer portal, team OSTMOXY, LLC (636YZVZ34J) |
| `Apple Distribution` certificate | login keychain + `.p12` beside the API key |
| `3rd Party Mac Developer Installer` certificate | login keychain + `.p12` beside the API key |
| Mac App Store provisioning profile | `packaging/appstore/embedded.provisionprofile` (git-ignored) |
| App Store Connect record | app `6803324238`, listing name **Dev Tokes** |

Verified present on 2026-08-20:

```
5) 78A933FC5954E1E61C16C91F27C3A07400509CBC "Apple Distribution: OSTMOXY, LLC (636YZVZ34J)"
6) C75ADE4CE0FADD9A00B5559BDBF61DBEA1A370CF "3rd Party Mac Developer Installer: OSTMOXY, LLC (636YZVZ34J)"
```

---

## Order of operations (as executed)

Two independent tracks converged at the build:

```
Step 1  App ID  ──►  Step 3  Provisioning profile  ──┐
                                                     ├──►  Build → validate → upload
Step 2  Certificates (team-wide, not per-app)  ──────┘

Step 4  App Store Connect record  (needs the App ID; otherwise parallel)
```

Certificates do not depend on the App ID, so Steps 1 and 2 could happen in
either order. Registering a bundle ID is a Mac App Store requirement only — the
Developer ID path the Homebrew cask uses never needs one.

## Step 1 — Register the App ID

Certificates, IDs & Profiles → **Identifiers** → **+** → App IDs → App.

- Description: `Tokes`
- Bundle ID: **Explicit** → `com.appideas.tokes`
- Capabilities: **none**. Sandbox entitlements are not portal capabilities —
  nothing there corresponds to `app-sandbox`, `network.client`, or
  `files.user-selected.read-only`. If you find yourself enabling something, stop.

If `com.appideas.tokes` had been rejected as taken, it would have been
registered to another team — a support ticket, so it was checked early.

## Steps 2 & 3 — Certificates and provisioning profile (scripted)

Both are automated by `scripts/appstore-certs.py`, which creates the two
certificates, imports them into the login keychain, backs each up as a `.p12`,
and downloads the Mac App Store provisioning profile to where the build expects
it. It now reads `packaging/appstore/asc-credentials.env` and takes no
arguments; the original invocation passed them explicitly:

```sh
scripts/appstore-certs.py --key-id <KEY_ID> --issuer <ISSUER_ID> \
    --p8 /path/to/AuthKey_<KEY_ID>.p8 [--dry-run]
```

Needs an App Store Connect API key with **Admin** (or Account Holder) access —
lesser roles cannot create distribution certificates. Created at App Store
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
  reissued, which invalidates every build already signed.

Verify:

```sh
security find-identity -v      # NOT -p codesigning: installer certs don't appear there
```

Doing it by hand instead: Certificates, IDs & Profiles → Certificates → **+** →
*Apple Distribution* and *Mac Installer Distribution* (Xcode → Settings →
Accounts → Manage Certificates → **+** avoids the CSR round-trip), then Profiles
→ **+** → Distribution → **Mac App Store Connect**, saved to
`packaging/appstore/embedded.provisionprofile`.

### Four API traps, each of which cost a wrong turn

Recorded here because they are properties of Apple's API, not of this session:

- **`csrContent` is the raw PEM, not base64 of it.** Base64-wrapping returns
  HTTP 409 *"Invalid Certificate"*, which reads like the key is bad rather than
  the encoding.
- **`xcrun altool --generate-jwt` writes the token to stderr**, after a banner
  line. `2>/dev/null | tail -1` yields an empty string and a confusing 401.
- **`curl` globs `[` and `]`** — `filter[identifier]=...` silently produces a
  malformed request unless you pass `-g`.
- **A POST probe against this API creates real, billable-slot resources.** Apple
  caps Apple Distribution certificates at 2 per team; two throwaway certs from
  an encoding experiment fill it. Probe encodings on something disposable, and
  stop at the first success.

## Step 4 — App Store Connect record

<https://appstoreconnect.apple.com> → Apps → **+** → New App.

- Platform **macOS**, Bundle ID `com.appideas.tokes`, SKU `tokes-macos`
- **Name**: `Dev Tokes` — plain "Tokes" was already taken on the store. The app
  keeps `CFBundleDisplayName = Tokes` and calls itself Tokes everywhere else.
- **Category**: Developer Tools
- **Price**: Free (and it stays free — no IAP, no subscription)
- **Privacy policy URL**: `https://appideas.com/privacy-policy/`
- **Support / marketing URL**: `https://appideas.com/tokes/`

Description, subtitle and keywords were authored in
`packaging/appstore/listing.md` and pushed by `scripts/appstore-metadata.py`;
App Store Connect is a render target, not a place to author. All fields were
checked against Apple's character limits.

Export compliance needed no answer — `ITSAppUsesNonExemptEncryption=false` is in
`scripts/Info.plist`, so App Store Connect never asks.

---

## What was still open when this closed

These moved to `../FOLLOW-UPS.md` rather than being finished here, because none
of them is account setup: the App Privacy questionnaire, the age rating,
screenshots, and review notes with a live token. All four block submission and
all four are answered in the App Store Connect web UI.
