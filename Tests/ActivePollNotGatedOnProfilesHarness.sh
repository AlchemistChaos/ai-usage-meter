#!/usr/bin/env bash
# The active Claude Code account is discovered from Claude Code itself (identity
# + statusline + keychain), not from a saved ccmanager profile. Gating the whole
# poll on listProfiles() being non-empty means a user with no saved profiles —
# including every fresh install — never polls Claude at all.
set -euo pipefail
cd "$(dirname "$0")/.."

manager="Sources/AIMeter/AccountManager.swift"

if grep -qE 'guard !profiles\.isEmpty else \{ return \}' "$manager"; then
  echo "FAIL: Claude poll bails whenever there are no saved profiles, so the active" >&2
  echo "      CLI account is never polled (statusline and keychain paths unreachable)." >&2
  exit 1
fi

grep -qE 'guard !profiles\.isEmpty \|\| ClaudeProvider\.identity\(\) != nil else \{ return \}' "$manager" || {
  echo "FAIL: the poll guard does not admit an active identity with zero profiles" >&2
  exit 1
}

echo "PASS: active account is polled even with no saved profiles"
