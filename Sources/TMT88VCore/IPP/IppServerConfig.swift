import Foundation

public struct IppServerConfig: Sendable {
    public var port: UInt16 = 8632
    public var printerPath = "/ipp/print"
    public var printerName = "EPSON TM-T88V"
    public var maxJobBytes = 64 * 1024 * 1024
    public var model: PrinterModel = .tmT88V80mm

    public init() {}

    public func printerURI(host: String = "127.0.0.1") -> String {
        "ipp://\(host):\(port)\(printerPath)"
    }

    public static let supportedFormats = ["image/urf", "image/pwg-raster"]
    public static let acceptedFormats = supportedFormats + ["application/octet-stream"]
}
