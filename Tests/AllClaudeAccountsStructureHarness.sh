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

rg -q 'activeProfileName' "$manager" || {
  echo "FAIL: statusline polling cannot fall back to the active saved Claude profile" >&2
  exit 1
}

rg -q 'ClaudeProvider\.activeUsageToken\(' "$manager" || {
  echo "FAIL: active Claude polling does not fall back to Claude Code's credential" >&2
  exit 1
}

rg -Uq 'activeProfileName\.map \{ name in\s*\n\s*\{ try await ClaudeProvider\.usableToken\(for: name\) \}' "$manager" || {
  echo "FAIL: active saved Claude profile is not used to refresh scoped usage" >&2
  exit 1
}

rg -q 'ClaudeProvider\.statuslineSnapshotsByAccount\(\)' "$manager" || {
  echo "FAIL: Claude polling does not read the per-account statusline readings" >&2
  exit 1
}

# latest.json has no account attached; reading it would credit one account's
# usage to whoever happens to be logged in now.
if rg -q 'latest\.json|latestStatuslineSnapshot' Sources/AIMeter; then
  echo "FAIL: the unattributed latest.json statusline reading is used again" >&2
  exit 1
fi

echo "PASS: all saved Claude accounts are UUID-keyed, polled, and deduplicated"
