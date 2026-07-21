#!/bin/bash
# Builds AI Meter.app — a menu bar (accessory) app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="AI Meter.app"
EXECUTABLE="AIMeter"

swift build -c "$CONFIG"
BIN=".build/$CONFIG/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp "Assets/AIMeter.icns" "$APP/Contents/Resources/AIMeter.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>AI Meter</string>
  <key>CFBundleDisplayName</key>     <string>AI Meter</string>
  <key>CFBundleIdentifier</key>      <string>com.alchemistchaos.aimeter</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key>      <string>AIMeter</string>
  <key>CFBundleIconFile</key>        <string>AIMeter</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <!-- Accessory app: menu bar only, no Dock icon. -->
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Sign with a Developer ID if one is configured, else ad-hoc (fine locally —
# apps you build yourself are never quarantined by Gatekeeper).
#   export AIMETER_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
IDENTITY="${AIMETER_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "signed: $(codesign -dv "$APP" 2>&1 | grep TeamIdentifier)"
else
  [[ -n "$IDENTITY" ]] && echo "note: AIMETER_SIGN_IDENTITY not found in keychain; using ad-hoc"
  codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "note: ad-hoc codesign failed; app will still run locally"
fi

echo "Built $APP"

# --install: put it in /Applications and (re)launch — the stable home macOS
# expects for permission grants and launch-at-login.
if [[ "${2:-}" == "--install" || "${1:-}" == "--install" ]]; then
  pkill -x AIMeter 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed and launched /Applications/$APP"
else
  echo "Run:      open $APP"
  echo "Install:  ./build-app.sh release --install"
  echo "Diagnose: ./$APP/Contents/MacOS/$EXECUTABLE --diagnose"
fi
