import CoreGraphics
import Foundation
import Testing
import ZPDFQPDF

/// Iteration 2, S-066: a link naming a destination its own drawing did not carry
/// into a merged copy never lands on another drawing's sheet. Old behaviour: the shim carried only
/// the names whose page it took, returned early when there were none, and rewrote links only for a
/// name it renamed on a collision — so a dangling `/Dest /detail` on one drawing resolved to the
/// `detail` another drawing carried.
@Suite("Iteration 2 — named links in merged copies (S-066)")
struct Iter2QPDFNamedLinkTests {

    typealias Named = Iter1RQPDFNamedDestinationTests

    /// One sheet whose three links name `/detail`, `(section)` and — through one indirect GoTo
    /// action two links share — `(section)` again, with no named destination of its own, and a
    /// fourth link with an explicit destination (its own sheet) that has nothing to do with names.
    static func danglingLinks() -> Data {
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R >>", nil),
            ("<< /Type /Pages /Kids [3 0 R] /Count 1 >>", nil),
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Annots [5 0 R 6 0 R 7 0 R 9 0 R] >>", nil),
        ]
        let content = "0 0 0 RG 10 190 m 190 10 l S\n"
        objects.append(("<< /Length \(content.utf8.count) >>", content))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [10 10 50 50] /Border [0 0 0] /Dest /detail >>", nil))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [60 10 100 50] /Border [0 0 0] /A 8 0 R >>", nil))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [110 10 150 50] /Border [0 0 0] /A 8 0 R >>", nil))
        objects.append(("<< /S /GoTo /D (section) >>", nil))
        objects.append(("<< /Type /Annot /Subtype /Link /Rect [160 10 190 50] /Border [0 0 0] /Dest [3 0 R /Fit] >>", nil))
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

    /// How many links on `page` carry a `/Dest` or an `/A`.
    static func linksWithTargets(_ document: CGPDFDocument, page index: Int) -> Int {
        guard let page = document.page(at: index + 1)?.dictionary else { return 0 }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { return 0 }
        var count = 0
        for item in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetDictionary(annotations, item, &annotation), let annotation else { continue }
            if CGPDFDictionaryGetObject(annotation, "Dest", &object) || CGPDFDictionaryGetObject(annotation, "A", &object) { count += 1 }
        }
        return count
    }

    @Test("A drawing's dangling named links lose their names when another drawing merged after it defines them")
    func danglingLinksDoNotLandInTheNextDrawing() throws {
        let box = try Sandbox("it2-named-dangling-first")
        let first = box.file("a.pdf"), second = box.file("b.pdf"), merged = box.file("merged.pdf")
        try Self.danglingLinks().write(to: first)
        try Named.linkedSet().write(to: second)
        try QPDF.merge(sources: [.init(first), .init(second)], output: merged)
        let document = try #require(CGPDFDocument(merged as CFURL))
        #expect(document.numberOfPages == 4)
        // B carries its names unrenamed: nothing of A's took them.
        #expect(Named.dests(document, "detail") == 2)
        #expect(Named.tree(document) == ["section": 2])
        // Old: ["/detail", "(section)", "(section)"] — A's links resolved to B's sheet 2 (page 3).
        #expect(Named.linkTargets(document, page: 0) == [])
        // The explicit destination is untouched, and B's own links still land on its own sheet.
        #expect(Self.linksWithTargets(document, page: 0) == 1)
        #expect(Named.linkTargets(document, page: 1) == ["/detail", "(section)"])
    }

    @Test("A drawing's dangling named links do not pick up the names a drawing merged before it carried")
    func danglingLinksDoNotLandInThePreviousDrawing() throws {
        let box = try Sandbox("it2-named-dangling-second")
        let first = box.file("a.pdf"), second = box.file("b.pdf"), merged = box.file("merged.pdf")
        try Named.linkedSet().write(to: first)
        try Self.danglingLinks().write(to: second)
        try QPDF.merge(sources: [.init(first), .init(second)], output: merged)
        let document = try #require(CGPDFDocument(merged as CFURL))
        #expect(document.numberOfPages == 4)
        #expect(Named.destNames(document) == ["detail", "far"])
        #expect(Named.tree(document) == ["section": 1])
        #expect(Named.linkTargets(document, page: 0) == ["/detail", "(section)"])
        // Old: ["/detail", "(section)", "(section)"] on page 4 — B's links landed on A's sheet 2.
        #expect(Named.linkTargets(document, page: 3) == [])
        #expect(Self.linksWithTargets(document, page: 3) == 1)
    }

    @Test("An extract keeps the links whose names it carried and drops those whose sheet it left behind")
    func extractDropsOnlyWhatItLeft() throws {
        let box = try Sandbox("it2-named-extract")
        let input = box.file("set.pdf"), output = box.file("extract.pdf")
        try Named.linkedSet().write(to: input)
        // Sheets 1 and 3: `/detail` and `(section)` name sheet 2, which is not taken.
        try QPDF.extractPages(input: input, output: output, pageIndices: [0, 2])
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(Named.destNames(document) == ["far"])
        #expect(Named.linkTargets(document, page: 0) == [])
        // Sheets 1 and 2: both names carried, both links kept (the it1r behaviour).
        let kept = box.file("kept.pdf")
        try QPDF.extractPages(input: input, output: kept, pageIndices: [0, 1])
        #expect(Named.linkTargets(try #require(CGPDFDocument(kept as CFURL)), page: 0) == ["/detail", "(section)"])
    }
}
