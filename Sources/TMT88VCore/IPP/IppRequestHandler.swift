import Foundation

public final class IppRequestHandler: @unchecked Sendable {
    private let configLock = NSLock()
    private var storedConfig: IppServerConfig
    private var config: IppServerConfig { configLock.withLock { storedConfig } }
    private let jobs: JobManager
    private let log: ServiceLog
    private let startTime = Date()

    public init(config: IppServerConfig, jobs: JobManager, log: ServiceLog) {
        self.storedConfig = config
        self.jobs = jobs
        self.log = log
    }

    func updatePort(_ port: UInt16) {
        configLock.withLock { storedConfig.port = port }
    }

    public func handle(_ body: Data) -> Data {
        let parsed: (message: IppMessage, bodyOffset: Int)
        do {
            parsed = try IppCodec.decode(body)
        } catch {
            log.event("ipp_malformed", ["error": "\(error)"])
            return IppCodec.encode(response(status: IppStatus.badRequest, requestID: peekRequestID(body), major: 1, minor: 1, message: "malformed IPP request"))
        }
        let request = parsed.message
        let document = body.subdata(in: (body.startIndex + parsed.bodyOffset)..<body.endIndex)
        let major: UInt8 = request.versionMajor == 1 ? 1 : 2
        let minor: UInt8 = request.versionMajor == 1 ? 1 : 0

        func reply(_ status: UInt16, _ message: String? = nil, extra: [IppGroup] = []) -> Data {
            IppCodec.encode(response(status: status, requestID: request.requestID, major: major, minor: minor, message: message, extra: extra))
        }

        guard (1...2).contains(request.versionMajor) else { return reply(IppStatus.versionNotSupported, "IPP version not supported") }
        guard request.requestID != 0 else { return reply(IppStatus.badRequest, "request-id must be non-zero") }
        guard let operation = request.group(IppTag.operationGroup),
              operation.attributes.count >= 2,
              operation.attributes[0].name == "attributes-charset",
              operation.attributes[1].name == "attributes-natural-language" else {
            return reply(IppStatus.badRequest, "attributes-charset and attributes-natural-language must come first")
        }
        guard let charset = operation.attributes[0].values.first?.string, ["utf-8", "us-ascii"].contains(charset.lowercased()) else {
            return reply(0x040D, "charset not supported")
        }

        switch request.code {
        case IppOperation.getPrinterAttributes:
            if let failure = checkPrinterURI(operation) { return reply(failure.0, failure.1) }
            return reply(IppStatus.ok, extra: [IppGroup(tag: IppTag.printerGroup, attributes: filteredPrinterAttributes(operation))])

        case IppOperation.validateJob:
            if let failure = checkPrinterURI(operation) { return reply(failure.0, failure.1) }
            if let failure = checkFormat(operation, document: nil) { return reply(failure.status, failure.message, extra: failure.groups) }
            return reply(IppStatus.ok)

        case IppOperation.printJob:
            if let failure = checkPrinterURI(operation) { return reply(failure.0, failure.1) }
            guard !document.isEmpty else { return reply(IppStatus.badRequest, "no document data") }
            guard document.count <= config.maxJobBytes else { return reply(IppStatus.requestEntityTooLarge, "document exceeds \(config.maxJobBytes) bytes") }
            if let failure = checkFormat(operation, document: document) { return reply(failure.status, failure.message, extra: failure.groups) }
            let format = RasterFormat.detect(document)?.rawValue ?? "unknown"
            let name = operation["job-name"]?.values.first?.string ?? "Untitled"
            let job = jobs.submit(name: name, format: format, document: document)
            return reply(IppStatus.ok, extra: [IppGroup(tag: IppTag.jobGroup, attributes: Array(jobAttributes(job).prefix(5)))])

        case IppOperation.getJobAttributes:
            guard let job = lookupJob(operation) else { return reply(IppStatus.notFound, "job not found") }
            return reply(IppStatus.ok, extra: [IppGroup(tag: IppTag.jobGroup, attributes: jobAttributes(job))])

        case IppOperation.getJobs:
            if let failure = checkPrinterURI(operation) { return reply(failure.0, failure.1) }
            let completed = operation["which-jobs"]?.values.first?.string == "completed"
            var selected = jobs.allJobs().filter { $0.state.isTerminal == completed }
            if let limit = operation["limit"]?.values.first?.int, limit > 0 { selected = Array(selected.prefix(Int(limit))) }
            return reply(IppStatus.ok, extra: selected.map { IppGroup(tag: IppTag.jobGroup, attributes: jobAttributes($0)) })

        case IppOperation.cancelJob:
            guard let id = jobID(operation) else { return reply(IppStatus.badRequest, "job-id or job-uri required") }
            switch jobs.cancel(id: id) {
            case .canceled: return reply(IppStatus.ok)
            case .notFound: return reply(IppStatus.notFound, "job not found")
            case .notPossible: return reply(IppStatus.notPossible, "job is already processing or finished")
            }

        default:
            return reply(IppStatus.operationNotSupported, "operation 0x\(String(request.code, radix: 16)) not supported")
        }
    }

