public enum DitherMode: String, CaseIterable, Sendable {
    case threshold
    case floydSteinberg = "floyd-steinberg"
}

public enum Dithering {
    public static func apply(_ image: GrayImage, mode: DitherMode, threshold: UInt8 = 128) -> MonoBitmap {
        switch mode {
        case .threshold: thresholded(image, threshold: threshold)
        case .floydSteinberg: floydSteinberg(image, threshold: threshold)
        }
    }

    static func thresholded(_ image: GrayImage, threshold: UInt8) -> MonoBitmap {
        let rowBytes = MonoBitmap.rowBytes(forWidth: image.width)
        var data = [UInt8](repeating: 0, count: rowBytes * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[y * image.width + x] < threshold {
                data[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        return MonoBitmap(width: image.width, height: image.height, data: data)
    }

    static func floydSteinberg(_ image: GrayImage, threshold: UInt8) -> MonoBitmap {
        let width = image.width
        let rowBytes = MonoBitmap.rowBytes(forWidth: width)
        var data = [UInt8](repeating: 0, count: rowBytes * image.height)
        var current = [Int](repeating: 0, count: width + 2)
        var next = [Int](repeating: 0, count: width + 2)
        let cutoff = Int(threshold)

        for y in 0..<image.height {
            for x in 0..<width {
                let value = min(255, max(0, Int(image.pixels[y * width + x]) + current[x + 1]))
                let black = value < cutoff
                let error = value - (black ? 0 : 255)
                if black { data[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8) }
                current[x + 2] += error * 7 / 16
                next[x] += error * 3 / 16
                next[x + 1] += error * 5 / 16
                next[x + 2] += error / 16
            }
            swap(&current, &next)
            for i in next.indices { next[i] = 0 }
        }
        return MonoBitmap(width: width, height: image.height, data: data)
    }
}
