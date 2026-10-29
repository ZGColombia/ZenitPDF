import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ZPDFExport

/// A hand-assembled PDF, object by object, so a fixture can hold exactly the construct a test is
/// about — a CID font with kerning, a Type 3 font, an inline image, a shared form XObject —
/// without depending on what a producer happens to write.
struct RedactionFixturePDF {
    private var bodies: [Data] = []

    /// Adds an object and returns its number.
    @discardableResult
    mutating func add(_ body: String) -> Int {
        bodies.append(Data(body.utf8))
        return bodies.count
    }

    /// Reserves a number to fill later (for objects that refer to each other).
    mutating func reserve() -> Int {
        bodies.append(Data())
        return bodies.count
    }

    mutating func set(_ number: Int, _ body: String) { bodies[number - 1] = Data(body.utf8) }

    /// Objects so far; the next one added gets `count + 1`.
    var count: Int { bodies.count }

    @discardableResult
    mutating func addStream(_ dictionary: String, _ data: Data) -> Int {
        var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        bodies.append(body)
        return bodies.count
    }

    @discardableResult
    mutating func addStream(_ dictionary: String, _ text: String) -> Int { addStream(dictionary, Data(text.utf8)) }

    mutating func setStream(_ number: Int, _ dictionary: String, _ data: Data) {
        var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        bodies[number - 1] = body
    }

    func data(root: Int, info: Int? = nil) -> Data {
        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { out.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        var trailer = "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R"
        if let info { trailer += " /Info \(info) 0 R" }
        trailer += " >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(trailer.utf8))
        return out
    }

    /// A catalog, a page tree and one page per content stream, with shared resources.
    static func document(
        pages: [(content: String, annotations: String?)],
        resources: String,
        mediaBox: String = "[0 0 420 300]",
        extraObjects: (inout RedactionFixturePDF) -> [String: String] = { _ in [:] },
        catalogExtras: String = "",
        info: String? = nil
    ) -> Data {
        var pdf = RedactionFixturePDF()
        let catalog = pdf.reserve()
        let tree = pdf.reserve()
        let extras = extraObjects(&pdf)
        var resolvedResources = resources
        for (key, value) in extras { resolvedResources = resolvedResources.replacingOccurrences(of: key, with: value) }
        var kids: [Int] = []
        for page in pages {
            let content = pdf.addStream("", page.content)
            var annotations = ""
            if let list = page.annotations {
                var text = list
                for (key, value) in extras { text = text.replacingOccurrences(of: key, with: value) }
                annotations = " /Annots \(text)"
            }
            kids.append(pdf.add("<< /Type /Page /Parent \(tree) 0 R /MediaBox \(mediaBox) /Resources \(resolvedResources) /Contents \(content) 0 R\(annotations) >>"))
        }
        pdf.set(tree, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>")
        var catalogText = "<< /Type /Catalog /Pages \(tree) 0 R \(catalogExtras) >>"
        for (key, value) in extras { catalogText = catalogText.replacingOccurrences(of: key, with: value) }
        pdf.set(catalog, catalogText)
        var infoNumber: Int?
        if let info { infoNumber = pdf.add(info) }
        return pdf.data(root: catalog, info: infoNumber)
    }

    /// Helvetica as a simple font with an explicit width table (500 for every code), so glyph
    /// positions are exactly computable.
    static let helveticaWithWidths =
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 /Widths ["
        + Array(repeating: "500", count: 95).joined(separator: " ") + "] /FontDescriptor << /Type /FontDescriptor /FontName /Helvetica "
        + "/Flags 32 /FontBBox [-166 -225 1000 931] /ItalicAngle 0 /Ascent 718 /Descent -207 /CapHeight 718 /StemV 88 >> >>"
}

extension RedactionFixturePDF {

    /// Phase 1's tender fixture — a bid figure inside `NLPDFR2RedactionTests.secretRect`, a title
    /// outside it, a frame, a reviewer's note on the figure, a second sheet, an author in the
    /// metadata — with the note added through the object layer rather than a PDFKit save, so the
    /// fixture does not depend on PDFKit writing files while other suites use it.
    static func tender(at url: URL, secretOnSheetTwo: Bool = false) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 300)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextAuthor: "Estimator Name"] as CFDictionary))
        func text(_ string: String, at point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(CGRect(x: 20, y: 20, width: 380, height: 260), width: 2)
        text("Tender summary", at: CGPoint(x: 60, y: 250))
        text("BIDAMOUNT 4820000 SEK", at: CGPoint(x: 70, y: 192))
        context.endPDFPage()
        context.beginPDFPage(nil)
        text(secretOnSheetTwo ? "Repeat BIDAMOUNT here" : "Level 3 plan notes", at: CGPoint(x: 60, y: 150))
        context.endPDFPage()
        context.closePDF()
        let base = data as Data
        let scan = try PDFDocumentScan(data: base)
        let page = try scan.pages()[0]
        var dictionary = page.dictionary
        let note = scan.nextObjectNumber
        dictionary["Annots"] = .array([.reference(number: note, generation: 0)])
        var update = PDFIncrementalUpdate()
        update.objects[note] = .dictionary([
            "Type": .name("Annot"), "Subtype": .name("Text"), "Contents": .string(Array("privatenote about the bid".utf8)),
            "Rect": .array([.integer(300), .integer(185), .integer(320), .integer(205)])
        ])
        update.objects[page.number] = .dictionary(dictionary)
        try update.appended(to: base, scan: scan).write(to: url)
    }
}

