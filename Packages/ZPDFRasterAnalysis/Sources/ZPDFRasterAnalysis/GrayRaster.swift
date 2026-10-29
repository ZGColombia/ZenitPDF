import CoreGraphics
import Foundation

/// An 8-bit grayscale picture of a region of a page: 0 is black, 255 white. Row 0 is the top of
/// the picture; page space has its origin bottom-left, and ``pagePoint(x:y:)`` converts.
public struct GrayRaster: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]
    /// The page-space rectangle the picture covers.
    public let pageRegion: CGRect

    public init(width: Int, height: Int, pixels: [UInt8], pageRegion: CGRect) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.pageRegion = pageRegion
    }

    /// The picture of `image`, which shows `pageRegion`, drawn into a gray buffer.
    public init?(image: CGImage, pageRegion: CGRect) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 255, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: buffer, pageRegion: pageRegion)
    }

    /// Page points per pixel, horizontally (the render scale's inverse).
    public var pointsPerPixel: Double { pageRegion.width / Double(width) }

    /// The page point at pixel coordinates (x to the right, y down from the top).
    public func pagePoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: pageRegion.minX + x * pointsPerPixel,
                y: pageRegion.maxY - y * (pageRegion.height / Double(height)))
    }

    /// The pixel coordinates of a page point.
    public func pixel(of point: CGPoint) -> (x: Double, y: Double) {
        ((point.x - pageRegion.minX) / pointsPerPixel, (pageRegion.maxY - point.y) / (pageRegion.height / Double(height)))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// The sub-picture of `rect` in pixel coordinates, clamped to the picture.
    public func crop(x: Int, y: Int, width w: Int, height h: Int) -> GrayRaster? {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return nil }
        var out = [UInt8](repeating: 255, count: (x1 - x0) * (y1 - y0))
        for row in y0..<y1 {
            out.replaceSubrange((row - y0) * (x1 - x0)..<(row - y0 + 1) * (x1 - x0), with: pixels[(row * width + x0)..<(row * width + x1)])
        }
        let topLeft = pagePoint(x: Double(x0), y: Double(y0)), bottomRight = pagePoint(x: Double(x1), y: Double(y1))
        return GrayRaster(width: x1 - x0, height: y1 - y0, pixels: out,
                          pageRegion: CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y))
    }

    /// Every `factor`-th pixel's block averaged, for a coarse pass.
    ///
    /// A side shorter than `factor` still gives one output pixel, and its block is only the
    /// pixels that exist: averaging over a block that runs past the picture read past the end of
    /// `pixels` (S-114, a thin boxed symbol crashed the app) or, sideways, into the next row.
    public func downsampled(by factor: Int) -> GrayRaster {
        guard factor > 1 else { return self }
        let w = max(1, width / factor), h = max(1, height / factor)
        // The source pixels the output covers: whole blocks, or the whole side when it is shorter.
        let coveredWidth = min(width, w * factor), coveredHeight = min(height, h * factor)
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let rows = (y * factor)..<min(coveredHeight, (y + 1) * factor)
            for x in 0..<w {
                let columns = (x * factor)..<min(coveredWidth, (x + 1) * factor)
                var sum = 0
                for row in rows { for column in columns { sum += Int(pixels[row * width + column]) } }
                out[y * w + x] = UInt8(sum / (rows.count * columns.count))
            }
        }
        return GrayRaster(width: w, height: h, pixels: out,
                          pageRegion: CGRect(x: pageRegion.minX, y: pageRegion.maxY - Double(coveredHeight) * (pageRegion.height / Double(height)),
                                             width: Double(coveredWidth) * pointsPerPixel, height: Double(coveredHeight) * (pageRegion.height / Double(height))))
    }

    /// The picture turned a quarter turn clockwise, or mirrored left-to-right.
    public func rotatedClockwise() -> GrayRaster {
        var out = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height { for x in 0..<width { out[x * height + (height - 1 - y)] = pixels[y * width + x] } }
        return GrayRaster(width: height, height: width, pixels: out, pageRegion: CGRect(x: pageRegion.minX, y: pageRegion.minY, width: pageRegion.height, height: pageRegion.width))
    }

    public func mirrored() -> GrayRaster {
        var out = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height { for x in 0..<width { out[y * width + (width - 1 - x)] = pixels[y * width + x] } }
        return GrayRaster(width: width, height: height, pixels: out, pageRegion: pageRegion)
    }
}
