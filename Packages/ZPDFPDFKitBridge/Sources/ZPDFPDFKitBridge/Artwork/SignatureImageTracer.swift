import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ZPDFContracts

/// A photographed or scanned signature, traced into outlines (NL-PDF-22).
///
/// The raster import compiles an image to a mosaic of at most
/// ``ArtworkLimits/maximumRasterSampleEdge`` cells — right for a seal, far too coarse for a pen
/// line. A signature is ink on paper, so this separates the ink from the paper (Otsu's threshold
/// on luminance: the background is removed, not painted white), drops specks, and traces every
/// ink shape's outline — holes included, so the loop of an "o" stays open — into filled regions
/// in unit space. The result is geometry like a compiled PDF page: sharp at any zoom, one ink
/// (``ImportedArtwork/sourceInk``) that the stamp colour can change.
///
/// It is **an image of a signature**, and the stamp built from it says so. It is not a digital
/// signature and proves nothing; `PDFSignatureWriter` is that (NL-PDF-16).
///
/// Hostile input is bounded as everywhere in artwork import: the pixel count is read from the
/// image header and refused before decoding, the decode is downsampled, and the traced geometry
/// is checked by ``ArtworkGeometry/limitViolation()`` before it leaves.
public enum SignatureImageTracer {

    /// Why a picture did not become a signature.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreadable
        case tooLarge(pixels: Int)
        case noInk
        case notASignature

