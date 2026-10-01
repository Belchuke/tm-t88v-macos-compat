#!/bin/bash
# Single source of identifiers, paths and defaults. Sourced by the build, signing, packaging and test scripts.
# Every value can be overridden through the environment, except where noted.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.belchuke.tmt88vcompat}"

SERVICE_LABEL="${SERVICE_LABEL:-$BUNDLE_ID_PREFIX.service}"
PKG_IDENTIFIER="${PKG_IDENTIFIER:-$BUNDLE_ID_PREFIX.pkg}"
MANAGER_IDENTIFIER="$BUNDLE_ID_PREFIX.manager"

QUEUE_NAME="${QUEUE_NAME:-TMT88V_Compat}"
QUEUE_DESCRIPTION="${QUEUE_DESCRIPTION:-EPSON TM-T88V}"
IPP_PORT="${IPP_PORT:-8632}"
PRINTER_URI="ipp://127.0.0.1:$IPP_PORT/ipp/print"

# The executable's FILE NAME must not end in a macOS bundle extension (.service, .app, ...). syspolicyd treats such a
# path as an app bundle, fails to register the plain Mach-O for bundle protection and SIGKILLs it at exec, before main().
# The launchd label ends in ".service" (that is fine for a label); the file is therefore named ".daemon".
SERVICE_BINARY_NAME="${SERVICE_BINARY_NAME:-$BUNDLE_ID_PREFIX.daemon}"
SERVICE_BINARY_PATH="/Library/PrivilegedHelperTools/$SERVICE_BINARY_NAME"
PLIST_PATH="/Library/LaunchDaemons/$SERVICE_LABEL.plist"
SUPPORT_DIR="/Library/Application Support/TMT88VCompat"
LOG_DIR="/Library/Logs/TMT88VCompat"
SERVICE_USER="${SERVICE_USER:-root}"

MIN_MACOS="13.0"
MIN_MACOS_MAJOR="${MIN_MACOS%%.*}"

DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
PKG_FILE_BASENAME="TMT88VCompat-$VERSION"

BINARIES=(tmt88v-service tmt88v-diag tmt88v-test tmt88v-raster-test)

# Code signing identifier for a built binary name.
signing_identifier() {
    case "$1" in
        tmt88v-service) echo "$SERVICE_LABEL" ;;
        tmt88v-diag) echo "$BUNDLE_ID_PREFIX.diag" ;;
        tmt88v-test) echo "$BUNDLE_ID_PREFIX.test" ;;
        tmt88v-raster-test) echo "$BUNDLE_ID_PREFIX.raster-test" ;;
        *) echo "unknown binary $1" >&2; return 1 ;;
    esac
}

# render_template INPUT OUTPUT: substitutes @TOKENS@ and fails if any remain.
render_template() {
    sed -e "s|@LABEL@|$SERVICE_LABEL|g" \
        -e "s|@PKG_ID@|$PKG_IDENTIFIER|g" \
        -e "s|@VERSION@|$VERSION|g" \
        -e "s|@QUEUE_NAME@|$QUEUE_NAME|g" \
        -e "s|@QUEUE_DESCRIPTION@|$QUEUE_DESCRIPTION|g" \
        -e "s|@PRINTER_URI@|$PRINTER_URI|g" \
        -e "s|@PORT@|$IPP_PORT|g" \
        -e "s|@SERVICE_BINARY_PATH@|$SERVICE_BINARY_PATH|g" \
        -e "s|@PLIST_PATH@|$PLIST_PATH|g" \
        -e "s|@SUPPORT_DIR@|$SUPPORT_DIR|g" \
        -e "s|@LOG_DIR@|$LOG_DIR|g" \
        -e "s|@SERVICE_USER@|$SERVICE_USER|g" \
        -e "s|@MIN_MACOS@|$MIN_MACOS|g" \
        -e "s|@MIN_MACOS_MAJOR@|$MIN_MACOS_MAJOR|g" \
        "$1" > "$2"
    if grep -n '@[A-Z_]*@' "$2"; then
        echo "unrendered tokens remain in $2" >&2
        return 1
    fi
}
