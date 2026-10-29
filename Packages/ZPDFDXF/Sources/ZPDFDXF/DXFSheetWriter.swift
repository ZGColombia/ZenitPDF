import Compression
import Foundation

/// A DXF drawn as one PDF sheet.
public struct DXFSheet: Sendable {
    /// The PDF bytes: one page, one optional content group (layer) per DXF layer.
    public let pdf: Data
    /// The sheet is drawn at 1 : `scaleDenominator` (model millimetres per paper millimetre).
    public let scaleDenominator: Int
    /// `true` when `$INSUNITS` named a real unit, so the scale is a fact about the file. `false`
    /// for a unitless drawing: it is drawn as if one unit were a millimetre, and must be calibrated.
    public let scaleIsFromFile: Bool
    public let unit: DXFUnit
    public let pageSizePoints: (width: Double, height: Double)
    public let layers: [String]
    public let skipped: [String: Int]
    /// Where a model point lands on the page, in PDF points (for tests and for placing things).
    public let transform: @Sendable (DXFPoint) -> (x: Double, y: Double)
}

/// Writes a ``DXFDrawing`` as a vector PDF sheet at a standard drawing scale.
public enum DXFSheetWriter {

    /// Standard drawing scales, smallest reduction first.
    public static let standardDenominators = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000, 1_250, 2_000, 2_500, 5_000, 10_000, 20_000, 50_000, 100_000]

    public struct Options: Sendable {
        /// The largest sheet the scale is chosen to fit (A0 landscape by default), in millimetres.
        public var maximumSheetMillimetres: (width: Double, height: Double) = (1_189, 841)
        public var marginMillimetres: Double = 10
        /// Force a scale instead of choosing one.
        public var scaleDenominator: Int?
        /// Flate-compress the content stream. Off for tests that read the stream.
        public var compress = true
        public init() {}
    }

    /// Throws `CancellationError` when the calling task is cancelled: every 1,024 entities, and
    /// every 4,096 points inside one polyline (S-119). It had no cancellation point, so a drawing
    /// the reader's point budget accepts could outrun the geometry service's deadline and was
    /// ended only by the wedge watchdog killing the service.
    public static func write(_ drawing: DXFDrawing, title: String, options: Options = Options()) throws -> DXFSheet {
        let unitMillimetres = drawing.unit.millimetres ?? 1
        // Extents in millimetres, from what is actually drawn.
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func include(_ p: DXFPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for (index, entity) in drawing.entities.enumerated() {
            if index & 1_023 == 0 { try Task.checkCancellation() }
            switch entity.shape {
            case let .polyline(points, _, _): points.forEach(include)
            case let .arc(center, radius, _, _), let .circle(center, radius):
                include(.init(x: center.x - radius, y: center.y - radius)); include(.init(x: center.x + radius, y: center.y + radius))
            case let .ellipse(center, major, _, _, _):
                let r = hypot(major.x, major.y)
                include(.init(x: center.x - r, y: center.y - r)); include(.init(x: center.x + r, y: center.y + r))
            case let .text(position, height, _, string):
                include(position); include(.init(x: position.x + height * Double(string.count) * 0.6, y: position.y + height))
            }
        }
        if !minX.isFinite { minX = 0; minY = 0; maxX = 1; maxY = 1 }
        let widthMM = max((maxX - minX) * unitMillimetres, 1e-6), heightMM = max((maxY - minY) * unitMillimetres, 1e-6)
        let (sheetW, sheetH) = options.maximumSheetMillimetres
        let usableW = sheetW - 2 * options.marginMillimetres, usableH = sheetH - 2 * options.marginMillimetres
        let denominator = options.scaleDenominator ?? standardDenominators.first { d in
            let (w, h) = (widthMM / Double(d), heightMM / Double(d))
            return (w <= usableW && h <= usableH) || (w <= usableH && h <= usableW)
        } ?? standardDenominators.last!
        let scale = Double(denominator)
        let margin = options.marginMillimetres
        let pageW = (widthMM / scale + 2 * margin) / 25.4 * 72
        let pageH = (heightMM / scale + 2 * margin) / 25.4 * 72
        let originX = minX, originY = minY
        let transform: @Sendable (DXFPoint) -> (x: Double, y: Double) = { p in
            (((p.x - originX) * unitMillimetres / scale + margin) / 25.4 * 72,
             ((p.y - originY) * unitMillimetres / scale + margin) / 25.4 * 72)
        }
        let pointsPerUnit = unitMillimetres / scale / 25.4 * 72

        var content = "0 G 0 g 0.25 w 1 J 1 j\n"
        // Grouped once, in entity order within each layer (R-194). Filtering every entity per
        // layer was O(layers × entities): some 10^8 string comparisons for a million entities
        // over a few hundred layers.
        let byLayer = Dictionary(grouping: drawing.entities, by: \.layer)
        var drawn = 0
        for (layerIndex, layer) in drawing.layers.enumerated() {
            content += "/OC /L\(layerIndex) BDC\n"
            for entity in byLayer[layer] ?? [] {
                if drawn & 1_023 == 0 { try Task.checkCancellation() }
                drawn += 1
                content += try path(for: entity.shape, transform: transform, pointsPerUnit: pointsPerUnit)
            }
            content += "EMC\n"
        }
        let pdf = PDFAssembler.assemble(
            pageSize: (pageW, pageH), content: Data(content.utf8), layers: drawing.layers, title: title, compress: options.compress)
        return DXFSheet(pdf: pdf, scaleDenominator: denominator, scaleIsFromFile: drawing.unitDeclared && drawing.unit != .unitless,
                        unit: drawing.unit, pageSizePoints: (pageW, pageH), layers: drawing.layers, skipped: drawing.skipped,
                        transform: transform)
    }

    // MARK: - Paths

    /// A PDF number: six decimals, trailing zeros and a bare point trimmed, never "-0".
    ///
    /// Fixed-point by hand (S-119). `String(format: "%.6f", locale:)` cost about 10 µs a call —
    /// measured, and the `Locale` was not the cost — and it runs twice per polyline point, so
    /// some 1.5 M points spent the geometry service's whole 30 s deadline formatting. The
    /// magnitude is rounded to millionths half away from zero; `%.6f` rounds the exact binary
    /// value, so the two can differ by one millionth of a point on an exact tie, which no sheet
    /// can show. Beyond 10^12 (no real sheet) the old formatter still answers.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let magnitude = abs(value)
        guard magnitude < 1e12 else {
            var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
            while text.contains("."), text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        let micros = Int64((magnitude * 1_000_000).rounded())
        guard micros != 0 else { return "0" }
        let whole = micros / 1_000_000
        var fraction = micros % 1_000_000
        var text = value < 0 ? "-" : ""
        text += String(whole)
        if fraction != 0 {
            var digits = 6
            while fraction % 10 == 0 { fraction /= 10; digits -= 1 }
            let written = String(fraction)
            text += "."
            if written.count < digits { text += String(repeating: "0", count: digits - written.count) }
            text += written
        }
        return text
    }

    static func path(for shape: DXFShape, transform: (DXFPoint) -> (x: Double, y: Double), pointsPerUnit: Double) throws -> String {
        func point(_ p: DXFPoint) -> String { let t = transform(p); return "\(number(t.x)) \(number(t.y))" }
        switch shape {
        case let .polyline(points, bulges, closed):
            guard let first = points.first else { return "" }
            var out = "\(point(first)) m\n"
            let segments = closed ? points.count : points.count - 1
            for i in 0..<segments {
                if i & 4_095 == 4_095 { try Task.checkCancellation() }
                let p = points[i], q = points[(i + 1) % points.count]
                let bulge = i < bulges.count ? bulges[i] : 0
                if bulge == 0 || !bulge.isFinite {
                    out += "\(point(q)) l\n"
                } else {
                    out += bulgeCurves(from: p, to: q, bulge: bulge, point: point)
                }
            }
            return out + (closed ? "h S\n" : "S\n")
        case let .arc(center, radius, start, end):
            let sweep = dxfSweep(from: start, to: end)
            guard sweep > 0 else { return "" }
            return arcCurves(center: center, radius: radius, start: dxfAngle(start), sweep: sweep, point: point, moveFirst: true) + "S\n"
        case let .circle(center, radius):
            return arcCurves(center: center, radius: radius, start: 0, sweep: 2 * .pi, point: point, moveFirst: true) + "h S\n"
        case let .ellipse(center, major, ratio, start, end):
            let sweep = dxfSweep(from: start, to: end)
            guard sweep > 0 else { return "" }
            let minor = DXFPoint(x: -major.y * ratio, y: major.x * ratio)
            // An ellipse is the affine image of the unit circle: map the circle's Bézier control points.
            let map: (DXFPoint) -> DXFPoint = { u in
                DXFPoint(x: center.x + major.x * u.x + minor.x * u.y, y: center.y + major.y * u.x + minor.y * u.y)
            }
            return arcCurves(center: .init(x: 0, y: 0), radius: 1, start: dxfAngle(start), sweep: sweep, point: { point(map($0)) }, moveFirst: true) + "S\n"
        case let .text(position, height, rotation, string):
            let t = transform(position)
            let size = height * pointsPerUnit
            guard size > 0.01 else { return "" }
            let (c, s) = (cos(rotation), sin(rotation))
            var lines = string.components(separatedBy: "\n")
            if lines.isEmpty { lines = [string] }
            var out = ""
            for (index, line) in lines.enumerated() {
                let dy = -Double(index) * size * 1.2
                let x = t.x - s * dy, y = t.y + c * dy
                out += "BT /F1 \(number(size)) Tf \(number(c)) \(number(s)) \(number(-s)) \(number(c)) \(number(x)) \(number(y)) Tm (\(PDFAssembler.escape(line))) Tj ET\n"
            }
            return out
        }
    }

    /// Cubic Bézier pieces of at most 90° each (k = 4/3 tan(θ/4) per piece).
    static func arcCurves(center: DXFPoint, radius: Double, start: Double, sweep: Double, point: (DXFPoint) -> String, moveFirst: Bool) -> String {
        guard sweep.isFinite, abs(sweep) <= 4 * .pi else { return "" }
        let pieces = max(1, Int(ceil(abs(sweep) / (.pi / 2))))
        let step = sweep / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out = ""
        var angle = start
        func at(_ a: Double) -> DXFPoint { DXFPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)) }
        if moveFirst { out += "\(point(at(angle))) m\n" }
        for _ in 0..<pieces {
            let next = angle + step
            let p0 = at(angle), p3 = at(next)
            let p1 = DXFPoint(x: p0.x - k * radius * sin(angle), y: p0.y + k * radius * cos(angle))
            let p2 = DXFPoint(x: p3.x + k * radius * sin(next), y: p3.y - k * radius * cos(next))
            out += "\(point(p1)) \(point(p2)) \(point(p3)) c\n"
            angle = next
        }
        return out
    }

    static func bulgeCurves(from p: DXFPoint, to q: DXFPoint, bulge: Double, point: (DXFPoint) -> String) -> String {
        let theta = 4 * atan(bulge)
        let chord = hypot(q.x - p.x, q.y - p.y)
        guard chord > 0, abs(theta) > 1e-12 else { return "\(point(q)) l\n" }
        let radius = chord / (2 * sin(abs(theta) / 2))
        let mid = DXFPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        let offset = radius * cos(abs(theta) / 2)
        let normal = DXFPoint(x: -(q.y - p.y) / chord, y: (q.x - p.x) / chord)
        let direction = theta > 0 ? 1.0 : -1.0
        let center = DXFPoint(x: mid.x + normal.x * offset * direction, y: mid.y + normal.y * offset * direction)
        let start = atan2(p.y - center.y, p.x - center.x)
        return arcCurves(center: center, radius: radius, start: start, sweep: theta, point: point, moveFirst: false)
    }
}

