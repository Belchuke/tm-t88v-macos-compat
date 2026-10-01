#!/bin/bash
# Starts the real service binary the way launchd does: production file name, the exact plist arguments, an empty environment
# (no HOME, TMPDIR, PATH, tty). Run ./scripts/build.sh first. Needs no sudo; uses a high loopback port.
set -uo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

BIN_SRC="${1:-$DIST_DIR/tmt88v-service}"
[[ -x "$BIN_SRC" ]] || { echo "build first: $BIN_SRC not found (./scripts/build.sh)"; exit 1; }

PORT="${TEST_PORT:-18671}"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
BIN="$TMP/$SERVICE_BINARY_NAME"
cp "$BIN_SRC" "$BIN"
pass=0; failures=0
check() { local n="$1"; shift; if "$@"; then pass=$((pass+1)); echo "  ok   $n"; else failures=$((failures+1)); echo "  FAIL $n"; fi; }

# start NAME ARGS...: runs under env -i, waits for the port
start() {
    local name="$1"; shift
    env -i "$BIN" "$@" > "$TMP/$name.out" 2> "$TMP/$name.err" &
    PID=$!
    for _ in $(seq 1 50); do
        lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1 && return 0
        if ! kill -0 "$PID" 2>/dev/null; then
            wait "$PID" 2>/dev/null
            echo "    process exited early with status $? ($name); stderr: $(head -c 300 "$TMP/$name.err")"
            return 1
        fi
        sleep 0.1
    done
    echo "    port $PORT never listened ($name)"
    return 1
}
healthy() { ipptool -t "ipp://127.0.0.1:$PORT/ipp/print" pkg/share/healthcheck.test > /dev/null 2>&1; }
stopped_within() { for _ in $(seq 1 $(( $1 * 10 ))); do kill -0 "$PID" 2>/dev/null || return 0; sleep 0.1; done; return 1; }

echo "executes under the production file name"
"$BIN" --help > /dev/null 2>&1; check "--help exits 0 as $SERVICE_BINARY_NAME (137 would mean killed at exec)" test $? -eq 0

echo "exact launchd arguments (with --quiet), empty environment"
start quiet --port "$PORT" --log-file "$TMP/logs/service.log" --quiet; check "starts and listens" test $? -eq 0
check "answers the installer health check" healthy
check "listens on loopback only" bash -c "! lsof -nP -a -p $PID -iTCP -sTCP:LISTEN | tail -n +2 | grep -vE '127\.0\.0\.1:|\[::1\]:'"
check "creates the missing log directory and file" test -s "$TMP/logs/service.log"
check "logs the listening event" grep -q '"event":"listening"' "$TMP/logs/service.log"
check "--quiet keeps stderr empty" test ! -s "$TMP/quiet.err"
kill -TERM "$PID"; check "SIGTERM stops it" stopped_within 3
wait "$PID" 2>/dev/null; check "SIGTERM exit status is 0 (launchd will not restart it)" test $? -eq 0

echo "same arguments without --quiet"
start loud --port "$PORT" --log-file "$TMP/logs2/service.log"; check "starts and listens" test $? -eq 0
check "answers the health check" healthy
check "echoes events to stderr when not quiet" test -s "$TMP/loud.err"
kill -TERM "$PID"; stopped_within 3

echo "log path that cannot be written"
start nolog --port "$PORT" --log-file /System/not-writable/service.log --quiet; check "still starts and listens" test $? -eq 0
check "still answers the health check" healthy
kill -TERM "$PID"; stopped_within 3

echo "no printer interaction at startup (USB mode, nothing is opened until a job arrives)"
start usb --port "$PORT" --log-file "$TMP/logs3/service.log" --quiet; check "listener is up before any USB access" test $? -eq 0
check "log says output=usb" grep -q '"output":"usb"' "$TMP/logs3/service.log"
kill -TERM "$PID"; stopped_within 3

echo "port already in use"
python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',$PORT)); s.listen(1); time.sleep(8)" &
BLOCK=$!; sleep 0.5
env -i "$BIN" --port "$PORT" --log-file "$TMP/logs4/service.log" --quiet > /dev/null 2> "$TMP/busy.err"; rc=$?
check "exits non-zero (launchd retries at most every 30 s)" test $rc -ne 0
check "records start_failed in the log (the failure is not silent)" grep -q '"event":"start_failed"' "$TMP/logs4/service.log"
kill $BLOCK 2>/dev/null; wait $BLOCK 2>/dev/null

echo
echo "service startup tests: $pass passed, $failures failed"
[[ $failures -eq 0 ]]
