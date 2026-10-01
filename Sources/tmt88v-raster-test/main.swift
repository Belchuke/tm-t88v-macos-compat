import CoreGraphics
import Foundation
import TMT88VCore

setlinebuf(stdout)

let usage = """
usage: tmt88v-raster-test (IMAGE | --pattern) [options]

  IMAGE                 PNG or JPEG file to print
  --pattern             print the built-in deterministic test pattern
  --write-pattern FILE  write the built-in test pattern as PNG and exit
  --dither MODE         floyd-steinberg (default) | threshold
  --scale MODE          fit (default, shrink only, centered) | actual-size (error if too wide)
  --threshold N         black/white cutoff 1-255 (default 128)
  --paper 80|58         paper width preset (default 80)
  --serial SERIAL       use the TM-T88V with this USB serial
  --no-cut              do not cut
  --preview FILE        write the final 1-bit bitmap as PNG
  --dry-run FILE        write the ESC/POS bytes to FILE instead of printing
  --decode FILE         decode raster ESC/POS FILE (for example a service sink file) into --preview PNG and exit
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

var model = PrinterModel.tmT88V80mm
var options = RasterOptions()
var imagePath: String?
var usePattern = false
var serial: String?
var previewPath: String?
var dryRunPath: String?
var noCut = false
var decodePath: String?

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
    case "--pattern": usePattern = true
    case "--write-pattern":
        let path = value()
        guard let pattern = TestPattern.make() else { fail("could not render pattern", code: 1) }
        do { try TestPattern.writePNG(pattern, to: URL(fileURLWithPath: path)) } catch { fail("\(error)", code: 1) }
        print("wrote \(pattern.width)x\(pattern.height) pattern to \(path)")
        exit(0)
    case "--dither":
        guard let mode = DitherMode(rawValue: value()) else { fail("unknown dither mode", code: 2) }
        options.dither = mode
    case "--scale":
        guard let mode = ScaleMode(rawValue: value()) else { fail("unknown scale mode", code: 2) }
        options.scale = mode
    case "--threshold":
        guard let n = UInt8(value()), n > 0 else { fail("threshold must be 1-255", code: 2) }
        options.threshold = n
    case "--paper":
        switch value() {
        case "80": model = .tmT88V80mm
        case "58": model = .tmT88V58mm
        case let other: fail("unsupported paper width \(other)", code: 2)
        }
    case "--serial": serial = value()
    case "--no-cut": noCut = true
    case "--preview": previewPath = value()
    case "--dry-run": dryRunPath = value()
    case "--decode": decodePath = value()
    default:
        if argument.hasPrefix("-") || imagePath != nil { fail("unknown argument \(argument)\n\(usage)", code: 2) }
        imagePath = argument
    }
}
if let decodePath {
    do {
        let receipts = try EscPosRasterDecoder.decode(try Data(contentsOf: URL(fileURLWithPath: decodePath)))
        for (index, receipt) in receipts.enumerated() {
            print("receipt \(index + 1): \(receipt.bitmap.width)x\(receipt.bitmap.height) dots, feed \(receipt.feedLines), cut \(receipt.cut)")
            if let previewPath, index == 0, let image = RasterProcessor.previewImage(receipt.bitmap) {
                try TestPattern.writePNG(image, to: URL(fileURLWithPath: previewPath))
                print("preview:   \(previewPath)")
            }
        }
        exit(0)
    } catch { fail("decode failed: \(error)", code: 1) }
}
if noCut { model.cutMode = .none }
guard usePattern != (imagePath != nil) else { fail("give exactly one of IMAGE or --pattern\n\(usage)", code: 2) }

let totalStart = DispatchTime.now()

do {
    let decodeStart = DispatchTime.now()
    let source: CGImage
    if let imagePath {
        source = try ImageDecoder.load(url: URL(fileURLWithPath: imagePath))
    } else {
        guard let pattern = TestPattern.make(width: model.dotsPerLine) else { fail("could not render pattern", code: 1) }
        source = pattern
    }
    let decodeMs = milliseconds(since: decodeStart)

    let processStart = DispatchTime.now()
    let bitmap = try RasterProcessor.process(source, model: model, options: options)
    let processMs = milliseconds(since: processStart)

    let payload = try RasterReceipt.build(bitmap: bitmap, model: model)

    print("source:    \(source.width)x\(source.height) px (\(source.width * source.height * 4) bytes decoded RGBA-equivalent)")
    print("bitmap:    \(bitmap.width)x\(bitmap.height) dots, \(bitmap.rowBytes) bytes/row, \(bitmap.data.count) bytes packed")
    print("printer:   \(model.name), \(model.dotsPerLine) dots @ \(model.dpi) dpi, \(options.dither.rawValue), \(options.scale.rawValue)")
    print("escpos:    \(payload.count) bytes")
    print(String(format: "timing:    decode %.1f ms, convert %.1f ms", decodeMs, processMs))

    if let previewPath, let preview = RasterProcessor.previewImage(bitmap) {
        try TestPattern.writePNG(preview, to: URL(fileURLWithPath: previewPath))
        print("preview:   \(previewPath)")
    }

    if let dryRunPath {
        try payload.write(to: URL(fileURLWithPath: dryRunPath))
        print(String(format: "dry run: wrote %d bytes to %@ (total %.1f ms)", payload.count, dryRunPath, milliseconds(since: totalStart)))
        exit(0)
    }

    let device = try UsbDiscovery.selectPrinter(model: model, serial: serial)
    print("found \(device.productName ?? "?") serial \(device.serialNumber ?? "?") (\(device.usbMode))")
    let transport = try IOUSBHostTransport.open(device: device)
    defer { transport.close() }

    do {
        let status = try PrinterStatusQuery.query(transport)
        print("status:    \(status.summary)")
        if status.blocksPrinting {
            fail("printer not ready: \(status.summary)", code: status.coverOpen ? 21 : (status.paperEnd || status.stoppedByPaperEnd) ? 20 : 22)
        }
    } catch let error as UsbError where error.code == .timeout || error.code == .usbReadFailed {
        print("status:    unavailable (\(error)); continuing")
    }

    let usbStart = DispatchTime.now()
    try transport.write(payload)
    let usbMs = milliseconds(since: usbStart)
    transport.close()
    print(String(format: "timing:    usb transfer %.1f ms, total %.1f ms", usbMs, milliseconds(since: totalStart)))
    print("sent \(payload.count) bytes (\(model.cutMode == .none ? "no cut" : "\(model.cutMode.rawValue) cut"))")
} catch let error as UsbError {
    fail(error.description, code: error.code.exitCode)
} catch let error as RasterError {
    fail(error.description, code: 30)
} catch {
    fail("unexpected error: \(error)", code: 1)
}
