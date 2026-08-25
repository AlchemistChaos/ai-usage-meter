#!/usr/bin/env bash
set -euo pipefail

provider="Sources/AIMeter/ClaudeProvider.swift"
oauth="Sources/AIMeter/ClaudeOAuth.swift"
manager="Sources/AIMeter/AccountManager.swift"

for file in "$provider" "$oauth"; do
  if rg -q 'https://console\.anthropic\.com/v1/oauth/token' "$file"; then
    echo "FAIL: $file still uses the Cloudflare-blocked console OAuth token endpoint" >&2
    exit 1
  fi
done

# NOTE: ClaudeProvider deliberately no longer refreshes tokens at all. It borrows
# Claude Code's credentials, and redeeming a refresh token rotates it server-side,
# evicting the live CLI session. See Tests/NoTokenRotationHarness.sh, which asserts
# the absence of that path. Only the login flow (ClaudeOAuth) talks to the token
# endpoint now, exchanging an authorization_code.

rg -q 'https://api\.anthropic\.com/v1/oauth/token' "$oauth" || {
  echo "FAIL: ClaudeOAuth does not exchange login codes through api.anthropic.com" >&2
  exit 1
}

rg -q 'claudeProfileErrorsByUUID' "$manager" || {
  echo "FAIL: AccountManager does not track Claude auth failures per account" >&2
  exit 1
}

rg -q 'claudeProfileErrorsByUUID\[uuid\]' "$manager" || {
  echo "FAIL: Claude account construction does not suppress stale windows for failed profiles" >&2
  exit 1
}

echo "PASS: Claude auth endpoint and stale failure handling"
