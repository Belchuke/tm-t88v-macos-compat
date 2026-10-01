import Foundation

public enum UsbDirection: String, Sendable {
    case `in` = "IN"
    case out = "OUT"
}

public enum UsbTransferType: String, Sendable {
    case control = "Control"
    case isochronous = "Isochronous"
    case bulk = "Bulk"
    case interrupt = "Interrupt"
}

public struct UsbEndpointInfo: Sendable, Equatable {
    public let address: UInt8
    public let attributes: UInt8
    public let maxPacketSize: UInt16
    public let interval: UInt8

    public var number: UInt8 { address & 0x0F }
    public var direction: UsbDirection { address & 0x80 != 0 ? .in : .out }

    public var transferType: UsbTransferType {
        switch attributes & 0x03 {
        case 0: .control
        case 1: .isochronous
        case 2: .bulk
        default: .interrupt
        }
    }
}

public struct UsbInterfaceInfo: Sendable, Equatable {
    public let number: UInt8
    public let alternateSetting: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubClass: UInt8
    public let interfaceProtocol: UInt8
    public var endpoints: [UsbEndpointInfo]

    public var isPrinterClass: Bool { interfaceClass == 0x07 && interfaceSubClass == 0x01 }
    public var isVendorClass: Bool { interfaceClass == 0xFF }

    public var classDescription: String {
        switch (interfaceClass, interfaceSubClass, interfaceProtocol) {
        case (0x07, 0x01, 0x01): "Printer Class (unidirectional)"
        case (0x07, 0x01, 0x02): "Printer Class (bidirectional)"
        case (0x07, 0x01, 0x03): "Printer Class (IEEE 1284.4)"
        case (0x07, 0x01, 0x04): "Printer Class (IPP-over-USB)"
        case (0x07, _, _): "Printer Class"
        case (0xFF, _, _): "Vendor Specific"
        default: "Class 0x\(Hex.byte(interfaceClass))"
        }
    }

    public var bulkOut: UsbEndpointInfo? {
        endpoints.first { $0.transferType == .bulk && $0.direction == .out }
    }

    public var bulkIn: UsbEndpointInfo? {
        endpoints.first { $0.transferType == .bulk && $0.direction == .in }
    }
}

public struct UsbDeviceInfo: Sendable {
    public let registryID: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public let manufacturer: String?
    public let productName: String?
    public let serialNumber: String?
    public let locationID: UInt32?
    public let bcdUSB: UInt16?
    public let linkSpeedBitsPerSecond: Int?
    public var interfaces: [UsbInterfaceSummary]

    public var usbMode: String {
        if interfaces.contains(where: { $0.info.isPrinterClass }) { return "Printer Class" }
        if interfaces.contains(where: { $0.info.isVendorClass }) { return "Vendor Class" }
        return "Unknown"
    }
}

public struct UsbInterfaceSummary: Sendable {
    public var info: UsbInterfaceInfo
    public var endpointsReadable: Bool
    public var endpointError: String?
    public var openedBy: [String]
}

enum Hex {
    static func byte(_ value: UInt8) -> String { String(format: "%02X", value) }
    static func word(_ value: UInt16) -> String { String(format: "%04X", value) }
}
