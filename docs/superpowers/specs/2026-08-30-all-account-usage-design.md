# All-Account Usage Design

## Goal

AI Meter must show the current subscription-limit usage for every Claude and
Codex account the user has added, at the same time. Adding one account must
never overwrite another account merely because their email addresses share a
prefix or because a different account becomes active in a provider CLI.

Claude remains view-only: AI Meter must not change Claude Code's active login,
write Claude Code's Keychain item, or refresh Claude Code's credential chain.
Codex retains its existing explicit switching behavior, but switching is no
longer required merely to obtain a fresh reading for an inactive account.

## Repository Scope

Implement this only in the independent
`AlchemistChaos/ai-usage-meter` repository. Do not modify
`AlchemistChaos/ai-usage-meter-fork` or `everyai-com/notch-limits`.

The installed application remains `/Applications/AI Meter.app`, with bundle
identifier `com.alchemistchaos.aimeter` and macOS 14 as the minimum supported
version.

## Current Failure

Claude has two distinct concepts that the UI currently blurs together:

1. Claude Code has one active identity in `~/.claude.json` and one live OAuth
   credential chain in the macOS Keychain or `~/.claude/.credentials.json`.
2. AI Meter can retain independent OAuth profiles under
   `~/.ccmanager/profiles/claude/` for accounts that should remain visible
   while inactive in Claude Code.

The current Add Anthropic Account flow stores profiles under the email local
part, such as `river`. Two accounts with the same local part can therefore
overwrite the same file. An account that was only visible because it was
active in Claude Code also disappears when the active Claude Code login
changes, because no AI Meter profile exists for that account.

The current code also treats every stored credential as if it might be a copy
of Claude Code's live refresh-token chain. It consequently refuses to refresh
all stored tokens. That protects Claude Code from refresh-token rotation, but
it also makes independently authorized meter-only profiles expire and require
repeated login.

## Identity and Storage

### Stable identity

Anthropic's account UUID is the canonical Claude profile identity. Email is
display metadata only.

New Claude profiles use this layout:

```text
~/.ccmanager/profiles/claude/<account-uuid>/credentials.json
```

Each profile document contains:

- the existing `claudeAiOauth` token payload;
- `_ccmanagerIdentity.accountUuid`, email, and plan;
- `_ccmanagerAuth.origin`, whose value is either `appOAuth` or `legacy`;
- `_ccmanagerAuth.schemaVersion`, initially `1`.

`appOAuth` means AI Meter obtained that credential from its own complete
authorization-code flow and is the sole local owner of that refresh-token
chain. `legacy` means provenance is unknown, so AI Meter must never redeem its
refresh token automatically.

### Collision behavior

Completing OAuth for an account whose UUID already exists updates that exact
profile atomically. Different UUIDs always produce different directories,
even when emails or email local parts match.

The dashboard displays the full email address, subject to the existing email
blur preference. It must not expose UUIDs in normal UI.

## Legacy Migration

Migration runs before profiles are listed or polled.

For every legacy `profiles/claude/<name>/credentials.json`:

1. Decode `_ccmanagerIdentity.accountUuid`.
2. Back up the original file under `~/.ccmanager/backups/claude/` with a
   timestamp and original directory name.
3. If no UUID destination exists, atomically move the profile there and mark
   its origin `legacy`.
4. If the UUID destination already exists, retain the credential with the
   later access-token expiry and preserve the other credential in backups.
5. Keep unreadable or UUID-less profiles in place and surface a reconnect
   state instead of deleting them.

Migration is idempotent and never deletes the only copy of a credential.
Profile files and backup files remain owner-readable and owner-writable only
(`0600`). Profile directories remain owner-only (`0700`).

## Authentication Boundaries

### Claude Code-owned credential

AI Meter may read Claude Code's active identity and unexpired access token to
show the active account. It must never persist, copy, overwrite, or refresh
that credential. Statusline rate-limit data remains the preferred active
account source.

### AI Meter-owned credential

The Add Anthropic Account flow creates an `appOAuth` profile. AI Meter may
refresh only these profiles. A successful refresh must atomically persist the
rotated access token, refresh token, expiries, and scopes before the new access
token is used for polling.

If a legacy profile expires, AI Meter shows Reconnect for only that account.
Completing reconnect performs a fresh authorization-code flow and upgrades the
profile to `appOAuth` only when the returned account UUID matches the selected
profile. A different account must not overwrite the reconnect target.

