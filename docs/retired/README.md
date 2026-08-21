# Retired docs

Work that is finished. Nothing here is a to-do list and nothing here is
maintained — each file is a record of what was done and why, kept because the
reasoning outlives the task and re-deriving it is expensive.

**These files are frozen at their date.** Read them for the reasoning, not for
the current state; anything describing how the repo works today lives one level
up in `docs/`.

| File | What it is | Closed |
|---|---|---|
| `credential-gap-2026-08-20.md` | The blocker that build 5 exposed — the App Store build had no viable way for an ordinary user to connect — and the measurement trail that shaped the fix. Closed by the GitHub device flow plus the guided Claude export. Its "one live path" (Tokes doing its own Claude OAuth) and its CIMD probe are **superseded**: Anthropic's 2026-02-19 policy forbids the former regardless of mechanism, and the probe is Cloudflare-blocked and moot. Current mechanism: `../CREDENTIALS.md`. | 2026-08-20 |
| `coverage-report-2026-08-20.md` | Coverage re-measured at `8e04712`, when the suite was 319/316. Superseded by the onboarding work the same day (now 377/374) across files it never saw. **§3.1, the catalogue of llvm-cov's provable false zeros, is still the reference** — it describes the tool, not the commit. | 2026-08-20 |
| `coverage-report-2026-08-19.md` | The submission-baseline coverage audit and the full work log that closed it out — 13 findings, ranked recommendations, three phases of close-out, and four re-measurements. Moved verbatim; its internal path references point at the old flat layout. | 2026-08-20 |
| `appstore-account-setup-2026-08-19.md` | The one-time Mac App Store account setup: App ID, both distribution certificates, the provisioning profile, and the App Store Connect record. None of it recurs. Includes the four App Store Connect API traps that each cost a wrong turn. The live runbook is `../.private/APP-STORE-SUBMISSION.md`. | 2026-08-19 |
