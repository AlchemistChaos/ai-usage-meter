#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
root="${HOME}/.ccmanager/claude-statusline"
latest="${root}/latest.json"
tmp="${latest}.$$"

mkdir -p "$root"
umask 077
printf '%s' "$input" > "$tmp"
mv "$tmp" "$latest"

# Attribute the reading to the account logged in to the emitting config dir
# now, so a later /login switch can never relabel it. Needs no credentials:
# only the identity in .claude.json. Any failure leaves latest.json alone.
{
  transcript="$(printf '%s' "$input" | plutil -extract transcript_path raw -o - -- - 2>/dev/null || true)"
  config_dir="${transcript%%/projects/*}"
  if [ -z "$transcript" ] || [ "$config_dir" = "$transcript" ]; then
    config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  fi
  if [ "$config_dir" = "${HOME}/.claude" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    identity="${HOME}/.claude.json"
  else
    identity="${config_dir}/.claude.json"
  fi
  account="$(plutil -extract oauthAccount.accountUuid raw -o - "$identity" 2>/dev/null || true)"
  if [[ "$account" =~ ^[A-Za-z0-9-]+$ ]]; then
    by_account="${root}/by-account"
    mkdir -p "$by_account"
    printf '%s' "$input" > "${by_account}/${account}.json.$$"
    mv "${by_account}/${account}.json.$$" "${by_account}/${account}.json"
  fi
} || true

# Keep the terminal status line quiet. AI Meter only needs the JSON side effect.
exit 0
