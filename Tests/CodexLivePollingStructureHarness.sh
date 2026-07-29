#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

manager="Sources/AIMeter/AccountManager.swift"
diagnostics="Sources/AIMeter/Diagnostics.swift"
readme="README.md"

require() {
  local pattern="$1"
  local message="$2"
  rg -Uq "$pattern" "$manager" || {
    echo "FAIL: $message" >&2
    exit 1
  }
}

require 'private var lastCodexPoll: Date\?' \
  "Codex polling has no throttle timestamp"
require 'private var lastCodexPollAccountID: String\?' \
  "Codex polling is not scoped to the active account"
require 'private var codexPollInFlightAccountID: String\?' \
  "Codex polling does not track an in-flight account"
require '(?s)func refresh\(\).*?pollCodexUsageIfStale\(\)' \
  "the refresh loop does not start live Codex polling"
require 'CodexRateLimitClient\.fetchSnapshot' \
  "the manager does not fetch the app-server snapshot"
require '(?s)CodexProvider\.identity\(.*?ProfileStore\.activeCredentialPath\(\.codex\).*?accountID\s*== requestedAccountID' \
  "a response can be cached after the active account changes"
require '(?s)SnapshotCache\.put\(.*?accountID: requestedAccountID,.*?snapshot: snapshot' \
  "the live snapshot is not cached for its requested account"
require 'CodexProvider\.latestSnapshot\(\)' \
  "the SQLite fallback was removed"
require '(?s)CodexProvider\.latestSnapshot\(\).*?canAttributeSQLiteFallback' \
  "the unscoped SQLite fallback can be assigned across a Codex account switch"
require '(?s)defer\s*\{.*?codexPollInFlightAccountID\s*=\s*nil.*?pollCodexUsageIfStale\(\)' \
  "a Codex account switch during an in-flight poll does not schedule the new account"
require '(?s)NSRunningApplication\.runningApplications\(.*?withBundleIdentifier:\s*CodexProvider\.desktopBundleIdentifier\)' \
  "the manager does not detect the running Codex desktop app"
require 'CodexProvider\.desktopAccountIdentity\(\)' \
  "the manager does not read the Codex desktop app account"
require '(?s)activeAccountID.*?id\.accountID\s*==\s*activeAccountID' \
  "saved Codex rows are not activated from the desktop app identity"

rg -Fq '[Codex] live app-server usage:' "$diagnostics" || {
  echo "FAIL: diagnostics do not identify live app-server usage" >&2
  exit 1
}
rg -Fq '[Codex] SQLite fallback usage' "$diagnostics" || {
  echo "FAIL: diagnostics do not identify the SQLite fallback" >&2
  exit 1
}
rg -Fq 'account/rateLimits/read' "$readme" || {
  echo "FAIL: README does not document the live Codex usage source" >&2
  exit 1
}

echo "PASS: live Codex polling structure"
