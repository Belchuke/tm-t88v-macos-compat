import CryptoKit
import Foundation

public struct IppMediaProfile: Sendable {
    public let widthHundredthsMM: Int32
    public let defaultHeightHundredthsMM: Int32 = 29700
    public let minHeightHundredthsMM: Int32 = 2540
    public let maxHeightHundredthsMM: Int32 = 200_000

    public init(model: PrinterModel) {
        widthHundredthsMM = Int32((model.printableWidthMM * 100).rounded())
    }

    static func mm(_ hundredths: Int32) -> String {
        let value = Double(hundredths) / 100
        return value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    public var defaultName: String { "custom_roll-\(Self.mm(widthHundredthsMM))_\(Self.mm(widthHundredthsMM))x\(Self.mm(defaultHeightHundredthsMM))mm" }
    public var minName: String { "custom_min_\(Self.mm(widthHundredthsMM))x\(Self.mm(minHeightHundredthsMM))mm" }
    public var maxName: String { "custom_max_\(Self.mm(widthHundredthsMM))x\(Self.mm(maxHeightHundredthsMM))mm" }

    func size(height: IppValue) -> IppValue {
        .collection([
            IppAttribute("x-dimension", .integer(widthHundredthsMM)),
            IppAttribute("y-dimension", height),
        ])
    }

    func mediaCol(height: Int32) -> IppValue {
        .collection([
            IppAttribute("media-size", size(height: .integer(height))),
            IppAttribute("media-bottom-margin", .integer(0)),
            IppAttribute("media-left-margin", .integer(0)),
            IppAttribute("media-right-margin", .integer(0)),
            IppAttribute("media-top-margin", .integer(0)),
            IppAttribute("media-source", .keyword("main-roll")),
            IppAttribute("media-type", .keyword("continuous")),
        ])
    }
}

public enum IppPrinterAttributes {
    public static func build(config: IppServerConfig, queuedJobs: Int, processing: Bool, startTime: Date) -> [IppAttribute] {
        let media = IppMediaProfile(model: config.model)
        let dpi = Int32(config.model.dpi)
        let uri = config.printerURI()
        let up = Int32(min(Date().timeIntervalSince(startTime), Double(Int32.max)))

        return [
            IppAttribute("printer-uri-supported", .uri(uri)),
            IppAttribute("uri-authentication-supported", .keyword("none")),
            IppAttribute("uri-security-supported", .keyword("none")),
            IppAttribute("printer-name", .name(config.printerName)),
            IppAttribute("printer-info", .text(config.printerName)),
            IppAttribute("printer-location", .text("")),
            IppAttribute("printer-make-and-model", .text(config.printerName)),
            IppAttribute("printer-device-id", .text("MFG:EPSON;CMD:ESC/POS;MDL:TM-T88V;CLS:PRINTER;")),
            IppAttribute("printer-uuid", .uri(uuid(for: config.printerName))),
            IppAttribute("printer-state", .enumeration(processing ? 4 : 3)),
            IppAttribute("printer-state-reasons", .keyword("none")),
            IppAttribute("printer-state-message", .text("")),
            IppAttribute("printer-is-accepting-jobs", .boolean(true)),
            IppAttribute("queued-job-count", .integer(Int32(queuedJobs))),
            IppAttribute("printer-up-time", .integer(max(1, up))),
            IppAttribute("printer-current-time", .dateTime(dateTime(Date()))),
            IppAttribute("printer-state-change-time", .integer(max(1, up))),
            IppAttribute("printer-config-change-time", .integer(1)),
            IppAttribute("ipp-versions-supported", [.keyword("1.1"), .keyword("2.0")]),
            IppAttribute("ipp-features-supported", .keyword("ipp-everywhere")),
            IppAttribute("operations-supported", supportedOperations.map { .enumeration(Int32($0)) }),
            IppAttribute("charset-configured", .charset("utf-8")),
            IppAttribute("charset-supported", .charset("utf-8")),
            IppAttribute("natural-language-configured", .naturalLanguage("en")),
            IppAttribute("generated-natural-language-supported", .naturalLanguage("en")),
            IppAttribute("compression-supported", .keyword("none")),
            IppAttribute("pdl-override-supported", .keyword("not-attempted")),
            IppAttribute("multiple-document-jobs-supported", .boolean(false)),
            IppAttribute("multiple-operation-time-out", .integer(60)),
            IppAttribute("which-jobs-supported", [.keyword("completed"), .keyword("not-completed")]),
            IppAttribute("job-ids-supported", .boolean(false)),
            IppAttribute("document-format-default", .mimeMediaType("image/urf")),
            IppAttribute("document-format-preferred", .mimeMediaType("image/urf")),
            IppAttribute("document-format-supported", IppServerConfig.acceptedFormats.map { .mimeMediaType($0) }),
            IppAttribute("urf-supported", ["V1.4", "CP1", "W8", "RS\(dpi)", "DM1"].map { .keyword($0) }),
            IppAttribute("pwg-raster-document-resolution-supported", .resolution(cross: dpi, feed: dpi, units: 3)),
            IppAttribute("pwg-raster-document-sheet-back", .keyword("normal")),
            IppAttribute("pwg-raster-document-type-supported", [.keyword("sgray_8"), .keyword("black_1")]),
            IppAttribute("color-supported", .boolean(false)),
            IppAttribute("print-color-mode-default", .keyword("monochrome")),
            IppAttribute("print-color-mode-supported", .keyword("monochrome")),
            IppAttribute("print-quality-default", .enumeration(4)),
            IppAttribute("print-quality-supported", .enumeration(4)),
            IppAttribute("printer-resolution-default", .resolution(cross: dpi, feed: dpi, units: 3)),
            IppAttribute("printer-resolution-supported", .resolution(cross: dpi, feed: dpi, units: 3)),
            IppAttribute("sides-default", .keyword("one-sided")),
            IppAttribute("sides-supported", .keyword("one-sided")),
            IppAttribute("orientation-requested-default", .enumeration(3)),
            IppAttribute("orientation-requested-supported", .enumeration(3)),
            IppAttribute("copies-default", .integer(1)),
            IppAttribute("copies-supported", .range(1, 1)),
            IppAttribute("page-ranges-supported", .boolean(false)),
            IppAttribute("number-up-default", .integer(1)),
            IppAttribute("number-up-supported", .integer(1)),
            IppAttribute("finishings-default", .enumeration(3)),
            IppAttribute("finishings-supported", .enumeration(3)),
            IppAttribute("pages-per-minute", .integer(10)),
            IppAttribute("job-creation-attributes-supported", ["copies", "media", "media-col", "orientation-requested", "print-color-mode", "print-quality", "printer-resolution", "sides", "job-name"].map { .keyword($0) }),
            IppAttribute("media-default", .keyword(media.defaultName)),
            IppAttribute("media-supported", [media.defaultName, media.minName, media.maxName].map { .keyword($0) }),
            IppAttribute("media-ready", .keyword(media.defaultName)),
            IppAttribute("media-size-supported", [
                media.size(height: .integer(media.defaultHeightHundredthsMM)),
                media.size(height: .range(media.minHeightHundredthsMM, media.maxHeightHundredthsMM)),
            ]),
            IppAttribute("media-col-default", media.mediaCol(height: media.defaultHeightHundredthsMM)),
            IppAttribute("media-col-ready", media.mediaCol(height: media.defaultHeightHundredthsMM)),
            IppAttribute("media-col-database", [
                media.mediaCol(height: media.defaultHeightHundredthsMM),
                .collection([
                    IppAttribute("media-size", media.size(height: .range(media.minHeightHundredthsMM, media.maxHeightHundredthsMM))),
                    IppAttribute("media-bottom-margin", .integer(0)),
                    IppAttribute("media-left-margin", .integer(0)),
                    IppAttribute("media-right-margin", .integer(0)),
                    IppAttribute("media-top-margin", .integer(0)),
                    IppAttribute("media-source", .keyword("main-roll")),
                    IppAttribute("media-type", .keyword("continuous")),
                ]),
            ]),
            IppAttribute("media-col-supported", ["media-size", "media-bottom-margin", "media-left-margin", "media-right-margin", "media-top-margin", "media-source", "media-type"].map { .keyword($0) }),
            IppAttribute("media-source-supported", .keyword("main-roll")),
            IppAttribute("media-type-supported", .keyword("continuous")),
            IppAttribute("media-bottom-margin-supported", .integer(0)),
            IppAttribute("media-left-margin-supported", .integer(0)),
            IppAttribute("media-right-margin-supported", .integer(0)),
            IppAttribute("media-top-margin-supported", .integer(0)),
        ]
    }

    public static let supportedOperations: [UInt16] = [
        IppOperation.printJob, IppOperation.validateJob, IppOperation.cancelJob,
        IppOperation.getJobAttributes, IppOperation.getJobs, IppOperation.getPrinterAttributes,
    ]

    static func uuid(for name: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("tmt88v-compat:\(name)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return "urn:uuid:" + UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    static func dateTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var data = Data()
        data.appendBE(UInt16(c.year ?? 1970))
        data.append(contentsOf: [UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
                                 UInt8((c.nanosecond ?? 0) / 100_000_000), UInt8(ascii: "+"), 0, 0])
        return data
    }
}
