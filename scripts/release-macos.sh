#!/bin/bash
# Developer ID release gates for CI. Never prints secret values.
#
#   release-macos.sh install-cert   MACOS_CERTIFICATE_P12_BASE64, MACOS_CERTIFICATE_PASSWORD, APPLE_TEAM_ID
#   release-macos.sh verify-signed  APPLE_TEAM_ID
#   release-macos.sh notarize       APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_PRIVATE_KEY_P8_BASE64
#                                   (optional: skipped with a warning when unset; sets NOTARIZED=0/1)
#   release-macos.sh verify-zip <zip>  APPLE_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/NMUCompat.app
CLI=dist/nmucompat

require_env() {
    local missing=()
    for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
    if ((${#missing[@]})); then
        echo "error: missing required secret(s): ${missing[*]}" >&2
        exit 1
    fi
}

check_team() {  # <path>
    local details
    details="$(codesign -dv --verbose=4 "$1" 2>&1)"
    grep -Fq "TeamIdentifier=${APPLE_TEAM_ID}" <<<"$details" || { echo "error: $1 not signed by team ${APPLE_TEAM_ID}" >&2; exit 1; }
    grep -Fq "Authority=Developer ID Application:" <<<"$details" || { echo "error: $1 not signed with Developer ID Application" >&2; exit 1; }
    grep -Eq "flags=.*runtime" <<<"$details" || { echo "error: $1 lacks Hardened Runtime" >&2; exit 1; }
    grep -Fq "Timestamp=" <<<"$details" || { echo "error: $1 lacks secure timestamp" >&2; exit 1; }
    grep -E '^(Authority|TeamIdentifier|Timestamp)=' <<<"$details" | head -3
}

case "${1:-}" in
install-cert)
    require_env MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD APPLE_TEAM_ID RUNNER_TEMP GITHUB_ENV
    cert="$RUNNER_TEMP/developer-id.p12"
    keychain="$RUNNER_TEMP/release-signing.keychain-db"
    kc_pass="$(openssl rand -base64 32)"
    printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$cert"
    security create-keychain -p "$kc_pass" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$kc_pass" "$keychain"
    security import "$cert" -P "$MACOS_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$keychain" \
        -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$keychain" >/dev/null
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
    rm -f "$cert"
    identity="$(security find-identity -v -p codesigning "$keychain" \
        | grep -F "Developer ID Application:" | grep -F "(${APPLE_TEAM_ID})" | sed -E 's/^ *[0-9]+\) [0-9A-F]+ "(.*)"$/\1/' | head -1)"
    [[ -n "$identity" ]] || { echo "error: Developer ID Application identity for ${APPLE_TEAM_ID} not found" >&2; exit 1; }
    echo "identity: $identity"
    echo "SIGN_IDENTITY=$identity" >> "$GITHUB_ENV"
    ;;
verify-signed)
    require_env APPLE_TEAM_ID
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign --verify --strict --verbose=2 "$CLI"
    check_team "$APP"
    check_team "$CLI"
    ;;
notarize)
    # Optional: without the App Store Connect API key secrets the release is Developer ID signed
    # but NOT notarized. Later steps read NOTARIZED from GITHUB_ENV.
    if [[ -z "${APPLE_API_KEY_ID:-}" || -z "${APPLE_API_ISSUER_ID:-}" || -z "${APPLE_API_PRIVATE_KEY_P8_BASE64:-}" ]]; then
        echo "::warning::Notarization skipped: APPLE_API_* secrets not set. Publishing a Developer ID signed, un-notarized build."
        if [[ -n "${GITHUB_ENV:-}" ]]; then echo "NOTARIZED=0" >> "$GITHUB_ENV"; fi
        exit 0
    fi
    require_env RUNNER_TEMP
    key="$RUNNER_TEMP/AuthKey_${APPLE_API_KEY_ID}.p8"
    printf '%s' "$APPLE_API_PRIVATE_KEY_P8_BASE64" | base64 --decode > "$key"
    chmod 600 "$key"
    # Temporary submission archive (never published): app + CLI.
    sub_dir="$RUNNER_TEMP/notary-submission"
    rm -rf "$sub_dir"; mkdir -p "$sub_dir"
    cp -R "$APP" "$CLI" "$sub_dir/"
    sub_zip="$RUNNER_TEMP/NMUCompat-notarization.zip"
    ditto -c -k --keepParent "$sub_dir" "$sub_zip"
    auth=(--key "$key" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
    result="$(xcrun notarytool submit "$sub_zip" "${auth[@]}" --wait --timeout 30m --output-format json)"
    echo "$result"
    id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")"
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")"
    xcrun notarytool log "$id" "${auth[@]}" "$RUNNER_TEMP/notary-log.json" || true
    [[ -f "$RUNNER_TEMP/notary-log.json" ]] && cat "$RUNNER_TEMP/notary-log.json"
    rm -f "$key" "$sub_zip"
    [[ "$status" == "Accepted" ]] || { echo "error: notarization status $status" >&2; exit 1; }
    # Only bundles can carry a stapled ticket; the bare CLI is checked online by Gatekeeper.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    if [[ -n "${GITHUB_ENV:-}" ]]; then echo "NOTARIZED=1" >> "$GITHUB_ENV"; fi
    ;;
verify-zip)
    require_env APPLE_TEAM_ID RUNNER_TEMP
    zip="$2"
    check_dir="$(mktemp -d "$RUNNER_TEMP/release-check.XXXXXX")"
    ditto -x -k "$zip" "$check_dir"
    root="$(find "$check_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    codesign --verify --deep --strict --verbose=2 "$root/NMUCompat.app"
    codesign --verify --strict --verbose=2 "$root/nmucompat"
    check_team "$root/NMUCompat.app"
    check_team "$root/nmucompat"
    if [[ "${NOTARIZED:-0}" == "1" ]]; then
        xcrun stapler validate "$root/NMUCompat.app"
        spctl --assess --type execute --verbose=4 "$root/NMUCompat.app"
    else
        echo "not notarized: skipping stapler/Gatekeeper assessment"
    fi
    lipo -archs "$root/NMUCompat.app/Contents/MacOS/NMUCompat" | grep -q arm64
    lipo -archs "$root/NMUCompat.app/Contents/MacOS/NMUCompat" | grep -q x86_64
    "$root/nmucompat" --help >/dev/null
    (cd "$(dirname "$zip")" && shasum -a 256 -c "$(basename "$zip").sha256")
    rm -rf "$check_dir"
    ;;
*)
    echo "usage: $0 install-cert|verify-signed|notarize|verify-zip <zip>" >&2
    exit 2
    ;;
esac
