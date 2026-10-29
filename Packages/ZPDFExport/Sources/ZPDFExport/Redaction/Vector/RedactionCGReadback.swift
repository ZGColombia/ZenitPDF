import CoreGraphics
import Foundation

/// Reads a redacted copy back through Core Graphics' own PDF parser (`CGPDFScanner`) — not
/// through the object layer that wrote it — and reports every path, glyph and image sample that
/// still lies inside a box, plus the page's text for the word checks (ADR-0033 §6).
///
/// A rewriter checked only by its own reader could agree with itself about a mistake; this
/// reader shares nothing with the writer's parser.
enum RedactionCGReadback {

    struct Result {
        var text = ""
        var violations: [String] = []
    }

    /// The tolerance a kept object may touch a box edge by, in points.
    static let edgeTolerance = 0.01

    static func scan(page: CGPDFPage, boxes: [CGRect]) -> Result {
        let state = State(boxes: boxes.map { $0.insetBy(dx: edgeTolerance, dy: edgeTolerance) })
        state.clip = page.getBoxRect(.cropBox)
        guard let table = makeTable() else { return Result(text: "", violations: ["the copy cannot be scanned"]) }
        state.table = table
        let content = CGPDFContentStreamCreateWithPage(page)
        state.contentStreams.append(content)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return Result(text: state.text, violations: state.violations)
    }

    // MARK: - State

    /// What `q` saves besides the CTM and text state: the clip's bounds, the colours (a pattern
    /// name when a pattern colour is set), the line width.
    struct Paint {
        var clip = CGRect.infinite
        var fillSpaceIsPattern = false
        var strokeSpaceIsPattern = false
        var fillPattern: String?
        var strokePattern: String?
        var lineWidth = 1.0
        var pendingClip = false
    }

    final class State {
        let boxes: [CGRect]
        var ctm = CGAffineTransform.identity
        var paint = Paint()
        var clip: CGRect {
            get { paint.clip }
            set { paint.clip = newValue }
        }
        /// Pattern space → page for patterns painted in the current stream.
        var patternBase = CGAffineTransform.identity
        var stack: [(CGAffineTransform, TextParameters, Paint)] = []
        var subpaths: [RedactionSubpath] = []
        var current: CGPoint?
        var text = ""
        var violations: [String] = []
        var contentStreams: [CGPDFContentStreamRef] = []
        var textParameters = TextParameters()
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var fonts: [String: RedactionFont?] = [:]
        var depth = 0
        var table: CGPDFOperatorTableRef?

        init(boxes: [CGRect]) { self.boxes = boxes }

        func violation(_ sentence: String) {
            if !violations.contains(sentence) { violations.append(sentence) }
        }
    }

    struct TextParameters {
        var charSpacing = 0.0, wordSpacing = 0.0, scale = 1.0, leading = 0.0, size = 0.0, rise = 0.0
        var fontName: String?
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> State {
        Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
        var values: [Double] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.append(Double(value))
        }
        return values.reversed()
    }

    private static func name(_ scanner: CGPDFScannerRef) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    // MARK: - The operator table

