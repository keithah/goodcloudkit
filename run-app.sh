#!/bin/bash
# Build the GoodCloud Tester example, wrap it in a proper .app bundle (so window focus,
# keyboard input, and Dock behavior work — a bare `swift run` executable doesn't become key),
# and launch it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c debug --product GoodCloudExample
BIN="$(swift build -c debug --show-bin-path)/GoodCloudExample"
APP="$(swift build -c debug --show-bin-path)/GoodCloud Tester.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GoodCloudExample"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GoodCloud Tester</string>
  <key>CFBundleDisplayName</key><string>GoodCloud Tester</string>
  <key>CFBundleIdentifier</key><string>xyz.goodcloud.tester</string>
  <key>CFBundleExecutable</key><string>GoodCloudExample</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "bundled: $APP"
open "$APP"
