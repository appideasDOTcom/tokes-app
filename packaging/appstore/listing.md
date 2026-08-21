# App Store listing copy

For `com.appideas.tokes`. The store title is **Dev Tokes** (plain "Tokes" was
already taken); the app calls itself **Tokes** everywhere else, which is normal —
`CFBundleDisplayName` stays `Tokes`.

All copy below describes the **App Store build specifically**. It does not
promise reading Claude Code's keychain, because that build cannot do it. Copy
that oversells a sandboxed build is a metadata rejection *and* a support burden.

---

> **The description below is newer than what is live.** The CONNECTING IT
> section was rewritten 2026-08-20 for build 6's sign-in and guided export; the
> pushed copy still describes only "paste a token / import a file". Push it with
> `scripts/appstore-metadata.py` before submitting — the live text undersells
> the app and, worse, tells users to do something that is no longer the primary
> path. Pushing metadata is not submitting.

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

Editable any time **without** a review cycle — the right place for temporary notes,
and the cheapest field in the listing to retreat from if App Review ever objects.

> **Two naming rules, both learned the expensive way — do not "tighten" past them.**
> The limits are **Claude account plan** limits (session 5 hr, weekly 7 day,
> model-scoped weekly), consumed by claude.ai and the Claude apps as much as by
> Claude Code. Never call them *Claude Code* limits: in this product "Claude Code"
> names a **credential source only**, and that path is compiled out of the App Store
> build entirely. And it is always **GitHub Copilot**, never bare *Copilot* —
> shortening it for character count undercuts the non-affiliation paragraph, which
> quotes "GitHub Copilot" as the trademark it disclaims.

```
Open source — you can read the code that reads your usage. Claude and GitHub Copilot limits in the menu bar, plus local history the API doesn't keep.
```

## Description (4000 max)

```
Tokes is a tiny menu bar app that shows how much of your AI coding plan you have
left — at a glance, without opening anything. If you check your AI tokens incessantly
like we do, Tokes will save you a few hundred clicks a day.

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

Tokes reads your own usage from your own account, and nothing else:

• GitHub Copilot: sign in with GitHub, in the app. Tokes asks for one read-only
  permission — your plan's billing usage — and keeps itself signed in
• Claude: Settings walks you through exporting your existing Claude Code login
  to a file and picking it, with an optional one-line addition to Claude Code
  that keeps that file current
• Or paste a token yourself, for either service — stored in your keychain

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

**What actually ships are six frames authored by `appideas-designer`**, uploaded
2026-08-20 and verified `COMPLETE`. Their path and the pull-don't-write rule are
in `screenshots-source.txt`; upload with `scripts/appstore-screenshots.py`.

| | Caption |
|---|---|
| `01-menu-bar.png` | Know before you're cut off |
| `02-panel.png` | Every limit, and when it resets |
| `03-history.png` | History the endpoints don't keep |
| `04-both-sources.png` | Claude and GitHub Copilot, in one place |
| `05-connect.png` | Your credential stays yours |
| `06-open-source.png` | Open source |

All 2880×1800, **no alpha** (App Store Connect rejects a macOS screenshot that
carries one, with an error that never says so), one locale, filename order =
display order.

**One fixture across all six** — session 88 resetting in 1h 12m, weekly 46,
Weekly Fable 62, Copilot 57 — because figures that change between screenshots
read as mocked up. Re-rendering any capture on different values means rebuilding
the whole set, not one frame.

The frames deliberately show a **configured** app, including a percentage beside
the menu bar icon, which needs `Show in menu bar: Highest value` rather than the
`.off` default. Review notes must therefore present the percentage as *optional*
— not as something that appears by itself, and not as something that doesn't
exist.

### The two generators

- `scripts/screenshots.sh --states` → `build/appstore/states/` — the raw
  material the designer composites from: every app state, light and dark, no
  canvas or copy. **Keeps its alpha channel deliberately**; flattening happens
  in their composite, not here.
- `scripts/screenshots.sh` → `build/appstore/screenshots/` — three
  self-contained frames with headline copy, written before the design pass.
  **Superseded, and not submittable as-is**: its output carries an alpha channel
  and would be rejected. Kept as a fallback that would need flattening first.

Both drive the real `StatusItemController`, `PopoverView` and `SettingsView`
compiled with `-DTOKES_APP_STORE`, on synthetic data with no RNG, so no real
account usage is published. `now` is captured once per run, so every frame in a
run shares one clock; re-running on a different day shifts the chart's weekday
axis labels, so capture a set in one run rather than mixing between runs.
