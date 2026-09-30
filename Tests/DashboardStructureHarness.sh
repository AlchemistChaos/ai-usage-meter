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
rg -q '@State private var contentHeight: CGFloat' "$view" || {
  echo "FAIL: dashboard content height should be measured, not estimated" >&2
  exit 1
}
rg -Fq '.onPreferenceChange(DashboardContentHeightKey.self)' "$view" || exit 1
rg -Fq '.scrollDisabled(contentHeight <= maxDashboardHeight)' "$view" || {
  echo "FAIL: scrolling should be disabled for content that fits" >&2
  exit 1
}
rg -Uq 'if hasTransientStatus \{\n\s+DashboardTransientStatus\(manager: manager\)\n\s+\}' "$view" || {
  echo "FAIL: empty transient status still adds bottom spacing" >&2
  exit 1
}
rg -q 'manager\.pendingCodexLogin != nil' "$view" || exit 1
rg -q 'manager\.pendingClaudeLogin != nil' "$view" || exit 1
rg -q 'manager\.lastError != nil' "$view" || exit 1
if rg -q 'AccountPresentation\.dashboardHeight' "$view"; then
  echo "FAIL: dashboard still uses the fixed height estimator" >&2
  exit 1
fi
rg -Uq 'ProviderHeader\(provider: group\.provider\)\n\s+\.padding\(\.horizontal, 2\)' "$view" || {
  echo "FAIL: provider headings should align with OTHER ACCOUNTS" >&2
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
rg -q '@State private var blurEmails = false' "$view" || {
  echo "FAIL: header email blur state is missing" >&2
  exit 1
}
rg -Fq 'BlurButton(isBlurred: blurEmails)' "$view" || {
  echo "FAIL: header email blur button is missing" >&2
  exit 1
}
if rg -Fq 'Text(isBlurred ? "Blurred" : "Blur")' "$view"; then
  echo "FAIL: header email blur control should be icon-only" >&2
  exit 1
fi
rg -Uq 'EmailLabel\(\n\s+text: account\.label,\n\s+blurEmails: blurEmails' "$view" || {
  echo "FAIL: account email labels are not routed through the blur renderer" >&2
  exit 1
}
rg -Fq '.blur(radius: shouldBlur ? 7 : 0)' "$view" || {
  echo "FAIL: email blur should be strong enough to hide account addresses" >&2
  exit 1
}
rg -q 'help\("Quit"\)' "$view" || {
  echo "FAIL: header quit control is missing" >&2
  exit 1
}
rg -q 'Add Anthropic account' "$view" || exit 1
rg -q 'Add OpenAI Codex account' "$view" || exit 1
rg -q 'Launch at login' "$view" || exit 1
rg -Fq 'Menu("Menu bar")' "$view" || {
  echo "FAIL: menu bar preferences are missing from settings" >&2
  exit 1
}
rg -Fq 'Toggle("Claude 5-hour"' "$view" || exit 1
rg -Fq 'Toggle("Claude weekly"' "$view" || exit 1
rg -Fq 'Toggle("Claude Fable"' "$view" || exit 1
rg -Fq 'Toggle("Codex weekly"' "$view" || exit 1
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
rg -Fq 'let windows = AccountPresentation.detailWindows(for: account)' "$view" || {
  echo "FAIL: inactive account detail should include every provider window" >&2
  exit 1
}
# A broken (reconnect-required) account must be unmistakable on its card.
[ "$(rg -n 'AccountPresentation\.needsReconnect\(account\)' "$view" | wc -l)" -ge 2 ] || {
  echo "FAIL: active and compact cards do not both flag broken accounts" >&2
  exit 1
}
rg -q 'BrokenAccountHighlight' "$view" || {
  echo "FAIL: broken accounts have no red border/glow" >&2
  exit 1
}
rg -q 'Button\("Reconnect", action: onReconnect\)' "$view" || {
  echo "FAIL: broken cards do not offer a clickable Reconnect" >&2
  exit 1
}
[ "$(rg -n 'onReconnect: \{ manager\.reconnect\(' "$view" | wc -l)" -ge 2 ] || {
  echo "FAIL: active and compact cards do not both wire Reconnect to the sign-in flow" >&2
  exit 1
}
rg -Uq 'func reconnect\(_ account: Account\)[\s\S]*?case \.claude:\s*beginClaudeLogin\(\s*browser: preferredReconnectBrowser,\s*loginHint: account\.email,\s*pasteCode: true\)[\s\S]*?case \.codex:\s*beginCodexLogin\(\)' Sources/AIMeter/AccountManager.swift || {
  echo "FAIL: Reconnect does not start the right provider's sign-in" >&2
  exit 1
}
rg -q '"Google Chrome\.app"' Sources/AIMeter/AccountManager.swift || {
  echo "FAIL: Claude reconnect does not prefer Chrome" >&2
  exit 1
}
[ "$(rg -n 'AccountPresentation\.reconnectMismatch\(' Sources/AIMeter/AccountManager.swift | wc -l)" -ge 2 ] || {
  echo "FAIL: Claude and Codex reconnects do not both warn about signing in as the wrong account" >&2
  exit 1
}
rg -q 'reconnectTargetEmail\[account\.provider\] = account\.email' Sources/AIMeter/AccountManager.swift || {
  echo "FAIL: Reconnect does not remember which account was clicked" >&2
  exit 1
}

# Claude Reconnect uses the copy-code sign-in: the approval can happen in any
# browser window (the meter cannot pick which one is signed into the account)
# and claude.ai's result is visible on the page instead of a lost redirect.
rg -q 'NSPasteboard\.general\.setString\(login\.url\.absoluteString' Sources/AIMeter/AccountManager.swift || {
  echo "FAIL: Claude Reconnect does not copy the sign-in link" >&2
  exit 1
}
rg -q 'Sign-in link copied' "$view" || {
  echo "FAIL: the paste box does not explain the copy-code sign-in" >&2
  exit 1
}

rg -q 'Button\("Paste code"\)' "$view" && rg -q 'NSPasteboard\.general\.string\(forType: \.string\)' "$view" || {
  echo "FAIL: the copy-code sign-in needs typing; add a one-click Paste code" >&2
  exit 1
}

# Per-account reconnect is shown on the card; the banner keeps other errors.
rg -q 'if let failure = outcome\.failure, !outcome\.needsReconnect' Sources/AIMeter/AccountManager.swift || {
  echo "FAIL: the error banner still repeats per-account reconnect messages" >&2
  exit 1
}

# Importing or switching would share one Codex login between AI Meter and the
# CLI, and `codex logout` revokes it server-side (see CodexIndependentProfilesHarness).
if rg -q 'Import OpenAI Codex login|Make Default|Switch Codex to this account' "$view"; then
  echo "FAIL: the dashboard still offers importing or switching a shared Codex login" >&2
  exit 1
fi
if rg -q 'TokenSummaryRow|UsageHistoryView|Button\("History"\)' "$view"; then
  echo "FAIL: token analytics UI is still present" >&2
  exit 1
fi

echo "PASS: dashboard header structure"
