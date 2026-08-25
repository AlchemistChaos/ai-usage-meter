#!/usr/bin/env bash
# When the active CLI account fails to authenticate, its cached usage windows
# must be suppressed and the card must say "reconnect", not keep rendering a
# stale snapshot as if it were live. claudeAccount() drives that off
# claudeProfileErrorsByUUID[uuid], so the active-account catch block has to
# populate that map — setting only the banner string is not enough.
set -euo pipefail
cd "$(dirname "$0")/.."

manager="Sources/AIMeter/AccountManager.swift"

grep -q 'claudeProfileErrorsByUUID\[activeUUID\] = ClaudeProvider.reconnectAccountMessage' "$manager" || {
  echo "FAIL: active-account auth failure does not set claudeProfileErrorsByUUID[activeUUID]," >&2
  echo "      so claudeAccount() never suppresses its stale windows and the card keeps" >&2
  echo "      showing old usage under a green dot." >&2
  exit 1
}

# The freshness label must not hardcode "Live usage" regardless of snapshot age.
if grep -qE 'provider == \.claude \? "Live usage" : "Local logs"' Sources/AIMeter/GlassDashboardView.swift; then
  echo "FAIL: header hardcodes \"Live usage\" — it renders over stale cached snapshots" >&2
  exit 1
fi

echo "PASS: stale usage cannot be presented as live"
