#!/bin/bash
# Submits the signed package to Apple notarization, waits, staples and verifies.
#   NOTARY_PROFILE   required: keychain profile created once with `xcrun notarytool store-credentials`
#   scripts/notarize.sh [path/to/package.pkg]
# No credentials are stored in the repository; the profile lives in your keychain.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)}"
PKG="${1:-$BUILD_DIR/pkg/$PKG_FILE_BASENAME.pkg}"
[[ -f "$PKG" ]] || { echo "package not found: $PKG (run scripts/build-pkg.sh with INSTALLER_SIGNING_IDENTITY set)"; exit 1; }

pkgutil --check-signature "$PKG" | grep -q "Developer ID Installer:" || { echo "package is not signed with Developer ID Installer; refusing to submit"; exit 1; }

mkdir -p "$BUILD_DIR/notary"
RESULT="$BUILD_DIR/notary/submit-$(date +%Y%m%d-%H%M%S).json"

echo "submitting $PKG (this waits for Apple's result)"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json | tee "$RESULT"

parse() { /usr/bin/python3 -c "import json,sys; print(json.load(open('$RESULT')).get('$1',''))"; }
status="$(parse status)"
id="$(parse id)"

if [[ "$status" != "Accepted" ]]; then
    echo "notarization status: $status (submission id $id)"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$BUILD_DIR/notary/log-$id.json" || true
    echo "issue details saved to $BUILD_DIR/notary/log-$id.json"
    exit 1
fi

echo "accepted (submission id $id); stapling"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl -a -vvv -t install "$PKG"
echo "notarized and stapled: $PKG"

# The stable-name asset is created ONLY now, from the finalized (notarized + stapled) bytes. Copying earlier would leave it
# without the stapled ticket and no longer identical to the versioned file. Never notarize the alias separately.
ALIAS="$(dirname "$PKG")/TMT88VCompat.pkg"
if [[ "$(basename "$PKG")" == "$PKG_FILE_BASENAME.pkg" ]]; then
    cp -f "$PKG" "$ALIAS"
    a="$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
    b="$(shasum -a 256 "$ALIAS" | cut -d' ' -f1)"
    [[ "$a" == "$b" ]] || { echo "ERROR: $ALIAS differs from $PKG after copying"; exit 1; }
    echo "release assets (identical, sha256 $a):"
    shasum -a 256 "$PKG" "$ALIAS"
    echo "next: ./scripts/verify-release.sh"
fi
