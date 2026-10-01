public enum IppOperation {
    public static let printJob: UInt16 = 0x0002
    public static let validateJob: UInt16 = 0x0004
    public static let createJob: UInt16 = 0x0005
    public static let sendDocument: UInt16 = 0x0006
    public static let cancelJob: UInt16 = 0x0008
    public static let getJobAttributes: UInt16 = 0x0009
    public static let getJobs: UInt16 = 0x000A
    public static let getPrinterAttributes: UInt16 = 0x000B
}

public enum IppStatus {
    public static let ok: UInt16 = 0x0000
    public static let okIgnoredOrSubstituted: UInt16 = 0x0001
    public static let badRequest: UInt16 = 0x0400
    public static let notPossible: UInt16 = 0x0404
    public static let notFound: UInt16 = 0x0406
    public static let requestEntityTooLarge: UInt16 = 0x0408
    public static let documentFormatNotSupported: UInt16 = 0x040A
    public static let attributesNotSupported: UInt16 = 0x040B
    public static let documentFormatError: UInt16 = 0x0412
    public static let internalError: UInt16 = 0x0500
    public static let operationNotSupported: UInt16 = 0x0501
    public static let versionNotSupported: UInt16 = 0x0503
}
