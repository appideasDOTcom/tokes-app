# Releasing Tokes

## One-time setup — half done

`appideasDOTcom/homebrew-tap` exists and is public, but **it is empty**: no cask
has ever been pushed to it. So the install command below does not work yet, and
`packaging/homebrew/tokes.rb` in this repo is still the 1.0.0 template with a
placeholder sha256. Finish it with:

```sh
gh repo clone appideasDOTcom/homebrew-tap
mkdir -p homebrew-tap/Casks
cp packaging/homebrew/tokes.rb homebrew-tap/Casks/
# Bump version + sha256 from the release notes first, then commit and push.
```

Two GitHub releases exist already (v1.0.0, v1.2.0) — the tag → CI → release path
works. Only the tap side is unfinished. Neither release is notarized, which is
why the cask still needs its `caveats` block.

## Each release

1. Set the version in `scripts/Info.plist` (`CFBundleShortVersionString`).
2. Commit, then tag `v<version>` (e.g. `v1.0.0`) and push the tag.
   The tag triggers `.github/workflows/release.yml`: tests → build →
   GitHub release with `Tokes-<version>.zip` attached and its sha256 in the notes.
3. In the tap repo, update `Casks/tokes.rb`: bump `version`, paste the sha256
   from the release notes. Commit and push.

Users will install with — once the tap actually has a cask in it:

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

Before tagging, run the end-to-end smoke once, deliberately (it steals focus
while it runs):

```sh
scripts/e2e-smoke.sh                    # real status item -> popover -> close
```

## Version numbering

Linux-kernel convention, applied at **both** the minor and patch level:

| Component | Even | Odd |
|---|---|---|
| Minor (`1.x.0`) | release line | development line |
| Patch (`1.4.x`) | RC / expected to go to production | testing only, never shipped |

So 1.4.0 and 1.4.2 are release candidates within the 1.4 line; 1.4.1 and 1.4.3
are test builds. Work toward the *next* release line happens at 1.5.x and lands
as 1.6.0. Never publish an odd number in either position.

`CFBundleVersion` is separate and **monotonic across the whole app** — it is
never reset when the marketing version changes. App Store Connect rejects a
duplicate, and `scripts/appstore.sh --upload` checks for one before it builds.

`scripts/appstore.sh --sync-version` pushes `CFBundleShortVersionString` from
`scripts/Info.plist` to the App Store Connect version record. They must agree or
the build never appears in the version's build picker, with no error saying why.

## Architecture

Both flavors build universal (`arm64` + `x86_64`). Apple is retiring Intel *app*
support, not universal binaries — Rosetta never touches a universal build. macOS
27 drops Intel Macs, but `LSMinimumSystemVersion` is 14.0 and Sonoma/Sequoia run
on plenty of 2017-2020 Intel hardware whose owners can never move past macOS 26.
Revisit when the deployment target passes 26. `--universal` is the default;
nothing disables it short of editing `build.sh`.

## Mac App Store

A separate artifact from the notarized zip above, built from the same source
with `-DTOKES_APP_STORE`. Read `APP-STORE-COMPLIANCE.md` for the design and
`.private/APP-STORE-SUBMISSION.md` for what is left to submit — the first explains what
that flag removes and why, the second carries the current App Store Connect
state and the blockers no script can supply. The one-time account setup is done
and recorded in `retired/appstore-account-setup-2026-08-19.md`.

Build and audit locally, no Apple certificates required:

```sh
scripts/build.sh --app-store      # sandboxed, ad-hoc signed -> build/appstore/Tokes.app
scripts/verify-appstore.sh        # static + runtime compliance audit
```

Certificates and the provisioning profile, once per team:

```sh
scripts/appstore-certs.py           # reads packaging/appstore/asc-credentials.env
```

Package and ship a submission — no arguments, no secrets:

```sh
scripts/appstore.sh                 # build, sign, audit, .pkg
scripts/appstore.sh --validate
scripts/appstore.sh --upload
scripts/appstore.sh --build-status
```

`appstore.sh` runs `verify-appstore.sh` and refuses to package if it fails, and
`--upload` refuses a `CFBundleVersion` already uploaded before it builds
anything. Bump it in `scripts/Info.plist` for every upload — App Store Connect
rejects a duplicate even when the marketing version is unchanged. Uploading does
not submit for review; the build waits in App Store Connect until a human
submits it.

Both pipelines have to keep working. `scripts/test.sh` runs the suite in both
configurations, and two workflows enforce it: `ci.yml` runs the suite plus the
App Store audit on every push to `main`/`develop` and every pull request, and
`release.yml` runs both again on a tag before it builds anything.
