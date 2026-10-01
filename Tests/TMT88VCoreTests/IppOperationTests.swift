import Foundation
import Testing
@testable import TMT88VCore

struct IppOperationTests {
    struct Harness {
        let output = CapturingOutput()
        let jobs: JobManager
        let handler: IppRequestHandler

        init(maxJobBytes: Int = 64 * 1024 * 1024, model: PrinterModel = .tmT88V80mm) {
            var config = IppServerConfig()
            config.maxJobBytes = maxJobBytes
            config.model = model
            jobs = JobManager(service: PrintService(model: model, output: output), log: ServiceLog(echoToStderr: false))
            handler = IppRequestHandler(config: config, jobs: jobs, log: ServiceLog(echoToStderr: false))
        }

        func call(_ request: Data) throws -> IppMessage {
            try Fixture.decodeResponse(handler.handle(request))
        }
    }

    static let smallURF = Fixture.urf(width: 510, height: 20) { x, y in y == 5 ? 0 : 255 }

    @Test func getPrinterAttributesReturnsReceiptCapabilities() throws {
        let response = try Harness().call(Fixture.ippRequest(IppOperation.getPrinterAttributes))
        #expect(response.code == IppStatus.ok)
        let printer = try #require(response.group(IppTag.printerGroup))
        #expect(printer["printer-state"]?.values == [.enumeration(3)])
        #expect(printer["printer-is-accepting-jobs"]?.values == [.boolean(true)])
        #expect(printer["color-supported"]?.values == [.boolean(false)])
        #expect(printer["sides-supported"]?.values == [.keyword("one-sided")])
        #expect(printer["printer-resolution-default"]?.values == [.resolution(cross: 180, feed: 180, units: 3)])
        #expect(printer["document-format-supported"]?.values.compactMap(\.string) == ["image/urf", "image/pwg-raster", "application/octet-stream"])
        #expect(printer["urf-supported"]?.values.compactMap(\.string).contains("RS180") == true)
        #expect(printer["printer-uri-supported"]?.values.first?.string == "ipp://127.0.0.1:8632/ipp/print")
        #expect(printer["uri-security-supported"]?.values == [.keyword("none")])
    }

    @Test func advertisedOperationsAreExactlyTheImplementedOnes() throws {
        let response = try Harness().call(Fixture.ippRequest(IppOperation.getPrinterAttributes))
        let advertised = try #require(response.group(IppTag.printerGroup)?["operations-supported"]).values.compactMap(\.int).map { UInt16($0) }
        #expect(Set(advertised) == [0x0002, 0x0004, 0x0008, 0x0009, 0x000A, 0x000B])
    }

    @Test func requestedAttributesFiltersTheResponse() throws {
        let response = try Harness().call(Fixture.ippRequest(
            IppOperation.getPrinterAttributes,
            extra: [IppAttribute("requested-attributes", [.keyword("printer-state"), .keyword("queued-job-count")])]
        ))
        let names = try #require(response.group(IppTag.printerGroup)).attributes.map(\.name)
        #expect(names == ["queued-job-count", "printer-state"] || Set(names) == ["printer-state", "queued-job-count"])
    }

    @Test func responseEchoesRequestIDAndVersion() throws {
        let response = try Harness().call(Fixture.ippRequest(IppOperation.getPrinterAttributes, id: 4242))
        #expect(response.requestID == 4242)
        #expect(response.versionMajor == 2)
        let operation = try #require(response.group(IppTag.operationGroup))
        #expect(operation.attributes[0].name == "attributes-charset")
        #expect(operation.attributes[1].name == "attributes-natural-language")
    }

    @Test func rejectsRequestIDZero() throws {
        #expect(try Harness().call(Fixture.ippRequest(IppOperation.getPrinterAttributes, id: 0)).code == IppStatus.badRequest)
    }

    @Test func rejectsUnsupportedMajorVersion() throws {
        var request = Fixture.ippRequest(IppOperation.getPrinterAttributes)
        request[request.startIndex] = 3
        #expect(try Harness().call(request).code == IppStatus.versionNotSupported)
    }

