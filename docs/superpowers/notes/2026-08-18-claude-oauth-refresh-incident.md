# 2026-08-18 Claude OAuth refresh / stale meter incident

## Symptom

AI Meter showed the active Claude account (`riverthenft@gmail.com`) as `100%`
remaining, then later showed `Claude OAuth refresh was rejected: Refresh token
expired`. Other Claude accounts briefly showed generic `NSURLErrorDomain`
failures.

## Root cause

- AI Meter polls Claude usage with per-profile OAuth credentials stored under
  `~/.ccmanager/profiles/claude/<profile>/credentials.json`.
- A normal Claude Code login updates Claude's active identity in
  `~/.claude.json`, but does not necessarily refresh AI Meter's stored
  per-profile token.
- Anthropic's old token endpoint
  `https://console.anthropic.com/v1/oauth/token` began returning Cloudflare
  `403 / Error 1010 browser_signature_banned` for app-side OAuth refresh.
- The working token endpoint is now
  `https://api.anthropic.com/v1/oauth/token`.
- My first pass overclassified all Claude polling failures as account auth
  failures. Anthropic `429 rate_limit_error` on the usage endpoint is transient
  and must keep showing cached account data; only `401`/`403` auth failures and
  OAuth refresh rejection should suppress stale windows.

## Fix implemented

- `ClaudeProvider.freshToken` refreshes via
  `https://api.anthropic.com/v1/oauth/token`.
- `ClaudeOAuth.exchange` uses the same API token endpoint for Add Anthropic
  account.
- `ClaudeProvider.decodeUsageResponse` classifies:
  - `401` / `403` as authentication failures.
  - `429` as transient rate limiting.
  - other non-200 responses as provider request failures.
- `AccountManager` tracks Claude auth failures by account UUID and suppresses
  stale cached windows only for auth failures.
- Transient/rate-limit failures no longer poison accounts or hide cached data.
- Claude login diagnostics are written to `~/.ccmanager/claude-login.log`
  without tokens or auth codes. The log records phases such as `begin`,
  `callback received`, `exchange ok`, `profile ok`, `save ok`, or failure text.

## Operational recovery

If a single Claude account remains stuck on refresh-token-expired:

1. Use AI Meter → Settings → Add Anthropic account.
2. Choose the browser session signed into that exact Anthropic account.
3. Complete the browser OAuth flow.
4. Confirm `~/.ccmanager/profiles/claude/<profile>/credentials.json` has a new
   modification time and future `claudeAiOauth.expiresAt`.

Do not assume `claude login` alone repairs AI Meter. The app stores independent
per-profile OAuth credentials so it can poll multiple Claude accounts.

## Regression coverage

- `Tests/ClaudeAuthStructureHarness.sh` ensures the blocked
  `console.anthropic.com/v1/oauth/token` endpoint is not used for token exchange
  or refresh, and that per-account auth-failure tracking exists.
- `Tests/ClaudeProviderHarness.swift` verifies usage parsing and distinguishes
  transient `429` responses from auth failures.
- `Tests/AccountPresentationHarness.swift` verifies error-status accounts render
  `—` instead of stale cached menu values.

## Fold-back notes

- Keep OAuth refresh and usage-polling errors semantically distinct.
- Never clear or suppress a profile's last known usage on transient provider
  failures.
- If Add Anthropic account appears to do nothing, inspect
  `~/.ccmanager/claude-login.log` before changing endpoints or client IDs.
