# Testing the two legacy applications

Status: **not yet verified.** Do not change the print pipeline unless one of these tests exposes a
real problem. Use the existing test queue `TMT88V_Compat_Test`; do not remove or edit the Epson queue.

## Setup (once)

1. Stop the running service, rebuild, restart with a log file. `build.sh` overwrites `dist/`, so
   the service must not be running during the build.
   ```
   ./scripts/build.sh
   dist/tmt88v-service --log-file ~/tmt88v-legacy.log
   ```
   Keep that Terminal window open (the same JSON lines also appear there).
2. Snapshot the queue and the old queue for comparison:
   ```
   lpstat -l -p TMT88V_Compat_Test EPSON_TM_T88V > ~/queues.txt
   lpoptions -p TMT88V_Compat_Test -l >> ~/queues.txt
   lpoptions -p EPSON_TM_T88V -l >> ~/queues.txt
   cp /etc/cups/ppd/TMT88V_Compat_Test.ppd /etc/cups/ppd/EPSON_TM_T88V.ppd ~/
   ```
3. Optional, needs admin: CUPS-side log for the run.
   ```
   sudo cupsctl --debug-logging
   ... run the tests ...
   sudo cupsctl --no-debug-logging
   sudo cp /var/log/cups/error_log ~/cups_error_log.txt && sudo chmod a+r ~/cups_error_log.txt
   ```
   Without admin: `log show --last 15m --predicate 'process == "cupsd"' > ~/cupsd_unified.txt`.
4. Do not print to the Epson queue and `TMT88V_Compat_Test` at the same moment (one USB interface).

## For each application, run these in order

For every step note: what you did, what came out of the printer, and the log lines for that job
(`grep -E '"job_(received|completed|failed)"|ipp_request' ~/tmt88v-legacy.log | tail`).

| # | Step | What to look for |
| --- | --- | --- |
| 1 | Open the app's printer selection / printer setup. Is `TMT88V_Compat_Test` listed? Select it. | Appears; no error or "driver missing" dialog |
| 2 | Open the app's paper size / page setup for this printer. Write down every size offered and which one is selected. Do the same for the Epson queue. | Sizes offered (`72x297mm`? only a custom size? something else); whether the app complains the size `RP80x297` is missing |
| 3 | Print the normal short receipt your customers print. | Text readable; full width, nothing clipped on left/right; one cut at the end; length reasonable (not a 297 mm blank tail) |
| 4 | Print the same document to the Epson queue (not at the same time) and compare to step 3 on paper. | Same width, margins, font size, line spacing, logo/barcode/QR position and size |
| 5 | Print a longer receipt (more than ~30 cm). | Where the cuts fall; whether content is lost or duplicated at page boundaries |
| 6 | Print with copies = 2 if the app offers it. | Number of receipts; log `requested.copies` |
| 7 | If the app prints images, barcodes or QR codes, print one of each. | Scannable barcode/QR; image not distorted |
| 8 | Quit and reopen the app. Does it remember the printer and paper size? | Selection persists, or reverts to the default printer |
| 9 | If the app can open a cash drawer, sound the buzzer, or select cut mode (Epson's driver has buzzer settings), try it. | The service does **not** implement drawer, buzzer or cut-mode options; record whether they are used |
| 10 | If the app prints silently (no dialog), repeat step 3 that way. | Same output; `requested` in the log shows what the app asked for |

## What to send back, per application

- Application name and version, and how it prints (print dialog, silent, from a template).
- The paper sizes seen in step 2 and the one used.
- A photo or description of each printed result (width, clipping, cut count, length), and the same for the Epson queue in step 4.
- `~/tmt88v-legacy.log` (or the relevant lines). The useful fields:
  - `job_received.requested`: `media`, `media-col` (dimensions), `copies`, `printer-resolution`,
    `print-scaling`, `orientation-requested`.
  - `job_completed`: `pages`, `cuts`, and `page_details[]`: `page_px`, `page_mm`, `raster`,
    `scale` / `scale_factor`, `trimmed_height`, `offset_x`.
  - `job_failed.error` if anything failed; any `ipp_request` with a status other than `0x0000`.
- `~/queues.txt` and the two `.ppd` files.
- If something looks wrong: the CUPS `error_log` section covering that job, and whether the same
  document prints correctly from TextEdit through the same queue.

Log contents never include the job name, user name or document data, so the log is safe to share.

## How to read the results

- `page_mm` close to `72.0 x 296.9` and `scale: none`: macOS delivered the page at the expected
  roll size. A different width means the app picked another paper size; check `media`/`media-col`.
- `scale: down`: the page was wider than 512 dots and was shrunk to fit. Content may look smaller than
  with the Epson driver. This points at paper-size selection, not a pipeline fault.
- `cuts` greater than 1 on a single receipt: the document spanned several pages. Each page is cut
  separately by design; whether the legacy apps need cut-per-document is what this test decides.
- A short printed length with `trimmed_height` much smaller than `page_px` height is the intended
  removal of blank paper at the end of the page.
