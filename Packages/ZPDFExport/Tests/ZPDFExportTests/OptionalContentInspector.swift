import CoreGraphics
import Foundation

/// Reads a produced PDF back and says what its **optional content** actually is: which groups the
/// catalog declares, which are on in the default configuration, and — operator by operator —
/// which marks on a page are inside a `/OC … BDC … EMC` span and which are not.
///
/// # Why this exists beside `PDFContentStreamInspector`
///
/// That inspector answers "is the markup's geometry in the output at all", which is what caught a
/// print path that drew nothing. ADR-0013 §3 asks a harder question, and says plainly that "it
/// opened" is not an answer: the markups must be *inside* the span, the span must be bound to the
/// group, the count must match, and switching the group off must give back the clean sheet. So
/// this type carries the same technique one level further — the same decoded content stream, the
/// same CTM tracking, plus the marked-content stack the operators sit in.
struct OptionalContentInspector {

    // MARK: - The catalog

    /// `/OCProperties /OCGs`, by `/Name`.
    let groupNames: [String]
    /// `/OCProperties /D /ON`, by `/Name`. A group named here is on when the file is opened.
    let onNames: [String]
    /// `/OCProperties /D /OFF`, by `/Name`.
    let offNames: [String]
    /// `/OCProperties /D /Order`, by `/Name` — what a reader's layer panel lists.
    let orderNames: [String]
    /// Whether the catalog has an `/OCProperties` entry at all.
    let hasOptionalContent: Bool

    let pages: [Page]

    struct Span {
        /// The name the `/OC` operand used, resolved through the page's `/Resources /Properties`
        /// by the reader; here it is the name as written.
        let propertyName: String
        var paintOperators: [String] = []
        var points: [CGPoint] = []
    }

    struct Page {
        /// Spans opened as `/OC /Name BDC`.
        var spans: [Span]
        /// Painting operators that no `/OC` span encloses — the drawing's own ink.
        var paintOperatorsOutsideSpans: [String]
        var markedContentIsBalanced: Bool
        var stream: String
        /// `/Resources /Properties`: the name a `BDC` operand uses, to the `/Name` of the
        /// optional-content group it resolves to. This is the binding the whole shape rests on,
        /// so the test resolves it rather than assuming the name means what it looks like.
        var propertyGroupNames: [String: String] = [:]
    }

    init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0,
              let inspector = PDFContentStreamInspector(data: data)
        else { return nil }

