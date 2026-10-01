import Foundation
import Testing
@testable import TMT88VUpdater

struct VerifierTests {
    func makePackage(_ root: TempRoot, magic: String = "xar!") -> String {
        let path = root.path + "/package.pkg"
        FileManager.default.createFile(atPath: path, contents: Data(magic.utf8) + Data(repeating: 0, count: 32))
        return path
    }

    func verify(_ configure: (ScenarioRunner) -> Void = { _ in }, magic: String = "xar!") throws -> Result<(SignerInfo, PackageMetadata), VerificationError> {
        let root = try TempRoot()
        let runner = ScenarioRunner()
        configure(runner)
        let package = makePackage(root, magic: magic)
        let verifier = PackageVerifier(runner: runner)
        let work = root.path + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        do {
            let signer = try verifier.verifySignature(of: package)
            let metadata = try verifier.readMetadata(of: package, workDirectory: work)
            try verifier.verifyGatekeeper(of: package, signer: signer)
            return .success((signer, metadata))
        } catch let error as VerificationError {
            return .failure(error)
        }
    }

    func rejected(_ configure: (ScenarioRunner) -> Void, magic: String = "xar!") throws -> VerificationError? {
        if case .failure(let error) = try verify(configure, magic: magic) { return error }
        return nil
    }

    @Test func goodPackageIsAccepted() throws {
        guard case .success(let (signer, metadata)) = try verify() else { Issue.record("expected acceptance"); return }
        #expect(signer.teamID == "P3WL6DBK59")
        #expect(metadata.identifier == "com.belchuke.tmt88vcompat.pkg")
        #expect(metadata.version == Version(0, 2, 0))
    }

    @Test func wrongPackageIdentifierIsRejected() throws {
        let error = try rejected { $0.packageIdentifier = "com.example.other.pkg" }
        #expect(error == .wrongIdentifier("com.example.other.pkg"))
    }

    @Test func wrongIdentifierOnlyInDistributionIsRejected() throws {
        let error = try rejected { $0.distributionIdentifier = "com.example.other.pkg" }
        #expect(error == .wrongIdentifier("com.example.other.pkg"))
    }

    @Test func disagreeingVersionsBetweenDistributionAndComponentAreRejected() throws {
        guard case .inconsistentMetadata? = try rejected({ $0.distributionVersion = "9.9.9" }) else { Issue.record("expected inconsistentMetadata"); return }
    }

    @Test func extraComponentPackagesAreRejected() throws {
        guard case .inconsistentMetadata? = try rejected({ $0.componentCount = 2 }) else { Issue.record("expected inconsistentMetadata"); return }
    }

    @Test(arguments: ["", "1", "1.2", "v0.2.0", "0.2.0-beta", "0.2", "latest", "0.02.0", "1.2.3.4"])
    func malformedPackageVersionIsRejected(version: String) throws {
        let error = try rejected { $0.packageVersion = version }
        #expect(error == .malformedVersion(version))
    }

    @Test func unsignedPackageIsRejected() throws {
        guard case .signatureInvalid? = try rejected({ $0.signatureStatus = 1 }) else { Issue.record("expected signatureInvalid"); return }
    }

    @Test func validSignatureFromAnotherTeamIsRejected() throws {
        let error = try rejected { $0.leaf = "Developer ID Installer: Someone Else (ABCDE12345)" }
        #expect(error == .wrongTeam(found: "ABCDE12345"))
    }

    @Test func accountNameContainingOurTeamIDDoesNotSpoofTheCheck() throws {
        let error = try rejected { $0.leaf = "Developer ID Installer: Evil Corp (P3WL6DBK59) (ABCDE12345)" }
        #expect(error == .wrongTeam(found: "ABCDE12345"))
    }

    @Test func applicationCertificateIsNotAnInstallerCertificate() throws {
        guard case .notInstallerCertificate? = try rejected({ $0.leaf = "Developer ID Application: Jacob Belchuke (P3WL6DBK59)" }) else { Issue.record("expected notInstallerCertificate"); return }
    }

