#!/usr/bin/env bash
# The capture hook must attribute each statusline reading to the account that
# was logged in to the emitting Claude Code config dir AT CAPTURE TIME, so a
# later /login switch can never relabel an old reading as another account.
set -euo pipefail
cd "$(dirname "$0")/.."

script="$PWD/scripts/claude-statusline-capture.sh"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$home/.claude/projects/p" "$home/.claude-work/projects/p"
printf '{"oauthAccount":{"accountUuid":"uuid-default"}}' > "$home/.claude.json"
printf '{"oauthAccount":{"accountUuid":"uuid-work"}}' > "$home/.claude-work/.claude.json"

payload() {
  printf '{"transcript_path":"%s/projects/p/s.jsonl","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":1790703600}}}' "$1" "$2"
}

payload "$home/.claude" 11 | env -u CLAUDE_CONFIG_DIR HOME="$home" bash "$script"
payload "$home/.claude-work" 22 | env -u CLAUDE_CONFIG_DIR HOME="$home" bash "$script"

by="$home/.ccmanager/claude-statusline/by-account"
[ -f "$by/uuid-default.json" ] || fail "default config dir reading not stored under its account"
[ -f "$by/uuid-work.json" ] || fail "custom config dir reading not stored under its account"
grep -q '"used_percentage":11' "$by/uuid-default.json" || fail "default account got the wrong reading"
grep -q '"used_percentage":22' "$by/uuid-work.json" || fail "work account got the wrong reading"

# Switching the default dir's login must not relabel the stored reading.
printf '{"oauthAccount":{"accountUuid":"uuid-other"}}' > "$home/.claude.json"
grep -q '"used_percentage":11' "$by/uuid-default.json" || fail "account switch rewrote an old reading"
[ ! -f "$by/uuid-other.json" ] || fail "reading was attributed to an account that never produced it"

# No identity → no attributed file, but the hook must still succeed silently.
rm "$home/.claude-work/.claude.json"
out="$(payload "$home/.claude-work" 33 | env -u CLAUDE_CONFIG_DIR HOME="$home" bash "$script")" || fail "hook failed without identity"
[ -z "$out" ] || fail "hook printed to the terminal status line"
grep -q '"used_percentage":22' "$by/uuid-work.json" || fail "unattributed reading overwrote an account file"

# Legacy single-file output stays for older AI Meter builds.
[ -f "$home/.ccmanager/claude-statusline/latest.json" ] || fail "latest.json no longer written"

echo "PASS: statusline readings are attributed per account at capture time"
