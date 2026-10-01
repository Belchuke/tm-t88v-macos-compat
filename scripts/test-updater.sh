#!/bin/bash
# End-to-end tests of the real tmt88v-updater executable. No GitHub and no root needed.
#
# A separate TEST VARIANT of the updater is built with -DTMT88V_UPDATER_TESTING (it honours TMT88V_UPDATE_URL and friends).
# The shipped updater is compiled without that flag and contains no override code; this script proves it with `strings`.
# System tools (pkgutil, spctl, installer, pgrep) are replaced by stub scripts; downloads come from a local HTTP server.
#
#   ./scripts/test-updater.sh [path/to/shipped/tmt88v-updater]
set -uo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

SHIPPED="${1:-$DIST_DIR/tmt88v-updater}"
TEST_BUILD="$BUILD_DIR/updater-test-build"
PORT="${TEST_PORT:-18680}"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; failures=0
check() { local n="$1"; shift; if "$@"; then pass=$((pass+1)); echo "  ok   $n"; else failures=$((failures+1)); echo "  FAIL $n"; fi; }
equals() { [[ "$1" == "$2" ]]; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }

echo "building the test variant (separate scratch path)"
swift build -c release --arch arm64 --product tmt88v-updater --scratch-path "$TEST_BUILD" -Xswiftc -DTMT88V_UPDATER_TESTING > "$TMP/build.out" 2>&1 \
    || { cat "$TMP/build.out" | tail -20; echo "test variant failed to build"; exit 1; }
VARIANT="$(swift build -c release --arch arm64 --product tmt88v-updater --scratch-path "$TEST_BUILD" --show-bin-path)/tmt88v-updater"

echo "the shipped updater has no test overrides"
if [[ -x "$SHIPPED" ]]; then
    for needle in TMT88V_UPDATE_URL TMT88V_UPDATER_ROOT TMT88V_UPDATER_ALLOW_HTTP TMT88V_UPDATER_TOOLS_DIR TMT88V_UPDATER_FAKE_NOW; do
        check "shipped binary does not contain $needle" bash -c "! strings -a '$SHIPPED' | grep -q $needle"
    done
    check "shipped binary hardcodes the official URL" bash -c "strings -a '$SHIPPED' | grep -q 'https://github.com/Belchuke/tm-t88v-macos-compat/releases/latest/download/TMT88VCompat.pkg'"
    check "shipped binary refuses to run as a non-root user" bash -c "! '$SHIPPED' run >/dev/null 2>&1"
    check "shipped binary ignores an update URL in the environment" bash -c "TMT88V_UPDATE_URL=http://127.0.0.1:1/x TMT88V_UPDATER_ROOT=/tmp '$SHIPPED' status | grep -q 'update URL:        https://github.com/Belchuke'"
else
    echo "  skip: $SHIPPED not found (run ./scripts/build.sh); only the test variant is exercised"
fi
check "the test variant does contain the overrides (sanity)" bash -c "strings -a '$VARIANT' | grep -q TMT88V_UPDATE_URL"

# ---- scenario machinery
SERVE="$TMP/serve"; TOOLS="$TMP/tools"; mkdir -p "$SERVE" "$TOOLS"
printf 'xar!fake-package-bytes-for-tests' > "$SERVE/TMT88VCompat.pkg"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE" > "$TMP/http.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

cat > "$TOOLS/pkgutil" <<'S'
#!/bin/bash
case "$1" in
  --pkg-info-plist)
    [[ -f "$TOOLS_STATE/installed_version" ]] || exit 1
    echo "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>pkg-version</key><string>$(cat "$TOOLS_STATE/installed_version")</string><key>pkgid</key><string>com.belchuke.tmt88vcompat.pkg</string></dict></plist>" ;;
  --check-signature)
    [[ "$(cat "$TOOLS_STATE/signature" 2>/dev/null)" == "bad" ]] && { echo "Status: no signature"; exit 1; }
    echo "Package \"x.pkg\":"
    echo "   Certificate Chain:"
    echo "    1. $(cat "$TOOLS_STATE/leaf")"
    echo "    2. Developer ID Certification Authority"
    echo "    3. Apple Root CA" ;;
  --expand)
    mkdir -p "$3/component.pkg"
    echo "<pkg-info identifier=\"com.belchuke.tmt88vcompat.pkg\" version=\"$(cat "$TOOLS_STATE/package_version")\"/>" > "$3/component.pkg/PackageInfo"
    echo "<installer-gui-script><pkg-ref id=\"com.belchuke.tmt88vcompat.pkg\" version=\"$(cat "$TOOLS_STATE/package_version")\">#component.pkg</pkg-ref></installer-gui-script>" > "$3/Distribution" ;;
