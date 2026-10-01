#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p dist
for tool in tmt88v-diag tmt88v-test tmt88v-raster-test tmt88v-service; do
    cp "$BIN_DIR/$tool" "dist/$tool"
done

status=0
for binary in dist/*; do
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
