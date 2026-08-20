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
  fallback, plus the `"Claude Code-credentials"` service name and the
  `CredentialError.denied` case whose message names it
- `CopilotCredentialsProvider.loadEditorToken()`, `configDirectory`, and
  `ghCLIToken()`
- Both `Process` uses — the App Store binary links no `NSTask` symbol at all

What remains, in both builds:

- **Manual token** — pasted in Settings, stored in Tokes' own keychain item
  (service `com.appideas.tokes`). A sandboxed app owns its own keychain items.
- **Imported file** — a credentials file the user picks in an open panel, kept
  as a security-scoped bookmark (`ImportedCredentialFile`). This is not a
  loophole: when someone chooses a file in the powerbox, macOS extends the
  container to include it. That is what the mechanism is for.

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
237 tests direct, 234 App Store (the three fewer are the Copilot editor-lookup
tests, guarded out with the reader they cover; two direct-build skips become
real assertions on the App Store side, where the `sourceUnavailable` paths they
cover actually exist).

`scripts/verify-appstore.sh` checks the built artifact:

- entitlements present, exactly three, no temporary exceptions
- the binary contains none of `/usr/bin/security`, `find-generic-password`,
  `Claude Code-credentials`, the `gh` paths, or `/tmp/tokes-debug.log`, and
  links no `Foundation.Process` / `NSTask` symbol, per architecture
- every `Info.plist` key App Store Connect validates, including the `DT*`
  build-provenance keys Xcode normally stamps and a SwiftPM bundle must write
  itself
- universal (`arm64` + `x86_64`) — macOS 14 still runs on Intel
- then it **launches the bundle** and confirms the container exists, the app
  reports `sandboxed=true` from its own code signature, the debug log landed in
  the container rather than `/tmp`, the history store redirected into the
  container, and `~/Library/Application Support/Tokes` was not touched

It is a real check, not a rubber stamp: fed the direct build it reports 19
failures, including the `NSTask` link.

Descriptive UI copy is deliberately *not* on the forbidden-string list. The App
Store build still says `~/.claude/.credentials.json` in the import help text and
opens the panel there — that is the feature working.

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

**Guideline 5.2.2 (third-party services).** Copilot monitoring polls
`https://api.github.com/copilot_internal/user`, which is undocumented and named
`internal`. The user supplies their own GitHub token and sees only their own
quota, but there is no published GitHub term permitting the call. If review
objects, dropping Copilot from the App Store build is a one-line change to
`CopilotCredentialSource.available(for:)` plus the `copilotEnabled` default —
the direct build keeps it.

The Claude side polls `https://api.anthropic.com/api/oauth/usage` with the
user's own OAuth token: their own account, their own data.

## Still needed from the operator

None of this is a code problem; no agent can obtain them.

- Apple Developer Program membership (separate from the Developer ID signing the
  Homebrew path uses).
- An **Apple Distribution** (or *3rd Party Mac Developer Application*)
  certificate **and** a **3rd Party Mac Developer Installer** certificate. The
  keychain currently holds only *Apple Development* identities, which cannot
  sign a submission.
- A Mac App Store provisioning profile for `com.appideas.tokes`, saved as
  `packaging/appstore/embedded.provisionprofile` (git-ignored).
- An App Store Connect app record.
- **Review notes with a working credential.** A reviewer has no Claude
  subscription, so with no token the app can only show its error state. Paste a
  live OAuth token into App Store Connect's review notes along with: *"Open
  Settings from the menu bar icon's right-click menu, choose 'Manual OAuth
  token', paste the token above, click Save Token, then Test Connection."*
  Tokens expire — check it is still valid on the day of submission, and expect
  a resubmission if a review round-trip outlives it.
