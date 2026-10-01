import Foundation

public enum PrinterStatusQuery {
    static let pollInterval: TimeInterval = 0.02

    public static func query(_ transport: UsbTransport, timeout: TimeInterval = 1) throws -> EscPosStatus {
        drain(transport)
        var status = EscPosStatus()
        for request in EscPosStatusRequest.allCases {
            try transport.write(Data(request.command))
            let response = try awaitResponse(transport, timeout: timeout, request: request)
            guard let byte = response.last(where: EscPosStatus.isValidResponse) else {
                throw UsbError(.usbReadFailed, "unexpected DLE EOT \(request.rawValue) response: \(response.map { Hex.byte($0) }.joined(separator: " "))")
            }
            status.apply(byte, for: request)
        }
        return status
    }

    private static func awaitResponse(_ transport: UsbTransport, timeout: TimeInterval, request: EscPosStatusRequest) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let data = try transport.read(maxLength: 64, timeout: timeout)
            if !data.isEmpty { return data }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        throw UsbError(.timeout, "no response to DLE EOT \(request.rawValue) within \(timeout)s")
    }

    private static func drain(_ transport: UsbTransport) {
        var quietReads = 0
        for _ in 0..<32 where quietReads < 3 {
            let data = (try? transport.read(maxLength: 64, timeout: 0.1)) ?? Data()
            quietReads = data.isEmpty ? quietReads + 1 : 0
            if data.isEmpty { Thread.sleep(forTimeInterval: pollInterval) }
        }
    }
}
