import Foundation
import IOKit
import IOUSBHost

public final class IOUSBHostTransport: UsbTransport, @unchecked Sendable {
    private static let serviceTerminatedMessage: UInt32 = 0xE000_0010
    private static let maxChunkSize = 16 * 1024

    public let device: UsbDeviceInfo
    public let interfaceInfo: UsbInterfaceInfo
    public var writeTimeout: TimeInterval = 15

    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe?
    private let state: ConnectionState

    public var isConnected: Bool { state.connected }

    public static func open(device: UsbDeviceInfo) throws -> IOUSBHostTransport {
        let services = UsbDiscovery.interfaceServices(ofDevice: device.registryID)
        defer { services.forEach { IOObjectRelease($0) } }
        guard !services.isEmpty else {
            throw UsbError(.printerDisconnected, "device \(device.productName ?? "?") has no IOUSBHostInterface (unplugged?)")
        }

        let ranked = services.sorted { rank($0) < rank($1) }
        var lastError: UsbError?
        for service in ranked {
            do {
                return try IOUSBHostTransport(device: device, service: service)
            } catch let error as UsbError {
                lastError = error
                if error.code == .interfaceBusy || error.code == .permissionDenied { throw error }
            }
        }
        throw lastError ?? UsbError(.endpointNotFound, "no interface with a bulk OUT endpoint")
    }

    private static func rank(_ service: io_service_t) -> Int {
        switch IORegistry.int(service, "bInterfaceClass") {
        case 0x07: 0
        case 0xFF: 1
        default: 2
        }
    }

    private init(device: UsbDeviceInfo, service: io_service_t) throws {
        let state = ConnectionState()
        let interface = try UsbInterfaceOpener.open(service: service) { _, messageType, _ in
            if messageType == Self.serviceTerminatedMessage {
                state.markDisconnected()
            }
        }

        let configuration = interface.configurationDescriptor
        let bytes = [UInt8](UnsafeRawBufferPointer(
            start: UnsafeRawPointer(configuration),
            count: Int(configuration.pointee.wTotalLength)
        ))
        let descriptor = interface.interfaceDescriptor.pointee
        guard let info = UsbDescriptorParser.parseConfiguration(bytes).first(where: {
            $0.number == descriptor.bInterfaceNumber && $0.alternateSetting == descriptor.bAlternateSetting
        }) else {
            interface.destroy()
            throw UsbError(.endpointNotFound, "interface \(descriptor.bInterfaceNumber) not present in configuration descriptor")
        }

        guard let bulkOut = info.bulkOut else {
            interface.destroy()
            throw UsbError(.endpointNotFound, "interface \(info.number) (\(info.classDescription)) has no bulk OUT endpoint")
        }

        do {
            outPipe = try interface.copyPipe(withAddress: Int(bulkOut.address))
            inPipe = try info.bulkIn.map { try interface.copyPipe(withAddress: Int($0.address)) }
        } catch {
            interface.destroy()
            throw UsbError.from(error, fallback: .endpointNotFound, context: "copyPipe failed")
        }

        self.state = state
        self.device = device
        self.interfaceInfo = info
        self.interface = interface
    }

    deinit {
        close()
    }

    public func write(_ data: Data) throws {
        try ensureConnected()
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxChunkSize, data.count)
            let chunk = NSMutableData(data: data.subdata(in: offset..<end))
            var transferred = 0
            do {
                try outPipe.__sendIORequest(with: chunk, bytesTransferred: &transferred, completionTimeout: writeTimeout)
            } catch {
                throw failure(error, fallback: .usbWriteFailed, context: "bulk OUT write of \(chunk.length) bytes at offset \(offset) failed after \(transferred) bytes")
            }
            guard transferred == chunk.length else {
                throw UsbError(.usbWriteFailed, "short write: \(transferred) of \(chunk.length) bytes at offset \(offset)")
            }
            offset = end
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        try ensureConnected()
        guard let inPipe else {
            throw UsbError(.endpointNotFound, "interface \(interfaceInfo.number) has no bulk IN endpoint")
        }
        guard let buffer = NSMutableData(length: maxLength) else {
            throw UsbError(.usbReadFailed, "could not allocate \(maxLength) byte buffer")
        }
        var transferred = 0
        do {
            try inPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw failure(error, fallback: .usbReadFailed, context: "bulk IN read failed")
        }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    public func ieee1284DeviceID() throws -> String {
        guard interfaceInfo.isPrinterClass else {
            throw UsbError(.endpointNotFound, "GET_DEVICE_ID requires a Printer Class interface")
        }
        let length = 1024
        let request = IOUSBDeviceRequest(
            bmRequestType: 0xA1,
            bRequest: 0,
            wValue: 0,
            wIndex: UInt16(interfaceInfo.number) << 8 | UInt16(interfaceInfo.alternateSetting),
            wLength: UInt16(length)
        )
        let data = try controlIn(request, length: length)
        guard data.count >= 2 else { return "" }
        let declared = Int(data[0]) << 8 | Int(data[1])
        let body = data.dropFirst(2).prefix(max(0, declared - 2))
        return String(decoding: body, as: UTF8.self)
    }

    public func portStatus() throws -> UInt8 {
        let request = IOUSBDeviceRequest(
            bmRequestType: 0xA1,
            bRequest: 1,
            wValue: 0,
            wIndex: UInt16(interfaceInfo.number),
            wLength: 1
        )
        guard let byte = try controlIn(request, length: 1).first else {
            throw UsbError(.usbReadFailed, "GET_PORT_STATUS returned no data")
        }
        return byte
    }

    public func close() {
        guard state.markClosed() else { return }
        interface.destroy()
    }

    private func controlIn(_ request: IOUSBDeviceRequest, length: Int) throws -> Data {
        try ensureConnected()
        guard let buffer = NSMutableData(length: length) else {
            throw UsbError(.usbReadFailed, "could not allocate \(length) byte buffer")
        }
        var transferred = 0
        do {
            try interface.__send(request, data: buffer, bytesTransferred: &transferred, completionTimeout: 5)
        } catch {
            throw failure(error, fallback: .usbReadFailed, context: "control request 0x\(Hex.byte(request.bRequest)) failed")
        }
        return Data(bytes: buffer.bytes, count: transferred)
    }

    private func ensureConnected() throws {
        if state.closed { throw UsbError(.printerDisconnected, "transport already closed") }
        if !state.connected { throw UsbError(.printerDisconnected, "printer was unplugged or powered off") }
    }

    private func failure(_ error: Error, fallback: UsbErrorCode, context: String) -> UsbError {
        let mapped = UsbError.from(error, fallback: fallback, context: context)
        if !state.connected {
            return UsbError(.printerDisconnected, mapped.message, ioReturn: mapped.ioReturn)
        }
        return mapped
    }
}

private final class ConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _connected = true
    private var _closed = false

    var connected: Bool { lock.withLock { _connected } }
    var closed: Bool { lock.withLock { _closed } }

    func markDisconnected() {
        lock.withLock { _connected = false }
    }

    func markClosed() -> Bool {
        lock.withLock {
            if _closed { return false }
            _closed = true
            return true
        }
    }
}
