#!/bin/bash
# Fixture tests for the installer scripts, plist, identifiers and uninstaller.
# Nothing here touches the system: launchctl, lpadmin, lpstat, ... are stubs and all paths live under a temp TMT88V_ROOT.
set -uo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
failures=0

check() {
    local name="$1"; shift
    if "$@"; then pass=$((pass + 1)); echo "  ok   $name"; else failures=$((failures + 1)); echo "  FAIL $name"; fi
}
equals() { [[ "$1" == "$2" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
file_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

make_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/launchctl" <<'S'
#!/bin/bash
echo "launchctl $*" >> "$STUB_STATE/calls"
label=""
case "$1" in
    print|bootout|enable) label="${2#system/}" ;;
    bootstrap) label="$(basename "${3%.plist}")" ;;
esac
tag=service; [[ "$label" == *.updater ]] && tag=updater
case "$1" in
    print) [[ -f "$STUB_STATE/loaded.$tag" ]] ;;
    bootstrap)
        [[ "$tag" == "service" && -n "${STUB_FAIL_BOOTSTRAP:-}" ]] && exit 1
        [[ "$tag" == "updater" && -n "${STUB_FAIL_BOOTSTRAP_UPDATER:-}" ]] && exit 1
        touch "$STUB_STATE/loaded.$tag" ;;
    bootout) rm -f "$STUB_STATE/loaded.$tag" ;;
    *) exit 0 ;;
esac
S
    cat > "$bin/lpadmin" <<'S'
#!/bin/bash
echo "lpadmin $*" >> "$STUB_STATE/calls"
[[ -n "${STUB_FAIL_LPADMIN:-}" ]] && { echo "lpadmin: forbidden" >&2; exit 1; }
name=""; uri=""; remove=""; shared="true"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) name="$2"; shift 2 ;;
        -x) remove="$2"; shift 2 ;;
        -v) uri="$2"; shift 2 ;;
        -o) [[ "$2" == "printer-is-shared=false" ]] && shared="false"; shift 2 ;;
        -m|-D) shift 2 ;;
        *) shift ;;
    esac
done
touch "$STUB_STATE/queues"
[[ -n "${STUB_CANONICAL_URI:-}" ]] && uri="$STUB_CANONICAL_URI"
[[ -n "${STUB_IGNORE_SHARED:-}" ]] && shared="true"
if [[ -n "$remove" ]]; then
    grep -v "^$remove|" "$STUB_STATE/queues" > "$STUB_STATE/queues.new"; mv "$STUB_STATE/queues.new" "$STUB_STATE/queues"
else
    grep -v "^$name|" "$STUB_STATE/queues" > "$STUB_STATE/queues.new"; echo "$name|$uri|$shared" >> "$STUB_STATE/queues.new"; mv "$STUB_STATE/queues.new" "$STUB_STATE/queues"
fi
S
    cat > "$bin/lpstat" <<'S'
#!/bin/bash
touch "$STUB_STATE/queues"
mode="$1"; name="$2"
line="$(grep "^$name|" "$STUB_STATE/queues")" || {
    if [[ "${STUB_LPSTAT_LANG:-en}" == "da" ]]; then echo "lpstat: Ugyldigt destinationsnavn på listen \"$name\"." >&2; else echo "lpstat: Invalid destination name in list \"$name\"." >&2; fi
    exit 1
}
uri="$(echo "$line" | cut -d'|' -f2)"
case "$mode" in
    -v) if [[ "${STUB_LPSTAT_LANG:-en}" == "da" ]]; then echo "enhed til $name: $uri"; else echo "device for $name: $uri"; fi ;;
    -p) if [[ "${STUB_LPSTAT_LANG:-en}" == "da" ]]; then echo "printeren $name er inaktiv. aktiveret siden i dag"; else echo "printer $name is idle.  enabled since today"; fi ;;
esac
S
    cat > "$bin/lpoptions" <<'S'
#!/bin/bash
line="$(grep "^$2|" "$STUB_STATE/queues")" || { echo "garbage"; exit 0; }
echo "copies=1 device-uri=$(echo "$line" | cut -d'|' -f2) finishings=3 printer-info='EPSON TM-T88V' printer-is-accepting-jobs=${STUB_ACCEPTING:-true} printer-is-shared=$(echo "$line" | cut -d'|' -f3) printer-state=${STUB_QUEUE_STATE:-3} printer-type=36932"
S
    cat > "$bin/ipptool" <<'S'
#!/bin/bash
[[ -z "${STUB_SERVICE_DOWN:-}" ]] || exit 1
[[ -n "${STUB_FAIL_URI_PROBE:-}" && "$*" == *"$STUB_FAIL_URI_PROBE"* ]] && exit 1
echo "        device-uri (uri) = stub"
exit 0
S
    cat > "$bin/sysctl" <<'S'
#!/bin/bash
echo "${STUB_ARM:-1}"
S
    cat > "$bin/sw_vers" <<'S'
#!/bin/bash
echo "${STUB_MACOS:-14.0}"
S
    printf '#!/bin/bash\necho "log stub"\n' > "$bin/log"
    cat > "$bin/lsof" <<'S'
