import Foundation
import TMT88VCore

setlinebuf(stdout)

let usage = """
usage: tmt88v-test [--serial SERIAL] [--paper 80|58] [--no-cut] [--skip-status] [--dry-run FILE]

  --serial SERIAL   print on the TM-T88V with this USB serial number (default: first found)
  --paper 80|58     paper width preset (default: 80)
  --no-cut          do not send the cut command
  --skip-status     do not query DLE EOT status before printing
  --dry-run FILE    write the ESC/POS bytes to FILE instead of sending them over USB
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var serial: String?
var model = PrinterModel.tmT88V80mm
var skipStatus = false
var dryRunPath: String?

var remaining = Array(CommandLine.arguments.dropFirst())
while !remaining.isEmpty {
    let argument = remaining.removeFirst()
    func value() -> String {
        guard !remaining.isEmpty else { fail("\(argument) requires a value\n\(usage)", code: 2) }
        return remaining.removeFirst()
    }
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--serial": serial = value()
    case "--paper":
        switch value() {
        case "80": model = .tmT88V80mm
        case "58": model = .tmT88V58mm
        case let other: fail("unsupported paper width \(other)", code: 2)
        }
    case "--no-cut": model.cutMode = .none
    case "--skip-status": skipStatus = true
    case "--dry-run": dryRunPath = value()
    default: fail("unknown argument \(argument)\n\(usage)", code: 2)
    }
}

let details = [
    "Model:   \(model.name)",
    "Paper:   \(Int(model.paperWidthMM)) mm, \(model.dotsPerLine) dots",
    "Cut:     \(model.cutMode.rawValue)",
    "Host:    \(ProcessInfo.processInfo.operatingSystemVersionString)",
    "Path:    IOUSBHost -> bulk OUT (no CUPS, no Epson filter)",
]
let payload = TestReceipt.build(model: model, details: details)

if let dryRunPath {
    do {
        try payload.write(to: URL(fileURLWithPath: dryRunPath))
        print("dry run: wrote \(payload.count) ESC/POS bytes to \(dryRunPath)")
        exit(0)
    } catch {
        fail("could not write \(dryRunPath): \(error)", code: 1)
    }
}

do {
    let device = try UsbDiscovery.selectPrinter(model: model, serial: serial)
    print("found \(device.productName ?? "?") serial \(device.serialNumber ?? "?") (\(device.usbMode))")

    let transport = try IOUSBHostTransport.open(device: device)
    defer { transport.close() }
    let endpoint = transport.interfaceInfo.bulkOut.map { String(format: "0x%02X", $0.address) } ?? "?"
    print("opened interface \(transport.interfaceInfo.number), bulk OUT \(endpoint)")

    if !skipStatus {
        do {
            let status = try PrinterStatusQuery.query(transport)
            print("status: \(status.summary)")
            if status.blocksPrinting {
                let code: Int32 = status.coverOpen ? 21 : (status.paperEnd || status.stoppedByPaperEnd) ? 20 : 22
                fail("printer not ready: \(status.summary)", code: code)
            }
        } catch let error as UsbError where error.code == .timeout || error.code == .usbReadFailed || error.code == .endpointNotFound {
            print("status: unavailable (\(error)); continuing")
        }
    }

    try transport.write(payload)
    print("sent \(payload.count) bytes: ESC @, text, feed, \(model.cutMode == .none ? "no cut" : "\(model.cutMode.rawValue) cut")")
    transport.close()
    print("closed")
} catch let error as UsbError {
    fail(error.description, code: error.code.exitCode)
} catch {
    fail("unexpected error: \(error)", code: 1)
}
