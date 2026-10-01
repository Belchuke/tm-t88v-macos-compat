#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGIN_DIR" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR"
else
    swift test
fi
