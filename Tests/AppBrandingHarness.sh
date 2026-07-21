#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_script="build-app.sh"
workflow=".github/workflows/release.yml"
cask="Casks/ai-usage-meter.rb"
readme="README.md"
package="Package.swift"

assert_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq "$text" "$file"; then
    echo "FAIL: $file does not contain: $text" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    echo "FAIL: $file still contains: $text" >&2
    exit 1
  fi
}

assert_contains "$build_script" 'APP="AI Meter.app"'
assert_contains "$build_script" 'EXECUTABLE="AIMeter"'
assert_contains "$build_script" '<string>AI Meter</string>'
assert_contains "$build_script" '<string>com.alchemistchaos.aimeter</string>'
assert_contains "$build_script" '<key>CFBundleIconFile</key>'
assert_contains "$build_script" '<string>AIMeter</string>'
assert_contains "$build_script" 'Assets/AIMeter.icns'
assert_contains "$package" 'name: "AIMeter"'
assert_contains "$package" 'path: "Sources/AIMeter"'

assert_contains "$workflow" 'AI Meter.app'
assert_contains "$workflow" 'AIMeter-${{ steps.v.outputs.version }}.dmg'
assert_contains "$cask" 'name "AI Meter"'
assert_contains "$cask" 'app "AI Meter.app"'
assert_contains "$readme" '# AI Meter'
assert_contains "$readme" '/Applications/AI Meter.app/Contents/MacOS/AIMeter --diagnose'

assert_not_contains "$workflow" 'CCManager.app'
assert_not_contains "$cask" 'app "CCManager.app"'
assert_not_contains "$build_script" 'CCManager'
assert_not_contains "$readme" 'Sources/CCManager'

echo "PASS: AI Meter branding is consistent"
