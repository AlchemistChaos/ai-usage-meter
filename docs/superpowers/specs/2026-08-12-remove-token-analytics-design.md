# Remove Token Analytics Design

**Date:** 2026-08-12

## Goal

Return AI Meter to its core job: display provider-reported Claude and Codex
subscription-limit utilization and reset times. Remove all transcript-derived and
local-event-derived token history, attribution, and API-equivalent value analytics.

## Retained Limit Sources

- Claude limits continue to come from the authenticated Anthropic OAuth usage
  response handled by `ClaudeProvider`.
- Active Codex limits continue to come from the installed Codex client's
  `account/rateLimits/read` response handled by `CodexRateLimitClient`.
- Codex rate-limit headers already present in `~/.codex/logs_2.sqlite` remain a
  fallback for last-known readings. This fallback reads limit metadata, not token
  history.
- `SnapshotCache`, reset projection, account profiles, OAuth/login, account
  switching, status-item metrics, and provider error reporting remain.

## Removed Analytics

- Claude transcript enumeration and parsing.
- Codex SSE token-event importing.
- Usage-event SQLite ledger and import checkpoints.
- Active-account attribution timeline.
- Today, 24-hour, 7-day, monthly, and yearly token aggregates.
- API-equivalent dollar estimates and plan-value calculations.
- History views, buttons, models, diagnostics, tests, and documentation.

Historical implementation plans remain in git history but are removed from the
working tree so they do not describe a supported product feature.

## Refresh Behavior

`AccountManager` runs one refresh cycle at launch and every 60 seconds. Each cycle
rebuilds account presentation from cached provider snapshots and attempts a fresh
Claude and active-Codex limit reading when that provider has not been polled in the
last 60 seconds. Existing in-flight guards prevent overlapping work. A provider
failure preserves the last valid snapshot and surfaces the existing error state.

Manual refresh, completed login, and account switching continue to bypass stale
state where the existing flow already resets the provider poll timestamp.

## Local Data

The app stops opening or writing `usage.sqlite` and `account-timeline.sqlite`.
This change does not automatically delete previously collected files from a
user's disk; they become inert. Automatic deletion is intentionally excluded to
avoid destructive migration code for data that no longer affects runtime cost.

## Verification

- Structure tests prove no production source references transcript importers,
  token analytics, usage history, or the analytics databases.
- Existing provider parsing, live polling, status-item, presentation, login, and
  dashboard tests continue to pass.
- A release build succeeds.
- Runtime sampling confirms AI Meter no longer opens files under
  `~/.claude/projects` and remains idle between provider refreshes.

