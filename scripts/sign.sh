#!/bin/bash
# Signs the tmt88v binaries with a Developer ID Application identity (hardened runtime + secure timestamp).
#
#   SIGNING_IDENTITY   required: certificate name or SHA-1 hash ("-" = ad-hoc, needs ALLOW_ADHOC=1, for dry runs only)
#   BUNDLE_ID_PREFIX   identifier namespace (default com.belchuke.tmt88vcompat); see scripts/config.sh
#   DIST_DIR           directory holding the binaries (default dist)
#   SIGN_KEYCHAIN      optional keychain path to search
#   ENTITLEMENTS       optional entitlements plist (none by default; none are required)
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY to a Developer ID Application identity (see scripts/signing-identities.sh)}"
source scripts/config.sh
TOOLS=("${BINARIES[@]}")

args=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    [[ "${ALLOW_ADHOC:-}" == "1" ]] || { echo "ad-hoc signing is for dry runs only; set ALLOW_ADHOC=1 to allow"; exit 1; }
    args+=(--timestamp=none)
else
    args+=(--timestamp)
fi
[[ -n "${SIGN_KEYCHAIN:-}" ]] && args+=(--keychain "$SIGN_KEYCHAIN")
[[ -n "${ENTITLEMENTS:-}" ]] && args+=(--entitlements "$ENTITLEMENTS")

for tool in "${TOOLS[@]}"; do
    [[ -f "$DIST_DIR/$tool" ]] || { echo "missing $DIST_DIR/$tool (run scripts/build.sh first)"; exit 1; }
    echo "signing $DIST_DIR/$tool as $(signing_identifier "$tool")"
    codesign "${args[@]}" --identifier "$(signing_identifier "$tool")" "$DIST_DIR/$tool"
done

./scripts/verify-signing.sh
