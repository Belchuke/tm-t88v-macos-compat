import Darwin
import Foundation
import Testing
@testable import TMT88VCore

struct LoopbackServerTests {
    final class Fixtures {
        let server: IppHTTPServer
        let output = CapturingOutput()
        var port: UInt16 { server.port }

        init(maxJobBytes: Int = 64 * 1024 * 1024) throws {
            var config = IppServerConfig()
            config.port = 0
            config.maxJobBytes = maxJobBytes
            let log = ServiceLog(echoToStderr: false)
            let jobs = JobManager(service: PrintService(model: .tmT88V80mm, output: output), log: log)
            server = IppHTTPServer(config: config, handler: IppRequestHandler(config: config, jobs: jobs, log: log), log: log)
            try server.start()
        }

        deinit { server.stop() }
    }

    struct Reply {
        let status: Int
        let headers: String
        let body: Data
    }

    static func connect(host: String, port: UInt16) -> Int32? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            offset += n
        }
    }

    static func readToEnd(_ fd: Int32) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return data }
            data.append(contentsOf: chunk[0..<n])
        }
    }

    static func parse(_ raw: Data) -> Reply? {
        guard let split = raw.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self)
        let parts = head.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return Reply(status: status, headers: head, body: raw[split.upperBound...])
    }

    static func request(port: UInt16, method: String = "POST", path: String = "/ipp/print", host: String? = nil,
                        contentType: String? = "application/ipp", body: Data = Data(), extraHeaders: [String] = [],
                        contentLength: Int? = nil) -> Reply? {
        guard let fd = connect(host: "127.0.0.1", port: port) else { return nil }
        defer { close(fd) }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let length = contentLength ?? (method == "POST" ? body.count : nil) { head += "Content-Length: \(length)\r\n" }
        for line in extraHeaders { head += line + "\r\n" }
        head += "\r\n"
        sendAll(fd, Array(head.utf8) + [UInt8](body))
        return parse(readToEnd(fd))
    }

    @Test func bindsOnlyToLoopback() throws {
        let fixture = try Fixtures()
        #expect(!fixture.server.boundAddresses.isEmpty)
        for address in fixture.server.boundAddresses {
            #expect(address.hasPrefix("127.0.0.1:") || address.hasPrefix("[::1]:"))
        }
        #expect(fixture.port != 0)
    }

    @Test func refusesConnectionsOnNonLoopbackInterfaceAddresses() throws {
        let fixture = try Fixtures()
        var list: UnsafeMutablePointer<ifaddrs>?
        #expect(getifaddrs(&list) == 0)
        defer { freeifaddrs(list) }
        var tried = 0
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET), entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var sin = $0.pointee.sin_addr
                inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buffer)
            if ip.hasPrefix("127.") { continue }
            tried += 1
            #expect(Self.connect(host: ip, port: fixture.port) == nil, "connected to server via non-loopback address \(ip)")
        }
        print("non-loopback IPv4 addresses probed: \(tried)")
    }

    @Test func serverStopsListeningAfterStop() throws {
        let fixture = try Fixtures()
        let port = fixture.port
        fixture.server.stop()
        #expect(Self.connect(host: "127.0.0.1", port: port) == nil)
    }

    @Test func secondServerOnSamePortFails() throws {
        let first = try Fixtures()
        var config = IppServerConfig()
        config.port = first.port
        let log = ServiceLog(echoToStderr: false)
        let jobs = JobManager(service: PrintService(model: .tmT88V80mm, output: first.output), log: log)
        let second = IppHTTPServer(config: config, handler: IppRequestHandler(config: config, jobs: jobs, log: log), log: log)
        #expect(throws: IppServerError.self) { try second.start() }
    }

    @Test func answersGetPrinterAttributesOverHTTP() throws {
        let fixture = try Fixtures()
        let reply = try #require(Self.request(port: fixture.port, body: Fixture.ippRequest(IppOperation.getPrinterAttributes)))
        #expect(reply.status == 200)
        #expect(reply.headers.lowercased().contains("content-type: application/ipp"))
        let message = try Fixture.decodeResponse(reply.body)
        #expect(message.code == IppStatus.ok)
        #expect(message.group(IppTag.printerGroup)?["printer-uri-supported"]?.values.first?.string == "ipp://127.0.0.1:\(fixture.port)/ipp/print")
    }

    @Test func acceptsHostNamesLocalhostAndLoopbackOnly() throws {
        let fixture = try Fixtures()
        let body = Fixture.ippRequest(IppOperation.getPrinterAttributes)
        #expect(Self.request(port: fixture.port, host: "localhost:\(fixture.port)", body: body)?.status == 200)
        #expect(Self.request(port: fixture.port, host: "127.0.0.1", body: body)?.status == 200)
        #expect(Self.request(port: fixture.port, host: "evil.example:\(fixture.port)", body: body)?.status == 403)
        #expect(Self.request(port: fixture.port, host: "192.168.1.5:\(fixture.port)", body: body)?.status == 403)
    }

    @Test func rejectsNonIPPRequests() throws {
        let fixture = try Fixtures()
        let body = Fixture.ippRequest(IppOperation.getPrinterAttributes)
        #expect(Self.request(port: fixture.port, method: "GET", body: Data())?.status == 405)
        #expect(Self.request(port: fixture.port, contentType: "text/plain", body: body)?.status == 415)
        #expect(Self.request(port: fixture.port, contentType: nil, body: body)?.status == 415)
        #expect(Self.request(port: fixture.port, path: "/other", body: body)?.status == 404)
        #expect(Self.request(port: fixture.port, body: body, contentLength: nil)?.status == 200)
    }

    @Test func rejectsOversizedBodiesBeforeReadingThem() throws {
        let fixture = try Fixtures(maxJobBytes: 1024)
        let reply = Self.request(port: fixture.port, body: Data(), contentLength: 10_000_000)
        #expect(reply?.status == 413)
    }

    @Test func requiresContentLengthWhenNotChunked() throws {
        let fixture = try Fixtures()
        let fd = try #require(Self.connect(host: "127.0.0.1", port: fixture.port))
        defer { close(fd) }
        Self.sendAll(fd, Array("POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/ipp\r\nConnection: close\r\n\r\n".utf8))
        #expect(Self.parse(Self.readToEnd(fd))?.status == 411)
    }

    @Test func malformedHTTPGetsBadRequest() throws {
        let fixture = try Fixtures()
        for garbage in ["GARBAGE\r\n\r\n", "POST /ipp/print\r\n\r\n", "POST /ipp/print HTTP/1.1\r\nnocolon\r\n\r\n"] {
            let fd = try #require(Self.connect(host: "127.0.0.1", port: fixture.port))
            defer { close(fd) }
            Self.sendAll(fd, Array(garbage.utf8))
            #expect(Self.parse(Self.readToEnd(fd))?.status == 400)
        }
    }

    @Test func handlesChunkedBodyWithExpectContinue() throws {
        let fixture = try Fixtures()
        let body = [UInt8](Fixture.ippRequest(IppOperation.getPrinterAttributes))
        let fd = try #require(Self.connect(host: "127.0.0.1", port: fixture.port))
        defer { close(fd) }
        Self.sendAll(fd, Array("POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nContent-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n".utf8))
        var interim = [UInt8](repeating: 0, count: 64)
        let n = recv(fd, &interim, interim.count, 0)
        #expect(String(decoding: interim[0..<max(0, n)], as: UTF8.self).hasPrefix("HTTP/1.1 100 Continue"))
        let half = body.count / 2
        for piece in [Array(body[0..<half]), Array(body[half...])] {
            Self.sendAll(fd, Array((String(piece.count, radix: 16) + "\r\n").utf8) + piece + Array("\r\n".utf8))
        }
        Self.sendAll(fd, Array("0\r\n\r\n".utf8))
        let reply = try #require(Self.parse(Self.readToEnd(fd)))
        #expect(reply.status == 200)
        #expect(try Fixture.decodeResponse(reply.body).code == IppStatus.ok)
    }

    @Test func printJobOverHTTPReachesTheOutput() throws {
        let fixture = try Fixtures()
        let document = Fixture.urf(width: 510, height: 12) { _, y in y < 4 ? 0 : 255 }
        let reply = try #require(Self.request(
            port: fixture.port,
            body: Fixture.ippRequest(IppOperation.printJob, printerURI: "ipp://127.0.0.1:\(fixture.port)/ipp/print", document: document)
        ))
        #expect(try Fixture.decodeResponse(reply.body).code == IppStatus.ok)
        #expect(waitUntil { fixture.output.payloads.count == 1 })
        let receipt = try #require(try EscPosRasterDecoder.decode(fixture.output.payloads[0]).first)
        #expect(receipt.bitmap.width == 512 && receipt.bitmap.height == 4)
    }

    @Test func keepAliveServesSeveralRequestsOnOneConnection() throws {
        let fixture = try Fixtures()
        let fd = try #require(Self.connect(host: "127.0.0.1", port: fixture.port))
        defer { close(fd) }
        let body = Fixture.ippRequest(IppOperation.getPrinterAttributes)
        for _ in 0..<3 {
            Self.sendAll(fd, Array("POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/ipp\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + [UInt8](body))
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while Self.parse(received).map({ reply in
                let length = reply.headers.lowercased().components(separatedBy: "content-length: ").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
                return reply.body.count < length
            }) ?? true {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: chunk[0..<n])
            }
            #expect(Self.parse(received)?.status == 200)
        }
    }
}
