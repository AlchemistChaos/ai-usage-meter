#!/bin/bash
# Builds CCManager.app — a menu bar (accessory) app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="CCManager.app"

swift build -c "$CONFIG"
BIN=".build/$CONFIG/CCManager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CCManager"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>CCManager</string>
  <key>CFBundleDisplayName</key>     <string>Codex / Claude Manager</string>
  <key>CFBundleIdentifier</key>      <string>local.ccmanager</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key>      <string>CCManager</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <!-- Accessory app: menu bar only, no Dock icon. -->
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the keychain and Codex config are readable without Gatekeeper noise.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "note: ad-hoc codesign failed; app will still run locally"

echo "Built $APP"
echo "Run:      open $APP"
echo "Diagnose: ./$APP/Contents/MacOS/CCManager --diagnose"
