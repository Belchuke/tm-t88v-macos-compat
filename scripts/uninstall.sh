#!/bin/bash
# Development uninstaller. Removes only what the TMT88V Compat installer created:
#   the TMT88V_Compat queue (and only if it points at our IPP address), our launchd job, our service binary,
#   our support and log directories, and our package receipt.
# It never touches Epson queues, Epson drivers under /Library/Printers, or any other CUPS setting.
#
#   sudo ./scripts/uninstall.sh [--yes] [--keep-logs]
#   TMT88V_DRY_RUN=1 ./scripts/uninstall.sh --yes     print the actions without running them
#   TMT88V_ROOT=/some/dir                             prefix for filesystem paths (used by the fixture tests)
set -euo pipefail

LABEL="${SERVICE_LABEL:-com.belchuke.tmt88vcompat.service}"
PKG_ID="${PKG_IDENTIFIER:-com.belchuke.tmt88vcompat.pkg}"
QUEUE="${QUEUE_NAME:-TMT88V_Compat}"
PORT="${IPP_PORT:-8632}"
PRINTER_URI="ipp://127.0.0.1:$PORT/ipp/print"
ROOT="${TMT88V_ROOT:-}"
DRY="${TMT88V_DRY_RUN:-0}"
PREFIX="${BUNDLE_ID_PREFIX:-com.belchuke.tmt88vcompat}"
SERVICE_BINARY="/Library/PrivilegedHelperTools/${SERVICE_BINARY_NAME:-$PREFIX.daemon}"
LEGACY_SERVICE_BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/TMT88VCompat"
LOG_DIR="/Library/Logs/TMT88VCompat"

assume_yes=0
keep_logs=0
for arg in "$@"; do
    case "$arg" in
        --yes) assume_yes=1 ;;
        --keep-logs) keep_logs=1 ;;
        *) echo "unknown argument $arg" >&2; exit 2 ;;
    esac
done

# Same rule as the installer: parse `lpoptions` (not translated), never `lpstat` text (Apple's CUPS localizes it: Danish prints
# "enhed til <queue>: <uri>"). Accepts only ipp:// to a loopback host on our port and path.
queue_device_uri() {
    lpoptions -p "$QUEUE" 2>/dev/null | tr ' ' '\n' | sed -n "s/^device-uri=//p" | head -n 1
}
LOOPBACK_URI_REGEX="^ipp://(127\\.0\\.0\\.1|[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]|\\[::1\\]):$PORT/ipp/print(\\?[A-Za-z0-9._~%&=:-]*)?\$"
uri_is_our_service() {
    [[ "$1" =~ $LOOPBACK_URI_REGEX ]]
}

run() {
    if [[ "$DRY" == "1" ]]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

if [[ "$DRY" != "1" && -z "$ROOT" && "$(id -u)" != "0" ]]; then
    echo "run with sudo: sudo $0 $*" >&2
    exit 1
fi

cat <<T
This will remove:
  launchd job        $LABEL
  launchd plist      $PLIST
  service binary     $SERVICE_BINARY
  print queue        $QUEUE (only if its device URI is the local service on port $PORT)
  support directory  $SUPPORT_DIR
  log directory      $LOG_DIR$([[ $keep_logs == 1 ]] && echo " (kept: --keep-logs)")
  package receipt    $PKG_ID
It will NOT touch any Epson queue (for example EPSON_TM_T88V), /Library/Printers, or any other CUPS setting.
T

if [[ "$assume_yes" != "1" ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "aborted"; exit 1; }
fi

run launchctl bootout "system/$LABEL" 2>/dev/null || true

if lpstat -v "$QUEUE" > /dev/null 2>&1; then
    uri="$(queue_device_uri)"
    if uri_is_our_service "$uri"; then
        run lpadmin -x "$QUEUE"
        echo "removed queue $QUEUE"
    else
        echo "queue $QUEUE points at '$uri', not at our service; left untouched"
    fi
else
    echo "queue $QUEUE not present"
fi

run rm -f "$ROOT$PLIST" "$ROOT$SERVICE_BINARY" "$ROOT$LEGACY_SERVICE_BINARY"
run rm -rf "$ROOT$SUPPORT_DIR"
[[ "$keep_logs" == "1" ]] || run rm -rf "$ROOT$LOG_DIR"
[[ -n "$ROOT" ]] || run pkgutil --forget "$PKG_ID" > /dev/null 2>&1 || true

echo "uninstall complete"
