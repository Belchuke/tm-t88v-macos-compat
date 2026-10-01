#!/bin/bash
# Shared by preinstall and postinstall. Tokens are rendered by scripts/build-pkg.sh.
# TMT88V_ROOT prefixes every filesystem path; it exists only so the fixture tests can run without touching the system.

LABEL="@LABEL@"
QUEUE="@QUEUE_NAME@"
QUEUE_DESCRIPTION="@QUEUE_DESCRIPTION@"
PRINTER_URI="@PRINTER_URI@"
PORT="@PORT@"
SERVICE_BINARY="@SERVICE_BINARY_PATH@"
PLIST="@PLIST_PATH@"
SUPPORT_DIR="@SUPPORT_DIR@"
LOG_DIR="@LOG_DIR@"
SERVICE_USER="@SERVICE_USER@"
MIN_MACOS_MAJOR=@MIN_MACOS_MAJOR@

ROOT="${TMT88V_ROOT:-}"
STATE_DIR="$ROOT$SUPPORT_DIR/state"
BACKUP_DIR="$STATE_DIR/backup"
STATE_FILE="$STATE_DIR/install-state"
INSTALL_LOG="$ROOT$LOG_DIR/install.log"

log() {
    mkdir -p "$(dirname "$INSTALL_LOG")"
    echo "$(date '+%Y-%m-%dT%H:%M:%S') [tmt88v-installer] $*" | tee -a "$INSTALL_LOG"
}

die() {
    log "ERROR: $*"
    exit 1
}

state_set() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
    echo "$1=$2" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

state_get() {
    sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1
}

service_loaded() {
    launchctl print "system/$LABEL" > /dev/null 2>&1
}

queue_exists() {
    lpstat -v "$QUEUE" > /dev/null 2>&1
}

