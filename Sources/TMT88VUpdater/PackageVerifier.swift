import Foundation

public enum VerificationError: Error, Equatable, CustomStringConvertible {
    case notAnArchive
    case signatureInvalid(String)
    case unexpectedCertificateChain([String])
    case notInstallerCertificate(String)
    case wrongTeam(found: String)
    case gatekeeperRejected(String)
    case notNotarized(source: String)
    case originMismatch(String)
    case metadataUnreadable(String)
    case wrongIdentifier(String)
    case malformedVersion(String)
    case inconsistentMetadata(String)

    public var description: String {
        switch self {
        case .notAnArchive: "file is not a flat installer package"
        case .signatureInvalid(let detail): "package signature is not valid: \(detail)"
        case .unexpectedCertificateChain(let chain): "unexpected certificate chain: \(chain.joined(separator: " > "))"
        case .notInstallerCertificate(let name): "leaf certificate is not a Developer ID Installer certificate: \(name)"
        case .wrongTeam(let found): "signed by team \(found), not \(UpdaterConstants.requiredTeamID)"
        case .gatekeeperRejected(let detail): "Gatekeeper rejected the package: \(detail)"
        case .notNotarized(let source): "package is not notarized (Gatekeeper source: \(source))"
        case .originMismatch(let detail): "Gatekeeper origin does not match the signing certificate: \(detail)"
        case .metadataUnreadable(let detail): "package metadata unreadable: \(detail)"
        case .wrongIdentifier(let id): "package identifier is \(id), not \(UpdaterConstants.packageIdentifier)"
        case .malformedVersion(let text): "package version is malformed: \(text)"
        case .inconsistentMetadata(let detail): "package metadata is inconsistent: \(detail)"
        }
    }
}

public struct SignerInfo: Equatable, Sendable {
    public let leafName: String
    public let teamID: String
}

public struct PackageMetadata: Equatable, Sendable {
    public let identifier: String
    public let version: Version
}

public struct PackageVerifier {
    public let runner: CommandRunning
    public let requiredTeamID: String
    public let requiredIdentifier: String

    public init(runner: CommandRunning, requiredTeamID: String = UpdaterConstants.requiredTeamID, requiredIdentifier: String = UpdaterConstants.packageIdentifier) {
        self.runner = runner
        self.requiredTeamID = requiredTeamID
        self.requiredIdentifier = requiredIdentifier
    }

    // MARK: 1. container + signature + Team ID

    public func verifySignature(of package: String) throws -> SignerInfo {
        guard let handle = FileHandle(forReadingAtPath: package) else { throw VerificationError.notAnArchive }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        try? handle.close()
        guard magic == Data("xar!".utf8) else { throw VerificationError.notAnArchive }

        let result = runner.run("/usr/sbin/pkgutil", ["--check-signature", package], timeout: UpdaterConstants.commandTimeoutSeconds)
        guard result.succeeded else {
            throw VerificationError.signatureInvalid("pkgutil exit \(result.status)\(result.timedOut ? " (timed out)" : "")")
        }
        let chain = Self.parseCertificateChain(result.output)
        guard chain.count == 3,
              chain[1] == UpdaterConstants.intermediateCertificateName,
              chain[2] == UpdaterConstants.rootCertificateName else {
            throw VerificationError.unexpectedCertificateChain(chain)
        }
        let leaf = chain[0]
        guard let team = Self.teamID(ofInstallerCertificate: leaf) else {
            throw VerificationError.notInstallerCertificate(leaf)
        }
        guard team == requiredTeamID else { throw VerificationError.wrongTeam(found: team) }
        return SignerInfo(leafName: leaf, teamID: team)
    }

    /// Lines of the form "   1. Certificate name" (the numbered certificate chain). Certificate names are not translated.
    public static func parseCertificateChain(_ output: String) -> [String] {
        var entries: [(Int, String)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(of: "."), let number = Int(trimmed[trimmed.startIndex..<dot]) else { continue }
            let name = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            entries.append((number, name))
        }
        guard entries.map(\.0) == Array(1...max(1, entries.count)) else { return [] }
        return entries.map(\.1)
    }

