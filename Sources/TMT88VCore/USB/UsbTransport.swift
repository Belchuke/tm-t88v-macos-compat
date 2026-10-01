import Foundation

public protocol UsbTransport: AnyObject {
    var isConnected: Bool { get }
    func write(_ data: Data) throws
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data
    func close()
}

public final class RecordingTransport: UsbTransport {
    public private(set) var written = Data()
    public var responder: ((Data) -> Data?)?
    private var pendingReads: [Data] = []
    public var isConnected: Bool = true

    public init() {}

    public func write(_ data: Data) throws {
        guard isConnected else { throw UsbError(.printerDisconnected, "recording transport closed") }
        written.append(data)
        if let response = responder?(data) {
            pendingReads.append(response)
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard !pendingReads.isEmpty else { return Data() }
        return pendingReads.removeFirst().prefix(maxLength)
    }

    public func close() {
        isConnected = false
    }
}