        public var description: String {
            switch self {
            case .unreadable:
                "the file is not an image this Mac can read"
            case let .tooLarge(pixels):
                "the image has \(pixels) pixels; the limit is \(SignatureImageTracer.maximumSourcePixels)"
            case .noInk:
                "no pen line stands out from the paper in this image"
            case .notASignature:
                "most of the image is dark, which is a photograph rather than ink on paper; crop it to the signature and try again"
            }
        }
    }

    /// The longest edge the image is decoded at.
    public static let decodeEdge = 1_400
    /// Images whose header states more pixels than this are refused unread.
    public static let maximumSourcePixels = 80_000_000
    /// Ink shapes smaller than this many pixels are specks of paper grain, not writing.
    public static let minimumShapePixels = 12

    /// Traces the image at `url`.
    public static func trace(fileAt url: URL) throws -> ImportedArtwork {
        let bytes = try StampArtworkImporter.readBoundedSource(at: url)
        return try trace(bytes: bytes, sourceName: url.lastPathComponent)
    }

    /// Traces image `bytes`.
    public static func trace(bytes: Data, sourceName: String) throws -> ImportedArtwork {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Refusal.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { throw Refusal.unreadable }
        guard width.multipliedReportingOverflow(by: height).partialValue <= maximumSourcePixels else {
            throw Refusal.tooLarge(pixels: width * height)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeEdge,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw Refusal.unreadable }

        let columns = image.width, rows = image.height
        var rgba = [UInt8](repeating: 255, count: columns * rows * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Transparent pixels become paper, never ink.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { throw Refusal.unreadable }

        var luminance = [UInt8](repeating: 0, count: columns * rows)
        for index in 0..<(columns * rows) {
            let r = Double(rgba[index * 4]), g = Double(rgba[index * 4 + 1]), b = Double(rgba[index * 4 + 2])
            luminance[index] = UInt8(min(255, max(0, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded())))
        }
        let threshold = otsuThreshold(luminance)
        var ink = luminance.map { $0 < threshold }
        removeSpecks(&ink, columns: columns, rows: rows, minimum: minimumShapePixels)
        let inkCount = ink.lazy.filter { $0 }.count
        guard inkCount > 0 else { throw Refusal.noInk }
        guard Double(inkCount) / Double(columns * rows) <= 0.4 else { throw Refusal.notASignature }

        // The ink's own colour: the mean of the ink pixels, the stamp's starting colour.
        var sum = (0.0, 0.0, 0.0)
        for index in 0..<(columns * rows) where ink[index] {
            sum.0 += Double(rgba[index * 4]); sum.1 += Double(rgba[index * 4 + 1]); sum.2 += Double(rgba[index * 4 + 2])
        }
        let n = Double(inkCount)
        let inkColour = RGBAColor(red: sum.0 / n / 255, green: sum.1 / n / 255, blue: sum.2 / n / 255)

        // Crop to the ink, with a pixel of paper around it.
        var minX = columns, minY = rows, maxX = -1, maxY = -1
        for row in 0..<rows {
            for column in 0..<columns where ink[row * columns + column] {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        minX = max(0, minX - 1); minY = max(0, minY - 1)
        maxX = min(columns - 1, maxX + 1); maxY = min(rows - 1, maxY + 1)
        let boxWidth = Double(maxX - minX + 1), boxHeight = Double(maxY - minY + 1)

        let loops = traceLoops(ink, columns: columns, rows: rows)
        // Unit space, y up: image rows run top-down.
        func unit(_ point: (Int, Int)) -> PDFPoint {
            PDFPoint(x: (Double(point.0) - Double(minX)) / boxWidth, y: 1 - (Double(point.1) - Double(minY)) / boxHeight)
        }
        var outers: [[PDFPoint]] = []
        var holes: [[PDFPoint]] = []
        for loop in loops {
            let simplified = simplify(loop.map(unit), tolerance: 0.6 / max(boxWidth, boxHeight))
            guard simplified.count >= 3 else { continue }
            // Ink on the left of every traced edge: outlines run counter-clockwise, holes clockwise.
            if signedArea(simplified) > 0 { outers.append(simplified) } else { holes.append(simplified) }
        }
        var regions = outers.map { ArtworkRegion(outer: $0) }
        for hole in holes {
            guard let probe = hole.first else { continue }
            // The smallest outline that contains the hole owns it.
            let owner = regions.indices
                .filter { contains(regions[$0].outer, probe) }
                .min { abs(signedArea(regions[$0].outer)) < abs(signedArea(regions[$1].outer)) }
            if let owner { regions[owner].holes.append(hole) }
        }
        let geometry = ArtworkGeometry(kind: .vector, regions: regions, sourceAspectRatio: boxWidth / boxHeight)
        if let violation = geometry.limitViolation() { throw violation }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ImportedArtwork(
            geometry: geometry, digest: digest, sourceBytes: bytes, sourceName: sourceName,
            pixelWidth: width, pixelHeight: height, sourceInk: inkColour
        )
    }

    // MARK: - Steps, internal for the tests

    /// Otsu's threshold: the level that best separates the two classes of a bimodal histogram.
    static func otsuThreshold(_ values: [UInt8]) -> UInt8 {
        var histogram = [Double](repeating: 0, count: 256)
        for value in values { histogram[Int(value)] += 1 }
        let total = Double(values.count)
        var sum = 0.0
        for level in 0..<256 { sum += Double(level) * histogram[level] }
        var sumBackground = 0.0, weightBackground = 0.0, best = 0.0, threshold = 128
        for level in 0..<256 {
            weightBackground += histogram[level]
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(level) * histogram[level]
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sum - sumBackground) / weightForeground
            let between = weightBackground * weightForeground * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if between > best { best = between; threshold = level + 1 }
        }
        return UInt8(min(255, threshold))
    }

    /// Clears 4-connected ink shapes smaller than `minimum` pixels.
    static func removeSpecks(_ ink: inout [Bool], columns: Int, rows: Int, minimum: Int) {
        var seen = [Bool](repeating: false, count: ink.count)
        var stack: [Int] = []
        for start in ink.indices where ink[start] && !seen[start] {
            var shape: [Int] = []
            stack.append(start)
            seen[start] = true
            while let index = stack.popLast() {
                shape.append(index)
                let x = index % columns, y = index / columns
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                    let next = ny * columns + nx
                    if ink[next] && !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
            if shape.count < minimum { for index in shape { ink[index] = false } }
        }
    }

    /// Every boundary between ink and paper as closed loops of pixel-corner points, each edge
    /// directed with the ink on its visual left: counter-clockwise around ink as seen on screen,
    /// so an outline has positive signed area once y is flipped up, and a hole negative.
    static func traceLoops(_ ink: [Bool], columns: Int, rows: Int) -> [[(Int, Int)]] {
        func isInk(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < columns && y < rows && ink[y * columns + x] }
        // Directed edges keyed by their start corner.
        var outgoing: [Int: [(Int, Int)]] = [:]
        func key(_ x: Int, _ y: Int) -> Int { y * (columns + 1) + x }
        func add(_ from: (Int, Int), _ to: (Int, Int)) { outgoing[key(from.0, from.1), default: []].append(to) }
        for y in 0..<rows {
            for x in 0..<columns where ink[y * columns + x] {
                // Walk each ink pixel's exposed sides so the ink stays on the same hand.
                if !isInk(x, y - 1) { add((x + 1, y), (x, y)) }         // top, right → left
                if !isInk(x - 1, y) { add((x, y), (x, y + 1)) }         // left, top → bottom
                if !isInk(x, y + 1) { add((x, y + 1), (x + 1, y + 1)) } // bottom, left → right
                if !isInk(x + 1, y) { add((x + 1, y + 1), (x + 1, y)) } // right, bottom → top
            }
        }
        var loops: [[(Int, Int)]] = []
        while let (startKey, ends) = outgoing.first(where: { !$0.value.isEmpty }) {
            let start = (startKey % (columns + 1), startKey / (columns + 1))
            var loop: [(Int, Int)] = [start]
            var current = start
            var previous: (Int, Int)? = nil
            var next = ends[0]
            outgoing[startKey]?.removeFirst()
            var guardSteps = 0
            while !(next.0 == start.0 && next.1 == start.1) && guardSteps < 4_000_000 {
                guardSteps += 1
                previous = current
                current = next
                loop.append(current)
                let k = key(current.0, current.1)
                guard var candidates = outgoing[k], !candidates.isEmpty else { break }
                // At a corner two shapes touch diagonally: keep turning the same way, so each
                // shape closes on itself rather than crossing into the other.
                var pick = 0
                if candidates.count > 1, let previous {
                    let incoming = (current.0 - previous.0, current.1 - previous.1)
                    pick = candidates.indices.min { a, b in
                        turn(incoming, (candidates[a].0 - current.0, candidates[a].1 - current.1))
                            < turn(incoming, (candidates[b].0 - current.0, candidates[b].1 - current.1))
                    } ?? 0
                }
                next = candidates.remove(at: pick)
                outgoing[k] = candidates
            }
            if loop.count >= 4 { loops.append(loop) }
            outgoing = outgoing.filter { !$0.value.isEmpty }
        }
        return loops
    }

    /// 0 for a right turn, 1 straight on, 2 left, 3 back (image coordinates).
    private static func turn(_ a: (Int, Int), _ b: (Int, Int)) -> Int {
        let cross = a.0 * b.1 - a.1 * b.0
        let dot = a.0 * b.0 + a.1 * b.1
        if cross > 0 { return 0 }
        if cross == 0 && dot > 0 { return 1 }
        if cross < 0 { return 2 }
        return 3
    }

    /// Douglas–Peucker on a closed ring.
    static func simplify(_ ring: [PDFPoint], tolerance: Double) -> [PDFPoint] {
        guard ring.count > 4 else { return ring }
        func distance(_ p: PDFPoint, _ a: PDFPoint, _ b: PDFPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot() }
            return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
        }
        func reduce(_ points: ArraySlice<PDFPoint>) -> [PDFPoint] {
            guard points.count > 2, let first = points.first, let last = points.last else { return Array(points) }
            var worst = 0.0, index = points.startIndex
            for i in points.index(after: points.startIndex)..<points.index(before: points.endIndex) {
                let d = distance(points[i], first, last)
                if d > worst { worst = d; index = i }
            }
            guard worst > tolerance else { return [first, last] }
            let left = reduce(points[points.startIndex...index])
            let right = reduce(points[index..<points.endIndex])
            return Array(left.dropLast()) + right
        }
        // Split the ring at its farthest point from the start, so both halves are open chains.
        let start = ring[0]
        let far = ring.indices.max { a, b in
            let da = (ring[a].x - start.x) * (ring[a].x - start.x) + (ring[a].y - start.y) * (ring[a].y - start.y)
            let db = (ring[b].x - start.x) * (ring[b].x - start.x) + (ring[b].y - start.y) * (ring[b].y - start.y)
            return da < db
        } ?? ring.count / 2
        let first = reduce(ring[0...far])
        let second = reduce((ring[far...] + [start])[...])
        return Array((first.dropLast() + second).dropLast())
    }

    static func signedArea(_ ring: [PDFPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var area = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    static func contains(_ ring: [PDFPoint], _ point: PDFPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
