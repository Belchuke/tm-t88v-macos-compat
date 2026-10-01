import Foundation

public struct PageDiagnostics: Sendable {
    public var page = 0
    public var widthPx = 0
    public var heightPx = 0
    public var dpiX = 0
    public var dpiY = 0
    public var blank = false
    public var trimmedHeightPx = 0
    public var rasterWidth = 0
    public var rasterHeight = 0
    public var scale = "none"
    public var scaleFactor = 1.0
    public var offsetX = 0
    public var cut = false

    public var widthMM: Double { dpiX > 0 ? (Double(widthPx) / Double(dpiX) * 25.4 * 10).rounded() / 10 : 0 }
    public var heightMM: Double { dpiY > 0 ? (Double(heightPx) / Double(dpiY) * 25.4 * 10).rounded() / 10 : 0 }

    public var logFields: [String: Any] {
        [
            "page": page, "page_px": "\(widthPx)x\(heightPx)", "page_mm": "\(widthMM)x\(heightMM)",
            "dpi": "\(dpiX)x\(dpiY)", "blank": blank, "trimmed_height": trimmedHeightPx,
            "raster": "\(rasterWidth)x\(rasterHeight)", "scale": scale, "scale_factor": scaleFactor,
            "offset_x": offsetX, "cut": cut,
        ]
    }
}

public struct PrintOutcome: Sendable {
    public var pageDetails: [PageDiagnostics] = []
    public var cuts: Int { pageDetails.filter(\.cut).count }
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
        for (index, page) in pages.enumerated() {
            outcome.dpi = page.dpiX
            var detail = PageDiagnostics(
                page: index + 1, widthPx: page.image.width, heightPx: page.image.height, dpiX: page.dpiX, dpiY: page.dpiY
            )
            guard let trimmed = page.image.trimmingTrailingWhite() else {
                outcome.blankPages += 1
                detail.blank = true
                outcome.pageDetails.append(detail)
                continue
            }
            detail.trimmedHeightPx = trimmed.height
            do {
                let bitmap = try RasterProcessor.process(gray: trimmed, model: model, options: options)
                detail.rasterWidth = bitmap.width
                detail.rasterHeight = bitmap.height
                detail.cut = model.cutMode != .none
                if trimmed.width > model.dotsPerLine {
                    detail.scale = "down"
                    detail.scaleFactor = (Double(model.dotsPerLine) / Double(trimmed.width) * 1000).rounded() / 1000
                } else {
                    detail.offsetX = (model.dotsPerLine - trimmed.width) / 2
                }
                outcome.pageDetails.append(detail)
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
