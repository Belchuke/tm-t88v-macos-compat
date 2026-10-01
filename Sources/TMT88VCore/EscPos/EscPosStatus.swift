import Foundation

public enum EscPosStatusRequest: UInt8, CaseIterable, Sendable {
    case printer = 1
    case offlineCause = 2
    case errorCause = 3
    case paperSensor = 4

    public var command: [UInt8] { [0x10, 0x04, rawValue] }
}

public struct EscPosStatus: Sendable, Equatable {
    public var offline = false
    public var coverOpen = false
    public var feedButtonPressed = false
    public var stoppedByPaperEnd = false
    public var errorOccurred = false
    public var cutterError = false
    public var unrecoverableError = false
    public var autoRecoverableError = false
    public var paperNearEnd = false
    public var paperEnd = false

    public init() {}

    public static func isValidResponse(_ byte: UInt8) -> Bool {
        byte & 0x93 == 0x12
    }

    public mutating func apply(_ byte: UInt8, for request: EscPosStatusRequest) {
        switch request {
        case .printer:
            offline = byte & 0x08 != 0
        case .offlineCause:
            coverOpen = byte & 0x04 != 0
            feedButtonPressed = byte & 0x08 != 0
            stoppedByPaperEnd = byte & 0x20 != 0
            errorOccurred = byte & 0x40 != 0
        case .errorCause:
            cutterError = byte & 0x08 != 0
            unrecoverableError = byte & 0x20 != 0
            autoRecoverableError = byte & 0x40 != 0
        case .paperSensor:
            paperNearEnd = byte & 0x0C != 0
            paperEnd = byte & 0x60 != 0
        }
    }

    public var summary: String {
        var flags: [String] = []
        if coverOpen { flags.append("COVER_OPEN") }
        if paperEnd || stoppedByPaperEnd { flags.append("PAPER_OUT") }
        if paperNearEnd { flags.append("PAPER_NEAR_END") }
        if cutterError { flags.append("CUTTER_ERROR") }
        if unrecoverableError { flags.append("UNRECOVERABLE_ERROR") }
        if autoRecoverableError { flags.append("AUTO_RECOVERABLE_ERROR") }
        if errorOccurred && !cutterError && !unrecoverableError && !autoRecoverableError { flags.append("ERROR") }
        if offline && flags.isEmpty { flags.append("OFFLINE") }
        return flags.isEmpty ? "READY" : flags.joined(separator: ", ")
    }

    public var blocksPrinting: Bool {
        coverOpen || paperEnd || stoppedByPaperEnd || cutterError || unrecoverableError
    }
}
