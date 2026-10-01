import Foundation

public struct PrintOutcome: Sendable {
    public var pages = 0
    public var blankPages = 0
    public var rasterWidth = 0
    public var rasterHeight = 0
    public var dpi = 0
    public var encodedBytes = 0
    public var connection = ""
    public var transferMilliseconds = 0.0
}

public enum PrintFailure: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case raster(String)
    case output(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let s), .raster(let s), .output(let s): s
        }
    }
}

public struct PrintService: Sendable {
    public let model: PrinterModel
    public let output: PrintOutput
    public var options = RasterOptions()

    public init(model: PrinterModel, output: PrintOutput) {
        self.model = model
        self.output = output
    }

    public func print(document: Data, declaredFormat: String?, jobID: Int) throws -> PrintOutcome {
        guard RasterFormat.detect(document) != nil else {
            throw PrintFailure.unsupportedFormat("document is not URF or PWG raster (declared \(declaredFormat ?? "none"))")
        }
        let pages: [RasterPage]
        do {
            pages = try RasterDocument.parse(document)
        } catch {
            throw PrintFailure.raster("\(error)")
        }

        var outcome = PrintOutcome(pages: pages.count)
        var payload = Data()
        for page in pages {
            outcome.dpi = page.dpiX
            guard let trimmed = page.image.trimmingTrailingWhite() else {
                outcome.blankPages += 1
                continue
            }
            do {
                let bitmap = try RasterProcessor.process(gray: trimmed, model: model, options: options)
                outcome.rasterWidth = bitmap.width
                outcome.rasterHeight = max(outcome.rasterHeight, bitmap.height)
                payload.append(try RasterReceipt.build(bitmap: bitmap, model: model))
            } catch {
                throw PrintFailure.raster("\(error)")
            }
        }
        outcome.encodedBytes = payload.count
        outcome.connection = output.connectionName
        guard !payload.isEmpty else { return outcome }

        do {
            let receipt = try output.send(payload, jobID: jobID)
            outcome.transferMilliseconds = receipt.transferMilliseconds
        } catch {
            throw PrintFailure.output("\(error)")
        }
        return outcome
    }
}
