import Darwin
import Foundation

public enum IppServerError: Error, CustomStringConvertible {
    case bindFailed(String)

    public var description: String {
        switch self {
        case .bindFailed(let reason): "bind_failed: \(reason)"
        }
    }
}

public final class IppHTTPServer: @unchecked Sendable {
    private static let maxHeaderBytes = 16 * 1024
    private static let maxConnections = 16
    private static let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    private let config: IppServerConfig
    private let handler: IppRequestHandler
    private let log: ServiceLog
    private let lock = NSLock()
    private var running = false
    private var listeners: [Int32] = []
    private var activeConnections = 0
    private let connectionQueue = DispatchQueue(label: "tmt88v.http", attributes: .concurrent)

    public private(set) var boundAddresses: [String] = []
    public private(set) var port: UInt16 = 0

    public init(config: IppServerConfig, handler: IppRequestHandler, log: ServiceLog) {
        self.config = config
        self.handler = handler
        self.log = log
    }

    public func start() throws {
        let v4 = try makeListener(family: AF_INET, port: config.port)
        port = boundPort(v4)
        listeners = [v4]
        handler.updatePort(port)
        boundAddresses = ["127.0.0.1:\(port)"]
        if let v6 = try? makeListener(family: AF_INET6, port: port) {
            listeners.append(v6)
            boundAddresses.append("[::1]:\(port)")
        }
        lock.withLock { running = true }
        for fd in listeners {
            Thread.detachNewThread { [self] in acceptLoop(fd) }
        }
    }

    public func stop() {
        lock.withLock { running = false }
        Thread.sleep(forTimeInterval: 0.3)
        for fd in listeners { close(fd) }
        listeners = []
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func makeListener(family: Int32, port: UInt16) throws -> Int32 {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IppServerError.bindFailed("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        let result: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw IppServerError.bindFailed("\(family == AF_INET ? "127.0.0.1" : "::1"):\(port): \(reason)")
        }
        return fd
    }

    private func boundPort(_ fd: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }

            let admitted = lock.withLock { () -> Bool in
                guard activeConnections < Self.maxConnections else { return false }
                activeConnections += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            connectionQueue.async { [self] in
                serve(client)
                lock.withLock { activeConnections -= 1 }
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var reader = SocketReader(fd: fd)
        while isRunning {
            guard let head = reader.readHead(limit: Self.maxHeaderBytes) else { return }
            guard let request = HTTPRequest(head: head) else {
                send(fd, status: "400 Bad Request", close: true)
                return
            }

            if let host = request.host, !Self.allowedHosts.contains(host) {
                log.event("http_rejected", ["reason": "host_header", "host": host])
                send(fd, status: "403 Forbidden", close: true)
                return
            }
            guard request.method == "POST" else { send(fd, status: "405 Method Not Allowed", extra: ["Allow: POST"], close: true); return }
            guard request.path.hasPrefix(config.printerPath) else { send(fd, status: "404 Not Found", close: true); return }
            guard request.contentType == "application/ipp" else { send(fd, status: "415 Unsupported Media Type", close: true); return }

            let limit = config.maxJobBytes + 64 * 1024
            if request.chunked {
                if request.expectContinue { writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
            } else {
                guard let length = request.contentLength else { send(fd, status: "411 Length Required", close: true); return }
                guard length <= limit else { send(fd, status: "413 Payload Too Large", close: true); return }
                if request.expectContinue { writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
            }

            let body: Data?
            if request.chunked {
                body = reader.readChunked(limit: limit)
            } else {
                body = reader.readExact(request.contentLength ?? 0)
            }
            guard let body else {
                send(fd, status: "400 Bad Request", close: true)
                return
            }

            let response = handler.handle(body)
            let keepAlive = request.keepAlive
            send(fd, status: "200 OK", body: response, extra: ["Content-Type: application/ipp"], close: !keepAlive)
            if !keepAlive { return }
        }
    }

    private func send(_ fd: Int32, status: String, body: Data = Data(), extra: [String] = [], close: Bool) {
        var head = "HTTP/1.1 \(status)\r\nServer: tmt88v-compat\r\nContent-Length: \(body.count)\r\nConnection: \(close ? "close" : "keep-alive")\r\n"
        for line in extra { head += line + "\r\n" }
        head += "\r\n"
        writeAll(fd, Array(head.utf8) + [UInt8](body))
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return }
            offset += n
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]

    init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        version = String(parts[2])
        var parsed: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = parsed
    }

    var host: String? {
        guard let value = headers["host"] else { return nil }
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return value }
            return String(value[...end])
        }
        return String(value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    var contentType: String? {
        headers["content-type"]?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    var contentLength: Int? { headers["content-length"].flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil } }
    var chunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
    var expectContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }

    var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        return version == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
    }
}

struct SocketReader {
    let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) { self.fd = fd }

    private mutating func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    mutating func readHead(limit: Int) -> String? {
        let terminator: [UInt8] = [13, 10, 13, 10]
        while true {
            if let range = buffer.firstRange(of: terminator) {
                let head = String(decoding: buffer[0..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(0..<range.upperBound)
                return head
            }
            if buffer.count > limit || !fill() { return nil }
        }
    }

    mutating func readExact(_ count: Int) -> Data? {
        while buffer.count < count {
            if !fill() { return nil }
        }
        defer { buffer.removeSubrange(0..<count) }
        return Data(buffer[0..<count])
    }

    mutating func readChunked(limit: Int) -> Data? {
        var body = Data()
        while true {
            guard let sizeLine = readLine(), let size = Int(sizeLine.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 {
                while let trailer = readLine(), !trailer.isEmpty {}
                return body
            }
            guard body.count + size <= limit, let chunk = readExact(size), readLine() != nil else { return nil }
            body.append(chunk)
        }
    }

    private mutating func readLine() -> String? {
        while true {
            if let index = buffer.firstRange(of: [13, 10]) {
                let line = String(decoding: buffer[0..<index.lowerBound], as: UTF8.self)
                buffer.removeSubrange(0..<index.upperBound)
                return line
            }
            if buffer.count > 4096 || !fill() { return nil }
        }
    }
}
