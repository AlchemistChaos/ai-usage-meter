#!/usr/bin/env bash
# The meter borrows Claude Code's OAuth credentials. Redeeming a refresh token
# rotates it server-side and invalidates whatever else holds that chain — which
# is the live Claude Code CLI session. So the Anthropic path must stay READ-ONLY:
# read the token, use it, and if it is expired wait for the CLI to refresh it.
set -euo pipefail
cd "$(dirname "$0")/.."

sources="Sources/AIMeter"

if grep -RnE '"grant_type"[[:space:]]*:[[:space:]]*"refresh_token"' "$sources"; then
  echo "FAIL: a refresh_token grant exists in $sources — this rotates Claude Code's" >&2
  echo "      refresh token and evicts the live CLI session (see sites above)." >&2
  exit 1
fi

if grep -RnE 'func freshToken\(for' "$sources"; then
  echo "FAIL: ClaudeProvider.freshToken(for:) still exists — it is the rotation path" >&2
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

grep -q 'case .claude: break' "$sources/AccountManager.swift" || {
  echo "FAIL: importCurrent lost its Claude guard — Claude creds could be imported" >&2
  exit 1
}

grep -q 'Claude switching is off' "$sources/AccountManager.swift" || {
  echo "FAIL: switchTo lost its Claude guard — a profile could overwrite the CLI keychain" >&2
  exit 1
}

echo "PASS: Claude path is read-only (no rotation, no import, no activate)"