    private static func makeTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        func on(_ name: String, _ callback: @escaping CGPDFOperatorCallback) {
            name.withCString { CGPDFOperatorTableSetCallback(table, $0, callback) }
        }
        on("q") { _, info in let s = RedactionCGReadback.state(info); s.stack.append((s.ctm, s.textParameters, s.paint)) }
        on("Q") { _, info in
            let s = RedactionCGReadback.state(info)
            if let (ctm, text, paint) = s.stack.popLast() { s.ctm = ctm; s.textParameters = text; s.paint = paint }
        }
        on("w") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).paint.lineWidth = v[0] } }
        on("W") { _, info in RedactionCGReadback.state(info).paint.pendingClip = true }
        on("W*") { _, info in RedactionCGReadback.state(info).paint.pendingClip = true }
        on("cs") { scanner, info in
            let s = RedactionCGReadback.state(info)
            s.paint.fillSpaceIsPattern = RedactionCGReadback.isPatternSpace(s, RedactionCGReadback.name(scanner))
            s.paint.fillPattern = nil
        }
        on("CS") { scanner, info in
            let s = RedactionCGReadback.state(info)
            s.paint.strokeSpaceIsPattern = RedactionCGReadback.isPatternSpace(s, RedactionCGReadback.name(scanner))
            s.paint.strokePattern = nil
        }
        on("scn") { scanner, info in
            let s = RedactionCGReadback.state(info)
            s.paint.fillPattern = s.paint.fillSpaceIsPattern ? RedactionCGReadback.name(scanner) : nil
        }
        on("SCN") { scanner, info in
            let s = RedactionCGReadback.state(info)
            s.paint.strokePattern = s.paint.strokeSpaceIsPattern ? RedactionCGReadback.name(scanner) : nil
        }
        for device in ["g", "rg", "k"] {
            on(device) { _, info in let s = RedactionCGReadback.state(info); s.paint.fillSpaceIsPattern = false; s.paint.fillPattern = nil }
        }
        for device in ["G", "RG", "K"] {
            on(device) { _, info in let s = RedactionCGReadback.state(info); s.paint.strokeSpaceIsPattern = false; s.paint.strokePattern = nil }
        }
        on("sh") { scanner, info in
            guard let shading = RedactionCGReadback.name(scanner) else { return }
            RedactionCGReadback.checkShading(RedactionCGReadback.state(info), named: shading)
        }
        on("cm") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 6) else { return }
            let s = RedactionCGReadback.state(info)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        on("m") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 2) else { return }
            let s = RedactionCGReadback.state(info), p = CGPoint(x: v[0], y: v[1]).applying(s.ctm)
            s.subpaths.append(RedactionSubpath(start: p, segments: [], closed: false))
            s.current = p
        }
        on("l") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 2) else { return }
            let s = RedactionCGReadback.state(info), p = CGPoint(x: v[0], y: v[1]).applying(s.ctm)
            RedactionCGReadback.appendSegment(s, .line(s.current ?? p, p))
            s.current = p
        }
        on("c") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 6) else { return }
            let s = RedactionCGReadback.state(info)
            let p1 = CGPoint(x: v[0], y: v[1]).applying(s.ctm), p2 = CGPoint(x: v[2], y: v[3]).applying(s.ctm)
            let p3 = CGPoint(x: v[4], y: v[5]).applying(s.ctm)
            RedactionCGReadback.appendSegment(s, .cubic(s.current ?? p1, p1, p2, p3))
            s.current = p3
        }
        on("v") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 4) else { return }
            let s = RedactionCGReadback.state(info)
            let p2 = CGPoint(x: v[0], y: v[1]).applying(s.ctm), p3 = CGPoint(x: v[2], y: v[3]).applying(s.ctm)
            let p0 = s.current ?? p2
            RedactionCGReadback.appendSegment(s, .cubic(p0, p0, p2, p3))
            s.current = p3
        }
        on("y") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 4) else { return }
            let s = RedactionCGReadback.state(info)
            let p1 = CGPoint(x: v[0], y: v[1]).applying(s.ctm), p3 = CGPoint(x: v[2], y: v[3]).applying(s.ctm)
            RedactionCGReadback.appendSegment(s, .cubic(s.current ?? p1, p1, p3, p3))
            s.current = p3
        }
        on("h") { _, info in
            let s = RedactionCGReadback.state(info)
            if let last = s.subpaths.last, let first = last.segments.first, let end = last.segments.last?.end {
                RedactionCGReadback.appendSegment(s, .line(end, first.start))
                s.current = first.start
            }
        }
        on("re") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 4) else { return }
            let s = RedactionCGReadback.state(info)
            let corners = [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1] + v[3]),
                           CGPoint(x: v[0], y: v[1] + v[3])].map { $0.applying(s.ctm) }
            s.subpaths.append(RedactionSubpath(start: corners[0], segments: (0..<4).map { .line(corners[$0], corners[($0 + 1) % 4]) }, closed: true))
            s.current = corners[0]
        }
        // Which paint operators fill and which stroke, for the pattern each uses.
        for paint in ["f", "F", "f*"] {
            on(paint) { _, info in RedactionCGReadback.checkPath(RedactionCGReadback.state(info), fills: true, strokes: false) }
        }
        for paint in ["S", "s"] {
            on(paint) { _, info in RedactionCGReadback.checkPath(RedactionCGReadback.state(info), fills: false, strokes: true) }
        }
        for paint in ["B", "B*", "b", "b*"] {
            on(paint) { _, info in RedactionCGReadback.checkPath(RedactionCGReadback.state(info), fills: true, strokes: true) }
        }
        on("n") { _, info in RedactionCGReadback.checkPath(RedactionCGReadback.state(info), fills: false, strokes: false) }

        // Text.
        on("BT") { _, info in let s = RedactionCGReadback.state(info); s.textMatrix = .identity; s.lineMatrix = .identity; s.text += " " }
        on("Tc") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).textParameters.charSpacing = v[0] } }
        on("Tw") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).textParameters.wordSpacing = v[0] } }
        on("Tz") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).textParameters.scale = v[0] / 100 } }
        on("TL") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).textParameters.leading = v[0] } }
        on("Ts") { scanner, info in if let v = RedactionCGReadback.numbers(scanner, 1) { RedactionCGReadback.state(info).textParameters.rise = v[0] } }
        on("Tf") { scanner, info in
            let s = RedactionCGReadback.state(info)
            guard let v = RedactionCGReadback.numbers(scanner, 1), let font = RedactionCGReadback.name(scanner) else { return }
            s.textParameters.size = v[0]
            s.textParameters.fontName = font
        }
        on("Td") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 2) else { return }
            let s = RedactionCGReadback.state(info)
            s.lineMatrix = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(s.lineMatrix)
            s.textMatrix = s.lineMatrix
            s.text += " "
        }
        on("TD") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 2) else { return }
            let s = RedactionCGReadback.state(info)
            s.textParameters.leading = -v[1]
            s.lineMatrix = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(s.lineMatrix)
            s.textMatrix = s.lineMatrix
            s.text += " "
        }
        on("Tm") { scanner, info in
            guard let v = RedactionCGReadback.numbers(scanner, 6) else { return }
            let s = RedactionCGReadback.state(info)
            s.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.textMatrix = s.lineMatrix
            s.text += " "
        }
        on("T*") { _, info in RedactionCGReadback.nextLine(RedactionCGReadback.state(info)) }
        on("Tj") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            RedactionCGReadback.show(RedactionCGReadback.state(info), [.string(RedactionCGReadback.bytes(string))])
        }
        on("'") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            let s = RedactionCGReadback.state(info)
            RedactionCGReadback.nextLine(s)
            RedactionCGReadback.show(s, [.string(RedactionCGReadback.bytes(string))])
        }
        on("\"") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string, let v = RedactionCGReadback.numbers(scanner, 2) else { return }
            let s = RedactionCGReadback.state(info)
            s.textParameters.wordSpacing = v[0]
            s.textParameters.charSpacing = v[1]
            RedactionCGReadback.nextLine(s)
            RedactionCGReadback.show(s, [.string(RedactionCGReadback.bytes(string))])
        }
        on("TJ") { scanner, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var elements: [PDFObject] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    elements.append(.string(RedactionCGReadback.bytes(string)))
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    elements.append(.real(Double(number)))
                }
            }
            RedactionCGReadback.show(RedactionCGReadback.state(info), elements)
        }

        // XObjects and inline images.
        on("Do") { scanner, info in
            guard let xobject = RedactionCGReadback.name(scanner) else { return }
            RedactionCGReadback.paintXObject(RedactionCGReadback.state(info), named: xobject)
        }
        on("EI") { scanner, info in
            var stream: CGPDFStreamRef?
            guard CGPDFScannerPopStream(scanner, &stream), let stream else { return }
            let s = RedactionCGReadback.state(info)
            RedactionCGReadback.checkImage(s, stream: stream, inline: true)
        }
        return table
    }

    private static func appendSegment(_ s: State, _ segment: RedactionSegment) {
        if s.subpaths.isEmpty { s.subpaths.append(RedactionSubpath(start: segment.start, segments: [], closed: false)) }
        s.subpaths[s.subpaths.count - 1].segments.append(segment)
    }

    private static func checkPath(_ s: State, fills: Bool, strokes: Bool) {
        defer { s.subpaths.removeAll(); s.current = nil; s.paint.pendingClip = false }
        let hull = s.subpaths.reduce(CGRect?.none) { partial, subpath in partial.map { $0.union(subpath.hull) } ?? subpath.hull }
        if s.paint.pendingClip { s.clip = hull.map { s.clip.intersection($0) } ?? .null }
        guard !s.boxes.isEmpty else { return }
        if let hull {
            if fills, let pattern = s.paint.fillPattern { checkPattern(s, named: pattern, area: hull) }
            if strokes, let pattern = s.paint.strokePattern {
                let scale = max(hypot(s.ctm.a, s.ctm.b), hypot(s.ctm.c, s.ctm.d))
                let half = max(s.paint.lineWidth, 1) * scale / 2 + 1
                checkPattern(s, named: pattern, area: hull.insetBy(dx: -half, dy: -half))
            }
        }
        for subpath in s.subpaths {
            // A black box itself: a filled rectangle lying exactly over one box. Where two boxes
            // overlap, its edges run inside the other one; it carries nothing but the box's own
            // place, and counting it refused every pair of overlapping boxes.
            if fills, !strokes, isBoxRectangle(subpath, s.boxes) { continue }
            if subpath.segments.isEmpty, s.boxes.contains(where: { $0.contains(subpath.start) && $0.minX < subpath.start.x && $0.minY < subpath.start.y }) {
                s.violation("a path point remains inside a box")
            }
            for segment in subpath.segments {
                var pieces = [segment]
                for box in s.boxes { pieces = pieces.flatMap { RedactionGeometry.split($0, at: box) } }
                if pieces.contains(where: { piece in s.boxes.contains { RedactionGeometry.isInside(piece, $0) } }) {
                    s.violation("a path still runs inside a box")
                    return
                }
            }
        }
    }

    /// Whether `subpath` is a closed axis-aligned rectangle equal to one of `boxes` (which are
    /// inset by ``edgeTolerance``).
    private static func isBoxRectangle(_ subpath: RedactionSubpath, _ boxes: [CGRect]) -> Bool {
        guard subpath.closed, subpath.segments.count == 4 else { return false }
        for segment in subpath.segments {
            guard case let .line(a, b) = segment, abs(a.x - b.x) < 1e-6 || abs(a.y - b.y) < 1e-6 else { return false }
        }
        let hull = subpath.hull
        return boxes.contains { box in
            let outer = box.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
            return abs(hull.minX - outer.minX) < 0.01 && abs(hull.minY - outer.minY) < 0.01
                && abs(hull.maxX - outer.maxX) < 0.01 && abs(hull.maxY - outer.maxY) < 0.01
        }
    }

    // MARK: - Text

    private static func bytes(_ string: CGPDFStringRef) -> [UInt8] {
        guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
    }

    private static func nextLine(_ s: State) {
        s.lineMatrix = CGAffineTransform(translationX: 0, y: -s.textParameters.leading).concatenating(s.lineMatrix)
        s.textMatrix = s.lineMatrix
        s.text += " "
    }

    private static func font(_ s: State) -> RedactionFont? {
        guard let name = s.textParameters.fontName, let content = s.contentStreams.last else { return nil }
        let key = "\(UInt(bitPattern: UnsafeRawPointer(content)))/\(name)"
        if let cached = s.fonts[key] { return cached }
        var font: RedactionFont?
        if let object = CGPDFContentStreamGetResource(content, "Font", name),
           case let .dictionary(dictionary)? = RedactionCGObjects.convert(object) {
            font = try? RedactionFont(dictionary: dictionary, resolve: { $0 })
        }
        s.fonts[key] = font
        return font
    }

    private static func show(_ s: State, _ elements: [PDFObject]) {
        let p = s.textParameters
        let font = font(s)
        for element in elements {
            if let adjustment = element.doubleValue {
                s.textMatrix = CGAffineTransform(translationX: -adjustment / 1000 * p.size * p.scale, y: 0).concatenating(s.textMatrix)
                if adjustment < -200 { s.text += " " }
                continue
            }
            guard case let .string(bytes) = element else { continue }
            guard let font, let codes = try? font.codes(bytes) else {
                // No usable metrics: the text is still read, byte for byte, for the word checks.
                s.text += String(bytes.map { Character(UnicodeScalar($0)) })
                if !s.boxes.isEmpty { s.violation("text in a font the readback cannot measure is shown on a redacted sheet") }
                continue
            }
            for code in codes {
                let width = font.width(code)
                let spacing = p.charSpacing + (font.takesWordSpacing(code) ? p.wordSpacing : 0)
                if !s.boxes.isEmpty {
                    let glyph = font.box(code)
                    let toPage = CGAffineTransform(a: p.size * p.scale, b: 0, c: 0, d: p.size, tx: 0, ty: p.rise)
                        .concatenating(s.textMatrix).concatenating(s.ctm)
                    let corners = [CGPoint(x: glyph.minX, y: glyph.minY), CGPoint(x: glyph.maxX, y: glyph.minY),
                                   CGPoint(x: glyph.maxX, y: glyph.maxY), CGPoint(x: glyph.minX, y: glyph.maxY)].map { $0.applying(toPage) }
                    if s.boxes.contains(where: { RedactionContentRewriter.quad(corners, intersects: $0) }) {
                        s.violation("a glyph remains under a box")
                    }
                }
                s.text += font.unicode(code) ?? ""
                s.textMatrix = CGAffineTransform(translationX: (width * p.size + spacing) * p.scale, y: 0).concatenating(s.textMatrix)
            }
        }
    }

    // MARK: - XObjects

    private static func paintXObject(_ s: State, named xobject: String) {
        guard let content = s.contentStreams.last, let object = CGPDFContentStreamGetResource(content, "XObject", xobject) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            checkImage(s, stream: stream, inline: false)
        case "Form":
            guard s.depth < 24, let table = s.table else { return }
            var matrix = CGAffineTransform.identity
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                for index in 0..<6 { CGPDFArrayGetNumber(array, index, &v[index]) }
                matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let saved = (s.ctm, s.textParameters, s.paint, s.patternBase)
            s.ctm = matrix.concatenating(s.ctm)
            s.patternBase = s.ctm
            var bbox: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "BBox", &bbox), let bbox, CGPDFArrayGetCount(bbox) == 4 {
                var v = [CGPDFReal](repeating: 0, count: 4)
                for index in 0..<4 { CGPDFArrayGetNumber(bbox, index, &v[index]) }
                let rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
                s.clip = s.clip.intersection(rect.applying(s.ctm))
            }
            s.depth += 1
            // A form without resources sees its parent's; the C API wants a dictionary, and
            // lookups in the stream's own fall through to the parent.
            let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
            s.contentStreams.append(inner)
            let scanner = CGPDFScannerCreate(inner, table, Unmanaged.passUnretained(s).toOpaque())
            _ = CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(inner)
            s.contentStreams.removeLast()
            s.depth -= 1
            (s.ctm, s.textParameters, s.paint, s.patternBase) = saved
        default:
            return
        }
    }

    private static func isPatternSpace(_ s: State, _ name: String?) -> Bool {
        guard let name else { return false }
        if name == "Pattern" { return true }
        guard ["DeviceGray", "DeviceRGB", "DeviceCMYK"].contains(name) == false, let content = s.contentStreams.last,
              let object = CGPDFContentStreamGetResource(content, "ColorSpace", name), let space = RedactionCGObjects.convert(object) else { return false }
        return space.nameValue == "Pattern" || space.arrayValue?.first?.nameValue == "Pattern"
    }

    private static func numbers(_ dictionary: CGPDFDictionaryRef, _ key: String, count: Int) -> [Double]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == count else { return nil }
        var values = [CGPDFReal](repeating: 0, count: count)
        for index in 0..<count { guard CGPDFArrayGetNumber(array, index, &values[index]) else { return nil } }
        return values.map { Double($0) }
    }

    /// A paint with a pattern colour over `area`: a shading pattern must not reach a box; a tiling
    /// pattern reaching one must be painted as a single tile, whose cell is then read back like a
    /// form placed at that tile (findings 1, 5, 6, 7, 15).
    private static func checkPattern(_ s: State, named pattern: String, area: CGRect) {
        guard s.boxes.contains(where: { RedactionGeometry.intersects(area, $0) }),
              let content = s.contentStreams.last, let object = CGPDFContentStreamGetResource(content, "Pattern", pattern) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else {
            s.violation("a shading pattern is painted across a box")
            return
        }
        let m = numbers(dictionary, "Matrix", count: 6) ?? [1, 0, 0, 1, 0, 0]
        let matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.patternBase)
        var xStep: CGPDFReal = 0, yStep: CGPDFReal = 0
        guard let b = numbers(dictionary, "BBox", count: 4), CGPDFDictionaryGetNumber(dictionary, "XStep", &xStep),
              CGPDFDictionaryGetNumber(dictionary, "YStep", &yStep), abs(xStep) > 1e-9, abs(yStep) > 1e-9,
              abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-12 else {
            s.violation("a tiling pattern painted across a box cannot be read back")
            return
        }
        let cell = CGRect(x: min(b[0], b[2]), y: min(b[1], b[3]), width: abs(b[2] - b[0]), height: abs(b[3] - b[1]))
        let inverse = matrix.inverted()
        let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                       CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)].map { $0.applying(inverse) }
        let sx = abs(Double(xStep)), sy = abs(Double(yStep))
        let firstI: Int, firstJ: Int
        switch RedactionGeometry.tileCover(corners: corners, cell: cell, xStep: sx, yStep: sy) {
        case .none: return
        case .many:
            s.violation("a repeating pattern is painted across a box")
            return
        case let .one(i, j): (firstI, firstJ) = (i, j)
        }
        guard s.depth < 24, let table = s.table else { return }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let saved = (s.ctm, s.textParameters, s.paint, s.patternBase)
        s.ctm = CGAffineTransform(translationX: Double(firstI) * sx, y: Double(firstJ) * sy).concatenating(matrix)
        s.patternBase = s.ctm
        s.paint = Paint(clip: cell.applying(s.ctm).intersection(area))
        s.depth += 1
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        s.contentStreams.append(inner)
        let scanner = CGPDFScannerCreate(inner, table, Unmanaged.passUnretained(s).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(inner)
        s.contentStreams.removeLast()
        s.depth -= 1
        (s.ctm, s.textParameters, s.paint, s.patternBase) = saved
    }

    /// `sh` paints over the whole clip: it must not reach a box.
    private static func checkShading(_ s: State, named shading: String) {
        guard !s.boxes.isEmpty, let content = s.contentStreams.last,
              let object = CGPDFContentStreamGetResource(content, "Shading", shading) else { return }
        var painted = s.clip
        var dictionary: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .dictionary, &dictionary) == false, CGPDFObjectGetValue(object, .stream, &stream), let stream {
            dictionary = CGPDFStreamGetDictionary(stream)
        }
        if let dictionary, let b = numbers(dictionary, "BBox", count: 4) {
            painted = painted.intersection(CGRect(x: min(b[0], b[2]), y: min(b[1], b[3]), width: abs(b[2] - b[0]), height: abs(b[3] - b[1])).applying(s.ctm))
        }
        guard !painted.isNull, painted.width > 0, painted.height > 0 else { return }
        if s.boxes.contains(where: { RedactionGeometry.intersects(painted, $0) }) {
            s.violation("a shading is painted under a box")
        }
    }

    private static func checkImage(_ s: State, stream: CGPDFStreamRef, inline: Bool) {
        guard !s.boxes.isEmpty else { return }
        let placement = s.ctm
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(placement) }
        let hit = s.boxes.filter { RedactionContentRewriter.quad(corners, intersects: $0) }
        guard !hit.isEmpty else { return }
        guard case let .stream(rawDictionary, data)? = RedactionCGObjects.convert(stream: stream) else {
            s.violation("an image under a box cannot be read back")
            return
        }
        let dictionary = inline ? RedactionInlineImageKeys.expanded(rawDictionary) : rawDictionary
        if dictionary["Filter"] != nil {
            s.violation("an image under a box is still compressed in a way that was not blanked")
            return
        }
        var colorSpaces: [String: PDFObject]?
        if case let .name(space)? = dictionary["ColorSpace"], let content = s.contentStreams.last,
           let object = CGPDFContentStreamGetResource(content, "ColorSpace", space), let converted = RedactionCGObjects.convert(object) {
            colorSpaces = [space: converted]
        }
        guard let layout = try? RedactionImages.layout(dictionary: dictionary, colorSpaces: colorSpaces, resolve: { $0 }) else {
            s.violation("an image under a box has a layout the readback cannot read")
            return
        }
        let bytes = [UInt8](data)
        guard bytes.count >= layout.rowBytes * layout.height else {
            s.violation("an image under a box is shorter than its size")
            return
        }
        let w = Double(layout.width), h = Double(layout.height)
        for row in 0..<layout.height {
            for column in 0..<layout.width {
                let page = CGPoint(x: (Double(column) + 0.5) / w, y: 1 - (Double(row) + 0.5) / h).applying(placement)
                guard hit.contains(where: { page.x > $0.minX && page.x < $0.maxX && page.y > $0.minY && page.y < $0.maxY }) else { continue }
                if RedactionImages.sample(bytes, layout: layout, row: row, column: column) != layout.blank {
                    s.violation("an image sample under a box was not blanked")
                    return
                }
            }
        }
        if !inline, case let .stream(maskDictionary, maskData)? = rawDictionary["SMask"] {
            guard maskDictionary["Filter"] == nil, let maskLayout = try? RedactionImages.layout(dictionary: maskDictionary, colorSpaces: nil, resolve: { $0 }) else {
                s.violation("a soft mask under a box cannot be read back")
                return
            }
            let maskBytes = [UInt8](maskData)
            guard maskBytes.count >= maskLayout.rowBytes * maskLayout.height else { return }
            let mw = Double(maskLayout.width), mh = Double(maskLayout.height)
            for row in 0..<maskLayout.height {
                for column in 0..<maskLayout.width {
                    let page = CGPoint(x: (Double(column) + 0.5) / mw, y: 1 - (Double(row) + 0.5) / mh).applying(placement)
                    guard hit.contains(where: { page.x > $0.minX && page.x < $0.maxX && page.y > $0.minY && page.y < $0.maxY }) else { continue }
                    if RedactionImages.sample(maskBytes, layout: maskLayout, row: row, column: column) != maskLayout.blank {
                        s.violation("a soft-mask sample under a box was not blanked")
                        return
                    }
                }
            }
        }
    }
}