    private func response(status: UInt16, requestID: UInt32, major: UInt8, minor: UInt8, message: String?, extra: [IppGroup] = []) -> IppMessage {
        var attributes = [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
        ]
        if let message { attributes.append(IppAttribute("status-message", .text(message))) }
        var result = IppMessage(code: status, requestID: requestID, groups: [IppGroup(tag: IppTag.operationGroup, attributes: attributes)] + extra)
        result.versionMajor = major
        result.versionMinor = minor
        return result
    }

    private func peekRequestID(_ body: Data) -> UInt32 {
        guard body.count >= 8 else { return 0 }
        let b = body.startIndex
        return UInt32(body[b + 4]) << 24 | UInt32(body[b + 5]) << 16 | UInt32(body[b + 6]) << 8 | UInt32(body[b + 7])
    }

    private func checkPrinterURI(_ operation: IppGroup) -> (UInt16, String)? {
        guard let uri = operation["printer-uri"]?.values.first?.string else { return (IppStatus.badRequest, "printer-uri required") }
        guard let components = URLComponents(string: uri), components.path == config.printerPath else {
            return (IppStatus.notFound, "unknown printer \(uri)")
        }
        return nil
    }

    private struct FormatFailure {
        let status: UInt16
        let message: String
        let groups: [IppGroup]
    }

    private func checkFormat(_ operation: IppGroup, document: Data?) -> FormatFailure? {
        if let declared = operation["document-format"]?.values.first?.string, !IppServerConfig.acceptedFormats.contains(declared) {
            return FormatFailure(
                status: IppStatus.documentFormatNotSupported, message: "document-format \(declared) not supported",
                groups: [IppGroup(tag: IppTag.unsupportedGroup, attributes: [IppAttribute("document-format", .mimeMediaType(declared))])]
            )
        }
        if let document, RasterFormat.detect(document) == nil {
            return FormatFailure(status: IppStatus.documentFormatError, message: "document is not URF or PWG raster", groups: [])
        }
        return nil
    }

    private func filteredPrinterAttributes(_ operation: IppGroup) -> [IppAttribute] {
        let all = IppPrinterAttributes.build(config: config, queuedJobs: jobs.queuedCount, processing: jobs.isProcessing, startTime: startTime)
        let requested = Set(operation["requested-attributes"]?.values.compactMap(\.string) ?? [])
        let groups: Set<String> = ["all", "printer-description", "job-template", "media-col-database"]
        if requested.isEmpty || !requested.isDisjoint(with: groups) { return all }
        return all.filter { requested.contains($0.name) }
    }

    private func jobID(_ operation: IppGroup) -> Int? {
        if let id = operation["job-id"]?.values.first?.int { return Int(id) }
        if let uri = operation["job-uri"]?.values.first?.string, let last = uri.split(separator: "/").last { return Int(last) }
        return nil
    }

    private func lookupJob(_ operation: IppGroup) -> PrintJob? {
        jobID(operation).flatMap { jobs.job(id: $0) }
    }

    private func jobAttributes(_ job: PrintJob) -> [IppAttribute] {
        let base = config.printerURI()
        let created = Int32(clamping: Int(job.created.timeIntervalSince(startTime)))
        var attributes = [
            IppAttribute("job-id", .integer(Int32(job.id))),
            IppAttribute("job-uri", .uri("\(base)/\(job.id)")),
            IppAttribute("job-state", .enumeration(job.state.rawValue)),
            IppAttribute("job-state-reasons", .keyword(job.reason)),
            IppAttribute("job-state-message", .text(job.message)),
            IppAttribute("job-printer-uri", .uri(base)),
            IppAttribute("job-name", .name(job.name)),
            IppAttribute("job-originating-user-name", .name("anonymous")),
            IppAttribute("time-at-creation", .integer(max(0, created))),
            IppAttribute("job-k-octets", .integer(Int32(clamping: (job.size + 1023) / 1024))),
        ]
        if let finished = job.finished {
            attributes.append(IppAttribute("time-at-completed", .integer(Int32(clamping: Int(finished.timeIntervalSince(startTime))))))
        }
        return attributes
    }
}
