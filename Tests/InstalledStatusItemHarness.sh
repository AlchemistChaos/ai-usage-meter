#!/bin/bash
set -euo pipefail

app_path="${AIMETER_APP_PATH:-AI Meter.app}"
binary="$app_path/Contents/MacOS/AIMeter"
output="$(mktemp -t aimeter-status-item-selftest.XXXXXX)"
pid=""

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rm -f "$output"
}
trap cleanup EXIT

"$binary" --status-item-selftest >"$output" 2>&1 &
pid=$!

for _ in 1 2 3 4 5; do
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid"
    pid=""
    grep -Fq 'PASS: installed status item interaction' "$output" || {
      cat "$output" >&2
      echo "FAIL: status item self-test did not report success" >&2
      exit 1
    }
    echo "PASS: installed status item interaction"
    exit 0
  fi
  sleep 1
done

echo "FAIL: installed app does not implement a terminating status-item self-test" >&2
exit 1
