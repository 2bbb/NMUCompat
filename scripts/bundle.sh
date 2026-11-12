#!/bin/bash
# Builds NMUCompat.app and the nmucompat CLI (release, ad-hoc signed) into ./dist.
#
#   scripts/bundle.sh                 # host architecture only
#   UNIVERSAL=1 scripts/bundle.sh     # arm64 + x86_64
#   VERSION=1.2.3 ZIP=1 UNIVERSAL=1 scripts/bundle.sh
#       → dist/NMUCompat-1.2.3-macos-universal.zip (app + CLI + README + LICENSE)
#   ZIP_LABEL=latest overrides the version part of the zip name.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUNDLE_VERSION="${BUNDLE_VERSION:-${VERSION%%[-+]*}}"
DIST=dist
APP="$DIST/NMUCompat.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]}" --product NMUCompatApp
swift build -c release "${ARCH_FLAGS[@]}" --product nmucompat
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP" "$DIST/nmucompat"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NMUCompatApp" "$APP/Contents/MacOS/NMUCompat"
cp "$BIN_DIR/nmucompat" "$DIST/nmucompat"

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
  <key>CFBundleShortVersionString</key><string>${BUNDLE_VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>NMUCompat discovers and configures ENTTEC ODE nodes on the local network.</string>
</dict>
</plist>
PLIST

# Ad-hoc by default. Release automation sets SIGN_IDENTITY to the Developer ID identity;
# then Hardened Runtime + secure timestamp are required for notarization.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS=(--force --sign -)
else
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
# Inside-out: the CLI is standalone; the app has a single executable and no nested code.
codesign "${SIGN_ARGS[@]}" "$DIST/nmucompat"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$DIST/nmucompat"

lipo -info "$APP/Contents/MacOS/NMUCompat"
lipo -info "$DIST/nmucompat"

if [[ "${ZIP:-0}" == "1" ]]; then
    "$(dirname "$0")/package.sh"
fi

echo "built $APP and $DIST/nmucompat"
