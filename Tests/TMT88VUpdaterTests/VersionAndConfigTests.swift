import Foundation
import Testing
@testable import TMT88VUpdater

struct VersionTests {
    @Test func ordering() throws {
        let v = { (s: String) throws -> Version in try #require(Version(s)) }
        #expect(try v("0.1.2") < v("0.2.0"))
        #expect(try v("0.2.0") < v("0.2.1"))
        #expect(try v("0.9.9") < v("0.10.0"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try v("0.1.2") == v("0.1.2"))
        #expect(try v("10.0.0") > v("9.99.99"))
        #expect(try v("1.0.0") > v("0.0.1"))
        #expect(try !(v("0.2.0") < v("0.2.0")))
        #expect(try v("0.2.0") >= v("0.2.0"))
    }

    @Test func numericNotLexicographic() throws {
        #expect(try #require(Version("0.10.0")) > #require(Version("0.9.0")))
        #expect(try #require(Version("1.2.10")) > #require(Version("1.2.9")))
        #expect("0.10.0" < "0.9.0")
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.2.3+4", "01.2.3", "1.02.3", "1.2.03", "1.2.x", " 1.2.3", "1.2.3 ", "1.2.3\n", "-1.2.3", "1..3", ".1.2", "1.2.", "1,2,3", "1.2.3a", "9999999999.0.0", "１.２.３", "1.2.٣", "latest", "0.2.0\0"])
    func malformedVersionsAreRejected(text: String) {
        #expect(Version(text) == nil)
    }

    @Test(arguments: ["0.0.0", "0.1.2", "0.2.0", "1.0.0", "10.20.30", "999999999.0.0"])
    func wellFormedVersionsParse(text: String) {
        #expect(Version(text)?.description == text)
    }
}

struct ConfigTests {
    func setting(_ contents: String?) throws -> UpdateSetting {
        let root = try TempRoot()
        if let contents { try root.writeConfig(contents) }
        return UpdaterConfig.load(path: root.paths.configPath)
    }

    @Test func defaultContentsEnableUpdates() throws {
        #expect(try setting(UpdaterConfig.defaultContents) == .enabled(fromFile: true))
    }

    @Test func missingFileUsesTheDefault() throws {
        #expect(try setting(nil) == .enabled(fromFile: false))
    }

    @Test func trueEnablesFalseDisables() throws {
        #expect(try setting("{\"automaticUpdates\": true}").isEnabled)
        #expect(try !setting("{\"automaticUpdates\": false}").isEnabled)
    }

    @Test(arguments: ["", "not json", "[]", "null", "{}", "{\"automaticUpdates\": \"true\"}", "{\"automaticUpdates\": 1}", "{\"automaticUpdates\": null}", "{\"automaticUpdates\": true", "{\"AutomaticUpdates\": true}", "\u{0}"])
    func malformedConfigFailsSafeDisabled(contents: String) throws {
        let result = try setting(contents)
        guard case .disabled(let reason) = result else {
            Issue.record("expected disabled for \(contents.debugDescription), got \(result)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func unknownKeysAreIgnored() throws {
        #expect(try setting("{\"automaticUpdates\": true, \"other\": 5}").isEnabled)
    }

    @Test func oversizedConfigFailsSafe() throws {
        let big = "{\"automaticUpdates\": true, \"pad\": \"" + String(repeating: "x", count: 70_000) + "\"}"
        #expect(try !setting(big).isEnabled)
    }
}

struct ProductionConstantsTests {
    @Test func officialURLIsTheExactHardcodedGitHubLatestDownload() {
        #expect(UpdaterConstants.officialUpdateURL.absoluteString == "https://github.com/Belchuke/tm-t88v-macos-compat/releases/latest/download/TMT88VCompat.pkg")
        #expect(UpdaterConstants.officialUpdateURL.scheme == "https")
    }

    @Test func trustBoundaryConstants() {
        #expect(UpdaterConstants.requiredTeamID == "P3WL6DBK59")
        #expect(UpdaterConstants.packageIdentifier == "com.belchuke.tmt88vcompat.pkg")
        #expect(UpdaterConstants.maxDownloadBytes == 100 * 1024 * 1024)
        #expect(UpdaterConstants.minimumIntervalSeconds == 86_400)
        #expect(UpdaterConstants.maximumJitterSeconds == 21_600)
    }

    @Test func pathsAreTheDocumentedOnes() {
        let paths = UpdaterPaths()
        #expect(paths.configPath == "/Library/Application Support/TMT88VCompat/config.json")
        #expect(paths.logPath == "/Library/Logs/TMT88VCompat/updater.log")
        #expect(paths.stateDir == "/Library/Application Support/TMT88VCompat/state")
    }
}
