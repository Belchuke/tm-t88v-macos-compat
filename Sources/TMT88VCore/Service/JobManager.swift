import Foundation

public enum JobState: Int32, Sendable {
    case pending = 3
    case processing = 5
    case canceled = 7
    case aborted = 8
    case completed = 9

    public var isTerminal: Bool { rawValue >= 7 }
}

public struct PrintJob: Sendable {
    public let id: Int
    public var name: String
    public var format: String
    public var size: Int
    public var state: JobState = .pending
    public var reason = "none"
    public var message = ""
    public var created = Date()
    public var finished: Date?
    var document: Data?
}

public final class JobManager: @unchecked Sendable {
    private let lock = NSLock()
    private let service: PrintService
    private let log: ServiceLog
    private let queue = DispatchQueue(label: "tmt88v.jobs")
    private let retainedJobs: Int
    private var jobs: [Int: PrintJob] = [:]
    private var order: [Int] = []
    private var nextID = 1
    private var cancelled = Set<Int>()

    public init(service: PrintService, log: ServiceLog, retainedJobs: Int = 100) {
        self.service = service
        self.log = log
        self.retainedJobs = retainedJobs
    }

    public var queuedCount: Int {
        lock.withLock { jobs.values.filter { !$0.state.isTerminal }.count }
    }

    public var isProcessing: Bool {
        lock.withLock { jobs.values.contains { $0.state == .processing } }
    }

    public func submit(name: String, format: String, document: Data) -> PrintJob {
        let job: PrintJob = lock.withLock {
            let job = PrintJob(id: nextID, name: name, format: format, size: document.count, document: document)
            nextID += 1
            jobs[job.id] = job
            order.append(job.id)
            return job
        }
        log.event("job_received", ["job_id": job.id, "format": format, "bytes": document.count])
        queue.async { [self] in run(jobID: job.id) }
        return job
    }

    public func job(id: Int) -> PrintJob? {
        lock.withLock { jobs[id] }
    }

    public func allJobs() -> [PrintJob] {
        lock.withLock { order.compactMap { jobs[$0] } }
    }

    public enum CancelResult { case canceled, notFound, notPossible }

    public func cancel(id: Int) -> CancelResult {
        lock.withLock {
            guard var job = jobs[id] else { return .notFound }
            guard job.state == .pending else { return .notPossible }
            job.state = .canceled
            job.reason = "job-canceled-by-user"
            job.finished = Date()
            job.document = nil
            jobs[id] = job
            return .canceled
        }
    }

    private func run(jobID: Int) {
        let started: (Data, PrintJob)? = lock.withLock {
            guard var job = jobs[jobID], job.state == .pending, let document = job.document else { return nil }
            job.state = .processing
            job.reason = "job-printing"
            jobs[jobID] = job
            return (document, job)
        }
        guard let (document, job) = started else {
            log.event("job_skipped", ["job_id": jobID])
            return
        }

        let begin = DispatchTime.now()
        do {
            let outcome = try service.print(document: document, declaredFormat: job.format, jobID: jobID)
            finish(jobID, state: .completed, reason: "job-completed-successfully", message: "")
            log.event("job_completed", [
                "job_id": jobID, "format": job.format, "pages": outcome.pages, "blank_pages": outcome.blankPages,
                "raster_width": outcome.rasterWidth, "raster_height": outcome.rasterHeight, "dpi": outcome.dpi,
                "escpos_bytes": outcome.encodedBytes, "connection": outcome.connection,
                "transfer_ms": outcome.transferMilliseconds, "total_ms": elapsed(since: begin),
            ])
        } catch {
            finish(jobID, state: .aborted, reason: "job-aborted-by-system", message: "\(error)")
            log.event("job_failed", ["job_id": jobID, "format": job.format, "error": "\(error)", "total_ms": elapsed(since: begin)])
        }
    }

    private func finish(_ id: Int, state: JobState, reason: String, message: String) {
        lock.withLock {
            guard var job = jobs[id] else { return }
            job.state = state
            job.reason = reason
            job.message = message
            job.finished = Date()
            job.document = nil
            jobs[id] = job
            while order.count > retainedJobs, let oldest = order.first, jobs[oldest]?.state.isTerminal == true {
                order.removeFirst()
                jobs[oldest] = nil
            }
        }
    }
}
