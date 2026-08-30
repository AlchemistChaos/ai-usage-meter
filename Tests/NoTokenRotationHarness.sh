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

grep -q 'static func freshClaudeCodeToken' "$sources/ClaudeProvider.swift" || {
  echo "FAIL: Claude Code's active read-only token path disappeared" >&2
  exit 1
}

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

grep -q 'case .claude: break' "$sources/AccountManager.swift" || {
  echo "FAIL: importCurrent lost its Claude guard — Claude creds could be imported" >&2
  exit 1
}

grep -q 'Claude switching is off' "$sources/AccountManager.swift" || {
  echo "FAIL: switchTo lost its Claude guard — a profile could overwrite the CLI keychain" >&2
  exit 1
}

echo "PASS: Claude Code path is read-only; only app-owned profiles rotate"
