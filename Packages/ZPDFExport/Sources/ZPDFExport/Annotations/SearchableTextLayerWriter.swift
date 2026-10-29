import CoreGraphics
import CoreText
import Foundation

/// "Save Searchable Copy…" (NL-PDF-13): the recognised words of a scanned drawing written into it
/// as an **invisible text layer**, so any reader can find and select them.
///
/// # What is written
///
/// An incremental update, like every Zenit write onto a drawing: per page, one appended content
/// stream of text-showing operators in render mode 3 (neither filled nor stroked — ISO 32000-1
/// §9.3.6), one shared standard font, and a superseding page dictionary naming both. Each word is
/// placed on its recognised box: the font size is the box's height across the text, and the
/// horizontal scaling stretches the word to the box's length, so a reader's selection highlight
/// sits on the word in the picture. The page's pixels do not change, which a test proves by
/// rendering the page before and after.
///
/// On a page with `/Rotate`, the words run the way the person reads the sheet, not the way the
/// page's own axes point.
public struct SearchableTextLayerWriter: Sendable {

    /// One recognised word, in page space.
    public struct Token: Sendable, Hashable {
        public var text: String
        public var bounds: CGRect

        public init(text: String, bounds: CGRect) {
            self.text = text
            self.bounds = bounds
        }
    }

    /// One page's words.
    public struct Page: Sendable {
        public var sourcePageIndex: Int
        /// `/Rotate`, any multiple of 90.
        public var rotation: Int
        public var tokens: [Token]

        public init(sourcePageIndex: Int, rotation: Int, tokens: [Token]) {
            self.sourcePageIndex = sourcePageIndex
            self.rotation = rotation
            self.tokens = tokens
        }
    }

    /// What was written.
    public struct Outcome: Sendable, Hashable {
        public var pageCount: Int
        public var pagesWithText: Int = 0
        public var wordsWritten: Int = 0
        /// Words skipped: empty, or a box that is not a finite rectangle.
        public var wordsSkipped: Int = 0
        public var preservedSourceBytes: Int
    }

    public init() {}

    static let fontName = "ZOCRText"

    public func data(source: Data, pages: [Page]) throws -> (data: Data, outcome: Outcome) {
        let scan: PDFDocumentScan
        let sourcePages: [PDFDocumentScan.PageEntry]
        do {
            scan = try PDFDocumentScan(data: source)
            sourcePages = try scan.pages()
        } catch let error as ExportError {
            throw ExportError.annotationExportRefused(
                error.description.replacingOccurrences(of: "a layer added to it", with: "a text layer added to it")
            )
        }
        var update = PDFIncrementalUpdate()
        var allocator = scan.nextObjectNumber
        func allocate() -> Int {
            defer { allocator += 1 }
            return allocator
        }
        var outcome = Outcome(pageCount: sourcePages.count, preservedSourceBytes: source.count)
        var fontReference: PDFObject?

        for job in pages.sorted(by: { $0.sourcePageIndex < $1.sourcePageIndex }) {
            guard job.sourcePageIndex >= 0, job.sourcePageIndex < sourcePages.count else {
                throw ExportError.annotationExportRefused(
                    "the searchable copy names page \(job.sourcePageIndex + 1), and the drawing has \(sourcePages.count)."
                )
            }
            let target = sourcePages[job.sourcePageIndex]
            var resources = scan.dictionary(target.inheritedResources) ?? [:]
            var fonts: [String: PDFObject] = scan.dictionary(resources["Font"]) ?? [:]
            var name = Self.fontName
            var suffix = 0
            while fonts[name] != nil { suffix += 1; name = "\(Self.fontName)\(suffix)" }

            var body = ""
            var written = 0
            for token in job.tokens {
                guard let operators = Self.operators(for: token, rotation: job.rotation, font: name) else {
                    outcome.wordsSkipped += 1
                    continue
                }
                body += operators
                written += 1
            }
            guard written > 0 else { continue }

            let font: PDFObject
            if let fontReference {
                font = fontReference
            } else {
                let number = allocate()
                update.objects[number] = .dictionary([
                    "Type": .name("Font"),
                    "Subtype": .name("Type1"),
                    "BaseFont": .name("Helvetica"),
                    "Encoding": .name("WinAnsiEncoding")
                ])
                font = .reference(number: number, generation: 0)
                fontReference = font
            }

            fonts[name] = font
            resources["Font"] = .dictionary(fonts)
            let resourcesNumber = allocate()
            update.objects[resourcesNumber] = .dictionary(resources)

            let carried = Self.existingContents(of: target, scan: scan)
            let balance = LayeredMarkupExporter.stateBalance(of: carried, scan: scan) ?? .balanced
            var content = String(repeating: "Q\n", count: balance.restoresAfter)
            content += "q\nBT\n3 Tr\n" + body + "ET\nQ\n"
            let prefixNumber = allocate()
            update.objects[prefixNumber] = .stream(
                dictionary: [:], data: Data(String(repeating: "q\n", count: balance.savesBefore).utf8)
            )
            let contentNumber = allocate()
            let raw = Data(content.utf8)
            if let deflated = PDFStreamCodec.flateEncode(raw), deflated.count < raw.count {
                update.objects[contentNumber] = .stream(dictionary: ["Filter": .name("FlateDecode")], data: deflated)
            } else {
                update.objects[contentNumber] = .stream(dictionary: [:], data: raw)
            }

            var dictionary = target.dictionary
            dictionary["Resources"] = .reference(number: resourcesNumber, generation: 0)
            dictionary["Contents"] = .array(
                [.reference(number: prefixNumber, generation: 0)] + carried + [.reference(number: contentNumber, generation: 0)]
            )
            update.objects[target.number] = .dictionary(dictionary)
            outcome.pagesWithText += 1
            outcome.wordsWritten += written
        }

        return (try update.appended(to: source, scan: scan), outcome)
    }

