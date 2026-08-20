# Asset standards for the App Store listing

What any asset — screenshot, icon, or word of copy — has to satisfy before it
goes to App Store Connect. Contracts around *how* assets are produced are
negotiable. These are not: they exist so the listing cannot misrepresent the app,
intentionally or by drift.

The engineering agent reviews every asset against this list before pushing, and
will refuse one that fails. That is a gate, not an opinion — expect it.

---

## 1. Screenshots must be the real app

Apple Guideline 2.3.3: screenshots must show the app in use.

- **App pixels come from `scripts/screenshots.sh`**, which compiles the real
  `PopoverView` / `SettingsView` / `StatusItemController`. They are never
  redrawn, retouched, or reconstructed in a design tool.
- The designer owns everything *around* the app: background, framing, headline
  copy, typography, ordering, per-size layout.
- Nobody hand-edits the generated output. A change to the UI is a rerun, not a
  retouch — otherwise the listing silently drifts away from the product.

## 2. Screenshots must depict the App Store build specifically

This is the trap only someone reading the code will catch, and it is the one
most likely to bite us.

The App Store build is sandboxed and **cannot** read Claude Code's or Copilot's
own credential stores — those readers are compiled out. So a screenshot showing
"Use Claude Code sign-in (automatic)" or "Use editor sign-in / gh CLI" would
advertise a capability that build does not have. That is misrepresentation even
though the screenshot came from a real build of Tokes.

`scripts/screenshots.sh` compiles with `-DTOKES_APP_STORE` for exactly this
reason. Any hand-supplied screenshot must be checked against the App Store
build's UI, not the Homebrew build's.

## 3. Sample data must be plausible, synthetic, and impersonal

- No real account usage, no real tokens, no real usernames.
- Deterministic, so a rerun reproduces the image.
- Numbers must be ones the app could actually report. Do not invent a limit type
  Tokes cannot read or a provider it does not support.

## 4. Claims must be ones the app can back

Every sentence in the description is a promise the app has to keep. Current copy
is accurate; keep it that way when it changes.

- ✅ "Collects no data, has no server, transmits nothing to us" — true, and
  verified by the sandbox entitlements: the only network entitlement is outbound
  client, and the only hosts contacted are Anthropic's and GitHub's.
- ✅ "Requires an active Claude subscription and/or Copilot seat" — say this;
  omitting it invites both rejection and refund requests.
- ❌ Anything implying Tokes provides, includes, or resells access to either
  service.
- ❌ Performance, ranking, or superlative claims we have not measured.

## 5. Third-party trademarks

Tokes monitors two services it is not affiliated with. Nominative use is
legitimate; implied endorsement is not.

- **Never** in the app name, subtitle, or keywords — those are the fields Apple
  enforces under Guideline 5.2.1.
- **Never** an Anthropic or GitHub logo, wordmark, or brand colour system in the
  icon or in screenshot chrome.
- **In the description**: allowed, descriptively, alongside the disclaimer that
  Tokes is independent and not endorsed by either company.

## 6. No borrowed authority

No fabricated ratings, awards, review quotes, "Editor's Choice"-style badges,
press logos, or invented user counts. Nothing that implies Apple, Anthropic, or
GitHub endorses the app.

## 7. Provenance

Every asset is original or properly licensed. No stock imagery of people implied
to be users. The icon is generated from `packaging/icon/Tokes.icon` by the design
practice and is never hand-edited.

## 8. Legibility

Text rendered into a screenshot must be readable at the size the store actually
displays it — not merely at full resolution.

---

## Pre-push checklist

Run before any asset reaches App Store Connect:

- [ ] Screenshots regenerated from the current `main`, not carried over
- [ ] Generated with `-DTOKES_APP_STORE`; no automatic-credential source visible
- [ ] Sample data synthetic, plausible, impersonal
- [ ] Every description claim still true of *this* build
- [ ] No third-party mark in name, subtitle, or keywords
- [ ] No logo, badge, award, or rating we did not earn
- [ ] Independence disclaimer present in the description
- [ ] Sizes and count match what App Store Connect requires
- [ ] Copy in `packaging/appstore/listing.md` matches what is being pushed

If any line fails, the asset does not ship until it is fixed. Escalate to the
operator rather than shipping a maybe.
