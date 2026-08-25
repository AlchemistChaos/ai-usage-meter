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

# Keep the terminal status line quiet. AI Meter only needs the JSON side effect.
exit 0
