import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFQPDF

/// Iteration 1 re-fix, NL-DOCS-08: the extraction and the merge carry the named
/// destinations of the pages they take, so a link that names one still lands. Old behaviour: the
/// shim's assemble() copied the pages, /PageLabels and /OCProperties only, so the copy had neither
/// /Dests nor /Names /Dests while its link still said `/Dest /detail`.
@Suite("Iteration 1 re-fix — named destinations through qpdf (NL-DOCS-08)")
struct Iter1RQPDFNamedDestinationTests {

    /// Three sheets. `/detail` (catalog /Dests) and `(section)` (a name tree with one kid, the
    /// dictionary form) name sheet 2; `/far` names sheet 3. Sheet 1 links to both of the first two.
    static func linkedSet() -> Data {
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R /Dests << /detail [4 0 R /XYZ 0 200 0] /far [5 0 R /Fit] >>"
                + " /Names << /Dests << /Kids [9 0 R] >> >> >>", nil),
            ("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>", nil),
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Annots [7 0 R 8 0 R] >>", nil),
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R >>", nil),
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R >>", nil),
        ]
        let content = "0 0 0 RG 10 10 m 190 190 l S\n"
        objects.append(("<< /Length \(content.utf8.count) >>", content))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [10 10 50 50] /Border [0 0 0] /Dest /detail >>", nil))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [60 10 100 50] /Border [0 0 0] /A << /S /GoTo /D (section) >> >>", nil))
        objects.append(("<< /Limits [(section) (section)] /Names [(section) << /D [4 0 R /Fit] >>] >>", nil))
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            var body = "\(index + 1) 0 obj\n\(object.0)\n"
            if let stream = object.1 { body += "stream\n\(stream)\nendstream\n" }
            pdf.append(Data((body + "endobj\n").utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    /// The zero-based page a destination array's first item is, in `document`.
    static func pageIndex(of destination: CGPDFArrayRef?, in document: CGPDFDocument) -> Int? {
        var page: CGPDFDictionaryRef?
        guard let destination, CGPDFArrayGetDictionary(destination, 0, &page), let page else { return nil }
        return (0..<document.numberOfPages).first { document.page(at: $0 + 1)?.dictionary == page }
    }

    /// Where the catalog's `/Dests` sends `name`.
    static func dests(_ document: CGPDFDocument, _ name: String) -> Int? {
        guard let catalog = document.catalog else { return nil }
        var dests: CGPDFDictionaryRef?
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), let dests,
              CGPDFDictionaryGetArray(dests, name, &array) else { return nil }
        return pageIndex(of: array, in: document)
    }

    /// The keys of the catalog's `/Dests`.
    static func destNames(_ document: CGPDFDocument) -> Set<String> {
        guard let catalog = document.catalog else { return [] }
        var dests: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), let dests else { return [] }
        final class Keys { var names: Set<String> = [] }
        let keys = Keys()
        CGPDFDictionaryApplyFunction(dests, { key, _, info in
            Unmanaged<Keys>.fromOpaque(info!).takeUnretainedValue().names.insert(String(cString: key))
        }, Unmanaged.passUnretained(keys).toOpaque())
        return keys.names
    }

    /// Every `(string) destination` pair of the flat `/Names /Dests` tree the copy writes.
    static func tree(_ document: CGPDFDocument) -> [String: Int?] {
        guard let catalog = document.catalog else { return [:] }
        var names: CGPDFDictionaryRef?
        var destsTree: CGPDFDictionaryRef?
        var flat: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
              CGPDFDictionaryGetDictionary(names, "Dests", &destsTree), let destsTree,
              CGPDFDictionaryGetArray(destsTree, "Names", &flat), let flat else { return [:] }
        var out: [String: Int?] = [:]
        for index in stride(from: 0, to: CGPDFArrayGetCount(flat) - 1, by: 2) {
            var key: CGPDFStringRef?
            var array: CGPDFArrayRef?
            guard CGPDFArrayGetString(flat, index, &key), let key,
                  let text = CGPDFStringCopyTextString(key) as String?,
                  CGPDFArrayGetArray(flat, index + 1, &array) else { continue }
            out[text] = pageIndex(of: array, in: document)
        }
        return out
    }

    /// The names page `index`'s links use: `/Dest` names and GoTo `/D` strings.
    static func linkTargets(_ document: CGPDFDocument, page index: Int) -> [String] {
        guard let page = document.page(at: index + 1)?.dictionary else { return [] }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { return [] }
        var out: [String] = []
        for item in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, item, &annotation), let annotation else { continue }
            var name: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(annotation, "Dest", &name), let name { out.append("/" + String(cString: name)) }
            var action: CGPDFDictionaryRef?
            var target: CGPDFStringRef?
            if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action,
               CGPDFDictionaryGetString(action, "D", &target), let target, let text = CGPDFStringCopyTextString(target) as String? {
                out.append("(\(text))")
            }
        }
        return out
    }

    @Test("Extracting sheets 1 and 2 keeps /detail and (section), which name sheet 2, and the links on sheet 1 still land")
    func extractCarriesNamedDestinations() throws {
        let box = try Sandbox("it1r-named-extract")
        let input = box.file("set.pdf"), output = box.file("extract.pdf")
        try Self.linkedSet().write(to: input)
        try QPDF.extractPages(input: input, output: output, pageIndices: [0, 1])
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 2)
        // Old: nil — the copy had no /Dests at all.
        #expect(Self.dests(document, "detail") == 1)
        // `/far` names sheet 3, which the extract does not take.
        #expect(Self.destNames(document) == ["detail"])
        // Old: [:] — no /Names /Dests.
        #expect(Self.tree(document) == ["section": 1])
        #expect(Self.linkTargets(document, page: 0) == ["/detail", "(section)"])
        // PDFKit follows the name-tree link to the second page of the copy. (It resolves no
        // PDF 1.1 catalog /Dests name, in the drawing either, so `/detail` is checked above.)
        let pdf = try #require(PDFDocument(url: output))
        let links = pdf.page(at: 0)?.annotations.filter { $0.type == "Link" } ?? []
        #expect(links.count == 2)
        let goTo = links.compactMap { ($0.action as? PDFActionGoTo)?.destination }.filter { $0.page != nil }
        #expect(goTo.map { $0.page.map { pdf.index(for: $0) } } == [1])

        // In another order, the destination follows its sheet to its new place.
        let reversed = box.file("reversed.pdf")
        try QPDF.extractPages(input: input, output: reversed, pageIndices: [2, 1, 0])
        let turned = try #require(CGPDFDocument(reversed as CFURL))
        #expect(Self.dests(turned, "detail") == 1 && Self.dests(turned, "far") == 0)
        #expect(Self.tree(turned) == ["section": 1])
    }

    @Test("A merge of two sets renames the second set's names and points its links at them")
    func mergeRenamesCollidingNames() throws {
        let box = try Sandbox("it1r-named-merge")
        let first = box.file("a.pdf"), second = box.file("b.pdf"), merged = box.file("merged.pdf")
        try Self.linkedSet().write(to: first)
        try Self.linkedSet().write(to: second)
        try QPDF.merge(sources: [.init(first), .init(second)], output: merged)
        let document = try #require(CGPDFDocument(merged as CFURL))
        #expect(document.numberOfPages == 6)
        #expect(Self.destNames(document) == ["detail", "far", "detail-2", "far-2"])
        #expect(Self.dests(document, "detail") == 1 && Self.dests(document, "far") == 2)
        #expect(Self.dests(document, "detail-2") == 4 && Self.dests(document, "far-2") == 5)
        #expect(Self.tree(document) == ["section": 1, "section-2": 4])
        // Each set's links land in its own sheets.
        #expect(Self.linkTargets(document, page: 0) == ["/detail", "(section)"])
        #expect(Self.linkTargets(document, page: 3) == ["/detail-2", "(section-2)"])
    }

    @Test("A drawing without named destinations gets none, and one whose names all point elsewhere gets none")
    func nothingToCarry() throws {
        let box = try Sandbox("it1r-named-none")
        let input = box.file("set.pdf"), output = box.file("extract.pdf")
        try Self.linkedSet().write(to: input)
        // Sheet 1 only: every name points at sheet 2 or 3.
        try QPDF.extractPages(input: input, output: output, pageIndices: [0])
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(Self.destNames(document).isEmpty)
        #expect(Self.tree(document).isEmpty)
        let catalog = try #require(document.catalog)
        var dests: CGPDFDictionaryRef?
        #expect(!CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), "no empty /Dests is written")
    }
}
