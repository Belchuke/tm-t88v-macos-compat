# TM-T88V macOS Compatibility

A native Apple Silicon compatibility layer for the Epson TM-T88V USB receipt printer.

The project replaces Epson's legacy Intel-based macOS printing components with a modern native solution while preserving the standard macOS printing workflow used by existing applications.

## How it works

Applications continue to print through the normal macOS printing system:

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
- Automatic updates from official GitHub Releases (from v0.2.0)
- No third-party runtime dependencies

## Updates

Starting with v0.2.0, updates are installed automatically in the background. Nothing needs to be done after installing.

- Updates are downloaded only from the official GitHub Releases of this project.
- Each package is verified before installation: it must be signed by this project's Developer ID and notarized by Apple.
- If anything cannot be verified, the current installation is left untouched.
- To turn automatic updates off, set `"automaticUpdates": false` in `/Library/Application Support/TMT88VCompat/config.json`.

## Requirements

- macOS 13 or newer
- Apple Silicon Mac
- Epson TM-T88V
- USB connection to the printer

## Installation

Download the latest `.pkg` from the GitHub Releases page and run the installer.

The installer will:

- install the native compatibility service
- start the background service
- create the `TMT88V_Compat` printer queue
- configure the printer to use the local IPP service

Existing Epson printer drivers and queues are not removed or modified.

After installation, applications can print to:

```text
TMT88V_Compat
```

like any other macOS printer.

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

## Known limitations

- Currently targets the Epson TM-T88V
- Epson Vendor Class USB mode has not been fully hardware-tested
- Cash drawer and buzzer controls are not exposed through the macOS print interface
- Epson-specific printer options may not have direct equivalents in the driverless print queue
- Compatibility with application-specific printer settings may vary

## License

See [LICENSE](LICENSE).
