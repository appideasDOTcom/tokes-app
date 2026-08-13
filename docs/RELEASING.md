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
