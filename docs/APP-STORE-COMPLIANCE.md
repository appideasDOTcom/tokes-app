# App Store compliance

Tokes ships from one codebase as two artifacts:

| | Direct build | App Store build |
|---|---|---|
| Channel | Homebrew cask, direct download | Mac App Store |
| Sandbox | no | yes |
| Compile flag | *(none)* | `-DTOKES_APP_STORE` |
| Output | `build/Tokes.app` | `build/appstore/Tokes.app` |
| Build | `scripts/build.sh` | `scripts/build.sh --app-store` |
| Package | `scripts/release.sh` (notarized `.zip`) | `scripts/appstore.sh` (signed `.pkg`) |

Both are `com.appideas.tokes`. Their settings and history do not mix: the
sandboxed build's `$HOME` is redirected into
`~/Library/Containers/com.appideas.tokes/Data`.

## The rule that actually binds

**App Review Guideline 2.5.2** — *"Apps should be self-contained in their
bundles, and may not read or write data outside the designated container area,
nor may they download, install, or execute code which introduces or changes
features or functionality of the app, including other apps."*

That is a stricter line than the sandbox kernel draws, and the gap is not small.
Measured on a real sandboxed, ad-hoc-signed bundle on macOS 26 (25G76):

| Path Tokes uses | Sandbox kernel | Guideline 2.5.2 |
|---|---|---|
| Read `~/.claude/.credentials.json` | **denies** (errno 257) | forbids |
| Read `~/.config/github-copilot/apps.json` | **denies** (errno 257) | forbids |
| Spawn `/usr/bin/security find-generic-password` | **allows** — exit 0, 567 bytes returned | forbids |
| `SecItemCopyMatching` for `"Claude Code-credentials"` | **allows** — `errSecSuccess`, 566 bytes, no prompt | forbids |
| Write `/tmp/tokes-debug.log` | **denies** | forbids |
| Read/write Tokes' own keychain item | allows | allows |
| Read a file the user picked in an open panel | allows | allows |

Two of those would have shipped a compliant-looking binary that quietly read
another application's credential store. So the boundary is drawn in the source,
not left to the kernel, and `scripts/verify-appstore.sh` checks the built binary
rather than trusting the intent.

## How the boundary is drawn

`Sources/Tokes/Distribution.swift` holds a compile-time `Distribution` and a
`Capabilities` set derived from it. Everything gated on
`Capabilities.canReadForeignCredentialStores` / `canRunHelperTools` is
`#if !TOKES_APP_STORE`-excluded, so the App Store binary does not merely decline
to read other apps' stores — the code is not in it.

Compiled out of the App Store build:

- `CredentialsProvider.loadClaudeCodeToken()` and its `/usr/bin/security`
  fallback, and the `CredentialError.denied` case whose message names the
  foreign keychain item
- `CopilotCredentialsProvider.loadEditorToken()`, `configDirectory`, and
  `ghCLIToken()`
- Both `Process` uses — the App Store binary links no `NSTask` symbol at all

**Not** compiled out, and this is the counter-intuitive part: the strings
`"Claude Code-credentials"` and `find-generic-password` are both present in the
App Store binary (4 occurrences each, measured). They are the export command
`ClaudeCodeExport` shows the user to run in *their own* terminal — copy, not
capability. The string that actually proves the reader is gone is the absolute
path `/usr/bin/security`, which the App Store binary does not contain at all
(measured: 0). Don't "fix" the first two by re-adding them to the auditor's
forbidden list; that would fail every build for shipping its own help text.

What remains, in both builds:

- **GitHub sign-in** — the device flow against Tokes' own GitHub App, reading
  usage from GitHub's *documented* per-user billing endpoints. Nothing about it
  touches another app's storage: the tokens are minted for Tokes and live in
  Tokes' own keychain item. This is the only credential path in the app that is
  both sanctioned by the provider and permanent; see `CREDENTIALS.md`.
