#!/usr/bin/env bash
# Claude Code's OAuth chain stays read-only. AI Meter may rotate only a token
# created by its own independent browser authorization flow and explicitly
# marked appOAuth.
set -euo pipefail
cd "$(dirname "$0")/.."

sources="Sources/AIMeter"

if grep -RnE '"grant_type"[[:space:]]*:[[:space:]]*"refresh_token"' \
    "$sources" --exclude='ClaudeOAuth.swift'; then
  echo "FAIL: refresh_token grants must be isolated to ClaudeOAuth.swift" >&2
  exit 1
fi

grep -q 'record.origin == .appOAuth' "$sources/ClaudeProvider.swift" || {
  echo "FAIL: stored Claude refresh is not guarded by appOAuth provenance" >&2
  exit 1
}

# AI Meter must not READ Claude Code's credential either. A borrowed token has
# no account attached: on 2026-09-29 Claude Code's keychain login was
# river@ultima.inc while ~/.claude.json said riverscreation, so river@ultima's
# 99% weekly usage was shown on riverscreation's card. Reading it also hung
# the poll on a keychain access dialog. Claude Code's usage reaches the meter
# only through the per-account statusline readings.
if grep -RnE 'Claude Code-credentials|\.credentials\.json|SecItemCopyMatching' "$sources"; then
  echo "FAIL: AI Meter reads Claude Code's credential (sites above)" >&2
  exit 1
fi

# Guard against over-deletion: the login flow legitimately exchanges an auth code.
grep -qRE '"grant_type"[[:space:]]*:[[:space:]]*"authorization_code"' "$sources/ClaudeOAuth.swift" || {
  echo "FAIL: ClaudeOAuth lost its authorization_code exchange — login is broken" >&2
  exit 1
}

# The meter must never WRITE Claude credentials either. Importing copies the CLI's
# live credential file into a profile (creating a shared token chain), and activating
# copies a profile back over it. Both must stay Codex-only.
if grep -RnE 'importActive\(\.claude|importCredential\(\s*\.claude|activate\(\.claude' "$sources"; then
  echo "FAIL: a Claude import/activate call exists — this creates or overwrites a" >&2
  echo "      shared token chain with the Claude Code CLI (see sites above)." >&2
  exit 1
fi

# Stronger than a per-provider guard: no import-current or switch path exists
# at all, so no profile can share a login (or keychain entry) with a CLI.
if grep -qE 'func importCurrent|func switchTo|ProfileStore\.(importActive|activate)\(' "$sources/AccountManager.swift"; then
  echo "FAIL: an import-current or switch path exists — it would share a login with the CLI" >&2
  exit 1
fi

echo "PASS: Claude Code path is read-only; only app-owned profiles rotate"
