# App Store packaging

Everything specific to the Mac App Store build lives here.

- `Tokes.entitlements` — the entire sandbox declaration. Three keys, no
  temporary exceptions. If a change needs a fourth, that is a design decision,
  not a build tweak: see `docs/APP-STORE-COMPLIANCE.md`.
- `embedded.provisionprofile` — **not in git.** Download the Mac App Store
  distribution profile from the Apple Developer portal and drop it here;
  `scripts/appstore.sh` embeds it into the bundle.

Build and audit locally without any of Apple's certificates:

```sh
scripts/build.sh --app-store          # ad-hoc signed, really sandboxed
scripts/verify-appstore.sh            # static + runtime compliance audit
```