    @Test func rejectsWrongAttributeOrder() throws {
        var message = IppMessage(code: IppOperation.getPrinterAttributes, requestID: 1, groups: [IppGroup(tag: IppTag.operationGroup, attributes: [
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
            IppAttribute("attributes-charset", .charset("utf-8")),
        ])])
        message.versionMajor = 2
        #expect(try Harness().call(IppCodec.encode(message)).code == IppStatus.badRequest)
    }

    @Test func rejectsUnsupportedCharset() throws {
        let message = IppMessage(code: IppOperation.getPrinterAttributes, requestID: 1, groups: [IppGroup(tag: IppTag.operationGroup, attributes: [
            IppAttribute("attributes-charset", .charset("utf-16")),
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
        ])])
        #expect(try Harness().call(IppCodec.encode(message)).code == 0x040D)
    }

    @Test func malformedBodyGetsBadRequestWithRequestID() throws {
        let response = try Harness().call(Data([2, 0, 0, 2, 0, 0, 0x12, 0x34, 0x01, 0x47]))
        #expect(response.code == IppStatus.badRequest)
        #expect(response.requestID == 0x1234)
    }

    @Test func emptyBodyIsRejectedNotCrashed() throws {
        #expect(try Harness().call(Data()).code == IppStatus.badRequest)
    }

    @Test func missingOrWrongPrinterURI() throws {
        let harness = Harness()
        #expect(try harness.call(Fixture.ippRequest(IppOperation.getPrinterAttributes, printerURI: nil)).code == IppStatus.badRequest)
        #expect(try harness.call(Fixture.ippRequest(IppOperation.getPrinterAttributes, printerURI: "ipp://127.0.0.1:8632/ipp/other")).code == IppStatus.notFound)
    }

    @Test func unsupportedOperationsAreReported() throws {
        let harness = Harness()
        for operation in [IppOperation.createJob, IppOperation.sendDocument, 0x0010, 0x4001] as [UInt16] {
            #expect(try harness.call(Fixture.ippRequest(operation)).code == IppStatus.operationNotSupported)
        }
    }

    @Test func validateJobChecksDocumentFormat() throws {
        let harness = Harness()
        #expect(try harness.call(Fixture.ippRequest(IppOperation.validateJob)).code == IppStatus.ok)
        #expect(try harness.call(Fixture.ippRequest(IppOperation.validateJob, extra: [IppAttribute("document-format", .mimeMediaType("image/urf"))])).code == IppStatus.ok)
        let rejected = try harness.call(Fixture.ippRequest(IppOperation.validateJob, extra: [IppAttribute("document-format", .mimeMediaType("application/pdf"))]))
        #expect(rejected.code == IppStatus.documentFormatNotSupported)
        #expect(rejected.group(IppTag.unsupportedGroup)?["document-format"]?.values.first?.string == "application/pdf")
    }

