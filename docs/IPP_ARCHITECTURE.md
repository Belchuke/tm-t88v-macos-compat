# Local IPP printer (Milestone 4)

```
macOS Print -> CUPS -> ipp://127.0.0.1:PORT/ipp/print -> tmt88v-service
   -> URF / PWG raster parse -> trim -> 512-dot 1-bit -> ESC/POS -> sink file | USB
```

## Decision: native Swift IPP server, not PAPPL

| | PAPPL | Native Swift (chosen) |
| --- | --- | --- |
| IPP correctness | Mature, widely tested | Small subset, checked against Apple's `ipptool` and libcups (see below) |
| Dependencies | C library; needs libcups (2.x for PAPPL 1.x, 3.x for 2.x), image libs, TLS, zlib | None beyond system frameworks |
| Embedding in a macOS product | Must build, universal/arm64-link, sign and notarize libcups and friends ourselves | Single arm64 binary, links only `/System` and `/usr/lib` |
| Raster reception | Built in | `RasterDocument` (URF, PWG) ~250 lines, fuzz-tested |
| DNS-SD | Advertises by default | None |
| Loopback-only | Configurable, but a larger surface to audit | 127.0.0.1 and ::1 sockets, nothing else |
| Maintenance | Track upstream and its dependency stack | Own ~1k lines; breaking macOS changes land in our tests |

The PAPPL column is from general knowledge and was **not** built or evaluated on this machine. The
decision rests mainly on the printer needing only six IPP operations, one document type family, and
no discovery. Revisit if the required IPP surface grows (Create-Job/Send-Document, PDF input,
authentication, TLS).

## Local-only exposure (confirmed)

- Listens on `127.0.0.1:PORT` and `[::1]:PORT` only (default `8632`). `lsof` shows exactly these
  two sockets. A test connects to every non-loopback IPv4 address of the host and requires refusal.
- **No Bonjour/DNS-SD.** The queue is created with an explicit device URI, so macOS never needs to
  discover it. It will not appear under "Add Printer > Nearby"; the installer must create it.
- Reachable from the LAN: nothing. Reachable by other local users and processes: yes (no
  authentication on loopback).
- Browser-origin abuse: requests need `Content-Type: application/ipp` (forces a CORS preflight for
  web pages) and a `Host` of `127.0.0.1`, `localhost` or `[::1]` (blocks DNS rebinding).
- Limits: 64 MB per document (`--max-job-mb`), 16 KB headers, 16 concurrent connections, 30 s read
  timeout, 128 jobs retained. Oversized `Content-Length` is refused before the body is read.

## Implemented IPP

Operations: Print-Job, Validate-Job, Cancel-Job, Get-Job-Attributes, Get-Jobs, Get-Printer-Attributes.
Not implemented (answered with `server-error-operation-not-supported`): Create-Job, Send-Document,
Hold/Release, Pause/Resume, subscriptions. Apple's IPP backend uses Print-Job for single documents.

Printer attributes include: state, state-reasons, accepting-jobs, queued-job-count, uuid,
device-id, `ipp-features-supported=ipp-everywhere`, document formats (`image/urf`,
`image/pwg-raster`, `application/octet-stream` for magic-detected raster), `urf-supported`
(V1.4 CP1 W8 RS180 DM1), PWG raster capabilities, monochrome only, one-sided only, 180 dpi,
copies 1-1, orientation portrait, media (below).

Document formats: **PDF is not accepted.** macOS renders to raster before delivery because the
generated PPD declares `image/urf`.

## Media

Advertised: one roll width equal to the printable width (80 mm preset: **72 mm**), default length
297 mm, length range 25.4 mm - 2000 mm, all margins 0, source `main-roll`, type `continuous`.
No A4/Letter. The 58 mm preset advertises 50.8 mm.

### Confirmed on this Mac (macOS 27.0.1, CUPS 2.3.4)

- Epson's current PPD uses a 204 pt (72 mm) page, margins 0, default `RP80x297`
  (80 x 297 mm roll, 204 x 841.8 pt), `RP58x297`, plus A4/Letter/Legal, custom width 72-204 pt,
  height 72-5669.2 pt, 180x180 dpi. Our range (height 72 - 5669.3 pt) matches.
- libcups' own PPD generator (`_ppdCreateFromIPP`, the function behind `lpadmin -m everywhere`)
  turns our attributes into a PPD with: `DefaultPageSize: 72x297mm`,
  `PageSize 72x297mm.Borderless`, `HWMargins 0 0 0 0`, custom size width fixed at 204.09 pt and
  height 72 - 5669.29 pt, `cupsFilter2: image/urf`, `DefaultResolution: 180dpi`.
  Reproduce: `scripts/e2e-sink.sh`.
- macOS CUPS filters (`cupsfilter -m image/urf` with that PPD) render text and PDF to URF pages of
  **510 x 2104 px at 180 dpi**. The service centres these on the 512-dot line (1 dot each side).

### Not preserved: Epson page-size names (`RP80x297`)

The driverless PPD names sizes from their dimensions (`72x297mm.Borderless`); the IPP attribute
cannot request `RP80x297`. Applications that remember the PostScript page-size *name* may not
find it and fall back to the default (which is still the correct 72 x 297 mm roll). Applications
that remember dimensions are unaffected. **Which of these the two legacy apps do is unknown and
must be checked on a real queue.** If names matter, the fallback is a PPD-based queue that copies
Epson's names with our own arm64 raster filter; that departs from the driverless design and is not
built.

### Behaviour choices that differ from Epson's driver (unverified against the legacy apps)

- Trailing white rows of every page are trimmed (a 297 mm page holding 3 text lines prints
  ~13 mm), then 3 feed lines and a partial cut.
- Every page of a job is its own receipt with its own cut. A document longer than one 297 mm page
  is cut at each page boundary. Epson's driver has cut-per-document and cut-per-page options.
- Pages wider than 512 dots are scaled down (never cropped, never scaled up).

## Printer identity and queue name

Not tested. The IPP `printer-name` is configurable (`--name`, default `EPSON TM-T88V`). The CUPS
queue name, device URI and queue UUID are chosen when the queue is created, so a replacement queue
can reuse the visible name `EPSON TM-T88V` (queue `EPSON_TM_T88V`) only after the old queue is
removed. Applications that persist the old printer UUID, or the old PPD options, cannot be helped by
the service. Investigate in Milestone 7.

## Logging

One JSON line per event on stderr, optionally to `--log-file` (rotated at 1 MB, 3 files kept).
Per job: `job_id`, `format`, `pages`, `blank_pages`, `raster_width`, `raster_height` (tallest page),
`dpi`, `escpos_bytes`, `connection` (`usb` | `sink`), `transfer_ms`, `total_ms`; failures log
`error`. Document content, job names and user names are never logged.

## Not done

Media-ready/paper status from the printer, `printer-state-reasons` from USB status, retry when the
printer is unplugged (a job fails and is `aborted`), Create-Job/Send-Document, launchd service,
queue creation, any real CUPS queue test (see TESTING.md).