/// Shared checks: what was under the boxes is gone; what was outside them is as it was.
enum RedactionProof {

    /// Copies a file into `ZPDF_REDACTION_KEEP` when that is set, to look at by hand.
    static func keep(_ url: URL, as name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ZPDF_REDACTION_KEEP"] else { return }
        let target = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-vredact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The share of pixels outside the boxes (inflated by two pixels, plus `ignoring`) that
    /// differ between the two renders at 100 dpi, by more than `delta` in any channel with no
    /// matching neighbour within one pixel.
    static func changedShareOutside(source: URL, output: URL, page index: Int, boxes: [CGRect], ignoring: [CGRect] = [], delta: Int = 32) throws -> Double {
        let sourceDocument = try #require(PDFDocument(url: source)), outputDocument = try #require(PDFDocument(url: output))
        let before = try #require(sourceDocument.page(at: index))
        let after = try #require(outputDocument.page(at: index))
        let a = try #require(RasterRedactor.render(before, dpi: 100))
        let b = try #require(RasterRedactor.render(after, dpi: 100))
        #expect(a.width == b.width && a.height == b.height)
        let transform = RasterRedactor.pixelTransform(for: before, dpi: 100, height: a.height)
        let excluded = (boxes.map { $0.insetBy(dx: -1.5, dy: -1.5) } + ignoring).map { $0.applying(transform).standardized.insetBy(dx: -2, dy: -2) }
        var outside = 0, differing = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if excluded.contains(where: { $0.contains(point) }) { continue }
                outside += 1
                let offset = (y * a.width + x) * 4
                var matched = false
                search: for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < b.width, ny < b.height else { continue }
                        let other = (ny * b.width + nx) * 4
                        let difference = (0..<3).map { abs(Int(a.pixels[offset + $0]) - Int(b.pixels[other + $0])) }.max() ?? 0
                        if difference <= delta { matched = true; break search }
                    }
                }
                if !matched { differing += 1 }
            }
        }
        return outside == 0 ? 0 : Double(differing) / Double(outside)
    }

    /// Core Graphics' reading of the sheet: what it finds inside the boxes.
    static func readbackViolations(_ url: URL, page index: Int, boxes: [CGRect]) throws -> [String] {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: index + 1))
        return RedactionCGReadback.scan(page: page, boxes: boxes).violations
    }

    /// Every stream of the file decoded and appended to the raw bytes.
    static func decompressed(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var haystack = data
        let scan = try PDFDocumentScan(data: data)
        for entry in scan.objects.values {
            if case let .stream(dictionary, raw) = entry.object,
               let decoded = try? RedactionStreamFilters.decode(dictionary: dictionary, data: raw, allowDCT: true).data {
                haystack.append(decoded)
            }
        }
        return haystack
    }

    /// Whether the sheet is still drawn as vector: no image XObject in its resources, directly
    /// or in a form it draws.
    static func pageHasNoPicture(_ url: URL, page index: Int) throws -> Bool {
        let scan = try PDFDocumentScan(data: try Data(contentsOf: url))
        let entry = try scan.pages()[index]
        let resources = scan.dictionary(entry.inheritedResources) ?? [:]
        let xobjects = scan.dictionary(resources["XObject"]) ?? [:]
        return !xobjects.values.contains { scan.dictionary($0)?["Subtype"]?.nameValue == "Image" }
    }

    /// Character bounds on the sheet for every character of `text` found in the page string.
    static func bounds(of text: String, in url: URL, page index: Int) throws -> [CGRect] {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: index))
        let string = page.string ?? ""
        guard let range = string.range(of: text) else { return [] }
        let start = string.distance(from: string.startIndex, to: range.lowerBound)
        return (0..<text.count).map { page.characterBounds(at: start + $0) }
    }

    static func close(_ a: [CGRect], _ b: [CGRect], within tolerance: Double = 0.05) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).allSatisfy { abs($0.minX - $1.minX) <= tolerance && abs($0.minY - $1.minY) <= tolerance && abs($0.width - $1.width) <= tolerance }
    }
}