    /// "Developer ID Installer: <account name> (<TEAMID>)". The account name is chosen by the account holder and may itself
    /// contain parentheses, so the Team ID is the LAST parenthesised token of exactly ten upper-case letters or digits.
    public static func teamID(ofInstallerCertificate name: String) -> String? {
        guard name.hasPrefix(UpdaterConstants.leafCertificatePrefix), name.hasSuffix(")") else { return nil }
        let body = String(name.dropFirst(UpdaterConstants.leafCertificatePrefix.count))
        guard let open = body.lastIndex(of: "(") else { return nil }
        let team = body[body.index(after: open)..<body.index(before: body.endIndex)]
        guard body.distance(from: body.startIndex, to: open) > 1, body[body.index(before: open)] == " " else { return nil }
        guard team.count == 10, team.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        return String(team)
    }

    // MARK: 2. metadata (only read after the signature is verified)

    public func readMetadata(of package: String, workDirectory: String) throws -> PackageMetadata {
        let expanded = workDirectory + "/expanded"
        let result = runner.run("/usr/sbin/pkgutil", ["--expand", package, expanded], timeout: UpdaterConstants.commandTimeoutSeconds)
        guard result.succeeded else { throw VerificationError.metadataUnreadable("pkgutil --expand exit \(result.status)") }

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: expanded)) ?? []
        let components = entries.filter { $0.hasSuffix(".pkg") && isDirectory(expanded + "/" + $0) }
        guard components.count == 1 else { throw VerificationError.inconsistentMetadata("expected exactly one component package, found \(components.count)") }
        guard entries.contains("Distribution") else { throw VerificationError.inconsistentMetadata("no Distribution file") }

        let info = try attributes(of: "pkg-info", in: expanded + "/" + components[0] + "/PackageInfo")
        guard let identifier = info.first?["identifier"], let versionText = info.first?["version"] else {
            throw VerificationError.metadataUnreadable("PackageInfo lacks identifier or version")
        }
        guard identifier == requiredIdentifier else { throw VerificationError.wrongIdentifier(identifier) }
        guard let version = Version(versionText) else { throw VerificationError.malformedVersion(versionText) }

        let refs = try attributes(of: "pkg-ref", in: expanded + "/Distribution")
        for ref in refs {
            if let id = ref["id"], id != requiredIdentifier { throw VerificationError.wrongIdentifier(id) }
            if let refVersion = ref["version"], refVersion != versionText {
                throw VerificationError.inconsistentMetadata("Distribution version \(refVersion) differs from component version \(versionText)")
            }
        }
        return PackageMetadata(identifier: identifier, version: version)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func attributes(of element: String, in path: String) throws -> [[String: String]] {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1_000_000,
              let data = FileManager.default.contents(atPath: path) else {
            throw VerificationError.metadataUnreadable("\(path.split(separator: "/").last ?? "") is missing, not a regular file, or too large")
        }
        let collector = ElementCollector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw VerificationError.metadataUnreadable("XML parse error in \(path.split(separator: "/").last ?? "")") }
        return collector.found
    }

    // MARK: 3. Gatekeeper + notarization

    public func verifyGatekeeper(of package: String, signer: SignerInfo) throws {
        let raw = runner.run("/usr/sbin/spctl", ["--assess", "--type", "install", "--raw", package], timeout: UpdaterConstants.commandTimeoutSeconds)
        guard let plist = (try? PropertyListSerialization.propertyList(from: Data(raw.output.utf8), options: [], format: nil)) as? [String: Any] else {
            throw VerificationError.gatekeeperRejected("no readable assessment result (exit \(raw.status))")
        }
        let verdict = plist["assessment:verdict"] as? Bool ?? false
        let authority = plist["assessment:authority"] as? [String: Any]
        let source = authority?["assessment:authority:source"] as? String ?? "unknown"
        guard raw.succeeded, verdict else { throw VerificationError.gatekeeperRejected("verdict is not accepted (source: \(source))") }
        guard source == UpdaterConstants.notarizedGatekeeperSource else { throw VerificationError.notNotarized(source: source) }

        let verbose = runner.run("/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", package], timeout: UpdaterConstants.commandTimeoutSeconds)
        guard verbose.succeeded else { throw VerificationError.gatekeeperRejected("spctl -vv exit \(verbose.status)") }
        var origin: String?
        for line in (verbose.output + "\n" + verbose.errorOutput).split(separator: "\n") where line.hasPrefix("origin=") {
            origin = String(line.dropFirst("origin=".count))
        }
        guard origin == signer.leafName else {
            throw VerificationError.originMismatch("origin=\(origin ?? "none"), certificate=\(signer.leafName)")
        }
    }
}

private final class ElementCollector: NSObject, XMLParserDelegate {
    let element: String
    var found: [[String: String]] = []

    init(element: String) {
        self.element = element
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == element { found.append(attributeDict) }
    }
}
