import Foundation

public enum UpdaterConstants {
    public static let packageIdentifier = "com.belchuke.tmt88vcompat.pkg"
    public static let requiredTeamID = "P3WL6DBK59"
    public static let officialUpdateURL = URL(string: "https://github.com/Belchuke/tm-t88v-macos-compat/releases/latest/download/TMT88VCompat.pkg")!

    public static let maxDownloadBytes: Int64 = 100 * 1024 * 1024
    public static let connectTimeoutSeconds = 20
    public static let downloadTimeoutSeconds = 300
    public static let installerTimeoutSeconds: TimeInterval = 900
    public static let commandTimeoutSeconds: TimeInterval = 120

    public static let minimumIntervalSeconds = 24 * 60 * 60
    public static let maximumJitterSeconds = 6 * 60 * 60

    public static let notarizedGatekeeperSource = "Notarized Developer ID"
    public static let leafCertificatePrefix = "Developer ID Installer: "
    public static let intermediateCertificateName = "Developer ID Certification Authority"
    public static let rootCertificateName = "Apple Root CA"
}

public struct UpdaterPaths: Sendable {
    public let supportDir: String
    public let logDir: String

    public init(root: String = "") {
        supportDir = root + "/Library/Application Support/TMT88VCompat"
        logDir = root + "/Library/Logs/TMT88VCompat"
    }

    public var stateDir: String { supportDir + "/state" }
    public var configPath: String { supportDir + "/config.json" }
    public var statePath: String { stateDir + "/updater-state.json" }
    public var lockPath: String { stateDir + "/updater.lock" }
    public var updateInProgressPath: String { stateDir + "/update-in-progress" }
    public var logPath: String { logDir + "/updater.log" }
}
