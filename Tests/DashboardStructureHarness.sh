#!/bin/bash
set -euo pipefail

view="Sources/AIMeter/GlassDashboardView.swift"
manager="Sources/AIMeter/AccountManager.swift"

if rg -q 'GlassValueStrip' "$view"; then
  echo "FAIL: Claude API-equivalent value strip is still present" >&2
  exit 1
fi

if rg -q 'Remaining subscription capacity|Anthropic · Claude|OpenAI · Codex' "$view"; then
  echo "FAIL: removed dashboard/provider copy is still present" >&2
  exit 1
fi
if rg -q 'provider == \.claude \? "A" : "C"' "$view"; then
  echo "FAIL: provider letter logos are still present" >&2
  exit 1
fi
rg -Uq 'Text\("Usage"\)\n\s+\.font\(\.system\(size: 10,' "$view" || {
  echo "FAIL: Usage should match the Updated text size" >&2
  exit 1
}
rg -q '\? "Claude"|: "Codex"' "$view" || {
  echo "FAIL: concise provider labels are missing" >&2
  exit 1
}
rg -Uq 'Text\(provider == \.claude \? "Claude" : "Codex"\)\n\s+\.font\(\.system\(size: 9, weight: \.semibold\)\)\n\s+\.foregroundStyle\(\.white\)' "$view" || {
  echo "FAIL: provider headings should match metadata size and remain white" >&2
  exit 1
}
rg -Fq '.scrollBounceBehavior(.basedOnSize)' "$view" || {
  echo "FAIL: the dashboard should not bounce-scroll when its content fits" >&2
  exit 1
}

rg -q 'accessibilityLabel\("Settings"\)' "$view" || {
  echo "FAIL: header settings menu is missing" >&2
  exit 1
}
rg -q 'help\("Refresh"\)' "$view" || {
  echo "FAIL: header refresh control is missing" >&2
  exit 1
}
rg -q 'help\("Quit"\)' "$view" || {
  echo "FAIL: header quit control is missing" >&2
  exit 1
}
rg -q 'Add Anthropic account' "$view" || exit 1
rg -q 'Import OpenAI Codex login' "$view" || exit 1
rg -q 'Launch at login' "$view" || exit 1
rg -q 'Add OpenAI Codex account' "$view" || {
  echo "FAIL: isolated Codex login action is missing" >&2
  exit 1
}
rg -q 'manager\.beginCodexLogin()' "$view" || exit 1
rg -q 'manager\.pendingCodexLogin' "$view" || exit 1
rg -q 'manager\.cancelCodexLogin()' "$view" || exit 1
rg -q 'Restart OpenAI Codex sign-in' "$view" || {
  echo "FAIL: pending Codex login cannot be restarted from settings" >&2
  exit 1
}
rg -q 'manager\.restartCodexLogin()' "$view" || exit 1
rg -q 'func restartCodexLogin()' "$manager" || exit 1
rg -Fq '.popover(isPresented:' "$view" || {
  echo "FAIL: inactive account reset popover is missing" >&2
  exit 1
}
rg -q 'AccountPresentation\.resetDetail' "$view" || exit 1
if rg -q 'ResetSummary\(window:' "$view"; then
  echo "FAIL: compact reset details should live in the click popover" >&2
  exit 1
fi

echo "PASS: dashboard header structure"