- **Manual token** — pasted in Settings, stored in Tokes' own keychain item
  (service `com.appideas.tokes`). A sandboxed app owns its own keychain items.
- **Imported file** — a credentials file the user picks in an open panel, kept
  as a security-scoped bookmark (`ImportedCredentialFile`). This is not a
  loophole: when someone chooses a file in the powerbox, macOS extends the
  container to include it. That is what the mechanism is for.

  Since build 6 the Claude side of this is a *guided* flow: Settings shows the
  user a `security` command to run **in their own terminal**, exporting their
  own keychain item to a file they then pick. The user is the actor at every
  step and Tokes still reads no foreign store — which is exactly why the
  command text can ship in the App Store binary (see the auditor note below).

The imported file is re-read on every poll rather than copied once, so a token
the owning tool rotates keeps working. Verified end-to-end under a real sandbox
(see below).

The temptations are all declined: **no temporary-exception entitlements**. The
whole sandbox declaration is three keys (`packaging/appstore/Tokes.entitlements`)
— app-sandbox, network-client, and user-selected read-only.

A signed submission carries two more, `com.apple.application-identifier` and
`com.apple.developer.team-identifier`, which `build.sh` derives from the
provisioning profile at signing time rather than committing. That keeps the
checked-in entitlements team-neutral, so an ad-hoc local audit build still runs
with no Apple account at all — and it is what makes the upload TestFlight
eligible. Without them App Store Connect accepts the build but warns 90886: the
profile declares an application identifier the signature doesn't.

## What is verified, and how

```sh
scripts/test.sh                      # suite in both configurations
scripts/build.sh --app-store         # sandboxed, ad-hoc signed — no certs needed
scripts/verify-appstore.sh           # static + runtime audit
```

`scripts/test.sh` runs the suite twice, because `-DTOKES_APP_STORE` removes
whole functions and the default configuration alone leaves that half unbuilt.
**377 direct (2 skipped), 374 App Store**, re-measured 2026-08-20 after the
onboarding work. The three fewer are the Copilot editor-lookup tests, guarded
out with the reader they cover; two direct-build skips become real assertions on
the App Store side, where the `sourceUnavailable` paths they cover actually
exist.

`scripts/verify-appstore.sh` checks the built artifact:

- entitlements present, exactly three, no temporary exceptions
- the binary contains none of `/usr/bin/security`, the three `gh` paths, or
  `/tmp/tokes-debug.log`, and links no `Foundation.Process` / `NSTask` symbol,
  per architecture
- **plus a source-level tripwire**: the foreign keychain service name
  `"Claude Code-credentials"` may appear in exactly two files — the reader
  that is `#if`'d out of this build, and the export walkthrough's copy. A third
  file naming it fails the audit
- every `Info.plist` key App Store Connect validates, including the `DT*`
  build-provenance keys Xcode normally stamps and a SwiftPM bundle must write
  itself
- universal (`arm64` + `x86_64`) — macOS 14 still runs on Intel
- then it **launches the bundle** and confirms the container exists, the app
  reports `sandboxed=true` from its own code signature, the debug log landed in
  the container rather than `/tmp`, the history store redirected into the
  container, and `~/Library/Application Support/Tokes` was not touched

It is a real check, not a rubber stamp: fed the direct build, its static
section alone reports **10 passed / 20 failed** — every forbidden string, both
architectures' `NSTask` link, all three entitlements missing, and the nine
`DT*` provenance keys a SwiftPM bundle has to write itself. Re-measured
2026-08-20 (evening). It has moved twice and both moves are informative: 19 →
22 when the auditor gained the `/usr/bin/gh` string and turned the
entitlement-count check from a warning into a failure, then 22 → 20 when two
strings left the list, below.

