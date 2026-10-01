import Foundation

public struct OutputReceipt: Sendable {
    public let connection: String
    public let transferMilliseconds: Double
}

public protocol PrintOutput: Sendable {
    var connectionName: String { get }
    func send(_ payload: Data, jobID: Int) throws -> OutputReceipt
}

public struct SinkOutput: PrintOutput {
    public let url: URL
    private let wantsDirectory: Bool
    public var connectionName: String { "sink" }

    public init(path: String) {
        self.url = URL(fileURLWithPath: path)
        self.wantsDirectory = path.hasSuffix("/")
    }

    public func send(_ payload: Data, jobID: Int) throws -> OutputReceipt {
        let start = DispatchTime.now()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let target = (exists && isDirectory.boolValue) || wantsDirectory
            ? url.appendingPathComponent("job-\(jobID).escpos")
            : url
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: target, options: .atomic)
        return OutputReceipt(connection: "sink", transferMilliseconds: elapsed(since: start))
    }
}

public struct UsbOutput: PrintOutput {
    public let model: PrinterModel
    public let serial: String?
    public var connectionName: String { "usb" }

    public init(model: PrinterModel, serial: String? = nil) {
        self.model = model
        self.serial = serial
    }

    public func send(_ payload: Data, jobID: Int) throws -> OutputReceipt {
        let device = try UsbDiscovery.selectPrinter(model: model, serial: serial)
        let transport = try IOUSBHostTransport.open(device: device)
        defer { transport.close() }

        do {
            let status = try PrinterStatusQuery.query(transport)
            if status.blocksPrinting {
                throw UsbError(.usbWriteFailed, "printer not ready: \(status.summary)")
            }
        } catch let error as UsbError where error.code == .timeout || error.code == .usbReadFailed {
        }

        let start = DispatchTime.now()
        try transport.write(payload)
        return OutputReceipt(connection: "usb", transferMilliseconds: elapsed(since: start))
    }
}

func elapsed(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}
