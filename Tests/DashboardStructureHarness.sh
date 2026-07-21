#!/bin/bash
set -euo pipefail

view="Sources/CCManager/GlassDashboardView.swift"

if rg -q 'GlassValueStrip' "$view"; then
  echo "FAIL: Claude API-equivalent value strip is still present" >&2
  exit 1
fi

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