**The forbidden-string list covers behaviour, not copy — and the line moved.**
Descriptive UI text was always exempt: the App Store build still says
`~/.claude/.credentials.json` in the import help and opens the panel there, which
is the feature working. Since the Claude export walkthrough,
`find-generic-password` and `Claude Code-credentials` are *also* legitimate copy
— they are the command Settings shows the user to run themselves — so a strings
scan can no longer tell a reader from a caption, and both were removed from the
list. What still proves no reader is compiled in: the absolute `/usr/bin/security`
path (only the shell-out reader carries it), the `Process`/`NSTask` symbol check
(no subprocess execution at all, in either architecture), and the source tripwire
pinning where the service name may appear. Dropping a string from that list
without replacing the guarantee is how this check would quietly become a rubber
stamp.

### The powerbox path, proven under sandbox

`ImportedCredentialFile.swift` was linked into a throwaway bundle signed with
the same entitlements, and its panel driven for real:

```
DIRECT_READ_BEFORE=DENIED(257)                     # sandbox blocks the path
PANEL_RESULT=/Users/costmo/tokes-powerbox-probe.json
READ_AFTER_IMPORT=OK bytes=81 token=gho_PROBE_TOKEN_v1

# separate process launch, no panel:
DIRECT_READ=DENIED(257)                            # still blocked
HAS_BOOKMARK=true
BOOKMARK_READ=OK bytes=81 token=gho_PROBE_TOKEN_v1 # the bookmark carries the grant

# file replaced atomically (new inode), another fresh launch:
AFTER_ROTATION token=gho_PROBE_TOKEN_v2_ROTATED    # rotation is followed
```

## Known exposure

**Guideline 5.2.2 (third-party services) — much reduced since build 6, not
gone.** The App Store build's default Copilot source is now `githubApp`: a
registered GitHub App with a single read-only *Plan* permission, GitHub's own
device flow, and the **documented** per-user billing endpoints
(`/users/{login}/settings/billing/{ai_credit,premium_request}/usage`). That is
a sanctioned, published interface, which is the whole point of having built it.

The undocumented `copilot_internal/user` endpoint is still reachable — but only
via the `manual` and (direct-build-only) `editor` sources, never by default.
The residual exposure is that a user *can* still select it. If review objects,
dropping Copilot from the App Store build is a one-line change to
`CopilotCredentialSource.available(for:)` plus the `copilotEnabled` default —
the direct build keeps it.

The Claude side polls `https://api.anthropic.com/api/oauth/usage` with the
user's own OAuth token: their own account, their own data.

## Still needed from the operator

None of this is a code problem; no agent can obtain them.

**Satisfied 2026-08-19** — kept here because the list is what a reader checks
against, and "done" is the answer: Apple Developer Program membership; the
**Apple Distribution** and **3rd Party Mac Developer Installer** certificates
(both now in the login keychain, team `636YZVZ34J`); a Mac App Store
provisioning profile at `packaging/appstore/embedded.provisionprofile`; and an
App Store Connect record (`Dev Tokes`, app id `6803324238`). The record of how
they were obtained is `retired/appstore-account-setup-2026-08-19.md`.

**Still outstanding:**

- **Review notes with a working credential.** A reviewer has no Claude
  subscription and no Claude Code install, so the guided export — the path real
  users take — is useless to them; the demo path is a pasted token. Tokens
  expire in hours, so paste a fresh one on the day of submission and **name the
  expiry failure mode in the notes**, which converts a likely rejection into a
  message to us. Full text in `.private/APP-STORE-SUBMISSION.md`.

*Closed 2026-08-20:* the **App Privacy questionnaire**, **age rating**, and
**screenshots** (six frames, `COMPLETE`), all web-UI answers that block
submission; and the **privacy policy URL**, which was never an operator answer
at all — it had been specified in `packaging/appstore/listing.md` all along and
simply never pushed, because it lives on `appInfoLocalizations` and
`scripts/appstore-metadata.py` was sending only `name`/`subtitle` there. Script
fixed and pushed.
- **A Developer ID Application certificate**, for the *other* pipeline. It is
  separate from the two App Store certificates, `scripts/appstore-certs.py`
  does not create it, and the keychain does not hold one — so the notarized
  Homebrew path has never been exercised end to end.
