import Foundation
import TMT88VCore

setlinebuf(stdout)

let usage = """
usage: tmt88v-service [options]

  --port N          loopback TCP port (default 8632; 0 picks a free port)
  --sink PATH       write ESC/POS to PATH instead of USB (a directory gets job-N.escpos); never touches the printer
  --paper 80|58     paper width preset (default 80)
  --name NAME       printer name advertised over IPP (default "EPSON TM-T88V")
  --serial SERIAL   use the TM-T88V with this USB serial
  --log-file PATH   also write JSON-line logs to PATH (rotated at 1 MB, 3 files kept)
  --max-job-mb N    reject documents larger than N MB (default 64)

Listens on 127.0.0.1 and ::1 only. No Bonjour/DNS-SD advertisement.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var config = IppServerConfig()
var sinkPath: String?
var serial: String?
var logPath: String?

var remaining = Array(CommandLine.arguments.dropFirst())
while !remaining.isEmpty {
    let argument = remaining.removeFirst()
    func value() -> String {
        guard !remaining.isEmpty else { fail("\(argument) requires a value\n\(usage)") }
        return remaining.removeFirst()
    }
    switch argument {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--port":
        guard let port = UInt16(value()) else { fail("invalid port") }
        config.port = port
    case "--sink": sinkPath = value()
    case "--paper":
        switch value() {
        case "80": config.model = .tmT88V80mm
        case "58": config.model = .tmT88V58mm
        case let other: fail("unsupported paper width \(other)")
        }
    case "--name": config.printerName = value()
    case "--serial": serial = value()
    case "--log-file": logPath = value()
    case "--max-job-mb":
        guard let mb = Int(value()), mb > 0, mb <= 512 else { fail("--max-job-mb must be 1-512") }
        config.maxJobBytes = mb * 1024 * 1024
    default: fail("unknown argument \(argument)\n\(usage)")
    }
}

let log = ServiceLog(fileURL: logPath.map { URL(fileURLWithPath: $0) })
let output: PrintOutput = sinkPath.map { SinkOutput(path: $0) } ?? UsbOutput(model: config.model, serial: serial)
let jobs = JobManager(service: PrintService(model: config.model, output: output), log: log)
let server = IppHTTPServer(config: config, handler: IppRequestHandler(config: config, jobs: jobs, log: log), log: log)

do {
    try server.start()
} catch {
    log.event("start_failed", ["error": "\(error)"])
    exit(1)
}

config.port = server.port
log.event("listening", [
    "addresses": server.boundAddresses,
    "printer_uri": config.printerURI(),
    "output": output.connectionName,
    "sink": sinkPath ?? "",
    "paper": config.model.name,
    "dots": config.model.dotsPerLine,
    "bonjour": false,
])
print("printer-uri: \(config.printerURI())")

let signalSources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log.event("stopping", ["signal": signalNumber])
        server.stop()
        exit(0)
    }
    source.resume()
    return source
}
withExtendedLifetime(signalSources) { dispatchMain() }