esac
S
cat > "$TOOLS/spctl" <<'S'
#!/bin/bash
if [[ "$*" == *--raw* ]]; then
  echo "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>assessment:authority</key><dict><key>assessment:authority:source</key><string>$(cat "$TOOLS_STATE/gk_source")</string></dict><key>assessment:verdict</key><$(cat "$TOOLS_STATE/gk_verdict")/></dict></plist>"
  [[ "$(cat "$TOOLS_STATE/gk_verdict")" == "true" ]]
else
  echo "x.pkg: accepted"; echo "source=$(cat "$TOOLS_STATE/gk_source")"; echo "origin=$(cat "$TOOLS_STATE/leaf")"
fi
S
cat > "$TOOLS/installer" <<'S'
#!/bin/bash
echo "$*" >> "$TOOLS_STATE/installer.calls"
[[ -f "$TOOLS_STATE/installer_fail" ]] && exit 1
cp "$TOOLS_STATE/package_version" "$TOOLS_STATE/installed_version"
echo "installer: The install was successful."
S
printf '#!/bin/bash\nexit 1\n' > "$TOOLS/pgrep"
chmod +x "$TOOLS"/*

NOW=1800000000
LEAF_GOOD="Developer ID Installer: Jacob Belchuke (P3WL6DBK59)"

# new_scenario NAME: fresh root, tool state, due state
new_scenario() {
    S="$TMP/$1"; ROOT="$S/root"; TOOLS_STATE="$S/tools-state"
    mkdir -p "$ROOT/Library/Application Support/TMT88VCompat/state" "$ROOT/Library/Logs/TMT88VCompat" "$TOOLS_STATE"
    chmod 755 "$ROOT/Library/Application Support/TMT88VCompat/state"
    STATE_DIR="$ROOT/Library/Application Support/TMT88VCompat/state"
    CONFIG="$ROOT/Library/Application Support/TMT88VCompat/config.json"
    LOG="$ROOT/Library/Logs/TMT88VCompat/updater.log"
    echo "0.1.2" > "$TOOLS_STATE/installed_version"; echo "0.2.0" > "$TOOLS_STATE/package_version"
    echo "$LEAF_GOOD" > "$TOOLS_STATE/leaf"; echo "Notarized Developer ID" > "$TOOLS_STATE/gk_source"; echo "true" > "$TOOLS_STATE/gk_verdict"
    printf '{"automaticUpdates": true}\n' > "$CONFIG"
    : > "$TMP/http.log"
    URL="http://127.0.0.1:$PORT/TMT88VCompat.pkg"
}
make_due() { printf '{"nextCheckAt":"2027-01-15T07:59:00Z"}\n' > "$STATE_DIR/updater-state.json"; }   # 1800000000 = 2027-01-15T08:00:00Z
run_updater() {
    TMT88V_UPDATER_ROOT="$ROOT" TMT88V_UPDATE_URL="${URL_OVERRIDE:-$URL}" TMT88V_UPDATER_ALLOW_HTTP=1 TMT88V_UPDATER_FAKE_NOW="$NOW" \
    TMT88V_UPDATER_ZERO_JITTER=1 TMT88V_UPDATER_TOOLS_DIR="$TOOLS" TOOLS_STATE="$TOOLS_STATE" "$VARIANT" run "$@" > "$S/run.out" 2>&1
}
requests() { grep -c '"GET /TMT88VCompat.pkg' "$TMP/http.log" || true; }
installer_calls() { [[ -f "$TOOLS_STATE/installer.calls" ]] && wc -l < "$TOOLS_STATE/installer.calls" | tr -d ' ' || echo 0; }

echo "config"
new_scenario disabled; make_due; echo '{"automaticUpdates": false}' > "$CONFIG"
run_updater; check "disabled: exit 0" equals "$?" "0"
check "disabled: no network request" equals "$(requests)" "0"
check "disabled: logged" has "$LOG" '"event":"updates_disabled"'
new_scenario malformed; make_due; echo '{oops' > "$CONFIG"
run_updater; check "malformed config: exit 0 and no network" equals "$(requests)" "0"
check "malformed config: logged as disabled" has "$LOG" '"event":"updates_disabled"'

echo "scheduling"
new_scenario fresh
run_updater; check "no state: exit 0" equals "$?" "0"
check "no state: no network request" equals "$(requests)" "0"
check "no state: schedule written" has "$STATE_DIR/updater-state.json" nextCheckAt
check "no state: logged" has "$LOG" '"event":"schedule_initialized"'
new_scenario notdue; printf '{"nextCheckAt":"2027-01-15T09:00:00Z"}\n' > "$STATE_DIR/updater-state.json"
run_updater; check "not due: no network request" equals "$(requests)" "0"
check "not due: logged" has "$LOG" '"event":"check_skipped_not_due"'
new_scenario corrupt; echo 'not json' > "$STATE_DIR/updater-state.json"
run_updater; check "corrupt state: exit 0, no network" equals "$(requests)" "0"
check "corrupt state: reset is logged" has "$LOG" '"event":"state_reset"'

echo "up to date / downgrade"
new_scenario same; make_due; echo "0.2.0" > "$TOOLS_STATE/installed_version"
run_updater; check "same version: exit 0" equals "$?" "0"
check "same version: downloaded once" equals "$(requests)" "1"
check "same version: installer not run" equals "$(installer_calls)" "0"
check "same version: logged" has "$LOG" '"event":"already_up_to_date"'
check "same version: next check is 24h+ away" has "$STATE_DIR/updater-state.json" '"nextCheckAt" : "2027-01-16T08:00:00Z"'
new_scenario older; make_due; echo "0.3.0" > "$TOOLS_STATE/installed_version"
run_updater; check "older package: installer not run" equals "$(installer_calls)" "0"

echo "successful update"
new_scenario ok; make_due
run_updater; check "update: exit 0" equals "$?" "0"
check "update: installer ran exactly once" equals "$(installer_calls)" "1"
check "update: installer got a private package path" bash -c "grep -q -- '-pkg $STATE_DIR/download-' '$TOOLS_STATE/installer.calls' && grep -q -- '-target /' '$TOOLS_STATE/installer.calls'"
check "update: new version confirmed" equals "$(cat "$TOOLS_STATE/installed_version")" "0.2.0"
for event in updater_started current_version download_started download_completed verification_started downloaded_version verification_succeeded install_started install_succeeded update_complete; do
    check "update: logged $event" has "$LOG" "\"event\":\"$event\""
done
check "update: temporary files cleaned" bash -c "[[ -z \"\$(ls '$STATE_DIR' | grep '^download-')\" ]]"
check "update: marker removed" test ! -e "$STATE_DIR/update-in-progress"
check "update: state records success" has "$STATE_DIR/updater-state.json" lastSuccessfulUpdateAt

echo "verification failures never reach the installer"
new_scenario wrongteam; make_due; echo "Developer ID Installer: Attacker (ZZZZZ99999)" > "$TOOLS_STATE/leaf"
run_updater; check "wrong team: exit 1" equals "$?" "1"
check "wrong team: installer not run" equals "$(installer_calls)" "0"
check "wrong team: logged" has "$LOG" '"event":"verification_failed"'
new_scenario unsigned; make_due; echo bad > "$TOOLS_STATE/signature"
run_updater; check "unsigned: installer not run" equals "$(installer_calls)" "0"
new_scenario unnotarized; make_due; echo "Unnotarized Developer ID" > "$TOOLS_STATE/gk_source"; echo false > "$TOOLS_STATE/gk_verdict"
run_updater; rc=$?
check "unnotarized: installer not run" equals "$(installer_calls)" "0"
check "unnotarized: exit 1" equals "$rc" "1"
new_scenario junk; make_due; printf 'this is an html error page' > "$SERVE/TMT88VCompat.pkg"
run_updater; check "junk download: installer not run" equals "$(installer_calls)" "0"
printf 'xar!fake-package-bytes-for-tests' > "$SERVE/TMT88VCompat.pkg"

echo "failures handled quietly"
new_scenario notfound; make_due; URL_OVERRIDE="http://127.0.0.1:$PORT/missing.pkg"
run_updater; check "404: exit 0" equals "$?" "0"
check "404: logged" has "$LOG" '"event":"download_failed"'
check "404: installer not run" equals "$(installer_calls)" "0"
unset URL_OVERRIDE
new_scenario nonet; make_due; URL_OVERRIDE="http://127.0.0.1:1/TMT88VCompat.pkg"
run_updater; check "no network: exit 0" equals "$?" "0"
unset URL_OVERRIDE
new_scenario instfail; make_due; touch "$TOOLS_STATE/installer_fail"
run_updater; check "installer failure: exit 1" equals "$?" "1"
check "installer failure: logged" has "$LOG" '"event":"install_failed"'
check "installer failure: installed version untouched" equals "$(cat "$TOOLS_STATE/installed_version")" "0.1.2"
run_updater; check "no retry storm: the next run is not due" has "$LOG" '"event":"check_skipped_not_due"'

echo "concurrency"
new_scenario locked; make_due
perl -e 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; print "locked\n"; STDOUT->flush; sleep 20;' "$STATE_DIR/updater.lock" > "$S/holder.out" &
HOLDER=$!
for _ in $(seq 1 50); do [[ -s "$S/holder.out" ]] && break; sleep 0.1; done
run_updater; check "second updater: exit 0" equals "$?" "0"
check "second updater: no network" equals "$(requests)" "0"
check "second updater: logged" has "$LOG" '"event":"updater_already_running"'
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
run_updater; check "after the holder dies the lock is free again (crash recovery)" equals "$(requests)" "1"

echo "unsafe environment"
new_scenario unsafe; make_due; chmod 777 "$STATE_DIR"
run_updater; check "world-writable state dir: refused (exit 1)" equals "$?" "1"
check "world-writable state dir: no network" equals "$(requests)" "0"

echo "real system tools (no stubs): the shipped updater's verifier against real packages"
if [[ -x "$SHIPPED" ]]; then
    shopt -s nullglob
    for pkg in "$BUILD_DIR"/pkg/TMT88VCompat-*.pkg; do
        out="$("$SHIPPED" verify "$pkg" 2>&1)"; rc=$?
        if xcrun stapler validate "$pkg" > /dev/null 2>&1; then
            check "notarized+stapled $(basename "$pkg"): accepted" equals "$rc" "0"
        else
            check "not notarized $(basename "$pkg"): rejected ($(echo "$out" | tail -1 | cut -c1-90))" equals "$rc" "1"
        fi
    done
    mkdir -p "$TMP/unsigned/r"; echo hi > "$TMP/unsigned/r/f"
    pkgbuild --root "$TMP/unsigned/r" --identifier "$PKG_IDENTIFIER" --version 9.9.9 "$TMP/unsigned/u.pkg" > /dev/null 2>&1
    "$SHIPPED" verify "$TMP/unsigned/u.pkg" > "$TMP/unsigned/out" 2>&1
    check "real unsigned package: rejected" equals "$?" "1"
    check "real unsigned package: rejection names the signature" has "$TMP/unsigned/out" "signature is not valid"
    echo "garbage" > "$TMP/unsigned/junk.pkg"
    "$SHIPPED" verify "$TMP/unsigned/junk.pkg" > /dev/null 2>&1
    check "real corrupt file: rejected" equals "$?" "1"
else
    echo "  skip: shipped updater not found"
fi

echo
echo "updater integration tests: $pass passed, $failures failed"
[[ $failures -eq 0 ]]