    // MARK: - One word

    /// The operators that place one word on its box, or `nil` for a word that cannot be placed.
    static func operators(for token: Token, rotation: Int, font: String = SearchableTextLayerWriter.fontName) -> String? {
        let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = token.bounds.standardized
        guard !text.isEmpty, box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0
        else { return nil }
        let turn = ((rotation % 360) + 360) % 360
        let sideways = turn == 90 || turn == 270
        let length = Double(sideways ? box.height : box.width)
        let across = Double(sideways ? box.width : box.height)
        let size = max(1, across)
        let natural = naturalWidth(of: text) * size
        let scaling = natural > 0 ? min(1_000, max(1, 100 * length / natural)) : 100
        let descent = across * 0.2
        let matrix: [Double]
        switch turn {
        case 90:
            matrix = [0, 1, -1, 0, Double(box.maxX) - descent, Double(box.minY)]
        case 180:
            matrix = [-1, 0, 0, -1, Double(box.maxX), Double(box.maxY) - descent]
        case 270:
            matrix = [0, -1, 1, 0, Double(box.minX) + descent, Double(box.maxY)]
        default:
            matrix = [1, 0, 0, 1, Double(box.minX), Double(box.minY) + descent]
        }
        let numbers = matrix.map { PDFObject.format(StandardAnnotationWriter.clean($0)) }.joined(separator: " ")
        return "/\(font) \(PDFObject.format(StandardAnnotationWriter.clean(size))) Tf "
            + "\(PDFObject.format(StandardAnnotationWriter.clean(scaling))) Tz "
            + "\(numbers) Tm (\(escaped(text))) Tj\n"
    }

    /// The word's advance at a font size of 1, in Helvetica — the standard font the layer uses.
    static func naturalWidth(of text: String) -> Double {
        let font = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        let total = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return total > 0 ? total : Double(characters.count) * 0.55
    }

    /// The word as a literal string in WinAnsiEncoding: parentheses and backslashes escaped,
    /// characters the encoding lacks written as `?` so the rest of the word still matches.
    static func escaped(_ text: String) -> String {
        Windows1252.pdfLiteral(text)
    }

    static func existingContents(of target: PDFDocumentScan.PageEntry, scan: PDFDocumentScan) -> [PDFObject] {
        guard let contents = target.dictionary["Contents"] else { return [] }
        if let values = contents.arrayValue { return values }
        if let values = scan.object(contents)?.arrayValue { return values }
        return [contents]
    }
}
