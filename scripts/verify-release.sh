#!/bin/bash
# Verifies the two release assets before publishing:
#   build/pkg/TMT88VCompat-<version>.pkg   (for humans and history)
#   build/pkg/TMT88VCompat.pkg             (the stable name the updater downloads)
# They must be byte-identical, signed by Developer ID Installer team P3WL6DBK59, notarized and stapled, and carry the version in VERSION.
set -uo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

VERSIONED="${1:-$BUILD_DIR/pkg/$PKG_FILE_BASENAME.pkg}"
ALIAS="$(dirname "$VERSIONED")/TMT88VCompat.pkg"
status=0
fail() { echo "  FAIL: $*"; status=1; }

[[ -f "$VERSIONED" ]] || { echo "missing $VERSIONED"; exit 1; }
[[ -f "$ALIAS" ]] || { echo "missing $ALIAS (run ./scripts/notarize.sh)"; exit 1; }

echo "== sha256"
shasum -a 256 "$VERSIONED" "$ALIAS"
[[ "$(shasum -a 256 "$VERSIONED" | cut -d' ' -f1)" == "$(shasum -a 256 "$ALIAS" | cut -d' ' -f1)" ]] || fail "the two assets are not byte-identical"
cmp -s "$VERSIONED" "$ALIAS" || fail "cmp reports a difference"

echo "== stapled ticket"
xcrun stapler validate "$ALIAS" > /dev/null 2>&1 && echo "  stapled: yes" || fail "the stable-name package has no stapled ticket"

echo "== updater-grade verification (the same code the installed updater runs)"
UPDATER="${UPDATER_BINARY:-$DIST_DIR/tmt88v-updater}"
if [[ -x "$UPDATER" ]]; then
    out="$("$UPDATER" verify "$ALIAS" 2>&1)"; rc=$?
    echo "$out" | sed 's/^/  /'
    [[ $rc -eq 0 ]] || fail "the updater would reject this package"
    echo "$out" | grep -q "metadata:     $PKG_IDENTIFIER $VERSION\$" || fail "package identifier/version differ from $PKG_IDENTIFIER $VERSION"
else
    fail "no updater binary at $UPDATER to run the verification"
fi

[[ $status -eq 0 ]] && echo "release assets OK: publish both files" || echo "release assets NOT ready"
exit $status
