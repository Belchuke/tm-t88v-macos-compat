import Foundation

public enum CutMode: String, Sendable {
    case none
    case partial
    case full
}

public struct PrinterModel: Sendable, Equatable {
    public var name: String
    public var usbVendorID: UInt16
    public var usbProductNames: [String]
    public var dpi: Int
    public var paperWidthMM: Double
    public var printableWidthMM: Double
    public var dotsPerLine: Int
    public var cutMode: CutMode
    public var cutFeedUnits: Int

    public init(
        name: String,
        usbVendorID: UInt16,
        usbProductNames: [String],
        dpi: Int,
        paperWidthMM: Double,
        printableWidthMM: Double,
        dotsPerLine: Int,
        cutMode: CutMode,
        cutFeedUnits: Int
    ) {
        self.name = name
        self.usbVendorID = usbVendorID
        self.usbProductNames = usbProductNames
        self.dpi = dpi
        self.paperWidthMM = paperWidthMM
        self.printableWidthMM = printableWidthMM
        self.dotsPerLine = dotsPerLine
        self.cutMode = cutMode
        self.cutFeedUnits = cutFeedUnits
    }

    public func matches(productName: String?) -> Bool {
        guard let productName else { return false }
        let normalized = productName.trimmingCharacters(in: .whitespaces).uppercased()
        return usbProductNames.contains { $0.uppercased() == normalized }
    }
}
