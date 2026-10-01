# Architecture decisions (Milestones 1–2)

## Language and toolchain

Swift Package (`Package.swift`), Swift 6, macOS 13+, built for `arm64`.

Swift gives first-class access to IOKit and IOUSBHost without a C shim, builds with the
Command Line Tools alone, and produces binaries that link only system frameworks.

## USB access: IOUSBHost.framework from user space

Investigated in the order requested:

| Option | Result |
| --- | --- |
| macOS USB Printer Class access | No kernel driver claims the TM-T88V interface. The only built-in consumer is the CUPS `usb` backend, which opens it per job. |
| IOKit user-space (IOUSBHost.framework) | **Works.** Interface opens without root, entitlements, signing or a system extension. Bulk OUT, bulk IN and Printer Class control requests all work. |
| libusb | Not needed. Would add a third-party dylib to ship and sign. |
| DriverKit / USBDriverKit | Not needed. Would require Apple-granted entitlements and a system extension approval. |

`IOUSBHostInterface` takes exclusive ownership of the interface while open. This means:

- our tool and the legacy CUPS queue cannot use the printer at the same moment; the loser
  gets `interface_busy` with the owning process named
- the future background service must open the interface per job (or release it when idle)
  if any other component still needs access during migration

## Observed enumeration (real TM-T88V, macOS 27.0.1, Apple Silicon)

```
Vendor ID   0x04B8 (EPSON)
Product ID  0x0E02
Serial      583655430118720000
Speed       Full speed, 12 Mbit/s
Interface 0 class 0x07/0x01/0x02  Printer Class, bidirectional
  0x01 Bulk OUT  maxPacket 64
  0x82 Bulk IN   maxPacket 64
IEEE 1284   MFG:EPSON;CMD:ESC/POS;MDL:TM-T88V;CLS:PRINTER;DES:EPSON TM-T88V;CID:EpsonTM00000001;
```

The TM-T88V can be switched to Epson "Vendor Class" mode with Epson's utility. In that mode
the product ID and interface class differ. Discovery therefore matches on vendor ID plus the
USB product string, not on a hardcoded product ID. The transport prefers a Printer Class
interface and falls back to a vendor-class interface with a bulk OUT endpoint. Vendor Class
mode has not been tested on hardware.

## Bulk IN behaviour

The printer answers an IN request immediately with a zero-length packet when it has nothing
queued, instead of NAKing. Status replies (`DLE EOT n`) arrive roughly 20 ms after the request.
`PrinterStatusQuery` therefore drains stale bytes until the pipe is quiet, then polls for each
reply. Without the drain, a late reply to one request is read as the answer to the next.

## Where Epson's Intel code sits today

```
/Library/Printers/EPSON/TerminalPrinter/filter/rastertotmt.app   i386 / ppc / x86_64   <- CUPS filter
/Library/Printers/EPSON/TerminalPrinter/PDE/EPSONTMPDE.plugin     ppc / x86_64 / i386   <- print dialog pane
/usr/libexec/cups/backend/usb                                     arm64e (Apple)
```

The legacy queue `EPSON_TM_T88V` uses `usb://EPSON/TM-T88V?serial=...` with the Epson PPD
whose `cupsFilter` is `rastertotmt`. That filter is the component that requires Rosetta.
`tmt88v-test` bypasses CUPS entirely, so neither component is involved.

## Printer parameters

The TM-T88V is **180 dpi**, not 203 dpi. Values live in `PrinterModel` (`Sources/TMT88VCore/Printer`):

| Preset | Paper | Printable | Dots/line |
| --- | --- | --- | --- |
| `tmT88V80mm` | 80 mm | 72 mm | 512 |
| `tmT88V58mm` | 58 mm | 50.8 mm | 360 |

Cut uses `GS V 66 n` (feed to cutter, partial cut). The TM-T88V autocutter leaves a small
uncut point by design.

## Module layout

```
Sources/TMT88VCore/
  Printer/   PrinterModel, TM-T88V presets, TestReceipt, PrinterStatusQuery
  USB/       UsbDiscovery, UsbTransport (+ RecordingTransport), IOUSBHostTransport,
             UsbDescriptorParser, UsbDeviceInfo, UsbError, IORegistry
  EscPos/    EscPosEncoder, EscPosStatus
Sources/tmt88v-diag/   Milestone 1 tool
Sources/tmt88v-test/   Milestone 2 tool
```

ESC/POS encoding knows nothing about USB, and the transport knows nothing about ESC/POS.
`UsbTransport` is the seam where the future service and the raster pipeline plug in.

## Error codes

| Code | Exit | Meaning |
| --- | --- | --- |
| `printer_not_found` | 10 | No matching device in IORegistry |
| `permission_denied` | 11 | `kIOReturnNotPrivileged` / `kIOReturnNotPermitted` |
| `interface_busy` | 12 | Interface already opened; owner process is reported |
| `endpoint_not_found` | 13 | No bulk OUT (or IN) on the interface |
| `usb_write_failed` | 14 | Bulk OUT failed or short write |
| `usb_read_failed` | 15 | Bulk IN / control request failed or invalid reply |
| `timeout` | 16 | Transfer timed out |
| `printer_disconnected` | 17 | Service terminated or device gone |
| `open_failed` | 18 | Interface open failed for another reason |
| paper out / cover open / other | 20 / 21 / 22 | `tmt88v-test` pre-flight status refused to print |

The raw IOReturn value and its `mach_error_string` are always included in the message.
IOUSBHost reports an already-open interface as `kIOReturnInternalError (0xE00002C9)`, so
`interface_busy` is determined by inspecting the interface's IORegistry children.

## Verified end-to-end print path

Physically verified on the owner's TM-T88V (2026-10-01): a print through a real macOS CUPS queue
reached the printer and was readable and correct, with no Epson driver or Rosetta involved.

```
macOS CUPS queue TMT88V_Compat_Test (driverless, image/urf)
  -> ipp://127.0.0.1:8632/ipp/print            tmt88v-service, loopback only, no Bonjour
  -> RasterDocument (URF/PWG) -> trim -> RasterProcessor (512 dots, 1-bit)
  -> RasterEncoder (GS v 0 bands) -> ESC/POS
  -> IOUSBHostTransport -> TM-T88V (bulk OUT 0x01)
```

Queue configuration and test details: `docs/TESTING.md`. IPP design, media and exposure:
`docs/IPP_ARCHITECTURE.md`. The two legacy applications are **not** yet verified.

## Per-job diagnostics

`job_received` logs the print options CUPS requested (`media`, `media-col` with dimensions,
`copies`, `printer-resolution`, `sides`, `orientation-requested`, `print-color-mode`,
`print-scaling`, `document-format`). `job_completed` logs `pages`, `cuts`, and `page_details` per page:
`page_px`, `page_mm`, `dpi`, `trimmed_height`, `raster` (final dots), `scale` (`none`/`down`) with
`scale_factor`, `offset_x` (centring), `blank`, `cut`. `ipp_request` logs every IPP operation and its
status. Job names, user names and document content are never logged.
