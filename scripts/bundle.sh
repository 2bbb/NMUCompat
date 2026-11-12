#!/bin/bash
# Builds NMUCompat.app (release, ad-hoc signed) into ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=dist/NMUCompat.app

swift build -c release --product NMUCompatApp
BIN="$(swift build -c release --show-bin-path)/NMUCompatApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NMUCompat"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NMUCompat</string>
  <key>CFBundleDisplayName</key><string>NMUCompat</string>
  <key>CFBundleIdentifier</key><string>com.github.2bbb.nmucompat</string>
  <key>CFBundleExecutable</key><string>NMUCompat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>NMUCompat discovers and configures ENTTEC ODE nodes on the local network.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
