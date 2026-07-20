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
  <key>CFBundleIdentifier</key>      <string>com.saphaare.ccmanager</string>
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

# Prefer the real Developer ID identity (stable identity for macOS permission
# grants and launch-at-login); fall back to ad-hoc if it's ever missing.
IDENTITY="Developer ID Application: SAPHAARE LABS PRIVATE LIMITED (M359MD8CXK)"
if security find-identity -v -p codesigning | grep -q "M359MD8CXK"; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "signed with Developer ID ($(codesign -dv "$APP" 2>&1 | grep TeamIdentifier))"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "note: ad-hoc codesign failed; app will still run locally"
fi

echo "Built $APP"

# --install: put it in /Applications and (re)launch — the stable home macOS
# expects for permission grants and launch-at-login.
if [[ "${2:-}" == "--install" || "${1:-}" == "--install" ]]; then
  pkill -x CCManager 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed and launched /Applications/$APP"
else
  echo "Run:      open $APP"
  echo "Install:  ./build-app.sh release --install"
  echo "Diagnose: ./$APP/Contents/MacOS/CCManager --diagnose"
fi
