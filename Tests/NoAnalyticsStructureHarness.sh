#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Sources/AIMeter"

forbidden=(
  'ClaudeTranscriptImporter'
  'CodexUsageImporter'
  'UsageLedger'
  'AccountTimelineStore'
  'UsageHistoryQuery'
  'UsageHistoryView'
  'TokenStats'
  'AttributedTokenStats'
  '.claude/projects'
  'todayTokens'
  'weekTokens'
  'weeklyPlanSpend'
  'soleStoredAccountUUID'
)

for pattern in "${forbidden[@]}"; do
  if rg -n --fixed-strings "$pattern" "$SOURCE" >/dev/null; then
    echo "FAIL: analytics reference remains in production sources: $pattern" >&2
    exit 1
  fi
done

echo "PASS: production sources contain no token analytics"
