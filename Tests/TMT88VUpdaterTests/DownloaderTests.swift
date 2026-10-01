import Darwin
import Foundation
import Testing
@testable import TMT88VUpdater

/// A tiny local HTTP server so the real curl-based downloader can be tested without any network.
final class TestHTTPServer: @unchecked Sendable {
    typealias Route = (Int32) -> Void
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0
    private var running = true
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private(set) var requestCount = 0

    init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        port = UInt16(bigEndian: out.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        lock.lock(); running = false; lock.unlock()
        close(listener)
    }

    func route(_ path: String, _ handler: @escaping Route) {
        lock.lock(); routes[path] = handler; lock.unlock()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func acceptLoop() {
        while true {
            lock.lock(); let alive = running; lock.unlock()
            guard alive else { return }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buffer, buffer.count, 0)
        guard n > 0 else { return }
        let head = String(decoding: buffer[0..<n], as: UTF8.self)
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock(); requestCount += 1; let handler = routes[path]; lock.unlock()
        if let handler { handler(client) } else { Self.send(client, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }
    }

    static func send(_ client: Int32, _ text: String) { send(client, Array(text.utf8)) }

    static func send(_ client: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            offset += n
        }
    }
}

struct DownloaderTests {
    func downloader() -> CurlDownloader {
        var d = CurlDownloader()
        d.allowInsecureForTesting = true
        d.connectTimeout = 3
        d.totalTimeout = 4
        return d
    }

    struct Destination {
        let root: TempRoot
        var path: String { root.path + "/out.pkg" }
    }

    func destination() throws -> Destination { Destination(root: try TempRoot()) }

    @Test func downloadsASuccessfulResponse() throws {
        let server = try TestHTTPServer()
        let body = Array("xar!".utf8) + [UInt8](repeating: 7, count: 5000)
        server.route("/ok") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"); TestHTTPServer.send($0, body) }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        try downloader().download(from: server.url("/ok"), to: path, maxBytes: 1_000_000)
        #expect(FileManager.default.contents(atPath: path) == Data(body))
    }

    @Test func http404IsAFailureAndLeavesNothingBehind() throws {
        let server = try TestHTTPServer()
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.httpError) { try downloader().download(from: server.url("/missing"), to: path, maxBytes: 1_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func http500IsAFailure() throws {
        let server = try TestHTTPServer()
        server.route("/boom") { TestHTTPServer.send($0, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.httpError) { try downloader().download(from: server.url("/boom"), to: path, maxBytes: 1_000_000) }
    }

    @Test func oversizedDeclaredLengthIsRejectedAndRemoved() throws {
        let server = try TestHTTPServer()
        server.route("/big") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: 5000000\r\nConnection: close\r\n\r\n"); TestHTTPServer.send($0, [UInt8](repeating: 1, count: 100_000)) }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.tooLarge) { try downloader().download(from: server.url("/big"), to: path, maxBytes: 10_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func oversizedBodyWithoutAContentLengthIsStopped() throws {
        let server = try TestHTTPServer()
        server.route("/stream") { client in
            TestHTTPServer.send(client, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
            let chunk = [UInt8](repeating: 2, count: 64 * 1024)
            for _ in 0..<2000 { TestHTTPServer.send(client, chunk) }
        }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        var d = downloader()
        d.totalTimeout = 20
        #expect(throws: DownloadError.tooLarge) { try d.download(from: server.url("/stream"), to: path, maxBytes: 200_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func incompleteDownloadIsRejected() throws {
        let server = try TestHTTPServer()
        server.route("/short") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n"); TestHTTPServer.send($0, [UInt8](repeating: 3, count: 100)) }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.incomplete) { try downloader().download(from: server.url("/short"), to: path, maxBytes: 1_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func stalledServerTimesOut() throws {
        let server = try TestHTTPServer()
        server.route("/stall") { _ in Thread.sleep(forTimeInterval: 8) }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        var d = downloader()
        d.totalTimeout = 2
        #expect(throws: DownloadError.timeout) { try d.download(from: server.url("/stall"), to: path, maxBytes: 1_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func emptyBodyIsRejected() throws {
        let server = try TestHTTPServer()
        server.route("/empty") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.emptyFile) { try downloader().download(from: server.url("/empty"), to: path, maxBytes: 1_000_000) }
    }

    @Test func redirectsAreFollowedWhenTheProtocolIsAllowed() throws {
        let server = try TestHTTPServer()
        let body = Array("xar!".utf8) + [UInt8](repeating: 9, count: 100)
        server.route("/final") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"); TestHTTPServer.send($0, body) }
        server.route("/go") { TestHTTPServer.send($0, "HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        try downloader().download(from: server.url("/go"), to: path, maxBytes: 1_000_000)
        #expect(FileManager.default.contents(atPath: path) == Data(body))
    }

    @Test func redirectLoopsAreStopped() throws {
        let server = try TestHTTPServer()
        server.route("/loop") { TestHTTPServer.send($0, "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.self) { try downloader().download(from: server.url("/loop"), to: path, maxBytes: 1_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func unreachableHostFailsCleanly() throws {
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.self) { try downloader().download(from: URL(string: "http://127.0.0.1:1/x")!, to: path, maxBytes: 1000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: production policy

    @Test func productionDownloaderRefusesPlainHTTPWithoutAnyRequest() throws {
        let server = try TestHTTPServer()
        server.route("/ok") { TestHTTPServer.send($0, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nxar!") }
        let dest = try destination(); let path = dest.path; defer { withExtendedLifetime(dest) {} }
        #expect(throws: DownloadError.insecureURL) { try CurlDownloader().download(from: server.url("/ok"), to: path, maxBytes: 1000) }
        #expect(server.requestCount == 0)
    }

    @Test func productionCurlArgumentsEnforceHTTPSBoundedAndIsolated() {
        let args = CurlDownloader.arguments(
            url: UpdaterConstants.officialUpdateURL, output: "/x", maxBytes: UpdaterConstants.maxDownloadBytes,
            connectTimeout: 20, totalTimeout: 300, allowInsecure: false, userAgent: "ua"
        )
        #expect(args.first == "-q", "-q must come first so root's ~/.curlrc is never read")
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value(after: "--proto") == "=https")
        #expect(value(after: "--proto-redir") == "=https")
        #expect(value(after: "--max-filesize") == String(100 * 1024 * 1024))
        #expect(value(after: "--connect-timeout") == "20")
        #expect(value(after: "--max-time") == "300")
        #expect(value(after: "--max-redirs") == "5")
        #expect(args.contains("--fail"))
        #expect(args.contains("--tlsv1.2"))
        #expect(args.last == "https://github.com/Belchuke/tm-t88v-macos-compat/releases/latest/download/TMT88VCompat.pkg")
        #expect(!args.contains { $0.lowercased().contains("token") || $0.lowercased().contains("authorization") || $0 == "--netrc" || $0 == "-n" })
    }

    @Test func testingArgumentsOnlyWidenTheProtocolListNotAnythingElse() {
        let prod = CurlDownloader.arguments(url: UpdaterConstants.officialUpdateURL, output: "/x", maxBytes: 1, connectTimeout: 1, totalTimeout: 1, allowInsecure: false, userAgent: "u")
        let test = CurlDownloader.arguments(url: UpdaterConstants.officialUpdateURL, output: "/x", maxBytes: 1, connectTimeout: 1, totalTimeout: 1, allowInsecure: true, userAgent: "u")
        #expect(prod.filter { !$0.hasPrefix("=") } == test.filter { !$0.hasPrefix("=") })
        #expect(test.contains("=http,https"))
    }
}
