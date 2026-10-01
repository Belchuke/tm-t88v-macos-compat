#!/bin/bash
# Verifies the built package: signature, Gatekeeper assessment, payload contents and the binaries inside it.
#   scripts/verify-pkg.sh [path/to/package.pkg]
# A Gatekeeper rejection reading exactly "Unnotarized Developer ID" is reported but is not a failure before notarization.
set -uo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

PKG="${1:-$BUILD_DIR/pkg/$PKG_FILE_BASENAME.pkg}"
status=0
fail() { echo "  FAIL: $*"; status=1; }

[[ -f "$PKG" ]] || { echo "package not found: $PKG"; exit 1; }
echo "== $PKG"

echo "-- pkgutil --check-signature"
sig="$(pkgutil --check-signature "$PKG" 2>&1)"
echo "$sig" | sed 's/^/  /'
echo "$sig" | grep -q "Developer ID Installer:" || fail "not signed with a Developer ID Installer certificate"
echo "$sig" | grep -qi "signed with a trusted timestamp" || fail "no trusted timestamp"

echo "-- Gatekeeper (spctl)"
gk="$(spctl -a -vv -t install "$PKG" 2>&1)"
echo "$gk" | sed 's/^/  /'
if echo "$gk" | grep -q "accepted" && echo "$gk" | grep -q "source=Notarized Developer ID"; then
    echo "  GATEKEEPER: accepted (notarized)"
elif echo "$gk" | grep -q "rejected" && echo "$gk" | grep -q "source=Unnotarized Developer ID"; then
    echo "  GATEKEEPER: rejected - Unnotarized Developer ID (expected before notarization, not a build failure)"
else
    fail "unexpected Gatekeeper result"
fi

echo "-- stapled ticket"
if xcrun stapler validate "$PKG" > /dev/null 2>&1; then echo "  stapled: yes"; else echo "  stapled: no"; fi

echo "-- payload"
EXPAND="$(mktemp -d)"
trap 'rm -rf "$EXPAND"' EXIT
pkgutil --expand-full "$PKG" "$EXPAND/x" > /dev/null 2>&1 || fail "pkgutil --expand-full failed"
payload="$(find "$EXPAND/x" -path '*Payload*' -type f | sed "s|^.*/Payload||" | sort)"
echo "$payload" | sed 's/^/  /'
for expected in "$SERVICE_BINARY_PATH" "$PLIST_PATH" "$UPDATER_BINARY_PATH" "$UPDATER_PLIST_PATH" "$SUPPORT_DIR/share/config.default.json" "$SUPPORT_DIR/bin/tmt88v-diag" "$SUPPORT_DIR/share/healthcheck.test" "$SUPPORT_DIR/uninstall.sh"; do
    echo "$payload" | grep -qxF "$expected" || fail "payload missing $expected"
done
echo "$payload" | grep -qx "$SUPPORT_DIR/config.json" && fail "payload ships config.json, which would overwrite a customer's setting on upgrade"
echo "$payload" | grep -qi "epson" && fail "payload touches an Epson path"
echo "$payload" | grep -q "^/Library/Printers" && fail "payload touches /Library/Printers"

service_in_pkg="$(find "$EXPAND/x" -path "*Payload$SERVICE_BINARY_PATH" -type f | head -1)"
if [[ -n "$service_in_pkg" ]]; then
    codesign --verify --deep --strict "$service_in_pkg" 2>&1 | sed 's/^/  /'
    [[ ${PIPESTATUS[0]} -eq 0 ]] || fail "service binary inside the package fails codesign verification"
    codesign -dv --verbose=4 "$service_in_pkg" 2>&1 | grep -E "^(Identifier|TeamIdentifier|Authority=Developer ID Application|Timestamp)" | sed 's/^/  /'
fi
echo "-- exec smoke test (the packaged service under its installed file name)"
updater_in_pkg="$(find "$EXPAND/x" -path "*Payload$UPDATER_BINARY_PATH" -type f | head -1)"
for entry in "$SERVICE_BINARY_PATH:$service_in_pkg" "$UPDATER_BINARY_PATH:$updater_in_pkg"; do
    installed_path="${entry%%:*}"
    extracted="${entry#*:}"
    base="$(basename "$installed_path")"
    case "$base" in
        *.service|*.app|*.bundle|*.framework|*.xpc|*.plugin) fail "file name '$base' ends in a bundle-style extension; macOS may kill it at exec" ;;
    esac
    if [[ -n "$extracted" ]]; then
        smoke="$(mktemp -d)/$base"
        cp "$extracted" "$smoke"
        "$smoke" --help > /dev/null 2>&1
        rc=$?
        [[ $rc -eq 0 ]] && echo "  '$base --help' exited 0" || fail "'$base --help' exited $rc (137 = killed at exec)"
        codesign --verify --deep --strict "$extracted" 2>&1 | sed 's/^/  /'
        [[ ${PIPESTATUS[0]} -eq 0 ]] || fail "$base inside the package fails codesign verification"
    else
        fail "$base not found inside the package"
    fi
done
for script in preinstall postinstall lib.sh; do
    find "$EXPAND/x" -path "*Scripts/$script" -type f | grep -q . || fail "package script $script missing"
done

[[ $status -eq 0 ]] && echo "package verification PASSED" || echo "package verification FAILED"
exit $status
