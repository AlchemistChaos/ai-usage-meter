# CCManager

A macOS menu bar app for juggling multiple Codex and Claude Code subscriptions:
see your usage windows at a glance, and switch accounts in one click.

```bash
./build-app.sh          # builds CCManager.app
open CCManager.app      # menu bar icon appears; no Dock icon
```

The menu bar shows remaining headroom on the tightest window. Clicking opens the
panel: every account with its usage bars, a recommendation for which to use next,
and a Switch button per account.

## Status

| | Codex | Claude Code |
|---|---|---|
| Read account identity (email, plan) | ✅ | ❌ |
| Read usage limits | ✅ | ❌ |
| Switch accounts | ✅ | ❌ |

**Codex works end to end. Claude Code does not yet** — see below.

## How Codex data is obtained

Identity comes from the JWT in `~/.codex/auth.json`, which carries the account
email, `chatgpt_plan_type`, and account id.

Usage comes from the `x-codex-*` response headers that the Codex CLI already
writes into `~/.codex/logs_2.sqlite`:

```
x-codex-primary-used-percent: 18
x-codex-primary-window-minutes: 10080
x-codex-primary-reset-at: 1784958562
x-codex-secondary-used-percent / -window-minutes / -reset-at
x-codex-plan-type: pro
```

Reading these locally costs **no quota and no network request**, which is why the
app harvests them instead of polling an API. Two consequences worth knowing:

- **`/backend-api/codex/usage` and `/rate_limits` both return 403.** There is no
  usable read-only usage endpoint; headers on real calls are the only source.
- **Data is only as fresh as your last Codex call.** Every figure is labelled with
  its age, and a window past its reset time is shown as empty rather than stale.
  On this machine only one such header row existed across 115k log rows — Codex
  records them sparingly and prunes the table, so expect gaps.

### About the "5 hour" window

Your account currently reports **only a weekly window** (10080 minutes, 18% used).
The secondary window is `0` minutes, meaning no 5-hour limit is being enforced on
this Pro plan. The app renders whatever windows the provider reports and labels a
300-minute window as `5h` automatically if one appears — nothing is hardcoded.

## Account switching

Profiles live in `~/.ccmanager/profiles/codex/<name>/auth.json`.

1. Log into an account with `codex login`.
2. In the app: **Import current Codex login…**, give it a name.
3. Repeat per account. Switch from the menu any time.

Switching copies the stored `auth.json` over `~/.codex/auth.json`. Safeguards:

- The current credential is backed up to `~/.ccmanager/backups/codex/` first.
- The write is atomic (temp file + `replaceItemAt`), so an interrupted switch
  cannot leave a truncated credential.
- All credential files are forced to `0600`.

⚠️ **Refresh tokens rotate.** A stored profile is a point-in-time snapshot; if it
sits unused long enough its refresh token may expire, and you'll need to
`codex login` again and re-import. This is inherent to file-based credentials.

## Why Claude Code isn't wired up

Investigated on 2026-07-20:

- Keychain services `Claude Code-credentials`, `-ef2e7502`, and `-f2877ae3` each
  contain **only an `mcpOAuth` object** — MCP server tokens. None hold a
  `claudeAiOauth` block, so there is no subscription token to read or swap.
- `~/.claude/.claude.json` has only `userID` / `machineID` — no account, email, or plan.
- Nothing under `~/.claude` records `anthropic-ratelimit-*` headers, so there is
  no local usage trail equivalent to Codex's.

The app reports this honestly rather than showing invented numbers.
`ClaudeProvider.probe()` already checks both the keychain and
`~/.claude/.credentials.json`; the moment a real credential appears there, wiring
the rest is small. To re-check:

```bash
./CCManager.app/Contents/MacOS/CCManager --diagnose
```

If you log in via `claude` in a terminal and that still reports no OAuth
credential, the Claude desktop app is holding the session in `Claude Safe
Storage`, which is app-encrypted and not readable by third-party apps.

## Layout

| File | Role |
|---|---|
| `App.swift` | `MenuBarExtra` entry point, CLI flags |
| `Models.swift` | `Account`, `UsageWindow`, headroom scoring |
| `CodexProvider.swift` | JWT identity + sqlite header harvesting |
| `ClaudeProvider.swift` | Keychain probe (see status above) |
| `ProfileStore.swift` | Profile storage, atomic switching, backups |
| `SnapshotCache.swift` | Per-account usage history with reset projection |
| `AccountManager.swift` | Refresh loop, recommendation |
| `MenuView.swift` | The panel UI |

## Next

- Notch UI (menu bar was built first deliberately; all logic is UI-independent).
- Claude support, pending a readable credential.
