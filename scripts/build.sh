#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$DIST_DIR"
for tool in "${BINARIES[@]}"; do
    cp "$BIN_DIR/$tool" "$DIST_DIR/$tool"
done

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    ./scripts/sign.sh
else
    echo "SIGNING_IDENTITY not set: binaries are NOT Developer ID signed (see docs/SIGNING.md)"
fi

status=0
for binary in "$DIST_DIR"/tmt88v-*; do
    echo "== $binary"
    file "$binary"
    archs="$(lipo -archs "$binary")"
    echo "lipo: $archs"
    if [[ " $archs " != *" arm64 "* && " $archs " != *" arm64e "* ]]; then
        echo "ERROR: $binary has no arm64 slice"
        status=1
    fi
    otool -L "$binary" | tail -n +2
    if otool -L "$binary" | tail -n +2 | grep -vE '^\s*/(System/Library|usr/lib)/' ; then
        echo "ERROR: $binary links a non-system library"
        status=1
    fi
done
exit $status