        var groups: [String] = []
        var on: [String] = []
        var off: [String] = []
        var order: [String] = []
        var present = false
        if let catalog = document.catalog {
            var properties: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties),
               let properties {
                present = true
                groups = Self.names(inArrayNamed: "OCGs", of: properties)
                var configuration: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(properties, "D", &configuration),
                   let configuration {
                    on = Self.names(inArrayNamed: "ON", of: configuration)
                    off = Self.names(inArrayNamed: "OFF", of: configuration)
                    order = Self.names(inArrayNamed: "Order", of: configuration)
                }
            }
        }
        self.groupNames = groups
        self.onNames = on
        self.offNames = off
        self.orderNames = order
        self.hasOptionalContent = present

        var walked: [Page] = []
        for (index, page) in inspector.pages.enumerated() {
            var result = Self.walk(page.stream)
            if let pdfPage = document.page(at: index + 1), let dictionary = pdfPage.dictionary {
                result.propertyGroupNames = Self.propertyBindings(of: dictionary)
            }
            walked.append(result)
        }
        self.pages = walked
    }

    /// `/Resources /Properties`, each entry resolved to the `/Name` of the group it points at.
    private static func propertyBindings(of page: CGPDFDictionaryRef) -> [String: String] {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources
        else { return [:] }
        var properties: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Properties", &properties), let properties
        else { return [:] }
        var found: [String: String] = [:]
        withUnsafeMutablePointer(to: &found) { pointer in
            CGPDFDictionaryApplyBlock(properties, { key, value, context in
                guard let context else { return true }
                let table = context.assumingMemoryBound(to: [String: String].self)
                var group: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &group), let group else { return true }
                var name: CGPDFStringRef?
                guard CGPDFDictionaryGetString(group, "Name", &name), let name,
                      let text = CGPDFStringCopyTextString(name)
                else { return true }
                table.pointee[String(cString: key)] = text as String
                return true
            }, pointer)
        }
        return found
    }

    // MARK: - Catalog reading

    private static func names(
        inArrayNamed key: String,
        of dictionary: CGPDFDictionaryRef
    ) -> [String] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
        var found: [String] = []
        collect(array, into: &found, depth: 0)
        return found
    }

    private static func collect(_ array: CGPDFArrayRef, into found: inout [String], depth: Int) {
        guard depth < 8 else { return }
        for index in 0..<CGPDFArrayGetCount(array) {
            var group: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(array, index, &group), let group {
                var name: CGPDFStringRef?
                if CGPDFDictionaryGetString(group, "Name", &name), let name,
                   let text = CGPDFStringCopyTextString(name) {
                    found.append(text as String)
                }
                continue
            }
            // `/Order` nests arrays to give the layer panel a tree.
            var nested: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, index, &nested), let nested {
                collect(nested, into: &found, depth: depth + 1)
            }
        }
    }

    // MARK: - The marked-content walk

    private enum Token {
        case number(Double)
        case name(String)
        case keyword(String)
    }

    private static let paintingOperators: Set<String> = [
        "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"
    ]

    private static func walk(_ text: String) -> Page {
        var spans: [Span] = []
        var outside: [String] = []
        /// The marked-content stack. An entry is the index of the `/OC` span it opened, or `nil`
        /// for `/P`, `/Span`, `/AAPL:Style` and every other tag that is not optional content.
        var marked: [Int?] = []
        var balanced = true
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var numbers: [Double] = []
        var names: [String] = []

        func current() -> Int? { marked.last(where: { $0 != nil }) ?? nil }

        func record(_ x: Double, _ y: Double) {
            guard let index = current() else { return }
            spans[index].points.append(CGPoint(x: x, y: y).applying(ctm))
        }

        for token in tokenize(text) {
            switch token {
            case let .number(value):
                numbers.append(value)
                if numbers.count > 64 { numbers.removeFirst(numbers.count - 64) }
                continue
            case let .name(value):
                names.append(value)
                if names.count > 8 { names.removeFirst(names.count - 8) }
                continue
            case let .keyword(keyword):
                switch keyword {
                case "q":
                    stack.append(ctm)
                case "Q":
                    if let previous = stack.popLast() { ctm = previous }
                case "cm":
                    if numbers.count >= 6 {
                        let values = Array(numbers.suffix(6))
                        ctm = CGAffineTransform(
                            a: values[0], b: values[1], c: values[2],
                            d: values[3], tx: values[4], ty: values[5]
                        ).concatenating(ctm)
                    }
                case "BDC":
                    if names.count >= 2, names[names.count - 2] == "OC" {
                        spans.append(Span(propertyName: names[names.count - 1]))
                        marked.append(spans.count - 1)
                    } else {
                        marked.append(nil)
                    }
                case "BMC":
                    marked.append(nil)
                case "EMC":
                    if marked.popLast() == nil { balanced = false }
                case "m", "l":
                    if numbers.count >= 2 {
                        let values = Array(numbers.suffix(2))
                        record(values[0], values[1])
                    }
                case "c":
                    if numbers.count >= 6 {
                        let values = Array(numbers.suffix(6))
                        record(values[0], values[1])
                        record(values[2], values[3])
                        record(values[4], values[5])
                    }
                case "v", "y":
                    if numbers.count >= 4 {
                        let values = Array(numbers.suffix(4))
                        record(values[0], values[1])
                        record(values[2], values[3])
                    }
                case "re":
                    if numbers.count >= 4 {
                        let values = Array(numbers.suffix(4))
                        record(values[0], values[1])
                        record(values[0] + values[2], values[1])
                        record(values[0] + values[2], values[1] + values[3])
                        record(values[0], values[1] + values[3])
                    }
                default:
                    if paintingOperators.contains(keyword) {
                        if let index = current() {
                            spans[index].paintOperators.append(keyword)
                        } else {
                            outside.append(keyword)
                        }
                    }
                }
                numbers.removeAll(keepingCapacity: true)
                names.removeAll(keepingCapacity: true)
            }
        }
        if !marked.isEmpty { balanced = false }
        return Page(
            spans: spans,
            paintOperatorsOutsideSpans: outside,
            markedContentIsBalanced: balanced,
            stream: text
        )
    }

    /// The operator syntax, with names kept.
    ///
    /// `PDFContentStreamInspector` throws names away — nothing it asserts on lives in one. Here
    /// the name *is* the assertion: `/OC /ZMOC BDC` is three tokens and the middle one is the
    /// binding to the group.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        var dictionaryDepth = 0

        func flush() {
            defer { current = "" }
            guard !current.isEmpty, dictionaryDepth == 0 else { return }
            if let value = Double(current) {
                tokens.append(.number(value))
            } else {
                tokens.append(.keyword(current))
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
                var name = ""
                while let next = iterator.next() {
                    if next == " " || next == "\n" || next == "\r" || next == "\t"
                        || next == "/" || next == "[" || next == "<" || next == "(" {
                        pending = next
                        break
                    }
                    name.unicodeScalars.append(next)
                }
                if dictionaryDepth == 0 { tokens.append(.name(name)) }
            default:
                current.unicodeScalars.append(scalar)
            }
        }
        flush()
        return tokens
    }
}