# Queue attributes are read from `lpoptions -p`, whose key=value tokens are not translated. Do NOT parse `lpstat` text:
# Apple's CUPS localizes it from the system language (Danish prints "enhed til <queue>: <uri>", not "device for ...").
queue_option() {
    lpoptions -p "$QUEUE" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

queue_device_uri() {
    queue_option device-uri
}

# Semantic check, not string equality: scheme ipp, loopback host (127.0.0.1, localhost, [::1]), our port, path /ipp/print.
# An optional ?query is tolerated; userinfo, other hosts (including 127.0.0.2 and lookalike names), other ports, other paths
# and ipps are rejected.
LOOPBACK_URI_REGEX='^ipp://(127\.0\.0\.1|[Ll][Oo][Cc][Aa][Ll][Hh][Oo][Ss][Tt]|\[::1\]):@PORT@/ipp/print(\?[A-Za-z0-9._~%&=:-]*)?$'
uri_is_our_service() {
    [[ "$1" =~ $LOOPBACK_URI_REGEX ]]
}

# Sets VERIFY_REASON. Logs the requested and returned values every time, and full diagnostics on failure.
verify_queue() {
    local uri shared state accepting
    uri="$(queue_device_uri)"
    shared="$(queue_option printer-is-shared)"
    state="$(queue_option printer-state)"
    accepting="$(queue_option printer-is-accepting-jobs)"
    VERIFY_REASON=""
    if [[ -z "$uri" ]]; then
        VERIFY_REASON="CUPS returned no device-uri for queue $QUEUE"
    elif ! uri_is_our_service "$uri"; then
        VERIFY_REASON="device-uri '$uri' is not the local service ($PRINTER_URI or an equivalent loopback form on port $PORT)"
    elif [[ "$shared" != "false" ]]; then
        VERIFY_REASON="printer-is-shared is '$shared', expected 'false'"
    elif [[ "$state" == "5" ]]; then
        VERIFY_REASON="the queue is stopped (printer-state=5)"
    elif [[ "$accepting" == "false" ]]; then
        VERIFY_REASON="the queue is not accepting jobs"
    elif ! ipptool -t "$uri" "$SUPPORT_DIR/share/healthcheck.test" > /dev/null 2>&1; then
        VERIFY_REASON="the queue's device-uri '$uri' does not reach the local service"
    fi
    log "queue check: requested='$PRINTER_URI' cups-returned='$uri' printer-is-shared='$shared' printer-state='$state' accepting-jobs='$accepting'"
    [[ -z "$VERIFY_REASON" ]] && return 0
    queue_diagnostics "$VERIFY_REASON"
    return 1
}

queue_diagnostics() {
    log "==== queue diagnostics ===="
    log "reason the check failed: $1"
    log "requested device URI:    $PRINTER_URI"
    log "parsed device-uri:       '$(queue_device_uri)'"
    log "environment: LANG='${LANG:-}' LC_ALL='${LC_ALL:-}' (CUPS localizes from the system language, not only from these)"
    diag "raw 'lpstat -v $QUEUE' (translated by CUPS, shown for reference only, never parsed)" lpstat -v "$QUEUE"
    diag "raw 'lpoptions -p $QUEUE' (what the check parses)" lpoptions -p "$QUEUE"
    local probe
    probe="$(mktemp)"
    cat > "$probe" <<'T'
{
	NAME "queue attributes as cupsd reports them"
	OPERATION Get-Printer-Attributes
	GROUP operation-attributes-tag
	ATTR charset attributes-charset utf-8
	ATTR language attributes-natural-language en
	ATTR uri printer-uri $uri
	ATTR keyword requested-attributes device-uri,printer-uri-supported,printer-is-shared,printer-state,printer-state-reasons,printer-is-accepting-jobs
}
T
    diag "ipptool Get-Printer-Attributes to cupsd (authoritative)" ipptool -tv "ipp://localhost/printers/$QUEUE" "$probe"
    rm -f "$probe"
    log "==== end of queue diagnostics ===="
}

port_listener() {
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2
}

KEEP_FLAG_FILE="/private/var/tmp/@LABEL@.keep-failed-state"

# Development only. Rollback is skipped when TMT88V_INSTALLER_KEEP_FAILED_STATE=1 is in the environment, or when the
# root-owned flag file exists (sudo does not pass the environment through to Installer-run scripts):
#   sudo touch /private/var/tmp/@LABEL@.keep-failed-state
keep_failed_state() {
    [[ "${TMT88V_INSTALLER_KEEP_FAILED_STATE:-0}" == "1" ]] && return 0
    [[ -n "$ROOT" ]] && return 1
    [[ -f "$KEEP_FLAG_FILE" && "$(stat -f %u "$KEEP_FLAG_FILE" 2>/dev/null)" == "0" ]]
}

diag() {
    local title="$1"; shift
    log "---- diagnostic: $title"
    "$@" 2>&1 | sed 's/^/    /' | tee -a "$INSTALL_LOG" || true
}

# Everything needed to see why the service is not answering. Never suppressed, always before any rollback.
collect_diagnostics() {
    log "==== service diagnostics ===="
    diag "launchctl print system/$LABEL" launchctl print "system/$LABEL"
    diag "processes (pgrep -alf $LABEL / tmt88v)" bash -c "pgrep -alf '$LABEL'; pgrep -alf 'tmt88v'; true"
    diag "listener on port $PORT" lsof -nP -iTCP:"$PORT" -sTCP:LISTEN
    diag "ls -la $SERVICE_BINARY" ls -la "$ROOT$SERVICE_BINARY"
    diag "file $SERVICE_BINARY" file "$ROOT$SERVICE_BINARY"
    diag "codesign --verify --deep --strict --verbose=4" codesign --verify --deep --strict --verbose=4 "$ROOT$SERVICE_BINARY"
    diag "plutil -p $PLIST" plutil -p "$ROOT$PLIST"
    diag "service.log" bash -c "tail -n 40 '$ROOT$LOG_DIR/service.log' 2>&1 || echo '(no service.log: the service never wrote a log line)'"
    diag "service-stderr.log" bash -c "tail -n 40 '$ROOT$LOG_DIR/service-stderr.log' 2>&1 || echo '(no service-stderr.log)'"
    local logbin="/usr/bin/log"
    [[ -n "$ROOT" ]] && logbin="log"
    diag "unified log, last 3 minutes (belchuke / tmt88v / syspolicyd exec policy)" \
        "$logbin" show --last 3m --style compact --predicate \
        'eventMessage CONTAINS[c] "belchuke" OR eventMessage CONTAINS[c] "tmt88v" OR (process == "syspolicyd" AND subsystem == "com.apple.syspolicy.exec") OR (process == "launchd" AND eventMessage CONTAINS[c] "tmt88v")'
    log "==== end of diagnostics ===="
}

# Undo only what this installer run created. Never touches any other queue or any Epson file.
rollback() {
    log "rolling back resources created by this installer run"
    if [[ "$(state_get queue_created_this_run)" == "1" ]]; then
        lpadmin -x "$QUEUE" > /dev/null 2>&1 && log "removed queue $QUEUE" || log "WARNING: could not remove queue $QUEUE"
    fi
    launchctl bootout "system/$LABEL" > /dev/null 2>&1 || true
    if [[ -f "$BACKUP_DIR/service" ]]; then
        cp -p "$BACKUP_DIR/service" "$ROOT$SERVICE_BINARY"
        [[ -f "$BACKUP_DIR/plist" ]] && cp -p "$BACKUP_DIR/plist" "$ROOT$PLIST"
        log "restored previous service files"
        if [[ "$(state_get service_loaded_before)" == "1" ]]; then
            launchctl bootstrap system "$PLIST" > /dev/null 2>&1 && log "restarted previous service" || log "WARNING: could not restart previous service"
        fi
    elif [[ "$(state_get binary_existed_before)" == "0" ]]; then
        rm -f "$ROOT$SERVICE_BINARY" "$ROOT$PLIST"
        log "removed newly installed service files"
    fi
    state_set phase rolled-back
}
