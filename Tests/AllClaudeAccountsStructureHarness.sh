#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

manager="Sources/AIMeter/AccountManager.swift"
provider="Sources/AIMeter/ClaudeProvider.swift"
store="Sources/AIMeter/ClaudeProfileStore.swift"

if rg -q 'split\(separator: "@"\)' "$manager" "$provider" "$store"; then
  echo "FAIL: Claude profile identity still derives from an email prefix" >&2
  exit 1
fi

rg -q 'accountUUID: profile.accountUuid' Sources/AIMeter/ClaudeOAuth.swift || {
  echo "FAIL: completed OAuth is not persisted by Anthropic account UUID" >&2
  exit 1
}

rg -q 'for name in profiles' "$manager" || {
  echo "FAIL: AccountManager no longer enumerates every saved Claude profile" >&2
  exit 1
}

rg -q 'polled\.contains\(profileUUID\)' "$manager" || {
  echo "FAIL: active and saved Claude identities are not deduplicated by UUID" >&2
  exit 1
}

echo "PASS: all saved Claude accounts are UUID-keyed, polled, and deduplicated"
