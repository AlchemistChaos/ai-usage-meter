# Claude Account-Scoped Reconnect Design

## Goal

Make AI Meter clearly distinguish Claude Code's active account from saved
inactive Claude profiles. An expired inactive profile must never make the
active Claude meter look disconnected.

## Current failure

AI Meter has two different meanings of "connected":

- Claude Code has one active account, identified by `~/.claude.json`.
- AI Meter retains independent OAuth profiles so it can poll additional Claude
  accounts in the background.

The app currently combines polling errors from those saved profiles into a
global Claude banner. This makes a working active account and valid menu-bar
numbers appear broken when an unrelated inactive profile expires.

The active-account fallback has a separate credential-selection defect. It
queries the macOS keychain by service name with `kSecMatchLimitOne`, even when
multiple `Claude Code-credentials` entries exist. That can return an older,
revoked credential instead of the current macOS user's credential.

## Account presentation

The Claude account matching Claude Code's current account UUID remains the
only Claude account used for menu-bar values. Its card must visibly say
`Active in Claude Code` and display its email subject to the existing email
blur preference.

Inactive accounts remain visible. If an inactive account's AI Meter credential
can no longer authenticate, its card shows account-scoped expired-connection
copy and one action: `Reconnect`. There is no `Remove` action and the profile is
not automatically deleted.

An expired inactive profile does not contribute a global error. The global
Claude error surface is reserved for a failure that prevents the active Claude
account from producing a usable live or cached reading, or for a provider-wide
failure that leaves no Claude account usable.

## Exact reconnect behavior

Selecting `Reconnect` starts the existing browser OAuth flow with the selected
profile's name, account UUID, and email retained as the reconnect target.

After OAuth completes, AI Meter compares the returned account UUID with the
target UUID:

- If they match, the fresh credential overwrites that profile, its
  account-scoped error clears, and Claude polling runs immediately.
- If they do not match, AI Meter does not overwrite either profile. It reports
  that the browser authenticated a different email and asks the user to retry
  with the intended account.

The ordinary `Add Anthropic account` flow remains untargeted and may create or
update the profile derived from the authenticated email.

Only one Claude OAuth operation may be pending at a time. Cancelling it clears
both the pending login and any reconnect target.

## Active Claude credential selection

The statusline snapshot remains the preferred active-account source.

If no usable statusline snapshot exists, AI Meter reads all keychain entries
whose service is `Claude Code-credentials`. It prefers a decodable,
non-expired credential whose keychain account equals the current macOS user.
If that exact entry is unavailable, it chooses the newest decodable,
non-expired matching entry. It must not return an expired first match merely
because keychain enumeration order placed it first.

The file credential at `~/.claude/.credentials.json` remains the final
fallback.

## OAuth lifetime and protocol fidelity

AI Meter records both access-token expiry and refresh-token expiry returned by
Anthropic. Refresh-token expiry is account metadata used for accurate status
and diagnostics; it is not presented as an access-token failure.

Refresh requests include the profile's stored scopes and preserve rotated
refresh tokens and updated expiry metadata atomically. The authorization and
token endpoints, scopes, and response fields must match the installed Claude
Code OAuth contract rather than silently omitting fields Claude Code uses.

An access token reaching its normal expiry must continue to refresh silently.
Only an unavailable or rejected refresh grant puts a saved profile into the
reconnect-required state.

## Error routing

Polling results are classified by account UUID:

- Successful active or inactive polling clears that account's prior error.
- Authentication failure marks only that profile as reconnect-required.
- Rate limits and transient network/provider failures retain the last known
  reading and do not become reconnect prompts.
- Inactive profile failures do not enter the global banner.
- An active-account failure enters the global banner only when the active
  account has no usable statusline, credential, or cached reading.

The menu bar continues showing the active Claude values whenever the active
account remains usable, regardless of inactive profile state.

## Tests

Regression coverage must prove:

1. An expired inactive profile does not populate the global Claude error.
2. The inactive profile remains visible with reconnect-required status.
3. Reconnect is bound to the selected account UUID and rejects a different
   authenticated account without overwriting either profile.
4. Cancelling OAuth clears the reconnect target.
5. Keychain candidate selection prefers the current macOS user's live
   credential over an expired duplicate and otherwise selects the newest live
   candidate.
6. Access and refresh expiry metadata and scopes survive OAuth exchange and
   refresh persistence.
7. Existing statusline merging, cached-window projection, active menu-label,
   rate-limit classification, and account-presentation tests continue to pass.

## Non-goals

- Automatically deleting expired profiles.
- Adding a profile removal action.
- Switching Claude Code's active account from AI Meter.
- Hiding inactive accounts.
- Claiming that Anthropic refresh grants never require reauthorization.
- Changing Codex account behavior or menu-bar values.
