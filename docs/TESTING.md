# Testing

## Automated unit tests (no hardware)

```
./scripts/test.sh
```

Covers configuration descriptor parsing (using the bytes captured from a real TM-T88V),
ESC/POS byte encoding, the test receipt, and DLE EOT status parsing.

## Simulated tests (no hardware)

`RecordingTransport` stands in for USB and answers DLE EOT requests through a responder
closure. The status tests use it to simulate ready, cover-open, paper-out, malformed reply,
no reply, and stale-bytes-in-pipe cases.

`tmt88v-test --dry-run FILE` writes the exact ESC/POS stream to a file without touching USB.

## Hardware tests (physical TM-T88V required)

| # | Test | Command | Expected | Status |
| --- | --- | --- | --- | --- |
| H1 | Discovery | `dist/tmt88v-diag --status` | VID/PID/serial/interface/endpoints, `READY` | Verified 2026-10-01 |
| H2 | Interface busy | open interface in another process, run `dist/tmt88v-test` | `interface_busy ... pid N, name`, exit 12 | Verified 2026-10-01 |
| H3 | Test receipt | `dist/tmt88v-test` | Receipt prints, paper is cut | USB transfer verified (248 bytes accepted, no CUPS job created). **Physical output and cut must be confirmed by a person.** |
| H4 | No cut | `dist/tmt88v-test --no-cut` | Receipt prints, no cut | Not run |
| H5 | Paper out | remove paper roll, `dist/tmt88v-test` | `PAPER_OUT`, exit 20 | Not run |
| H6 | Cover open | open cover, `dist/tmt88v-test` | `COVER_OPEN`, exit 21 | Not run |
| H7 | Not connected | unplug USB, `dist/tmt88v-test` | `printer_not_found`, exit 10 | Not run |
| H8 | Unplug during job | unplug while printing a long job | `printer_disconnected`, exit 17 | Not run (needs a longer job; meaningful in Milestone 3) |
| H9 | Vendor Class mode | switch printer to Vendor Class, rerun H1 and H3 | Device found, prints | Not run |
| H10 | Legacy queue conflict | print to the Epson queue and run `tmt88v-test` concurrently | One side reports busy, nothing hangs | Not run |
| H11 | 58 mm paper | `dist/tmt88v-test --paper 58` with 58 mm roll and printer configured for 58 mm | Prints within width | Not run |

## Milestone 3 and 4 tests

Automated, no hardware (`./scripts/test.sh`, 129 tests): bit packing for widths 1/7/8/9/511/512,
dithering, `GS v 0` banding, scale-down-only and centring, URF/PWG parsing (including truncation
at every byte and random garbage), ESC/POS raster decoding, IPP codec round trips, malformed and
fuzzed IPP, every IPP operation and error status, media/page-size attributes, sink output, HTTP
edge cases (chunked, `Expect: 100-continue`, host header, size limits, keep-alive) and loopback
binding including refused connections on the host's non-loopback addresses.

Simulated against real macOS CUPS components, no hardware (`./scripts/e2e-sink.sh`): `cupsfilter`
renders text and a 2-page PDF to URF using the libcups-generated PPD, `ipptool` submits them to
`tmt88v-service --sink`, and the sink files are decoded and checked for 512-dot width and a cut.

## Physically verified full path (Milestone 4)

Reported by the machine owner on 2026-10-01 (macOS 27.0.1, Apple Silicon, CUPS 2.3.4, Epson TM-T88V
USB Printer Class). A job printed through a real macOS CUPS queue to the physical printer. The
receipt text was `TM-T88V IPP TEST` / `Full macOS print path works.`, readable and correct.

```
macOS CUPS (TMT88V_Compat_Test) -> ipp://127.0.0.1:8632/ipp/print -> tmt88v-service (USB mode)
  -> URF/PWG raster -> raster processor -> ESC/POS -> IOUSBHost -> TM-T88V
```

Queue configuration, as read back from the system (read-only `lpstat`, `lpoptions`, PPD):

| Item | Value |
| --- | --- |
| Queue name | `TMT88V_Compat_Test` |
| Device URI | `ipp://127.0.0.1:8632/ipp/print` |
| Driver | driverless: `printer-make-and-model` = `TM-T88V - IPP Everywhere` (`-m everywhere`) |
| PPD | `/etc/cups/ppd/TMT88V_Compat_Test.ppd`: `DefaultPageSize 72x297mm`, `HWMargins 0 0 0 0`, custom width 204.09 pt, height 72-5669.29 pt, `cupsFilter2 image/urf`, `DefaultColorModel Gray`, `DefaultResolution 180dpi` |
| Printer info | `EPSON TM-T88V` |
| State | idle, enabled, accepting jobs, `printer-state-reasons=none` |
| `printer-is-shared` | **`true`** (see below) |
| Service | `dist/tmt88v-service` in USB mode, port 8632 |

Commands: service `dist/tmt88v-service`; queue creation as documented (H14):
`sudo lpadmin -p TMT88V_Compat_Test -E -v ipp://127.0.0.1:8632/ipp/print -m everywhere`. The exact
commands the owner ran and the application used to print were not recorded; the queue settings
above were read from the system afterwards and match.

The generated PPD is identical to the one predicted before the queue existed from libcups'
generator (`scripts/e2e-sink.sh`), so that prediction method is confirmed.

**Finding:** `lpadmin -E` leaves `printer-is-shared=true`. The existing Epson queue has `false`.
The service itself only listens on loopback, but CUPS could advertise and share this queue if
macOS Printer Sharing is on. The installer should pass `-o printer-is-shared=false`.

**Still not verified:** the two legacy applications (see `docs/LEGACY_APP_TESTING.md`), the
Milestone 3 raster test pattern on paper, paper-out/cover-open/unplug behaviour through the
service, behaviour while the Epson queue is printing, and reboot persistence.

| # | Test | Status |
| --- | --- | --- |
| H12 | Milestone 3: `dist/tmt88v-raster-test --pattern` prints correctly | Pending, no paper result reported yet |
| H13 | `tmt88v-service` in USB mode prints | **Verified** (via H14) |
| H14 | Real CUPS queue created and printed through | **Verified** |
| H15 | Text/page rendering from the macOS print stack through the queue | **Verified** for the short test receipt; application used not recorded |
| H16 | The two legacy applications | **Not verified** |
| H17 | Legacy apps with `72x297mm` instead of `RP80x297` | Unknown |
| H18 | Service in USB mode while the Epson queue is also printing | Not run |
| H19 | Printer unplugged mid-job and between jobs | Not run |
| H20 | Long (multi-page) receipt and cut positions through CUPS | Not run |
| H21 | Reboot / logout: service and queue persistence | Not run (no launchd service yet) |
