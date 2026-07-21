#!/bin/bash
set -euo pipefail

glass="Sources/CCManager/NativeGlassBackground.swift"
dashboard="Sources/CCManager/GlassDashboardView.swift"

test -f "$glass" || {
  echo "FAIL: native glass view is missing" >&2
  exit 1
}
rg -q 'NSVisualEffectView' "$glass" || exit 1
rg -Fq 'override func hitTest(_ point: NSPoint) -> NSView? { nil }' "$glass" || {
  echo "FAIL: decorative native glass must not intercept input" >&2
  exit 1
}
rg -q 'window\.isOpaque = false' "$glass" || exit 1
rg -q 'window\.backgroundColor = \.clear' "$glass" || exit 1
rg -q 'blendingMode = \.behindWindow' "$glass" || exit 1
rg -q 'NativeGlassBackground\(\)' "$dashboard" || exit 1
if rg -q 'Rectangle\(\)\.fill\(\.ultraThinMaterial\)' "$dashboard"; then
  echo "FAIL: SwiftUI-only full-window material is still present" >&2
  exit 1
fi

echo "PASS: native glass window structure"
