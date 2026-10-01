# TM-T88V macOS Compatibility Layer

A native macOS compatibility layer for Epson TM-T88V USB receipt printers.

The project exists to replace Epson's legacy Intel-based macOS printing components with a modern Apple Silicon-native solution while preserving standard macOS printing support for existing applications.

## Goal

Preserve the existing workflow:

Application
→ macOS Print
→ EPSON TM-T88V

while replacing the legacy Epson driver path with:

macOS Print
→ Local IPP printer
→ Native compatibility service
→ ESC/POS
→ USB
→ Epson TM-T88V

No changes should be required in applications that already use the built-in macOS printing system.

## Status

Milestones 1 (USB discovery) and 2 (direct ESC/POS over USB) are implemented.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/TESTING.md](docs/TESTING.md).

## Build

Requires the Xcode Command Line Tools (Swift 6). No third-party dependencies.

```
./scripts/build.sh     # release build into dist/, verifies arm64 and system-only linkage
./scripts/test.sh      # unit and simulated tests
```

## Tools

```
dist/tmt88v-diag             # USB descriptors, endpoints, IEEE 1284 ID
dist/tmt88v-diag --status    # plus real-time ESC/POS status over bulk IN
dist/tmt88v-diag --all       # every Epson USB device, not only TM-T88V
dist/tmt88v-test             # print test receipt and cut, directly over USB
dist/tmt88v-test --dry-run receipt.bin
```

Neither tool needs root, entitlements, or a system extension.

## Verify native Apple Silicon binaries

```
file dist/tmt88v-diag dist/tmt88v-test
lipo -archs dist/tmt88v-diag dist/tmt88v-test
otool -L dist/tmt88v-diag dist/tmt88v-test
```
