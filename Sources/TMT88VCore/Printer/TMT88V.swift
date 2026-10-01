public extension PrinterModel {
    static let tmT88V80mm = PrinterModel(
        name: "EPSON TM-T88V",
        usbVendorID: 0x04B8,
        usbProductNames: ["TM-T88V"],
        dpi: 180,
        paperWidthMM: 80,
        printableWidthMM: 72,
        dotsPerLine: 512,
        cutMode: .partial,
        cutFeedUnits: 0
    )

    static let tmT88V58mm = PrinterModel(
        name: "EPSON TM-T88V (58 mm)",
        usbVendorID: 0x04B8,
        usbProductNames: ["TM-T88V"],
        dpi: 180,
        paperWidthMM: 58,
        printableWidthMM: 50.8,
        dotsPerLine: 360,
        cutMode: .partial,
        cutFeedUnits: 0
    )
}
