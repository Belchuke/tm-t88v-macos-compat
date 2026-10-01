public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 255) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }
}

public struct MonoBitmap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        let rowBytes = Self.rowBytes(forWidth: width)
        precondition(data.count == rowBytes * height, "data count must equal rowBytes * height")
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.data = data
    }

    public static func rowBytes(forWidth width: Int) -> Int {
        (width + 7) / 8
    }

    public func isBlack(x: Int, y: Int) -> Bool {
        data[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0
    }
}