/// Core Graphics PDF objects as ``PDFObject`` values, streams decoded by Core Graphics.
enum RedactionCGObjects {

    /// Keys never followed: they lead back up the page tree or into font programs.
    static let skipped: Set<String> = ["Parent", "P", "Kids", "FontFile", "FontFile2", "FontFile3", "CIDToGIDMap", "CIDSet", "Metadata"]

    static func convert(_ object: CGPDFObjectRef, depth: Int = 0) -> PDFObject? {
        guard depth < 12 else { return nil }
        switch CGPDFObjectGetType(object) {
        case .null:
            return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            return CGPDFObjectGetValue(object, .boolean, &value) ? .boolean(value != 0) : nil
        case .integer:
            var value: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &value) ? .integer(Int(value)) : nil
        case .real:
            var value: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &value) ? .real(Double(value)) : nil
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { return nil }
            return .name(String(cString: value))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value, let pointer = CGPDFStringGetBytePtr(value) else { return nil }
            return .string(Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(value))))
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { return nil }
            return .array(convert(array: value, depth: depth))
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { return nil }
            return .dictionary(convert(dictionary: value, depth: depth))
        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return nil }
            return convert(stream: value, depth: depth)
        @unknown default:
            return nil
        }
    }

    static func convert(array: CGPDFArrayRef, depth: Int) -> [PDFObject] {
        var out: [PDFObject] = []
        for index in 0..<min(CGPDFArrayGetCount(array), 200_000) {
            var item: CGPDFObjectRef?
            if CGPDFArrayGetObject(array, index, &item), let item, let converted = convert(item, depth: depth + 1) { out.append(converted) }
        }
        return out
    }

    static func convert(dictionary: CGPDFDictionaryRef, depth: Int) -> [String: PDFObject] {
        var out: [String: PDFObject] = [:]
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            let name = String(cString: key)
            if !skipped.contains(name), let converted = convert(value, depth: depth + 1) { out[name] = converted }
            return true
        }, nil)
        return out
    }

    /// A stream with the filters Core Graphics undid removed from its dictionary; JPEG data
    /// keeps its `/DCTDecode`.
    static func convert(stream: CGPDFStreamRef, depth: Int = 0) -> PDFObject? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var entries = convert(dictionary: dictionary, depth: depth)
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        for key in ["Filter", "F", "DecodeParms", "DP", "Length", "L"] { entries.removeValue(forKey: key) }
        switch format {
        case .raw: break
        case .jpegEncoded: entries["Filter"] = .name("DCTDecode")
        case .JPEG2000: entries["Filter"] = .name("JPXDecode")
        @unknown default: entries["Filter"] = .name("Unknown")
        }
        return .stream(dictionary: entries, data: data)
    }
}
