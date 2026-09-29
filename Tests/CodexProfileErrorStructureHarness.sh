#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

manager="Sources/AIMeter/AccountManager.swift"
rg -q 'codexProfileErrorsByAccountID' "$manager" || {
  echo "FAIL: inactive Codex authentication failures are not account-scoped" >&2
  exit 1
}
rg -q 'codexProfileErrorsByAccountID\[accountID\]' "$manager" || {
  echo "FAIL: inactive Codex polling does not record its account error" >&2
  exit 1
}
rg -q 'reconnectRequired.*cachedAt' "$manager" || {
  echo "FAIL: failed Codex profiles do not preserve cached context with reconnect copy" >&2
  exit 1
}
rg -q 'CodexProvider\.savedProfileError\(' "$manager" || {
  echo "FAIL: Codex cards read saved-profile errors without ignoring the active account" >&2
  exit 1
}
rg -q 'codexProfileErrorsByAccountID\[requestedAccountID\] = nil' "$manager" || {
  echo "FAIL: a successful active Codex poll does not clear that account's old error" >&2
  exit 1
}
rg -q 'CodexRateLimitClient\.savedProfileFailure\(error\)' "$manager" || {
  echo "FAIL: every saved-profile Codex failure is still labelled an expired login" >&2
  exit 1
}
echo "PASS: inactive Codex failures are visible and account-scoped"