#!/bin/bash
if [[ -n "${STUB_PORT_BUSY:-}" ]]; then echo "COMMAND PID USER"; echo "other 123 someone TCP 127.0.0.1:8632 (LISTEN)"; fi
exit 0
S
    printf '#!/bin/bash\nexit 0\n' > "$bin/sleep"
    chmod +x "$bin"/*
}

# new_fixture NAME: fresh fake root, stubs and rendered package scripts
new_fixture() {
    F="$TMP/$1"
    mkdir -p "$F/root" "$F/state" "$F/scripts" "$F/stubs"
    make_stubs "$F/stubs"
    touch "$F/state/queues"
    for s in preinstall postinstall lib.sh; do render_template "pkg/scripts/$s" "$F/scripts/$s"; done
    chmod +x "$F/scripts/preinstall" "$F/scripts/postinstall"
    export TMT88V_ROOT="$F/root" STUB_STATE="$F/state" PATH="$F/stubs:$ORIG_PATH"
    unset STUB_FAIL_BOOTSTRAP STUB_FAIL_LPADMIN STUB_SERVICE_DOWN STUB_ARM STUB_MACOS STUB_PORT_BUSY STUB_BINARY_EXIT TMT88V_INSTALLER_KEEP_FAILED_STATE STUB_LPSTAT_LANG STUB_CANONICAL_URI STUB_IGNORE_SHARED STUB_QUEUE_STATE STUB_ACCEPTING STUB_FAIL_URI_PROBE STUB_FAIL_BOOTSTRAP_UPDATER STUB_UPDATER_EXIT
}

# place_payload CONTENT: simulates Installer laying down the payload files
place_payload() {
    mkdir -p "$TMT88V_ROOT$(dirname "$SERVICE_BINARY_PATH")" "$TMT88V_ROOT$(dirname "$PLIST_PATH")" "$TMT88V_ROOT$SUPPORT_DIR/share"
    printf '#!/bin/bash\n# %s\nexit "${STUB_BINARY_EXIT:-0}"\n' "${1:-new}" > "$TMT88V_ROOT$SERVICE_BINARY_PATH"
    chmod +x "$TMT88V_ROOT$SERVICE_BINARY_PATH"
    echo "plist" > "$TMT88V_ROOT$PLIST_PATH"
    mkdir -p "$TMT88V_ROOT$(dirname "$UPDATER_BINARY_PATH")" "$TMT88V_ROOT$(dirname "$UPDATER_PLIST_PATH")"
    printf '#!/bin/bash\n# %s\nexit "${STUB_UPDATER_EXIT:-0}"\n' "${2:-new-updater}" > "$TMT88V_ROOT$UPDATER_BINARY_PATH"
    chmod +x "$TMT88V_ROOT$UPDATER_BINARY_PATH"
    echo "updater-plist-${2:-new-updater}" > "$TMT88V_ROOT$UPDATER_PLIST_PATH"
    printf '{\n  "automaticUpdates": true\n}\n' > "$TMT88V_ROOT$SUPPORT_DIR/share/config.default.json"
}

run_install() {
    "$F/scripts/preinstall" > "$F/pre.out" 2>&1 || return 11
    place_payload "${1:-new}" "${2:-new-updater}"
    "$F/scripts/postinstall" > "$F/post.out" 2>&1 || return 12
}

queue_count() { grep -c "^$1|" "$STUB_STATE/queues" || true; }
calls_have() { grep -qF -- "$1" "$STUB_STATE/calls"; }
calls_lack() { ! grep -qF -- "$1" "$STUB_STATE/calls" 2>/dev/null; }
state_is() { grep -qx "$1=$2" "$TMT88V_ROOT$SUPPORT_DIR/state/install-state"; }
service_running() { [[ -f "$STUB_STATE/loaded.service" ]]; }
updater_running() { [[ -f "$STUB_STATE/loaded.updater" ]]; }
mode_of() { stat -f %Lp "$1"; }

ORIG_PATH="$PATH"

echo "identifiers and templates"
check "service label"        equals "$SERVICE_LABEL" "com.belchuke.tmt88vcompat.service"
check "package identifier"   equals "$PKG_IDENTIFIER" "com.belchuke.tmt88vcompat.pkg"
check "manager identifier"   equals "$MANAGER_IDENTIFIER" "com.belchuke.tmt88vcompat.manager"
check "bundle prefix"        equals "$BUNDLE_ID_PREFIX" "com.belchuke.tmt88vcompat"
check "printer uri"          equals "$PRINTER_URI" "ipp://127.0.0.1:8632/ipp/print"
check "queue name"           equals "$QUEUE_NAME" "TMT88V_Compat"
check "signing id service"   equals "$(signing_identifier tmt88v-service)" "com.belchuke.tmt88vcompat.service"
check "signing id diag"      equals "$(signing_identifier tmt88v-diag)" "com.belchuke.tmt88vcompat.diag"
check "no old placeholder anywhere" bash -c '! grep -rIl "org.tmt88v-compat" scripts pkg Sources Package.swift README.md docs 2>/dev/null | grep -v test-installer.sh | grep .'

PLIST_OUT="$TMP/service.plist"
render_template pkg/launchd/service.plist.template "$PLIST_OUT"
check "plist lints"               plutil -lint "$PLIST_OUT"
check "plist label"               equals "$(plutil -extract Label raw "$PLIST_OUT")" "$SERVICE_LABEL"
check "plist program"             equals "$(plutil -extract ProgramArguments.0 raw "$PLIST_OUT")" "/Library/PrivilegedHelperTools/com.belchuke.tmt88vcompat.daemon"
check "plist port"                equals "$(plutil -extract ProgramArguments.2 raw "$PLIST_OUT")" "8632"
check "plist log path"            equals "$(plutil -extract ProgramArguments.4 raw "$PLIST_OUT")" "/Library/Logs/TMT88VCompat/service.log"
check "plist quiet flag"          equals "$(plutil -extract ProgramArguments.5 raw "$PLIST_OUT")" "--quiet"
check "plist RunAtLoad"           equals "$(plutil -extract RunAtLoad raw "$PLIST_OUT")" "true"
check "plist KeepAlive SuccessfulExit=false" equals "$(plutil -extract KeepAlive.SuccessfulExit raw "$PLIST_OUT")" "false"
check "plist ThrottleInterval 30" equals "$(plutil -extract ThrottleInterval raw "$PLIST_OUT")" "30"
check "plist loopback only (no Sockets/bonjour keys)" file_lacks "$PLIST_OUT" "Sockets"
for t in preinstall postinstall lib.sh; do
    render_template "pkg/scripts/$t" "$TMP/$t.out"
    check "script $t renders and parses" bash -n "$TMP/$t.out"
done
render_template pkg/distribution.xml.template "$TMP/dist.xml"
check "distribution is arm64-only" file_has "$TMP/dist.xml" 'hostArchitectures="arm64"'
check "distribution min macOS"     file_has "$TMP/dist.xml" 'min="13.0"'
check "distribution system domain only" file_has "$TMP/dist.xml" 'enable_localSystem="true"'
check "distribution package id"    file_has "$TMP/dist.xml" "$PKG_IDENTIFIER"
check "uninstall defaults match config" bash -c "grep -q 'com.belchuke.tmt88vcompat.service' scripts/uninstall.sh && grep -q 'TMT88V_Compat' scripts/uninstall.sh && grep -q 'com.belchuke.tmt88vcompat.pkg' scripts/uninstall.sh"

echo "fresh install"
new_fixture fresh
echo "EPSON_TM_T88V|usb://EPSON/TM-T88V?serial=1|false" >> "$STUB_STATE/queues"
run_install; rc=$?
check "install succeeds" equals "$rc" "0"
check "service loaded" service_running
check "queue created once" equals "$(queue_count "$QUEUE_NAME")" "1"
check "queue device URI" grep -q "^$QUEUE_NAME|$PRINTER_URI|false" "$STUB_STATE/queues"
check "lpadmin uses driverless, enabled, not shared" calls_have "lpadmin -p $QUEUE_NAME -E -v $PRINTER_URI -m everywhere -D $QUEUE_DESCRIPTION -o printer-is-shared=false"
check "state complete" state_is phase complete
check "queue recorded as created this run" state_is queue_created_this_run 1
check "no queue removed" calls_lack "lpadmin -x"
check "launchctl uses bootstrap, not load" calls_lack "launchctl load"
check "Epson queue untouched" grep -q "^EPSON_TM_T88V|" "$STUB_STATE/queues"
check "install log written" test -s "$TMT88V_ROOT$LOG_DIR/install.log"

echo "idempotent re-run"
: > "$STUB_STATE/calls"
run_install; rc=$?
check "second install succeeds" equals "$rc" "0"
check "still exactly one queue" equals "$(queue_count "$QUEUE_NAME")" "1"
check "re-run does not claim to have created the queue" state_is queue_created_this_run 0
check "re-run stops the running service first" calls_have "launchctl bootout system/$SERVICE_LABEL"
check "re-run never removes a queue" calls_lack "lpadmin -x"
check "Epson queue still untouched" grep -q "^EPSON_TM_T88V|" "$STUB_STATE/queues"
run_install; check "third install succeeds" equals "$?" "0"
check "still exactly one queue after three runs" equals "$(queue_count "$QUEUE_NAME")" "1"

echo "refusals before changing anything"
new_fixture wrongq
echo "$QUEUE_NAME|ipp://somewhere.else/ipp|true" >> "$STUB_STATE/queues"
run_install; check "queue with foreign URI is refused" equals "$?" "11"
check "foreign queue unmodified" grep -qx "$QUEUE_NAME|ipp://somewhere.else/ipp|true" "$STUB_STATE/queues"
check "nothing bootstrapped" calls_lack "launchctl bootstrap"
new_fixture busy; export STUB_PORT_BUSY=1
run_install; check "busy port is refused" equals "$?" "11"
check "busy-port message names the port" file_has "$F/pre.out" "port $IPP_PORT is already in use"
check "busy port: nothing bootstrapped" calls_lack "launchctl bootstrap"
new_fixture oldmac; export STUB_MACOS=12.6
run_install; check "macOS 12 is refused" equals "$?" "11"
new_fixture intel; export STUB_ARM=0
run_install; check "non-Apple-Silicon is refused" equals "$?" "11"

echo "rollback"
new_fixture down; export STUB_SERVICE_DOWN=1
run_install; check "service that never answers fails the install" equals "$?" "12"
check "failed install: no queue created" equals "$(queue_count "$QUEUE_NAME")" "0"
check "failed install: service stopped" test ! -f "$STUB_STATE/loaded.service"
check "failed install: new binary removed" test ! -e "$TMT88V_ROOT$SERVICE_BINARY_PATH"
check "failed install: new plist removed" test ! -e "$TMT88V_ROOT$PLIST_PATH"
check "failed install: state rolled back" state_is phase rolled-back

new_fixture lpfail; echo "EPSON_TM_T88V|usb://x|false" >> "$STUB_STATE/queues"; export STUB_FAIL_LPADMIN=1
run_install; check "queue creation failure fails the install" equals "$?" "12"
check "queue failure: no queue left behind" equals "$(queue_count "$QUEUE_NAME")" "0"
check "queue failure: service stopped" test ! -f "$STUB_STATE/loaded.service"
check "queue failure: Epson queue untouched" grep -q "^EPSON_TM_T88V|" "$STUB_STATE/queues"
check "queue failure: message is clear" file_has "$F/post.out" "lpadmin could not create or update queue"

new_fixture bootfail; export STUB_FAIL_BOOTSTRAP=1
run_install; check "bootstrap failure fails the install" equals "$?" "12"
check "bootstrap failure: no queue" equals "$(queue_count "$QUEUE_NAME")" "0"

new_fixture upgrade
run_install "old-binary"; check "initial install" equals "$?" "0"
export STUB_SERVICE_DOWN=1
run_install "new-binary"; check "failed upgrade fails" equals "$?" "12"
check "failed upgrade restores the previous binary" file_has "$TMT88V_ROOT$SERVICE_BINARY_PATH" "# old-binary"
check "failed upgrade restarts the previous service" service_running
check "failed upgrade keeps the pre-existing queue" equals "$(queue_count "$QUEUE_NAME")" "1"
check "failed upgrade did not remove the queue" calls_lack "lpadmin -x"


echo "binary file name (the root cause of the failed real install)"
check "service binary is not named like a bundle (.service/.app)" bash -c "case '$(basename "$SERVICE_BINARY_PATH")' in *.service|*.app|*.xpc|*.bundle|*.framework|*.plugin) exit 1;; esac"
check "service binary name"  equals "$(basename "$SERVICE_BINARY_PATH")" "com.belchuke.tmt88vcompat.daemon"
check "plist launches the renamed binary" equals "$(plutil -extract ProgramArguments.0 raw "$PLIST_OUT")" "$SERVICE_BINARY_PATH"
check "launchd label is unchanged (.service label is fine)" equals "$SERVICE_LABEL" "com.belchuke.tmt88vcompat.service"
REAL_BIN="$REPO_ROOT/build/dist/tmt88v-service"
if [[ -x "$REAL_BIN" ]]; then
    smoke_dir="$(mktemp -d)"
    cp "$REAL_BIN" "$smoke_dir/$(basename "$SERVICE_BINARY_PATH")"
    "$smoke_dir/$(basename "$SERVICE_BINARY_PATH")" --help > /dev/null 2>&1
    check "real signed binary runs (exit 0) under its installed file name" equals "$?" "0"
else
    echo "  skip real-binary exec check (run ./scripts/build.sh first)"
fi

echo "exec canary and diagnostics"
new_fixture killed; export STUB_BINARY_EXIT=137
run_install; check "a binary killed at exec fails the install" equals "$?" "12"
check "message says SIGKILL at exec" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "killed with SIGKILL at exec"
check "failure is caught before launchd is involved" calls_lack "launchctl bootstrap"
check "diagnostics printed before rollback" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "==== service diagnostics ===="
check "diagnostics: launchctl print" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: launchctl print system/$SERVICE_LABEL"
check "diagnostics: port listener" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: listener on port $IPP_PORT"
check "diagnostics: file" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: file "
check "diagnostics: codesign" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: codesign --verify --deep --strict --verbose=4"
check "diagnostics: plist" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: plutil -p"
check "diagnostics: service.log" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: service.log"
check "diagnostics: service-stderr.log" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: service-stderr.log"
check "diagnostics: unified log" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "diagnostic: unified log"
check "diagnostics: missing service.log is explained" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "never wrote a log line"
check "diagnostics come before the rollback" bash -c "awk '/==== service diagnostics/{d=NR} /rolling back resources/{r=NR} END{exit !(d && r && d<r)}' '$TMT88V_ROOT$LOG_DIR/install.log'"
check "killed binary: rolled back (no files, no queue)" bash -c "[[ ! -e '$TMT88V_ROOT$SERVICE_BINARY_PATH' && \$(grep -c '^$QUEUE_NAME|' '$STUB_STATE/queues') == 0 ]]"

new_fixture unreach; export STUB_SERVICE_DOWN=1
run_install; check "unreachable service fails the install" equals "$?" "12"
check "health-check failure also prints diagnostics" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "==== service diagnostics ===="
check "health-check failure is rolled back by default" test ! -e "$TMT88V_ROOT$SERVICE_BINARY_PATH"

echo "developer debug mode (TMT88V_INSTALLER_KEEP_FAILED_STATE)"
new_fixture keep; export STUB_SERVICE_DOWN=1 TMT88V_INSTALLER_KEEP_FAILED_STATE=1
run_install; check "debug mode: install still reports failure" equals "$?" "12"
check "debug mode: binary left in place" test -x "$TMT88V_ROOT$SERVICE_BINARY_PATH"
check "debug mode: plist left in place" test -f "$TMT88V_ROOT$PLIST_PATH"
check "debug mode: launchd job left loaded" service_running
check "debug mode: logs left in place" test -s "$TMT88V_ROOT$LOG_DIR/install.log"
check "debug mode: says rollback was skipped on purpose" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "rollback intentionally SKIPPED"
check "debug mode: no queue created" equals "$(queue_count "$QUEUE_NAME")" "0"
check "debug mode: state recorded" state_is phase failed-kept-for-debugging
check "debug mode: no rollback actions ran" calls_lack "lpadmin -x"
new_fixture keepq; export STUB_FAIL_LPADMIN=1 TMT88V_INSTALLER_KEEP_FAILED_STATE=1
run_install; check "debug mode does not apply to queue failures" equals "$?" "12"
check "queue failure still rolls back in debug mode" test ! -e "$TMT88V_ROOT$SERVICE_BINARY_PATH"
new_fixture off
run_install; check "debug mode is off by default" equals "$?" "0"
check "default install never mentions skipped rollback" file_lacks "$TMT88V_ROOT$LOG_DIR/install.log" "SKIPPED"


echo "queue verification: locale (Apple's CUPS translates lpstat; Danish prints 'enhed til <queue>: <uri>')"
new_fixture danish; export STUB_LPSTAT_LANG=da
echo "EPSON_TM_T88V|usb://EPSON/TM-T88V?serial=1|false" >> "$STUB_STATE/queues"
check "stub really speaks Danish" bash -c "lpstat -v EPSON_TM_T88V | grep -q '^enhed til EPSON_TM_T88V: '"
run_install; check "install succeeds when CUPS output is Danish" equals "$?" "0"
check "Danish: queue verified in the log" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "verified (device URI $PRINTER_URI"
run_install; check "Danish: re-run is accepted (preinstall recognises our own queue)" equals "$?" "0"
check "Danish: still one queue" equals "$(queue_count "$QUEUE_NAME")" "1"
./scripts/uninstall.sh --yes > "$F/un.out" 2>&1; check "Danish: uninstall removes our queue" equals "$(queue_count "$QUEUE_NAME")" "0"
check "Danish: uninstall leaves the Epson queue" grep -q "^EPSON_TM_T88V|" "$STUB_STATE/queues"
new_fixture danishrb; export STUB_LPSTAT_LANG=da STUB_SERVICE_DOWN=1
run_install; check "Danish: rollback still works" equals "$?" "12"
check "Danish: rolled back, no queue" equals "$(queue_count "$QUEUE_NAME")" "0"

echo "queue verification: URI canonicalization (semantic, not string equality)"
for good in "ipp://localhost:$IPP_PORT/ipp/print" "ipp://LOCALHOST:$IPP_PORT/ipp/print" "ipp://[::1]:$IPP_PORT/ipp/print" "ipp://127.0.0.1:$IPP_PORT/ipp/print?uuid=0123-abc"; do
    new_fixture "good$RANDOM"; export STUB_CANONICAL_URI="$good"
    run_install; check "accepts $good" equals "$?" "0"
    check "  queue kept for $good" equals "$(queue_count "$QUEUE_NAME")" "1"
done
for bad in "ipp://192.168.1.5:$IPP_PORT/ipp/print" "ipp://printer.example.com:$IPP_PORT/ipp/print" "ipp://127.0.0.2:$IPP_PORT/ipp/print" \
           "ipp://127.0.0.1.evil.com:$IPP_PORT/ipp/print" "ipp://127.0.0.1:9999/ipp/print" "ipp://127.0.0.1:$IPP_PORT/ipp/other" \
           "ipps://127.0.0.1:$IPP_PORT/ipp/print" "ipp://user@127.0.0.1:$IPP_PORT/ipp/print" "ipp://127.0.0.1:$IPP_PORT/ipp/print#x" \
           "usb://EPSON/TM-T88V?serial=1" "ipp://[2001:db8::1]:$IPP_PORT/ipp/print"; do
    new_fixture "bad$RANDOM"; export STUB_CANONICAL_URI="$bad"
    run_install; check "rejects $bad" equals "$?" "12"
    check "  rolled back for $bad" equals "$(queue_count "$QUEUE_NAME")" "0"
done
new_fixture unreachable; export STUB_CANONICAL_URI="ipp://localhost:$IPP_PORT/ipp/print" STUB_FAIL_URI_PROBE="localhost:$IPP_PORT"
run_install; check "a loopback URI that does not reach our service is rejected" equals "$?" "12"
check "  reason says it does not reach the service" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "does not reach the local service"

echo "queue verification: printer-is-shared and state"
new_fixture shared; export STUB_IGNORE_SHARED=1
run_install; check "a queue left shared fails the install" equals "$?" "12"
check "  reason names printer-is-shared" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "printer-is-shared is 'true', expected 'false'"
check "  rolled back" equals "$(queue_count "$QUEUE_NAME")" "0"
new_fixture stopped; export STUB_QUEUE_STATE=5
run_install; check "a stopped queue fails the install" equals "$?" "12"
check "  reason says stopped" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "the queue is stopped"
new_fixture notaccepting; export STUB_ACCEPTING=false
run_install; check "a queue not accepting jobs fails the install" equals "$?" "12"
new_fixture sharedok
run_install; check "normal install confirms printer-is-shared=false in the log" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "printer-is-shared='false'"

echo "queue verification: diagnostics on failure"
new_fixture qdiag; export STUB_CANONICAL_URI="ipp://192.168.1.5:$IPP_PORT/ipp/print" STUB_LPSTAT_LANG=da
run_install
check "diag: section header" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "==== queue diagnostics ===="
check "diag: requested URI" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "requested device URI:    $PRINTER_URI"
check "diag: parsed URI" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "parsed device-uri:       'ipp://192.168.1.5:$IPP_PORT/ipp/print'"
check "diag: reason" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "reason the check failed: device-uri 'ipp://192.168.1.5:$IPP_PORT/ipp/print' is not the local service"
check "diag: raw lpstat output (translated) is captured" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "enhed til $QUEUE_NAME: ipp://192.168.1.5"
check "diag: raw lpoptions output is captured" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "device-uri=ipp://192.168.1.5"
check "diag: authoritative ipptool query attempted" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "ipptool Get-Printer-Attributes to cupsd"
check "diag: one-line summary of requested vs returned" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "queue check: requested='$PRINTER_URI' cups-returned='ipp://192.168.1.5:$IPP_PORT/ipp/print'"

echo "uri_is_our_service direct table"
new_fixture uritable
uri_case() { (source "$F/scripts/lib.sh"; uri_is_our_service "$2"; [[ $? -eq 0 ]] && r=accept || r=reject; [[ "$r" == "$1" ]]); }
check "accept 127.0.0.1" uri_case accept "ipp://127.0.0.1:$IPP_PORT/ipp/print"
check "accept localhost" uri_case accept "ipp://localhost:$IPP_PORT/ipp/print"
check "accept [::1]" uri_case accept "ipp://[::1]:$IPP_PORT/ipp/print"
check "reject LAN address" uri_case reject "ipp://10.0.0.7:$IPP_PORT/ipp/print"
check "reject empty" uri_case reject ""
check "uninstall.sh applies the same rule" bash -c "PORT=$IPP_PORT; eval \"\$(sed -n '/^LOOPBACK_URI_REGEX=/,/^}/p' scripts/uninstall.sh)\"; uri_is_our_service 'ipp://localhost:$IPP_PORT/ipp/print' && ! uri_is_our_service 'ipp://10.0.0.7:$IPP_PORT/ipp/print'"


echo "automatic updater: package scripts, plist and config"
UPDATER_PLIST_OUT="$TMP/updater.plist"
render_template pkg/launchd/updater.plist.template "$UPDATER_PLIST_OUT"
check "updater plist lints" plutil -lint "$UPDATER_PLIST_OUT"
check "updater label" equals "$(plutil -extract Label raw "$UPDATER_PLIST_OUT")" "com.belchuke.tmt88vcompat.updater"
check "updater label equals config" equals "$UPDATER_LABEL" "com.belchuke.tmt88vcompat.updater"
check "updater binary path" equals "$(plutil -extract ProgramArguments.0 raw "$UPDATER_PLIST_OUT")" "/Library/PrivilegedHelperTools/com.belchuke.tmt88vcompat.updater"
check "updater runs the 'run' subcommand" equals "$(plutil -extract ProgramArguments.1 raw "$UPDATER_PLIST_OUT")" "run"
check "updater is root" equals "$(plutil -extract UserName raw "$UPDATER_PLIST_OUT")" "root"
check "updater RunAtLoad" equals "$(plutil -extract RunAtLoad raw "$UPDATER_PLIST_OUT")" "true"
check "updater wakes hourly (it decides in-process whether 24h+jitter has passed)" equals "$(plutil -extract StartInterval raw "$UPDATER_PLIST_OUT")" "3600"
check "updater runs as a background process" equals "$(plutil -extract ProcessType raw "$UPDATER_PLIST_OUT")" "Background"
check "updater is not kept alive in a loop" bash -c "! plutil -extract KeepAlive raw '$UPDATER_PLIST_OUT' >/dev/null 2>&1"
check "updater binary file name is not bundle-style" bash -c "case '$(basename "$UPDATER_BINARY_PATH")' in *.service|*.app|*.xpc|*.bundle) exit 1;; esac"
check "updater signing identifier" equals "$(signing_identifier tmt88v-updater)" "com.belchuke.tmt88vcompat.updater"
check "default config enables updates" bash -c "grep -q '\"automaticUpdates\": true' pkg/share/config.default.json"
check "package scripts never use the network" bash -c "! grep -rEq 'curl|wget|nc ' pkg/scripts"
check "payload does not ship config.json" bash -c "! grep -q 'install.*config.json' scripts/build-pkg.sh"

echo "automatic updater: installation"
new_fixture upd
run_install; check "install succeeds" equals "$?" "0"
check "updater files installed" test -x "$TMT88V_ROOT$UPDATER_BINARY_PATH"
check "updater plist installed" test -f "$TMT88V_ROOT$UPDATER_PLIST_PATH"
check "updater job bootstrapped" updater_running
check "service job also bootstrapped" service_running
check "default config.json created" file_has "$TMT88V_ROOT$SUPPORT_DIR/config.json" '"automaticUpdates": true'
check "updater binary mode 755" equals "$(mode_of "$TMT88V_ROOT$UPDATER_BINARY_PATH")" "755"
check "updater plist mode 644" equals "$(mode_of "$TMT88V_ROOT$UPDATER_PLIST_PATH")" "644"
check "config.json mode 644" equals "$(mode_of "$TMT88V_ROOT$SUPPORT_DIR/config.json")" "644"
check "state directory mode 755" equals "$(mode_of "$TMT88V_ROOT$SUPPORT_DIR/state")" "755"
check "updater bootstrapped through launchctl bootstrap" calls_have "launchctl bootstrap system $UPDATER_PLIST_PATH"
check "install log records the new config" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "created the default config.json"

echo "automatic updater: config is preserved across upgrades"
new_fixture cfg
mkdir -p "$TMT88V_ROOT$SUPPORT_DIR"; printf '{"automaticUpdates": false}\n' > "$TMT88V_ROOT$SUPPORT_DIR/config.json"
run_install; check "install over an existing config succeeds" equals "$?" "0"
check "config=false is preserved" equals "$(cat "$TMT88V_ROOT$SUPPORT_DIR/config.json")" '{"automaticUpdates": false}'
run_install; check "second upgrade succeeds" equals "$?" "0"
check "config=false still preserved after a second upgrade" equals "$(cat "$TMT88V_ROOT$SUPPORT_DIR/config.json")" '{"automaticUpdates": false}'
check "log says the config was kept" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "kept the existing config.json"
printf 'garbage not json' > "$TMT88V_ROOT$SUPPORT_DIR/config.json"
run_install; check "a malformed config is not overwritten either (updater fails safe on it)" equals "$(cat "$TMT88V_ROOT$SUPPORT_DIR/config.json")" "garbage not json"

echo "automatic updater: idempotent"
new_fixture updidem
run_install; run_install; run_install
check "repeat installs succeed" updater_running
check "updater loaded exactly once" bash -c "[[ \$(ls '$STUB_STATE'/loaded.updater* | wc -l | tr -d ' ') -eq 1 ]]"
check "config unchanged and valid" file_has "$TMT88V_ROOT$SUPPORT_DIR/config.json" '"automaticUpdates": true'

echo "automatic updater: installed BY the updater (its own launchd job must not be touched)"
new_fixture selfupd
run_install; : > "$STUB_STATE/calls"
printf '%s\n' "$$" > "$TMT88V_ROOT$SUPPORT_DIR/state/update-in-progress"
run_install "new" "newer-updater"
check "upgrade started by the updater succeeds" equals "$?" "0"
check "updater job is not booted out" calls_lack "launchctl bootout system/$UPDATER_LABEL"
check "updater job is not re-bootstrapped" calls_lack "launchctl bootstrap system $UPDATER_PLIST_PATH"
check "log explains why" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "started by the updater"
check "print service was still replaced normally" calls_have "launchctl bootstrap system $PLIST_PATH"
check "new updater binary is on disk for the next scheduled run" file_has "$TMT88V_ROOT$UPDATER_BINARY_PATH" "# newer-updater"
sleep 0 & dead=$!; wait $dead
printf '%s\n' "$dead" > "$TMT88V_ROOT$SUPPORT_DIR/state/update-in-progress"; : > "$STUB_STATE/calls"
run_install; check "stale marker (dead pid) is ignored; manual install reloads the updater" calls_have "launchctl bootstrap system $UPDATER_PLIST_PATH"

echo "automatic updater: can never fail the print installation"
new_fixture updfail; export STUB_FAIL_BOOTSTRAP_UPDATER=1
run_install; check "updater bootstrap failure does not fail the install" equals "$?" "0"
check "queue still created" equals "$(queue_count "$QUEUE_NAME")" "1"
check "warning logged" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "WARNING: could not bootstrap the updater job"
new_fixture updbroken; export STUB_UPDATER_EXIT=137
run_install; check "an updater binary that cannot execute does not fail the install" equals "$?" "0"
check "print service is up regardless" service_running
check "warning names the problem" file_has "$TMT88V_ROOT$LOG_DIR/install.log" "updater binary cannot be executed"
check "install completed" state_is phase complete

echo "automatic updater: rollback"
new_fixture updrb; export STUB_SERVICE_DOWN=1
run_install; check "failed first install" equals "$?" "12"
check "rollback removes the new updater binary" test ! -e "$TMT88V_ROOT$UPDATER_BINARY_PATH"
check "rollback removes the new updater plist" test ! -e "$TMT88V_ROOT$UPDATER_PLIST_PATH"
check "rollback never loaded the updater" bash -c "! updater_running" 
new_fixture updrb2
run_install "old" "old-updater"; check "initial install" equals "$?" "0"
export STUB_SERVICE_DOWN=1
run_install "new" "new-updater"; check "failed upgrade" equals "$?" "12"
check "failed upgrade restores the previous updater binary" file_has "$TMT88V_ROOT$UPDATER_BINARY_PATH" "# old-updater"
check "failed upgrade restores the previous updater plist" file_has "$TMT88V_ROOT$UPDATER_PLIST_PATH" "updater-plist-old-updater"
check "failed upgrade keeps the existing config" file_has "$TMT88V_ROOT$SUPPORT_DIR/config.json" "automaticUpdates"

echo "uninstall targets only our resources"
new_fixture uninstall
echo "EPSON_TM_T88V|usb://EPSON/TM-T88V?serial=1|false" >> "$STUB_STATE/queues"
echo "TMT88V_Compat_Test|$PRINTER_URI|true" >> "$STUB_STATE/queues"
mkdir -p "$TMT88V_ROOT/Library/Printers/EPSON/TerminalPrinter"; echo driver > "$TMT88V_ROOT/Library/Printers/EPSON/TerminalPrinter/filter"
run_install; check "install before uninstall" equals "$?" "0"
echo "updater log" > "$TMT88V_ROOT$LOG_DIR/updater.log"
./scripts/uninstall.sh --yes > "$F/un.out" 2>&1; check "uninstall succeeds" equals "$?" "0"
check "our queue removed" equals "$(queue_count "$QUEUE_NAME")" "0"
check "service unloaded" test ! -f "$STUB_STATE/loaded.service"
check "binary removed" test ! -e "$TMT88V_ROOT$SERVICE_BINARY_PATH"
check "plist removed" test ! -e "$TMT88V_ROOT$PLIST_PATH"
check "support dir removed" test ! -e "$TMT88V_ROOT$SUPPORT_DIR"
check "updater job unloaded" bash -c "! updater_running"
check "updater binary removed" test ! -e "$TMT88V_ROOT$UPDATER_BINARY_PATH"
check "updater plist removed" test ! -e "$TMT88V_ROOT$UPDATER_PLIST_PATH"
check "config.json removed" test ! -e "$TMT88V_ROOT$SUPPORT_DIR/config.json"
check "updater state removed" test ! -e "$TMT88V_ROOT$SUPPORT_DIR/state"
check "updater log removed" test ! -e "$TMT88V_ROOT$LOG_DIR/updater.log"
check "log dir removed" test ! -e "$TMT88V_ROOT$LOG_DIR"
check "Epson queue remains" grep -q "^EPSON_TM_T88V|" "$STUB_STATE/queues"
check "other test queue remains" grep -q "^TMT88V_Compat_Test|" "$STUB_STATE/queues"
check "Epson files remain" test -f "$TMT88V_ROOT/Library/Printers/EPSON/TerminalPrinter/filter"
check "only our queue was removed" bash -c "[[ \$(grep -c 'lpadmin -x' '$STUB_STATE/calls') == 1 ]] && grep -q 'lpadmin -x $QUEUE_NAME\$' '$STUB_STATE/calls'"
./scripts/uninstall.sh --yes > "$F/un2.out" 2>&1; check "uninstall is repeatable" equals "$?" "0"

new_fixture legacy
mkdir -p "$TMT88V_ROOT/Library/PrivilegedHelperTools"; echo old > "$TMT88V_ROOT/Library/PrivilegedHelperTools/$SERVICE_LABEL"
./scripts/uninstall.sh --yes > "$F/un.out" 2>&1
check "uninstall also removes the old .service-named binary" test ! -e "$TMT88V_ROOT/Library/PrivilegedHelperTools/$SERVICE_LABEL"

new_fixture foreign
echo "$QUEUE_NAME|ipp://other.example/ipp|true" >> "$STUB_STATE/queues"
./scripts/uninstall.sh --yes > "$F/un.out" 2>&1
check "queue with a foreign URI is not removed" grep -q "^$QUEUE_NAME|ipp://other.example" "$STUB_STATE/queues"

new_fixture dry
run_install > /dev/null; before="$(ls -R "$TMT88V_ROOT" | md5)"
TMT88V_DRY_RUN=1 ./scripts/uninstall.sh --yes > "$F/dry.out" 2>&1
check "dry run prints actions" file_has "$F/dry.out" "DRY-RUN: lpadmin -x $QUEUE_NAME"
check "dry run changes nothing" equals "$(ls -R "$TMT88V_ROOT" | md5)" "$before"
check "dry run keeps the queue" equals "$(queue_count "$QUEUE_NAME")" "1"

echo
echo "installer fixture tests: $pass passed, $failures failed"
[[ $failures -eq 0 ]]