## Usage Polling

Every saved Claude profile is polled independently against Anthropic's OAuth
usage endpoint. The active Claude Code account is also represented even when
it has no saved AI Meter profile. Accounts are deduplicated by UUID so an
account present in both sources appears once.

Polling remains limited to at most once per minute per account. Requests may
run concurrently, but one slow account must not block or erase another
account's reading.

Every saved Codex profile is also polled live through the installed official
Codex app-server. AI Meter starts the helper with an isolated `CODEX_HOME`
containing only that profile's credential and calls
`account/rateLimits/read`. This must not replace `~/.codex/auth.json` or alter
the account active in Codex CLI or Codex Desktop.

The normal active Codex account continues to use its existing app-server
path. Account UUID deduplication prevents it appearing twice when the same
account is also saved as a profile. Explicit Codex switching and credential
backups remain available, but are independent from background usage polling.

Claude and Codex polling both use bounded concurrency and account-scoped
one-minute freshness checks so many accounts do not create an unbounded helper
or network burst.

## Error Handling and Honesty

- `401`, `403`, or a rejected refresh grant marks only that account as needing
  reconnect.
- `429`, timeouts, offline errors, and provider failures keep the last known
  reading with a cached/stale timestamp.
- An expired cached window is not shown as current usage.
- A failed account never removes or hides another account.
- An unsuccessful add or reconnect leaves all existing profiles unchanged.
- Diagnostics report profile UUID prefixes, labels, origins, and credential
  freshness without printing tokens or authorization codes.

## UI Behavior

The existing Claude and Codex sections remain. Every account gets its own card
showing email, plan, available usage windows, reset time, freshness, and active
status where applicable.

Claude cards are informational only. Clicking an inactive Claude card may show
details or a reconnect action, but never switches Claude Code. The Add
Anthropic Account action remains available for enrolling another account.

The menu-bar aggregate continues to use only the active account for each
provider. The expanded panel is the place where all account readings appear
simultaneously.

## Components

- `ClaudeProfileStore.swift` owns UUID paths, schema decoding, atomic writes,
  backups, and legacy migration.
- `ClaudeProvider.swift` owns token decoding, provider requests, and the strict
  read-only boundary around Claude Code credentials.
- `ClaudeOAuth.swift` owns authorization-code exchange and refresh for
  `appOAuth` profiles.
- `AccountManager.swift` orchestrates account discovery, UUID deduplication,
  independent polling, and account-scoped errors.
- `CodexRateLimitClient.swift` accepts an optional isolated `CODEX_HOME` and
  returns the account identity alongside the rate-limit snapshot so results
  cannot be attributed to the wrong profile.
- `GlassDashboardView.swift` presents all accounts and account-scoped
  reconnect actions without Claude switching.

The new profile-store responsibility is separated from the existing generic
`ProfileStore`, whose credential activation behavior remains Codex-only.

## Testing

Automated coverage must prove:

1. Two emails with the same local part but different UUIDs produce different
   profile paths and remain visible together.
2. Re-adding the same UUID updates one profile rather than creating a
   duplicate.
3. Legacy migration is idempotent, preserves backups, and resolves duplicate
   UUID profiles without losing the only credential copy.
4. AI Meter refreshes `appOAuth` profiles and atomically persists rotated
   tokens.
5. AI Meter never refreshes, imports, activates, or writes Claude Code-owned
   credentials.
6. Reconnect refuses to overwrite a profile when OAuth returns a different
   UUID.
7. One account's authentication or transient failure does not hide or poison
   any other account.
8. The active Claude Code account and a matching saved profile deduplicate to
   one card.
9. Every saved Codex profile is polled through its isolated `CODEX_HOME`, and
   polling never changes the live `~/.codex/auth.json` credential.
10. A helper response whose account ID does not match the requested Codex
    profile is discarded rather than misattributed.
11. Existing Codex switching, backup, menu-bar, privacy, and native-glass tests
    remain green.
12. An installed-build smoke test confirms all enrolled Claude and Codex
    accounts render in the expanded menu panel.

## Non-goals

- Switching Claude Code accounts from AI Meter.
- Discovering accounts that the user has never authorized in AI Meter and that
  are not currently active in Claude Code.
- Browser-cookie scraping.
- A hosted backend or cross-device credential synchronization.
- Changing provider subscription limits or inventing missing reset times.
- Modifying the old fork or upstream Notch Limits repository.
