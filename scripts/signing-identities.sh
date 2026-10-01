#!/bin/bash
set -euo pipefail

echo "== Developer ID Application (signs the binaries)"
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "none found in the searched keychains"

echo
echo "== Developer ID Installer (signs the .pkg)"
security find-identity -v | grep "Developer ID Installer" || echo "none found in the searched keychains"

echo
echo "== all valid code signing identities"
security find-identity -v -p codesigning

cat <<'T'

Use the quoted name or, to avoid ambiguity, the 40-character SHA-1 hash:

  SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/sign.sh
  SIGNING_IDENTITY=<40-hex-sha1> ./scripts/sign.sh
T
