import Foundation

public enum RasterEncoder {
    public static let defaultBandHeight = 128

    public static func encode(_ bitmap: MonoBitmap, bandHeight: Int = defaultBandHeight) -> Data {
        guard bitmap.width > 0, bitmap.height > 0 else { return Data() }
        let band = max(1, min(bandHeight, 65535))
        var output = Data(capacity: bitmap.data.count + (bitmap.height / band + 1) * 8)

        var row = 0
        while row < bitmap.height {
            let rows = min(band, bitmap.height - row)
            output.append(contentsOf: [
                0x1D, 0x76, 0x30, 0x00,
                UInt8(bitmap.rowBytes & 0xFF), UInt8(bitmap.rowBytes >> 8),
                UInt8(rows & 0xFF), UInt8(rows >> 8),
            ])
            output.append(contentsOf: bitmap.data[(row * bitmap.rowBytes)..<((row + rows) * bitmap.rowBytes)])
            row += rows
        }
        return output
    }
}
