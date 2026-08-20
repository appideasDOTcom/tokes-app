# App Store listing copy

For `com.appideas.tokes`. The store title is **Dev Tokes** (plain "Tokes" was
already taken); the app calls itself **Tokes** everywhere else, which is normal —
`CFBundleDisplayName` stays `Tokes`.

All copy below describes the **App Store build specifically**. It does not
promise reading Claude Code's keychain, because that build cannot do it. Copy
that oversells a sandboxed build is a metadata rejection *and* a support burden.

---

## Name (30 max)

```
Dev Tokes
```

## Subtitle (30 max)

```
Menu bar AI usage monitor
```

> **Deliberately brand-free.** "Claude & Copilot usage limits" fits in 29
> characters and would convert better, but third-party trademarks in the
> **name, subtitle and keywords** are a live rejection risk under Guideline
> 5.2.1 — those fields are where Apple actually enforces it. Naming the services
> in the *description* is nominative use and is standard practice. If you'd
> rather take the risk for discoverability, the brand subtitle is the swap.

## Keywords (100 max, comma-separated, no spaces)

```
usage,quota,limits,menubar,ai,llm,developer,tokens,monitor,rate,api,coding,assistant,statusbar
```

> Same reasoning: no brand names. Adding `claude,copilot,anthropic,github` would
> help search a great deal and is the single highest-risk field in the listing.

## Promotional text (170 max)

Editable any time **without** a review cycle — the right place for temporary notes.

```
Watch your Claude and GitHub Copilot usage limits from the menu bar, with local history charts. Free, open source, no account, no telemetry.
```

## Description (4000 max)

```
Tokes is a tiny menu bar app that shows how much of your AI coding plan you have
left — at a glance, without opening anything.

WHAT IT SHOWS

• Claude session (5 hour), weekly (7 day), and model-scoped weekly limits
• GitHub Copilot premium requests — credits used against your monthly allowance
• A three-bar menu bar icon that fills bottom-up and turns orange past 60% and
  red past 85%, so a limit running hot is visible without looking twice
• An optional percentage next to the icon: the highest limit, or one you pick

HOVER FOR DETAIL

Move the pointer over the icon and a panel drops down with a chart per limit,
the current percentage, and a reset countdown. Click to pin it open.

HISTORY THE API DOESN'T KEEP

The usage endpoints report only the current instant — no history at all. Tokes
records a sample on every refresh and keeps eight days locally, so you get a
trend line instead of a single number. Nothing leaves your Mac.

CONNECTING IT

Tokes reads your own usage from your own account, using a credential you supply:

• Paste an OAuth token in Settings — stored in your keychain, nowhere else
• Or import a credentials file you pick yourself in a file panel. Tokes re-reads
  it on each refresh, so a rotated token keeps working

Requires an active Claude subscription and/or GitHub Copilot seat. Tokes does not
provide, resell, or include either service.

PRIVACY

There is no account, no analytics, no telemetry, and no server. Credentials live
in your keychain; usage history lives in the app's own container on your Mac.
Tokes talks to Anthropic and GitHub, and to nobody else — including us.

OPEN SOURCE

Tokes is free and always will be, and the complete source is public. Read exactly
what it does, or build it yourself:
https://github.com/appideasDOTcom/tokes-app

Tokes is an independent project. It is not affiliated with, endorsed by, or
sponsored by Anthropic or GitHub. "Claude" and "GitHub Copilot" are trademarks of
their respective owners and are used here only to describe what Tokes monitors.
```

## Support / marketing URLs

| Field | Value |
|---|---|
| Support URL | `https://appideas.com/tokes/` |
| Marketing URL | `https://appideas.com/tokes/` |
| Privacy policy URL | `https://appideas.com/privacy-policy/` |

## Category, pricing, privacy

- Primary category: **Developer Tools** (matches `LSApplicationCategoryType`)
- Price: **Free**, no in-app purchases
- App Privacy: **Data Not Collected** — every category answered "No"
- Age rating: 4+
- Export compliance: no prompt (`ITSAppUsesNonExemptEncryption=false` is in the plist)

## Screenshots

`scripts/screenshots.sh` → `build/appstore/screenshots/` at 2880×1800:

1. `01-menu-bar-and-popover.png` — the icon in the menu bar with its popover open
2. `02-usage-history.png` — the charts, larger
3. `03-settings.png` — Settings as the **App Store build** presents it

Synthetic, deterministic data — no real account usage is published, and re-running
reproduces the same images.
