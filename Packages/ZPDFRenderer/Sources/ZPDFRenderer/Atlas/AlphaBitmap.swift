import CoreGraphics
import Foundation

/// An 8-bit coverage bitmap: one byte per pixel, `0` empty, `255` fully covered.
///
/// This is the currency both atlases deal in, and the reason the two backends agree on text and
/// on count symbols. The atlas is rasterised **once**, by Core Graphics, at the device pixel size
/// the frame actually needs. Core Graphics then composites the tile as a mask; Metal samples the
/// same bytes as an `r8Unorm` texture. Neither backend re-renders a glyph, so neither can round a
/// glyph outline differently from the other, and the golden comparison of a text scene tests
/// placement and colour — the things the two backends really do differently — instead of testing
/// two independent font rasterisers against each other, which would be a test of Core Graphics.
public struct AlphaBitmap: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height` bytes, no padding.
    public private(set) var coverage: [UInt8]

    public init(width: Int, height: Int) {
        self.width = Swift.max(0, width)
        self.height = Swift.max(0, height)
        self.coverage = [UInt8](repeating: 0, count: self.width * self.height)
    }

    public init?(width: Int, height: Int, coverage: [UInt8]) {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.coverage = coverage
    }

    public var isEmpty: Bool { width == 0 || height == 0 }
    public var byteCount: Int { coverage.count }

    public subscript(x: Int, y: Int) -> UInt8 {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return coverage[y * width + x]
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            coverage[y * width + x] = newValue
        }
    }

    /// Copies a `w x h` block from `source` into this bitmap at `(x, y)`, clipped.
    public mutating func blit(_ source: AlphaBitmap, atX x: Int, y: Int) {
        guard !source.isEmpty else { return }
        for row in 0..<source.height {
            let destinationY = y + row
            guard destinationY >= 0, destinationY < height else { continue }
            for column in 0..<source.width {
                let destinationX = x + column
                guard destinationX >= 0, destinationX < width else { continue }
                coverage[destinationY * width + destinationX] =
                    source.coverage[row * source.width + column]
            }
        }
    }

    /// Rasterises into a fresh 8-bit grey `CGContext`, runs `body`, and reads the coverage back.
    ///
    /// A grey context with a black ground and white ink is used rather than an alpha-only one:
    /// alpha-only contexts do not accept `CTFontDrawGlyphs` consistently across macOS versions,
    /// and coverage-as-luminance is exactly the same number.
    public static func rasterize(
        width: Int,
        height: Int,
        _ body: (CGContext) -> Void
    ) -> AlphaBitmap? {
        guard width > 0, height > 0,
              width <= RenderLimits.maximumTargetPixels,
              height <= RenderLimits.maximumTargetPixels
        else { return nil }
        let bytesPerRow = width
        var storage = [UInt8](repeating: 0, count: bytesPerRow * height)
        let made: Bool = storage.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSmoothing(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            body(context)
            return true
        }
        guard made else { return nil }
        return AlphaBitmap(width: width, height: height, coverage: storage)
    }
}
