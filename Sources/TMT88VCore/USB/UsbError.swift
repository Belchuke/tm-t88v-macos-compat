import Foundation
import IOKit

public enum UsbErrorCode: String, Sendable {
    case printerNotFound = "printer_not_found"
    case permissionDenied = "permission_denied"
    case interfaceBusy = "interface_busy"
    case endpointNotFound = "endpoint_not_found"
    case usbWriteFailed = "usb_write_failed"
    case usbReadFailed = "usb_read_failed"
    case timeout = "timeout"
    case printerDisconnected = "printer_disconnected"
    case openFailed = "open_failed"

    public var exitCode: Int32 {
        switch self {
        case .printerNotFound: 10
        case .permissionDenied: 11
        case .interfaceBusy: 12
        case .endpointNotFound: 13
        case .usbWriteFailed: 14
        case .usbReadFailed: 15
        case .timeout: 16
        case .printerDisconnected: 17
        case .openFailed: 18
        }
    }
}

public struct UsbError: Error, CustomStringConvertible, Sendable {
    public let code: UsbErrorCode
    public let message: String
    public let ioReturn: IOReturn?

    public init(_ code: UsbErrorCode, _ message: String, ioReturn: IOReturn? = nil) {
        self.code = code
        self.message = message
        self.ioReturn = ioReturn
    }

    public var description: String {
        var text = "\(code.rawValue): \(message)"
        if let ioReturn {
            text += " [IOReturn \(IOReturnFormatter.describe(ioReturn))]"
        }
        return text
    }

    static func from(_ error: Error, fallback: UsbErrorCode, context: String) -> UsbError {
        if let usbError = error as? UsbError { return usbError }
        let nsError = error as NSError
        let ioReturn = IOReturn(truncatingIfNeeded: nsError.code)
        let code: UsbErrorCode = switch ioReturn {
        case kIOReturnNotPrivileged, kIOReturnNotPermitted: .permissionDenied
        case kIOReturnExclusiveAccess, kIOReturnBusy, kIOReturnStillOpen: .interfaceBusy
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotResponding, kIOReturnOffline: .printerDisconnected
        case kIOReturnTimeout: .timeout
        default: fallback
        }
        return UsbError(code, "\(context): \(nsError.localizedDescription) (\(nsError.domain))", ioReturn: ioReturn)
    }
}

enum IOReturnFormatter {
    static func describe(_ value: IOReturn) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: value))
        guard let cString = mach_error_string(value) else { return hex }
        return "\(hex) \(String(cString: cString))"
    }
}