    @Test func printJobAcceptsURFAndCompletes() throws {
        let harness = Harness()
        let response = try harness.call(Fixture.ippRequest(
            IppOperation.printJob,
            extra: [IppAttribute("job-name", .name("t")), IppAttribute("document-format", .mimeMediaType("image/urf"))],
            document: Self.smallURF
        ))
        #expect(response.code == IppStatus.ok)
        let job = try #require(response.group(IppTag.jobGroup))
        #expect(job["job-id"]?.values == [.integer(1)])
        #expect(job["job-uri"]?.values.first?.string == "ipp://127.0.0.1:8632/ipp/print/1")
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .completed })
        #expect(harness.output.payloads.count == 1)
    }

    @Test func printJobWithoutFormatAutoDetectsRaster() throws {
        let harness = Harness()
        let response = try harness.call(Fixture.ippRequest(
            IppOperation.printJob,
            extra: [IppAttribute("document-format", .mimeMediaType("application/octet-stream"))],
            document: Fixture.pwgGray(width: 100, height: 10) { _, y in y == 2 ? 0 : 255 }
        ))
        #expect(response.code == IppStatus.ok)
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .completed })
    }

    @Test func printJobRejectsEmptyDocument() throws {
        #expect(try Harness().call(Fixture.ippRequest(IppOperation.printJob)).code == IppStatus.badRequest)
    }

    @Test func printJobRejectsPDFDeclaredFormat() throws {
        let harness = Harness()
        let response = try harness.call(Fixture.ippRequest(
            IppOperation.printJob, extra: [IppAttribute("document-format", .mimeMediaType("application/pdf"))], document: Data("%PDF-1.4".utf8)
        ))
        #expect(response.code == IppStatus.documentFormatNotSupported)
        #expect(harness.jobs.allJobs().isEmpty)
    }

    @Test func printJobRejectsGarbageAsFormatError() throws {
        let harness = Harness()
        let response = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Data("not a raster".utf8)))
        #expect(response.code == IppStatus.documentFormatError)
        #expect(harness.jobs.allJobs().isEmpty)
    }

    @Test func printJobEnforcesSizeLimit() throws {
        let harness = Harness(maxJobBytes: 100)
        let response = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Self.smallURF))
        #expect(response.code == IppStatus.requestEntityTooLarge)
        #expect(harness.jobs.allJobs().isEmpty)
    }

    @Test func truncatedRasterBecomesAbortedJobNotCrash() throws {
        let harness = Harness()
        let truncated = Self.smallURF.prefix(Self.smallURF.count / 2)
        #expect(try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Data(truncated))).code == IppStatus.ok)
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .aborted })
        #expect(harness.output.payloads.isEmpty)
    }

    @Test func outputFailureAbortsJob() throws {
        let harness = Harness()
        harness.output.failure = UsbError(.printerNotFound, "no printer")
        _ = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Self.smallURF))
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .aborted })
        #expect(harness.jobs.job(id: 1)?.message.contains("printer_not_found") == true)
    }

    @Test func getJobAttributesAndGetJobs() throws {
        let harness = Harness()
        _ = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Self.smallURF))
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .completed })

        let attributes = try harness.call(Fixture.ippRequest(IppOperation.getJobAttributes, extra: [IppAttribute("job-id", .integer(1))]))
        #expect(attributes.code == IppStatus.ok)
        #expect(attributes.group(IppTag.jobGroup)?["job-state"]?.values == [.enumeration(9)])

        let byURI = try harness.call(Fixture.ippRequest(IppOperation.getJobAttributes, extra: [IppAttribute("job-uri", .uri("ipp://127.0.0.1:8632/ipp/print/1"))]))
        #expect(byURI.code == IppStatus.ok)

        let completed = try harness.call(Fixture.ippRequest(IppOperation.getJobs, extra: [IppAttribute("which-jobs", .keyword("completed"))]))
        #expect(completed.groups.filter { $0.tag == IppTag.jobGroup }.count == 1)
        let active = try harness.call(Fixture.ippRequest(IppOperation.getJobs))
        #expect(active.groups.filter { $0.tag == IppTag.jobGroup }.isEmpty)

        #expect(try harness.call(Fixture.ippRequest(IppOperation.getJobAttributes, extra: [IppAttribute("job-id", .integer(99))])).code == IppStatus.notFound)
    }

    @Test func cancelJob() throws {
        let harness = Harness()
        #expect(try harness.call(Fixture.ippRequest(IppOperation.cancelJob, extra: [IppAttribute("job-id", .integer(5))])).code == IppStatus.notFound)
        #expect(try harness.call(Fixture.ippRequest(IppOperation.cancelJob)).code == IppStatus.badRequest)
        _ = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Self.smallURF))
        #expect(waitUntil { harness.jobs.job(id: 1)?.state == .completed })
        #expect(try harness.call(Fixture.ippRequest(IppOperation.cancelJob, extra: [IppAttribute("job-id", .integer(1))])).code == IppStatus.notPossible)
    }

    @Test func jobIDsIncreaseAndPrintOrderIsSubmissionOrder() throws {
        let harness = Harness()
        for _ in 0..<3 { _ = try harness.call(Fixture.ippRequest(IppOperation.printJob, document: Self.smallURF)) }
        #expect(waitUntil { harness.jobs.allJobs().allSatisfy { $0.state == .completed } && harness.jobs.allJobs().count == 3 })
        #expect(harness.jobs.allJobs().map(\.id) == [1, 2, 3])
    }
}
