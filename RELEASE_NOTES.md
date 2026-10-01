# TM-T88V macOS Compatibility v0.1.2

First public release of the TM-T88V macOS Compatibility Layer.

This project provides a native Apple Silicon replacement for Epson's legacy Intel-based macOS printing components for the Epson TM-T88V USB receipt printer.

## Features

- Native Apple Silicon / ARM64
- Epson TM-T88V USB support
- Standard macOS printing through CUPS
- Local IPP print service
- Direct USB communication using IOUSBHost
- ESC/POS raster printing
- 80 mm and 58 mm paper support
- Automatic paper cutting
- Automatic background service using launchd
- No Rosetta dependency
- No DriverKit or system extension
- No third-party runtime dependencies
- Loopback-only IPP service
- Printer queue is not shared

## Installation

Download:

`TMT88VCompat-0.1.2.pkg`

Then open the package and follow the macOS installer.

The package is signed with a Developer ID certificate, notarized by Apple, and contains a stapled notarization ticket.

The installer creates the following printer:

`TMT88V_Compat`

Existing Epson drivers and printer queues are not modified or removed.

## Requirements

- macOS 13 or newer
- Apple Silicon Mac
- Epson TM-T88V
- USB connection to the printer

## Uninstall

```bash
sudo "/Library/Application Support/TMT88VCompat/uninstall.sh" --yes
```

## Notes

This is the first public release.

Epson-specific features such as cash drawer and buzzer controls are not currently exposed through the macOS print interface.
