import CoreGraphics
import Foundation

/// An 8-bit grayscale raster, row-major, **row 0 at the top**.
///
/// The comparison works in gray rather than RGB on purpose. A revision cloud printed in
/// red and the same cloud printed in black are the same change, and a colour difference
/// on an otherwise identical sheet is a plotting-profile difference, not a design one.
/// Colour is the *overlay's* job, and the overlay tints from these same coverage values.
///
/// `255` is paper, `0` is ink: the same polarity CoreGraphics device gray uses, so the
/// bytes come straight out of the bitmap context with no inversion pass.
public struct GrayImage: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// `width * height` bytes.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw CompareFault.malformedRaster(reason: "size \(width)x\(height)")
        }
        let expected = width.multipliedReportingOverflow(by: height)
        guard !expected.overflow, pixels.count == expected.partialValue else {
            throw CompareFault.malformedRaster(
                reason: "\(pixels.count) bytes for \(width)x\(height)"
            )
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A uniform image, for tests and for the overlay background.
    public init(width: Int, height: Int, filledWith value: UInt8) throws {
        // The product is checked before the buffer is built: `width * height` used to trap
        // ahead of the designated initialiser's own overflow guard (BH-473).
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow else {
            throw CompareFault.malformedRaster(reason: "size \(width)x\(height)")
        }
        try self.init(
            width: width,
            height: height,
            pixels: [UInt8](repeating: value, count: count)
        )
    }

    public var pixelCount: Int { width * height }

    @inline(__always)
    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// `true` when the two images can be compared pixel for pixel.
    public func hasSameGeometry(as other: GrayImage) -> Bool {
        width == other.width && height == other.height
    }

    public var geometryDescription: String { "\(width)x\(height)" }

    // MARK: - CoreGraphics

    /// Rasterises a `CGImage` into device gray at its own pixel size.
    ///
    /// - Parameter maximumPixels: rejected before any allocation when exceeded.
    public static func from(_ image: CGImage, maximumPixels: Int) throws -> GrayImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw CompareFault.malformedRaster(reason: "CGImage is \(width)x\(height)")
        }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= maximumPixels else {
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: product.overflow ? Int.max : product.partialValue,
                limit: maximumPixels
            )
        }

        var buffer = [UInt8](repeating: 255, count: product.partialValue)
        let space = CGColorSpaceCreateDeviceGray()
        let produced: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            // Paper first: a page rendered without an opaque background composites onto
            // white here rather than onto whatever the allocator left behind.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard produced else { throw CompareFault.coreGraphicsFailure(operation: "gray bitmap context") }
        return try GrayImage(width: width, height: height, pixels: buffer)
    }

    /// A `CGImage` view of this buffer, for display and for Vision.
    public func cgImage() throws -> CGImage {
        let space = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw CompareFault.coreGraphicsFailure(operation: "gray data provider")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CompareFault.coreGraphicsFailure(operation: "gray CGImage")
        }
        return image
    }

    // MARK: - Resampling

    /// Resamples into a `width × height` grid using `inverseMap`, which takes a
    /// **destination pixel** coordinate to the **source pixel** coordinate to read.
    ///
    /// Taking the inverse map rather than the forward one is not a convenience: forward
    /// mapping leaves holes wherever the transform expands, and a hole in a difference
    /// image reads as a change that is not there.
    ///
    /// Sampling is bilinear, and anything outside the source is `background` — white, so
    /// that a page dragged partly off the baseline sheet reads as blank paper rather
    /// than as a black rectangle of "removed" content.
    public func resampled(
        using inverseMap: AlignmentTransform,
        width targetWidth: Int,
        height targetHeight: Int,
        background: UInt8 = 255,
        maximumPixels: Int
    ) throws -> GrayImage {
        guard targetWidth > 0, targetHeight > 0 else {
            throw CompareFault.malformedRaster(reason: "target size \(targetWidth)x\(targetHeight)")
        }
        let product = targetWidth.multipliedReportingOverflow(by: targetHeight)
        guard !product.overflow, product.partialValue <= maximumPixels else {
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: product.overflow ? Int.max : product.partialValue,
                limit: maximumPixels
            )
        }
        guard inverseMap.isFinite else {
            throw CompareFault.alignment(.nonInvertibleTransform(determinant: inverseMap.determinant))
        }

        // The identity case is the common one — two revisions of the same sheet — and
        // resampling it would soften every edge for nothing.
        if inverseMap.isIdentity(tolerance: 1e-9), targetWidth == width, targetHeight == height {
            return self
        }

        var output = [UInt8](repeating: background, count: product.partialValue)
        let maxX = Double(width - 1)
        let maxY = Double(height - 1)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for row in 0..<targetHeight {
                    let dy = Double(row) + 0.5
                    var sx = inverseMap.c * dy + inverseMap.tx + inverseMap.a * 0.5
                    var sy = inverseMap.d * dy + inverseMap.ty + inverseMap.b * 0.5
                    let rowBase = row * targetWidth
                    for column in 0..<targetWidth {
                        defer {
                            sx += inverseMap.a
                            sy += inverseMap.b
                        }
                        let px = sx - 0.5
                        let py = sy - 0.5
                        guard px >= -0.5, py >= -0.5, px <= maxX + 0.5, py <= maxY + 0.5 else {
                            continue
                        }
                        let x0 = Swift.max(0, Swift.min(width - 1, Int(px.rounded(.down))))
                        let y0 = Swift.max(0, Swift.min(height - 1, Int(py.rounded(.down))))
                        let x1 = Swift.min(width - 1, x0 + 1)
                        let y1 = Swift.min(height - 1, y0 + 1)
                        let fx = Swift.max(0, Swift.min(1, px - Double(x0)))
                        let fy = Swift.max(0, Swift.min(1, py - Double(y0)))
                        let p00 = Double(source[y0 * width + x0])
                        let p10 = Double(source[y0 * width + x1])
                        let p01 = Double(source[y1 * width + x0])
                        let p11 = Double(source[y1 * width + x1])
                        let top = p00 + (p10 - p00) * fx
                        let bottom = p01 + (p11 - p01) * fx
                        let value = top + (bottom - top) * fy
                        destination[rowBase + column] = UInt8(
                            Swift.max(0, Swift.min(255, value.rounded()))
                        )
                    }
                }
            }
        }
        return try GrayImage(width: targetWidth, height: targetHeight, pixels: output)
    }

    // MARK: - Measures

    /// Mean absolute difference in gray levels, `0…255`. The accept/reject measure the
    /// automatic aligner verifies a candidate transform with.
    public func meanAbsoluteDifference(to other: GrayImage) throws -> Double {
        guard hasSameGeometry(as: other) else {
            throw CompareFault.mismatchedRasterGeometry(
                baseline: geometryDescription, revised: other.geometryDescription
            )
        }
        var total = 0.0
        pixels.withUnsafeBufferPointer { lhs in
            other.pixels.withUnsafeBufferPointer { rhs in
                var accumulator: Int64 = 0
                for index in 0..<lhs.count {
                    accumulator += Int64(abs(Int(lhs[index]) - Int(rhs[index])))
                }
                total = Double(accumulator)
            }
        }
        return total / Double(pixelCount)
    }

    /// The fraction of pixels darker than `threshold` — "how much ink is on this sheet".
    public func inkCoverage(threshold: UInt8 = 200) -> Double {
        var count = 0
        for value in pixels where value < threshold { count += 1 }
        return Double(count) / Double(pixelCount)
    }
}
