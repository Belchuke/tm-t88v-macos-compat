import Foundation

public enum UsbDescriptorParser {
    static let interfaceType: UInt8 = 0x04
    static let endpointType: UInt8 = 0x05

    public static func parseConfiguration(_ bytes: [UInt8]) -> [UsbInterfaceInfo] {
        var interfaces: [UsbInterfaceInfo] = []
        var offset = 0

        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= bytes.count else { break }
            let type = bytes[offset + 1]

            if type == interfaceType, length >= 9 {
                interfaces.append(UsbInterfaceInfo(
                    number: bytes[offset + 2],
                    alternateSetting: bytes[offset + 3],
                    interfaceClass: bytes[offset + 5],
                    interfaceSubClass: bytes[offset + 6],
                    interfaceProtocol: bytes[offset + 7],
                    endpoints: []
                ))
            } else if type == endpointType, length >= 7, !interfaces.isEmpty {
                let endpoint = UsbEndpointInfo(
                    address: bytes[offset + 2],
                    attributes: bytes[offset + 3],
                    maxPacketSize: UInt16(bytes[offset + 4]) | UInt16(bytes[offset + 5]) << 8,
                    interval: bytes[offset + 6]
                )
                interfaces[interfaces.count - 1].endpoints.append(endpoint)
            }

            offset += length
        }

        return interfaces
    }
}