    @Test(arguments: [
        "Developer ID Installer: Jacob Belchuke (p3wl6dbk59)",
        "Developer ID Installer: Jacob Belchuke (P3WL6DBK5)",
        "Developer ID Installer: Jacob Belchuke (P3WL6DBK599)",
        "Developer ID Installer: Jacob Belchuke P3WL6DBK59",
        "Developer ID Installer: (P3WL6DBK59)",
        "Developer ID Installer:Jacob (P3WL6DBK59)",
        "Apple Development: Jacob Belchuke (P3WL6DBK59)",
        "3rd Party Mac Developer Installer: Jacob (P3WL6DBK59)",
    ])
    func malformedLeafCertificateNamesAreRejected(name: String) throws {
        #expect(try rejected { $0.leaf = name } != nil)
    }

    @Test func unexpectedCertificateChainsAreRejected() throws {
        let leaf = "Developer ID Installer: Jacob Belchuke (P3WL6DBK59)"
        guard case .unexpectedCertificateChain? = try rejected({ $0.chain = [leaf] }) else { Issue.record("self-signed single certificate"); return }
        guard case .unexpectedCertificateChain? = try rejected({ $0.chain = [leaf, "Evil CA", "Apple Root CA"] }) else { Issue.record("wrong intermediate"); return }
        guard case .unexpectedCertificateChain? = try rejected({ $0.chain = [leaf, "Developer ID Certification Authority", "Fake Root"] }) else { Issue.record("wrong root"); return }
    }

    @Test func gatekeeperRejectionIsRejected() throws {
        guard case .gatekeeperRejected? = try rejected({ $0.gatekeeperVerdict = false; $0.gatekeeperStatus = 3 }) else { Issue.record("expected gatekeeperRejected"); return }
    }

    @Test func unnotarizedDeveloperIDIsRejected() throws {
        let error = try rejected { $0.gatekeeperSource = "Unnotarized Developer ID"; $0.gatekeeperVerdict = false; $0.gatekeeperStatus = 3 }
        guard case .gatekeeperRejected? = error else { Issue.record("expected gatekeeperRejected, got \(String(describing: error))"); return }
    }

    @Test func acceptedButNotNotarizedSourceIsRejected() throws {
        let error = try rejected { $0.gatekeeperSource = "Developer ID" }
        #expect(error == .notNotarized(source: "Developer ID"))
    }

    @Test func gatekeeperOriginMustMatchTheSigningCertificate() throws {
        guard case .originMismatch? = try rejected({ $0.gatekeeperOrigin = "Developer ID Installer: Someone Else (ABCDE12345)" }) else { Issue.record("expected originMismatch"); return }
    }

    @Test func corruptedAndMalformedPackagesAreRejected() throws {
        #expect(try rejected({ _ in }, magic: "PK\u{3}\u{4}") == .notAnArchive)
        #expect(try rejected({ _ in }, magic: "") == .notAnArchive)
        guard case .metadataUnreadable? = try rejected({ $0.expandStatus = 1 }) else { Issue.record("expand failure"); return }
    }

    @Test func certificateChainParsingIgnoresFingerprintLines() {
        let chain = PackageVerifier.parseCertificateChain(ScenarioRunner.signatureOutput(["A", "B", "C"]))
        #expect(chain == ["A", "B", "C"])
        #expect(PackageVerifier.parseCertificateChain("Status: no signature\n").isEmpty)
    }

    @Test func teamIDParsing() {
        #expect(PackageVerifier.teamID(ofInstallerCertificate: "Developer ID Installer: Jacob Belchuke (P3WL6DBK59)") == "P3WL6DBK59")
        #expect(PackageVerifier.teamID(ofInstallerCertificate: "Developer ID Installer: A (B) (ABCDE12345)") == "ABCDE12345")
        #expect(PackageVerifier.teamID(ofInstallerCertificate: "Developer ID Application: A (ABCDE12345)") == nil)
    }

    @Test func installedVersionComesFromThePackageReceipt() {
        let runner = ScenarioRunner()
        let reader = InstalledVersionReader(runner: runner)
        #expect(reader.read() == Version(0, 1, 2))
        runner.installed = nil
        #expect(reader.read() == nil)
        runner.installed = "garbage"
        #expect(reader.read() == nil)
    }
}
