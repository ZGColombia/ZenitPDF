import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit-per-channel RGBA image with **premultiplied** alpha, in the sRGB colour space.
///
/// Premultiplied is not an implementation detail: it is what a Metal `bgra8Unorm` target holds
/// after a standard source-over blend, and it is what `CGBitmapContext` produces with
/// `premultipliedLast`. Comparing one against the other only means anything if both are stated to
/// be in the same representation, so the type states it.
public struct RasterImage: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, row major, R G B A.
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.width = Swift.max(1, width)
        self.height = Swift.max(1, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var byteCount: Int { pixels.count }

    /// The four channel bytes at `(x, y)`, or all zeroes outside the image.
    public func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// Alpha coverage at `(x, y)` as `0...1`.
    public func alpha(x: Int, y: Int) -> Double {
        Double(pixel(x: x, y: y).3) / 255
    }

    // MARK: - PNG

    /// Encodes to PNG. Returns `nil` rather than throwing, because the only failure is ImageIO
    /// refusing, which is not a condition a caller can act on differently.
    public func pngData() -> Data? {
        guard let image = makeCGImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func fromCGImage(_ image: CGImage) -> RasterImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= RenderLimits.maximumTargetPixels,
              height <= RenderLimits.maximumTargetPixels
        else { return nil }
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return RasterImage(width: width, height: height, pixels: storage)
    }

    /// Wraps the pixels in a `CGImage`. The image owns a copy; mutating this value afterwards is
    /// safe.
    public func makeCGImage() -> CGImage? {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Converts BGRA byte order — what a Metal `bgra8Unorm` texture reads back as — to RGBA.
    public static func fromBGRA(width: Int, height: Int, bytes: [UInt8]) -> RasterImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        var rgba = [UInt8](repeating: 0, count: bytes.count)
        var offset = 0
        while offset < bytes.count {
            rgba[offset] = bytes[offset + 2]
            rgba[offset + 1] = bytes[offset + 1]
            rgba[offset + 2] = bytes[offset]
            rgba[offset + 3] = bytes[offset + 3]
            offset += 4
        }
        return RasterImage(width: width, height: height, pixels: rgba)
    }
}
