public enum RasterError: Error, CustomStringConvertible, Equatable {
    case unreadableImage(String)
    case invalidDimensions(width: Int, height: Int)
    case imageTooWide(width: Int, maxWidth: Int)
    case imageTooTall(height: Int, maxHeight: Int)
    case bitmapWiderThanPrinter(width: Int, maxWidth: Int)
    case contextCreationFailed

    public var description: String {
        switch self {
        case .unreadableImage(let reason): "unreadable_image: \(reason)"
        case .invalidDimensions(let w, let h): "invalid_dimensions: \(w)x\(h)"
        case .imageTooWide(let w, let max): "image_too_wide: \(w) dots exceeds printer width \(max) in actual-size mode"
        case .imageTooTall(let h, let max): "image_too_tall: \(h) rows exceeds limit \(max)"
        case .bitmapWiderThanPrinter(let w, let max): "bitmap_wider_than_printer: \(w) dots exceeds \(max)"
        case .contextCreationFailed: "context_creation_failed: could not create bitmap context"
        }
    }
}
