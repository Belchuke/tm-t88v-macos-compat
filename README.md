# TM-T88V macOS Compatibility

A native Apple Silicon compatibility layer for the Epson TM-T88V USB receipt printer.

It replaces Epson's legacy Intel-based macOS printing components while preserving the standard macOS printing workflow used by existing applications.

## How it works

```text
Application
    ↓
macOS Print / CUPS
    ↓
Local IPP Printer
    ↓
Native ARM64 Compatibility Service
    ↓
ESC/POS
    ↓
USB
    ↓
Epson TM-T88V
```

Applications that already use the built-in macOS printing system do not need to be modified.

## Features

- Native Apple Silicon / ARM64
- Epson TM-T88V USB support
- Standard macOS printing through CUPS
- No Rosetta dependency
- No DriverKit or system extension
- Native Swift implementation
- Direct USB communication through `IOUSBHost`
- Local IPP print service
- Loopback-only networking
- No Bonjour or network printer advertising
- Printer queue is not shared
- 80 mm and 58 mm paper configurations
- 180 DPI raster printing
- Automatic paper cutting
- Signed and notarized macOS installer
- Automatic background service using `launchd`
- Secure automatic updates
- No third-party runtime dependencies

## Requirements

- macOS 13 or newer
- Apple Silicon Mac
- Epson TM-T88V
- USB connection to the printer

## Installation

Download the latest customer installer:

**[Download TMT88VCompat-0.2.0.pkg](https://github.com/Belchuke/tm-t88v-macos-compat/releases/download/v0.2.0/TMT88VCompat-0.2.0.pkg)**

Open the downloaded `.pkg` and follow the macOS installer.

The installer:

- installs the native compatibility service
- starts the background service
- creates the `TMT88V_Compat` printer queue
- configures the printer to use the local IPP service
- installs the automatic updater

Existing Epson printer drivers and queues are not removed or modified.

After installation, applications can print to:

```text
TMT88V_Compat
```

like any other macOS printer.

## Automatic Updates

Starting with v0.2.0, the compatibility layer updates itself automatically in the background.

Updates are downloaded only from the official GitHub Releases for this repository and are verified before installation.

The updater verifies the package signature, Apple Developer team, package identity, version, and Apple notarization before an update can be installed.

No update prompts or user interaction are required.

`TMT88VCompat.pkg` in each GitHub release is reserved for the automatic updater. For manual installation, use the versioned package such as `TMT88VCompat-0.2.0.pkg`.

## Building from source

Requires Swift 6 and the Xcode Command Line Tools.

```bash
./scripts/build.sh
```

Run the test suite with:

```bash
./scripts/test.sh
```

Build output is placed in:

```text
dist/
```

## Tools

### Printer diagnostics

```bash
dist/tmt88v-diag --status
```

Displays the connected TM-T88V USB information and printer status.

### Direct print test

```bash
dist/tmt88v-test
```

Prints a test receipt directly through USB without using CUPS.

### Raster test

```bash
dist/tmt88v-raster-test --pattern
```

Prints the built-in raster test pattern.

### Print service

```bash
dist/tmt88v-service
```

Starts the local IPP compatibility service.

The default endpoint is:

```text
ipp://127.0.0.1:8632/ipp/print
```

## Uninstall

The installed package includes an uninstaller:

```bash
sudo "/Library/Application Support/TMT88VCompat/uninstall.sh" --yes
```

The uninstaller removes only resources created by this project.

Existing Epson printer drivers, Epson queues, and unrelated CUPS configuration are left untouched.

## Known Limitations

- Currently targets the Epson TM-T88V
- Epson Vendor Class USB mode has not been fully hardware-tested
- Cash drawer and buzzer controls are not exposed through the macOS print interface
- Epson-specific printer options may not have direct equivalents in the driverless print queue
- Compatibility with application-specific printer settings may vary

## License

See [LICENSE](LICENSE).
