# Releasing Tokes

## One-time setup

```sh
# Create the tap repo:
gh repo create appideasDOTcom/homebrew-tap --public --clone
mkdir homebrew-tap/Casks
cp /Users/costmo/Documents/dev/appideas/tokes/packaging/homebrew/tokes.rb homebrew-tap/Casks/
# Commit and push the tap.
```

## Each release

1. Set the version in `scripts/Info.plist` (`CFBundleShortVersionString`).
2. Commit, then tag `v<version>` (e.g. `v1.0.0`) and push the tag.
   The tag triggers `.github/workflows/release.yml`: tests → build →
   GitHub release with `Tokes-<version>.zip` attached and its sha256 in the notes.
3. In the tap repo, update `Casks/tokes.rb`: bump `version`, paste the sha256
   from the release notes. Commit and push.

Users install with:

```sh
brew install appideasDOTcom/tap/tokes
```

## Local packaging (without CI)

```sh
scripts/release.sh                                   # ad-hoc signed
scripts/release.sh --sign "Developer ID Application: ..." --notarize <profile>
```

Prints the zip path and sha256. Once builds are signed + notarized, remove the
`caveats` block from the cask.

## Temporary (until resolved)

The Apple App Store release cannot include the current authentication mechanism.
An App Store build must be sandboxed, and every credential path Tokes uses today
depends on something the sandbox denies. **Both providers are affected**, not
just Claude.

Blocked under the sandbox:

| Path | Where | Why it fails sandboxed |
|---|---|---|
| `~/.claude/.credentials.json` | `CredentialsProvider` | File outside the app container |
| `"Claude Code-credentials"` keychain item | `CredentialsProvider` | Another app's keychain item, not in Tokes' access group |
| `/usr/bin/security` shell-out | `CredentialsProvider` | Subprocess execution |
| `~/.config/github-copilot/apps.json`, `hosts.json` | `CopilotCredentialsProvider` | Files outside the app container |
| `gh auth token` shell-out | `CopilotCredentialsProvider` | Subprocess execution |

Not blocked: the manual-token path for either provider (Tokes' own keychain item,
service `com.appideas.tokes`), since a sandboxed app may use its own keychain —
though this still needs verifying against a real sandboxed build. That is the only
credential mechanism that survives as-is, so the App Store build is some form of
"paste your own key" for both services.

Open question for when we take this up: the Claude usage endpoint is
`api/oauth/usage` and is OAuth-scoped — whether a standard Anthropic API key
authenticates against it at all is unverified. Check that before committing to an
API-key design.

## Not yet provisioned (blocks App Store submission regardless of code)

None of these is a code problem, and no agent can obtain them — they are
account-level and need Costmo:

- Apple Developer Program membership for the App Store (separate from the
  Developer ID signing used by the Homebrew/notarized path above).
- A **Mac App Store distribution certificate** and a matching provisioning
  profile. `release.sh` currently signs ad-hoc or with Developer ID; neither is
  accepted for App Store submission.
- An App Store Connect app record, needed before anything can be uploaded.

The App Store build is also a different artifact from the one above: a signed
`.pkg` via `productbuild`/`productsign` uploaded with Transporter, not the
notarized `.zip` the cask consumes. Both pipelines have to keep working.