/// A minimal PDF 1.7 writer: one page, Helvetica, and optional content groups.
enum PDFAssembler {

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "(": out += "\\("
            case ")": out += "\\)"
            default:
                if scalar.value >= 32, scalar.value < 127 { out.unicodeScalars.append(scalar) }
                else if let byte = windows1252[scalar.value] { out += String(format: "\\%03o", byte) }
                else { out += "?" }
            }
        }
        return out
    }

    /// The Latin-1 range plus the common WinAnsi extras (en/em dash, quotes, euro, bullet).
    static let windows1252: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        for value in UInt32(160)...UInt32(255) { map[value] = UInt8(value) }
        let extras: [UInt32: UInt8] = [0x20AC: 0x80, 0x2013: 0x96, 0x2014: 0x97, 0x2018: 0x91, 0x2019: 0x92,
                                       0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2026: 0x85, 0x00D8: 0xD8]
        for (key, value) in extras { map[key] = value }
        return map
    }()

    static func literal(_ text: String) -> String { "(" + escape(text) + ")" }

    static func assemble(pageSize: (Double, Double), content: Data, layers: [String], title: String, compress: Bool) -> Data {
        var objects: [Data] = []
        let layerBase = 7   // 1 catalog, 2 pages, 3 page, 4 font, 5 contents, 6 info
        let layerRefs = layers.indices.map { "\(layerBase + $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [\(layerRefs)] /D << /Order [\(layerRefs)] /ON [\(layerRefs)] /BaseState /ON >> >> >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        let properties = layers.indices.map { "/L\($0) \(layerBase + $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(DXFSheetWriter.number(pageSize.0)) \(DXFSheetWriter.number(pageSize.1))] /Resources << /Font << /F1 4 0 R >> /Properties << \(properties) >> >> /Contents 5 0 R >>".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        var stream = content
        var filter = ""
        if compress, let deflated = zlib(content) {
            stream = deflated
            filter = " /Filter /FlateDecode"
        }
        var contents = Data("<< /Length \(stream.count)\(filter) >>\nstream\n".utf8)
        contents.append(stream)
        contents.append(Data("\nendstream".utf8))
        objects.append(contents)
        objects.append(Data("<< /Title \(literal(title)) /Producer (Zenit PDF DXF intake) >>".utf8))
        for layer in layers { objects.append(Data("<< /Type /OCG /Name \(literal(layer)) >>".utf8)) }

        var pdf = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        // `%ld`, not `%d`: `%d` reads 32 bits and wrapped an offset past 2 GiB (T-044).
        for offset in offsets { table += String(format: "%010ld 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 6 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    /// zlib (RFC 1950): header, raw DEFLATE from `Compression`, Adler-32.
    static func zlib(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var buffer = Data(count: capacity)
        let written = data.withUnsafeBytes { source in
            buffer.withUnsafeMutableBytes { destination in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        buffer.count = written
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { bytes in
            for byte in bytes { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        }
        var out = Data([0x78, 0x9C])
        out.append(buffer)
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}
