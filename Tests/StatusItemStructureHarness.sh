#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="Sources/AIMeter/App.swift"
controller="Sources/AIMeter/StatusItemController.swift"

test -f "$controller" || {
  echo "FAIL: AppKit status item controller is missing" >&2
  exit 1
}

if rg -q 'MenuBarExtra' "$app"; then
  echo "FAIL: stale-prone SwiftUI MenuBarExtra is still the status-item owner" >&2
  exit 1
fi

rg -Uq 'NSStatusBar\.system\.statusItem\(\s*withLength: NSStatusItem\.variableLength\)' "$controller" || {
  echo "FAIL: controller does not create an AppKit status item" >&2
  exit 1
}
rg -Fq 'autosaveName = "com.alchemistchaos.aimeter.status-item"' "$controller" || {
  echo "FAIL: status item has no stable autosave identity" >&2
  exit 1
}
rg -q 'StatusItemLifecycle<NSStatusItem>' "$controller" || {
  echo "FAIL: controller bypasses the idempotent lifecycle" >&2
  exit 1
}
rg -q 'NSPopover\(\)' "$controller" || exit 1
rg -q 'popover\.behavior = \.transient' "$controller" || {
  echo "FAIL: dashboard popover will not close on outside click" >&2
  exit 1
}
rg -Uq 'NSHostingController\(\s*rootView: MenuView\(manager: manager\)\)' "$controller" || {
  echo "FAIL: popover does not host the existing dashboard" >&2
  exit 1
}
rg -q 'button\.target = self' "$controller" || exit 1
rg -q '#selector\(togglePopover' "$controller" || {
  echo "FAIL: gauge click is not wired to the dashboard" >&2
  exit 1
}
rg -Uq 'popover\.show\([^)]*relativeTo: sender\.bounds,[^)]*of: sender,[^)]*preferredEdge: \.maxY' "$controller" || {
  echo "FAIL: popover is not anchored below the flipped status-bar button" >&2
  exit 1
}
rg -Fq 'NSWindow.didResizeNotification' "$controller" || {
  echo "FAIL: popover resizing is not observed" >&2
  exit 1
}
rg -q 'PopoverPlacement\.frame' "$controller" || {
  echo "FAIL: resized popover is not kept onscreen" >&2
  exit 1
}
rg -q 'DispatchQueue\.main\.asyncAfter' "$controller" || {
  echo "FAIL: popover placement is not corrected after AppKit settles" >&2
  exit 1
}
rg -q 'private var statusItemController: StatusItemController\?' "$app" || {
  echo "FAIL: app delegate does not retain the status item controller" >&2
  exit 1
}
rg -Uq 'applicationDidFinishLaunching[^{]*\{[^}]*ensureStatusItem\(\)' "$app" || {
  echo "FAIL: launch does not ensure the gauge" >&2
  exit 1
}
rg -Uq 'applicationDidBecomeActive[^{]*\{[^}]*ensureStatusItem\(\)' "$app" || {
  echo "FAIL: activation does not recover the gauge" >&2
  exit 1
}
rg -Fq 'NSWorkspace.didWakeNotification' "$app" || {
  echo "FAIL: wake recovery is missing" >&2
  exit 1
}
rg -Fq 'NSApplication.didChangeScreenParametersNotification' "$app" || {
  echo "FAIL: display-change recovery is missing" >&2
  exit 1
}

echo "PASS: AppKit status item structure"
