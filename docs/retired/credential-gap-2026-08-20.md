# RETIRED — The App Store build cannot be connected by a normal user

> **Closed 2026-08-20.** This documents a blocker that no longer exists, kept
> for the reasoning that shaped the fix. **For how connecting actually works
> today, read `../CREDENTIALS.md`** — it carries the current mechanism and the
> still-live "do not re-propose" list. Nothing in this file is a to-do.
>
> What closed it: a GitHub App device-flow sign-in for Copilot
> (`CopilotCredentialSource.githubApp`) and a guided user-run export plus
> optional SessionStart hook for Claude (`ClaudeCodeExport`). Both landed and
> shipped in build 6, and both were verified live by the operator.
>
> Two things below are **superseded and wrong to act on now**: the "one live
> path" section proposes Tokes doing its own Claude OAuth, which Anthropic's
> 2026-02-19 policy forbids regardless of whether it works mechanically; and
> the CIMD probe it names as "the first action for the next session" was
> attempted and is blocked by a Cloudflare challenge, browser-only, and moot
> for the same policy reason.

The analysis below stands as the record of why the design is shaped this way.
The dead ends remain dead — do not re-propose them.

## The failure, exactly

`SettingsView → Claude Connection → Credentials` offers two sources in the App
Store build (`CredentialSource.available == [importedFile, manual]`):

1. **Import a Claude Code credentials file** — the default. Its help text says
   *"normally `~/.claude/.credentials.json`"*. **On a current Claude Code install
   that file does not exist**: credentials live in the login keychain under
   service `Claude Code-credentials`. Confirmed on this machine.
2. **Manual OAuth token** — the only remaining option. Getting the token requires
   running `security find-generic-password -s "Claude Code-credentials" -w` in a
   terminal and parsing JSON. Then it **expires in about 1.5 hours** and there is
   no refresh path, so the user does it again. And again.

The automatic keychain read that would make this work is **compiled out** of this
flavor by `-DTOKES_APP_STORE`, and must stay that way — Guideline 2.5.2 forbids
reading another app's credential store. See `docs/APP-STORE-COMPLIANCE.md`.

So the shipped App Store build has **no viable connection path**. Not a clumsy
one — none.

## Four dead ends, each eliminated by measurement. Do not re-propose them.

- **Read Claude Code's keychain item.** Forbidden by 2.5.2. The sandbox kernel
  *permits* it, which is why this looks available and is not — that gap is the
  entire subject of `docs/APP-STORE-COMPLIANCE.md`.
- **Ship or hand over a credentials file.** The import path re-reads the file
  every poll, and the Homebrew build survives only because *Claude Code* keeps
  rewriting it. A user whose Claude Code uses the keychain has no such file, and
  a static copy expires exactly like a pasted token.
- **Paste an OAuth access token.** Measured against a live `max` subscription:
  access token **1.5 h** remaining, refresh token **5.4 h**. This is the current
  shipping answer and it is why the app is unusable.
- **A demo / sample-data mode.** Built 2026-08-20, shipped in build 5, and
  **deliberately removed from the source the same day** on the operator's
  instruction. It worked, and that was the problem: it removed *App Review's*
  dependency on a credential while leaving real users with no way to connect,
  which disguised this blocker as solved and moved 1.4.2 closer to submission.
  It will look like an obvious idea again — it is not one until users have a
  connection path. Do not rebuild it as a way around this document.

## The one live path: Tokes does its own OAuth sign-in

**Refresh tokens rotate and renew indefinitely.** The token response carries
`refresh_token_expires_in`, and Claude Code emits `oauth_401_recovered_from_rotation`
— so 5.4 h is a *deadline to refresh by*, not a credential lifetime. A client
polling every minute never approaches it. Nothing in `Sources/` implements this:
`grep -rn "refresh_token" Sources/` returns nothing.

The blocker is **identity, not mechanism**:

- Anthropic publishes no `/.well-known/oauth-authorization-server` on
  `api.anthropic.com`, `claude.ai`, or `console.anthropic.com` (all 404), so
  there is no dynamic client registration.
- `https://claude.ai/oauth/claude-code-client-metadata` returns a **Client ID
  Metadata Document** for Claude Code: `token_endpoint_auth_method: none`,
  PKCE, `redirect_uris` of `http://localhost/callback` and `http://127.0.0.1/callback`.
- Borrowing **that** `client_id` would make the consent screen read **"Claude
  Code"** inside an app named Dev Tokes. That misrepresents the app to the user,
  collapses both grants into one revocable entry, and Anthropic can constrain it
  at any time. Rejected — not a technical objection, an honesty one.

### First action for the next session

`client_id` being a *URL* is the CIMD pattern, which exists precisely so third
parties need no registration endpoint. **Whether Anthropic's authorize endpoint
resolves an arbitrary CIMD URL is untested and decides everything.** One
unauthenticated GET (nothing is authorized by loading it):

```
https://claude.ai/oauth/authorize?response_type=code
  &client_id=https%3A%2F%2Fappideas.com%2Ftokes%2Foauth-client-metadata
  &redirect_uri=http%3A%2F%2F127.0.0.1%2Fcallback
  &code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
  &code_challenge_method=S256&scope=user%3Aprofile&state=probe
```

- **an error about *fetching* the metadata document** → generic CIMD support.
  APPideas hosts a JSON document at that URL naming the client **"Dev Tokes"**,
  Tokes implements auth-code + PKCE with a loopback listener, and the result is
  a permanent, mouse-clicks-only sign-in on an **independent** token chain — no
  conflict with Claude Code, no terminal, no re-pasting. This closes the blocker.
- **`invalid_client` / unknown client** → hardcoded allowlist. Then there is no
  sanctioned OAuth path at all, and the product question becomes whether the App
  Store flavor is viable in its current form. Escalate to the operator rather
  than shipping the paste-a-token experience.

Note the scopes a Claude Code credential currently carries, for reference:
`user:profile`, `user:inference`, `user:sessions:claude_code`, `user:mcp_servers`,
`user:file_upload`. Tokes needs only enough to read `/api/oauth/usage`.

## Rotation caveat, if refresh is implemented on a *pasted* credential

Rotation means two clients cannot share one chain — whoever refreshes last wins.
A user running both Claude Code and Tokes on the same refresh token would knock
each other's session out, and the App Store build cannot write back to Claude
Code's keychain item to heal it. An independent chain from Tokes' own sign-in
does not have this problem, which is another reason to prefer it over
"paste your refresh token".

## What is already correct and should not be redone

- The flavor split and everything in `docs/APP-STORE-COMPLIANCE.md`.
- Store listing, screenshots, privacy policy URL, age rating, App Privacy.
- Build 5 is uploaded and audits 32/0. It is fine as a *TestFlight* artifact for
  exercising the UI, but **its behaviour no longer matches the tree** — it
  contains the removed demo mode. Not fit to submit for review.
- The review notes in `docs/.private/APP-STORE-SUBMISSION.md` are restored to their
  token-based form and marked BLOCKED. The mechanism they describe is accurate;
  they cannot be finalised until there is a connection path worth documenting.
