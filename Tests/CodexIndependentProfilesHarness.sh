#!/usr/bin/env bash
# A saved Codex account must keep its OWN login, made in the isolated
# "Add OpenAI Codex account" flow. `codex logout` revokes the CLI's session
# server-side, so any saved copy of the CLI's credential (or a CLI copy of a
# saved credential) dies with it — observed as 401 token_revoked on
# river@ultima and the@chaos.one on 2026-09-29.
set -euo pipefail
cd "$(dirname "$0")/.."

sources="Sources/AIMeter"
manager="$sources/AccountManager.swift"
dashboard="$sources/GlassDashboardView.swift"

fail() { echo "FAIL: $1" >&2; exit 1; }

if rg -q 'ProfileStore\.importActive\(' "$manager"; then
  fail "AccountManager copies the CLI's Codex login into a saved profile"
fi
if rg -q 'ProfileStore\.activate\(' "$manager"; then
  fail "AccountManager copies a saved Codex login into the CLI"
fi
if rg -q 'importCurrentCodex|switchTo\(' "$dashboard"; then
  fail "the dashboard still offers importing or switching a shared Codex login"
fi
rg -Uq 'ProfileStore\.importCredential\(\s*\n\s*\.codex,\s*\n\s*from: session\.authFile' "$manager" \
  || fail "the isolated Codex sign-in no longer saves its own credential"

echo "PASS: saved Codex accounts keep their own logins"
