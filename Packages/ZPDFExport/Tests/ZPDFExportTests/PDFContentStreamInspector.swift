import CoreGraphics
import Foundation

/// Reads a produced PDF back and says what is actually in its page content streams.
///
/// # Why the tests do this rather than trust the call
///
/// Every previous export defect in this project was a call that returned success. `printDocument`
/// rasterised each page, appended a sheet, ran the operation and reported nothing wrong — and
/// printed no markup at all, for months. A test that asserts `write(...)` did not throw would
/// have been green throughout.
///
/// So the flatten tests do the only thing that could have caught it: they open the produced file,
/// decode its page content streams, interpret the subset of the operator set that moves a pen,
/// and assert that a markup's page-space geometry is **in the output**. The interpreter tracks
/// `q`/`Q`/`cm` because the renderer draws through a flip and a translation, so a raw coordinate
/// comparison would be a comparison against the wrong space.
struct PDFContentStreamInspector {

    struct Page {
        /// `/MediaBox`, as the produced file declares it.
        let mediaBox: CGRect
        /// `/Rotate`, normalised.
        let rotation: Int
        /// Every point named by a path-construction operator, mapped through the CTM in force
        /// when it was named — so these are output user-space points, comparable with the page
        /// geometry the caller asked for.
        let pathPoints: [CGPoint]
        /// The painting operators encountered, e.g. `S`, `f`, `f*`.
        let paintOperators: [String]
        /// `Do` invocations: form and image XObjects.
        let xObjectInvocations: Int
        /// Inline images (`BI ... EI`).
        let inlineImages: Int
        /// The decoded stream, for a test that wants to look for itself.
        let stream: String
    }

    let pages: [Page]

    init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0
        else { return nil }
        var pages: [Page] = []
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { return nil }
            let text = Self.contentStream(of: page)
            let walked = Self.walk(text)
            pages.append(Page(
                mediaBox: page.getBoxRect(.mediaBox),
                rotation: Int(page.rotationAngle),
                pathPoints: walked.points,
                paintOperators: walked.paints,
                xObjectInvocations: walked.xObjects,
                inlineImages: walked.inlineImages,
                stream: text
            ))
        }
        self.pages = pages
    }

    /// Whether some path point lands within `tolerance` of `point`.
    static func contains(_ points: [CGPoint], _ point: CGPoint, tolerance: Double = 0.75) -> Bool {
        points.contains { candidate in
            abs(Double(candidate.x - point.x)) <= tolerance
                && abs(Double(candidate.y - point.y)) <= tolerance
        }
    }

    // MARK: - Reading the stream

    private static func contentStream(of page: CGPDFPage) -> String {
        guard let dictionary = page.dictionary else { return "" }
        var contents: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "Contents", &contents),
              let contents
        else { return "" }
        var chunks: [Data] = []
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(contents, .stream, &stream), let stream {
            if let data = copy(stream) { chunks.append(data) }
        } else {
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(contents, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var element: CGPDFStreamRef?
                    if CGPDFArrayGetStream(array, index, &element), let element,
                       let data = copy(element) {
                        chunks.append(data)
                    }
                }
            }
        }
        let joined = chunks.reduce(into: Data()) { total, chunk in
            total.append(chunk)
            total.append(0x0A)
        }
        return String(decoding: joined, as: UTF8.self)
    }

    private static func copy(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        return data as Data
    }

    // MARK: - The interpreter

    private struct Walked {
        var points: [CGPoint] = []
        var paints: [String] = []
        var xObjects = 0
        var inlineImages = 0
    }

    private static let paintingOperators: Set<String> = [
        "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"
    ]

    private static func walk(_ text: String) -> Walked {
        var result = Walked()
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var operands: [Double] = []
        var skippingInlineImage = false

        func map(_ x: Double, _ y: Double) {
            result.points.append(CGPoint(x: x, y: y).applying(ctm))
        }

        for token in tokenize(text) {
            if skippingInlineImage {
                if token == "EI" { skippingInlineImage = false }
                continue
            }
            if let number = Double(token) {
                operands.append(number)
                // A path with thousands of points would otherwise grow this unboundedly if a
                // malformed stream never produced an operator.
                if operands.count > 64 { operands.removeFirst(operands.count - 64) }
                continue
            }
            switch token {
            case "q":
                stack.append(ctm)
            case "Q":
                if let previous = stack.popLast() { ctm = previous }
            case "cm":
                if operands.count >= 6 {
                    let values = Array(operands.suffix(6))
                    let concat = CGAffineTransform(
                        a: values[0], b: values[1], c: values[2],
                        d: values[3], tx: values[4], ty: values[5]
                    )
                    ctm = concat.concatenating(ctm)
                }
            case "m", "l":
                if operands.count >= 2 {
                    let values = Array(operands.suffix(2))
                    map(values[0], values[1])
                }
            case "c":
                if operands.count >= 6 {
                    let values = Array(operands.suffix(6))
                    map(values[0], values[1])
                    map(values[2], values[3])
                    map(values[4], values[5])
                }
            case "v", "y":
                if operands.count >= 4 {
                    let values = Array(operands.suffix(4))
                    map(values[0], values[1])
                    map(values[2], values[3])
                }
            case "re":
                if operands.count >= 4 {
                    let values = Array(operands.suffix(4))
                    map(values[0], values[1])
                    map(values[0] + values[2], values[1])
                    map(values[0] + values[2], values[1] + values[3])
                    map(values[0], values[1] + values[3])
                }
            case "Do":
                result.xObjects += 1
            case "BI":
                result.inlineImages += 1
                skippingInlineImage = true
            default:
                if paintingOperators.contains(token) { result.paints.append(token) }
            }
            operands.removeAll(keepingCapacity: true)
        }
        return result
    }

    /// A tokenizer for the operator syntax, enough for path geometry.
    ///
    /// Strings, names, arrays and dictionaries are skipped rather than parsed: nothing this
    /// inspector asserts on lives inside one, and a half-parsed dictionary is how a scanner
    /// starts reading operands as operators.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        var dictionaryDepth = 0

        func flush() {
            if !current.isEmpty {
                if dictionaryDepth == 0 { tokens.append(current) }
                current = ""
            }
        }

        while let scalar = pending ?? iterator.next() {
            pending = nil
            switch scalar {
            case " ", "\n", "\r", "\t", "\u{0C}", "\u{00}":
                flush()
            case "%":
                flush()
                while let next = iterator.next(), next != "\n", next != "\r" {}
            case "(":
                flush()
                var depth = 1
                while depth > 0, let next = iterator.next() {
                    if next == "\\" { _ = iterator.next(); continue }
                    if next == "(" { depth += 1 }
                    if next == ")" { depth -= 1 }
                }
            case "<", ">":
                flush()
                // `<<` and `>>` bracket a dictionary; a lone `<` opens a hex string.
                if let next = iterator.next() {
                    if next == scalar {
                        dictionaryDepth += scalar == "<" ? 1 : -1
                        dictionaryDepth = Swift.max(0, dictionaryDepth)
                    } else if scalar == "<" {
                        var seen = next
                        while seen != ">", let following = iterator.next() { seen = following }
                    } else {
                        pending = next
                    }
                }
            case "[", "]", "{", "}":
                flush()
            case "/":
                flush()
                while let next = iterator.next() {
                    if next == " " || next == "\n" || next == "\r" || next == "\t"
                        || next == "/" || next == "[" || next == "<" || next == "(" {
                        pending = next
                        break
                    }
                }
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return tokens
    }
}
