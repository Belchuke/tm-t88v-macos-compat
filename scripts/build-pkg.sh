#!/bin/bash
# Builds the installer package from the signed binaries in dist/.
#
#   INSTALLER_SIGNING_IDENTITY   Developer ID Installer identity (name or SHA-1). If unset, an UNSIGNED package is built (development only).
#   ALLOW_ADHOC=1                accept ad-hoc binaries (fixture builds; never ship)
#   BUNDLE_ID_PREFIX, VERSION, SERVICE_USER, IPP_PORT, QUEUE_NAME   see scripts/config.sh
#
# Output: build/pkg/TMT88VCompat-<version>.pkg   (or -unsigned.pkg)
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

./scripts/verify-signing.sh

ROOT="$BUILD_DIR/pkgroot"
SCRIPTS="$BUILD_DIR/pkgscripts"
COMPONENT_DIR="$BUILD_DIR/component"
OUT_DIR="$BUILD_DIR/pkg"
rm -rf "$ROOT" "$SCRIPTS" "$COMPONENT_DIR"
mkdir -p "$ROOT$(dirname "$SERVICE_BINARY_PATH")" "$ROOT$(dirname "$PLIST_PATH")" \
         "$ROOT$SUPPORT_DIR/bin" "$ROOT$SUPPORT_DIR/share" "$SCRIPTS" "$COMPONENT_DIR" "$OUT_DIR"

install -m 755 "$DIST_DIR/tmt88v-service" "$ROOT$SERVICE_BINARY_PATH"
install -m 755 "$DIST_DIR/tmt88v-updater" "$ROOT$UPDATER_BINARY_PATH"
install -m 755 "$DIST_DIR/tmt88v-diag" "$ROOT$SUPPORT_DIR/bin/tmt88v-diag"
install -m 755 "$DIST_DIR/tmt88v-test" "$ROOT$SUPPORT_DIR/bin/tmt88v-test"
install -m 755 "$DIST_DIR/tmt88v-raster-test" "$ROOT$SUPPORT_DIR/bin/tmt88v-raster-test"
install -m 644 pkg/share/healthcheck.test "$ROOT$SUPPORT_DIR/share/healthcheck.test"
install -m 644 pkg/share/config.default.json "$ROOT$SUPPORT_DIR/share/config.default.json"
install -m 755 scripts/uninstall.sh "$ROOT$SUPPORT_DIR/uninstall.sh"

render_template pkg/launchd/service.plist.template "$ROOT$PLIST_PATH"
chmod 644 "$ROOT$PLIST_PATH"
plutil -lint "$ROOT$PLIST_PATH"
render_template pkg/launchd/updater.plist.template "$ROOT$UPDATER_PLIST_PATH"
chmod 644 "$ROOT$UPDATER_PLIST_PATH"
plutil -lint "$ROOT$UPDATER_PLIST_PATH"

for script in preinstall postinstall lib.sh; do
    render_template "pkg/scripts/$script" "$SCRIPTS/$script"
    bash -n "$SCRIPTS/$script"
done
chmod 755 "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"
chmod 644 "$SCRIPTS/lib.sh"

pkgbuild --root "$ROOT" \
         --identifier "$PKG_IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         --scripts "$SCRIPTS" \
         "$COMPONENT_DIR/component.pkg"

render_template pkg/distribution.xml.template "$BUILD_DIR/distribution.xml"

sign_args=()
output="$OUT_DIR/$PKG_FILE_BASENAME.pkg"
if [[ -n "${INSTALLER_SIGNING_IDENTITY:-}" ]]; then
    sign_args=(--sign "$INSTALLER_SIGNING_IDENTITY" --timestamp)
else
    output="$OUT_DIR/$PKG_FILE_BASENAME-unsigned.pkg"
    echo "INSTALLER_SIGNING_IDENTITY not set: building an UNSIGNED package (cannot be notarized)"
fi

rm -f "$output"
productbuild --distribution "$BUILD_DIR/distribution.xml" --package-path "$COMPONENT_DIR" ${sign_args[@]+"${sign_args[@]}"} "$output"

echo "built $output"
