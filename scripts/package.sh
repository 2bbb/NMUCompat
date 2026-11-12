#!/bin/bash
# Packs dist/NMUCompat.app + dist/nmucompat (+ README, LICENSE) into the public zip and writes
# a SHA-256 file. Run only after signing (and, for releases, notarization + stapling).
#   VERSION / ZIP_LABEL / UNIVERSAL as in bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
DIST=dist
SUFFIX=$([[ "${UNIVERSAL:-0}" == "1" ]] && echo universal || uname -m)
NAME="NMUCompat-${ZIP_LABEL:-$VERSION}-macos-${SUFFIX}"
STAGE="$DIST/$NAME"

rm -rf "$STAGE" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
mkdir -p "$STAGE"
cp -R "$DIST/NMUCompat.app" "$STAGE/"
cp "$DIST/nmucompat" "$STAGE/"
cp README.md LICENSE "$STAGE/"
# ditto preserves signatures, stapled tickets and bundle metadata.
(cd "$DIST" && ditto -c -k --keepParent "$NAME" "$NAME.zip")
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "zip: $DIST/$NAME.zip"
cat "$DIST/$NAME.zip.sha256"
