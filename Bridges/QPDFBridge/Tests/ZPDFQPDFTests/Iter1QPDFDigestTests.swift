import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFQPDF

/// Iteration 1, R-118: the Reduce File Size gate reads linework inside form
/// XObjects. Old behaviour: the digest scanned the page's own stream only, and Core Graphics'
/// scanner does not descend into forms, so a drawing wrapped in a form compared nothing.
@Suite("Iteration 1 — vector digest reads forms (R-118)")
struct Iter1QPDFDigestTests {

    /// One page whose linework lives in a form (`/Fm0`), drawn from the page stream, plus an
    /// optional square annotation with an appearance of its own.
    static func formDrawing(movedLine: Bool = false, annotation: Bool = false) -> Data {
        var form = "0 0 0 RG 0.5 w\n"
        for index in 0..<40 { form += "30 \(40 + index * 12) m 500 \(movedLine && index == 7 ? 41 + index * 12 : 40 + index * 12) l S\n" }
        let page = "q 1 0 0 1 20 20 cm /Fm0 Do Q\n"
        let appearance = "1 0 0 RG 2 w 1 1 98 48 re S\n"
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R >>", nil),
            ("<< /Type /Pages /Kids [3 0 R] /Count 1 >>", nil),
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /XObject << /Fm0 5 0 R >> >>"
                + (annotation ? " /Annots [6 0 R]" : "") + " >>", nil),
            ("<< /Length \(page.utf8.count) >>", page),
            ("<< /Type /XObject /Subtype /Form /BBox [0 0 560 560] /Length \(form.utf8.count) >>", form),
        ]
        if annotation {
            objects.append(("<< /Type /Annot /Subtype /Square /Rect [100 700 200 750] /F 4 /AP << /N 7 0 R >> >>", nil))
            objects.append(("<< /Type /XObject /Subtype /Form /BBox [0 0 100 50] /Length \(appearance.utf8.count) >>", appearance))
        }
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            var body = "\(index + 1) 0 obj\n\(object.0)\n"
            if let stream = object.1 { body += "stream\n\(stream)\nendstream\n" }
            body += "endobj\n"
            pdf.append(Data(body.utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    @Test("A line moved inside a form changes the digest; the digest carries the form's operators")
    func movedLineInsideAForm() throws {
        let box = try Sandbox("iter1-form-digest")
        let a = box.file("a.pdf"), b = box.file("b.pdf")
        try Self.formDrawing().write(to: a)
        try Self.formDrawing(movedLine: true).write(to: b)
        let before = try #require(QPDFVectorDigest.pageDigests(ofFileAt: a))
        let after = try #require(QPDFVectorDigest.pageDigests(ofFileAt: b))
        // Old: both pages digested to the boxes line alone ("…/1") and compared equal.
        #expect(before.first?.forms.count == 1)
        #expect(before.first?.forms.keys.first?.hasSuffix("/1") == false, "the form's linework is in its digest")
        #expect(QPDFVectorDigest.pages(ofFileAt: a) != QPDFVectorDigest.pages(ofFileAt: b))
        #expect(!QPDFVectorDigest.matches(before: before, after: after, allowingAddedForms: true))
        #expect(QPDFVectorDigest.matches(before: before, after: before, allowingAddedForms: false))
    }

    @Test("Reduce File Size on a form-wrapped drawing still passes; with annotations flattened, the added appearance form is allowed")
    func gateAcceptsAddedAppearanceForms() throws {
        let box = try Sandbox("iter1-form-gate")
        let plain = box.file("plain.pdf"), annotated = box.file("annotated.pdf")
        try Self.formDrawing().write(to: plain)
        try Self.formDrawing(annotation: true).write(to: annotated)

        let reduced = box.file("reduced.pdf")
        _ = try QPDF.transform(input: plain, output: reduced,
                               transform: QPDFTransform(compresses: true, downsampling: QPDFImageDownsampling(targetDPI: 150)))
        #expect(QPDFVectorDigest.pages(ofFileAt: plain) == QPDFVectorDigest.pages(ofFileAt: reduced))

        let flattened = box.file("flattened.pdf")
        let report = try QPDF.transform(input: annotated, output: flattened, transform: QPDFTransform(
            flattensAnnotations: true, compresses: true, downsampling: QPDFImageDownsampling(targetDPI: 150)
        ))
        #expect(report.flattenedAnnotationCount == 1)
        let before = try #require(QPDFVectorDigest.pageDigests(ofFileAt: annotated))
        let after = try #require(QPDFVectorDigest.pageDigests(ofFileAt: flattened))
        #expect(after.first?.forms.count == 2, "the drawing's form and the burned-in appearance")
        #expect(QPDFVectorDigest.matches(before: before, after: after, allowingAddedForms: true))
        #expect(!QPDFVectorDigest.matches(before: before, after: after, allowingAddedForms: false))
    }
}

/// Iteration 1, NL-DOCS-08: qpdf's page extraction keeps the sheets' page labels
/// and the document's layer definitions. Old behaviour: the copy was built from the page objects
/// alone — no /PageLabels and no /OCProperties, so extracted sheets lost their numbers and layered
/// content lost its layer panel.
@Suite("Iteration 1 — qpdf extract keeps labels and layers (NL-DOCS-08)")
struct Iter1QPDFExtractTests {

    /// Three sheets labelled A-101…A-103, each drawing a line inside optional-content group L1.
    static func labelledLayeredSet() -> Data {
        let content = "/OC /L1 BDC 0 0 0 RG 10 10 m 190 190 l S EMC\n"
        var objects: [(String, String?)] = [
            ("<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>"
                + " /OCProperties << /OCGs [7 0 R] /D << /Order [7 0 R] /ON [7 0 R] /OFF [] >> >> >>", nil),
            ("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>", nil),
        ]
        for _ in 0..<3 {
            objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R /Resources << /Properties << /L1 7 0 R >> >> >>", nil))
        }
        objects.append(("<< /Length \(content.utf8.count) >>", content))
        objects.append(("<< /Type /OCG /Name (Walls) >>", nil))
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

    @Test("Extracting sheets 3 and 1 keeps their labels A-103 and A-101 and the layer definitions")
    func extractKeepsLabelsAndLayers() throws {
        let box = try Sandbox("iter1-extract-labels")
        let input = box.file("set.pdf"), output = box.file("extract.pdf")
        try Self.labelledLayeredSet().write(to: input)
        try QPDF.extractPages(input: input, output: output, pageIndices: [2, 0])
        let document = try #require(CGPDFDocument(output as CFURL))
        #expect(document.numberOfPages == 2)
        // Old: no /PageLabels, so a reader numbered them 1 and 2.
        let catalog = try #require(document.catalog)
        var labels: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels))
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.page(at: 0)?.label == "A-103" && pdf.page(at: 1)?.label == "A-101", "\(String(describing: pdf.page(at: 0)?.label))")
        // Old: no /OCProperties.
        var properties: CGPDFDictionaryRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties))
        var groups: CGPDFArrayRef?
        #expect(properties.map { CGPDFDictionaryGetArray($0, "OCGs", &groups) } == true)
        #expect(groups.map(CGPDFArrayGetCount) == 1)
    }
}

extension Iter1QPDFExtractTests {

    @Test("The extract keeps the source's PDF version, and a merge continues the labels and joins the layer groups")
    func versionAndMerge() throws {
        let box = try Sandbox("iter1-extract-merge")
        let first = box.file("a.pdf"), second = box.file("b.pdf"), plain = box.file("plain.pdf")
        try Self.labelledLayeredSet().write(to: first)
        // The second set: labels B-201…, its own layer group.
        let b = String(decoding: Self.labelledLayeredSet(), as: UTF8.self)
            .replacingOccurrences(of: "/P (A-) /St 101", with: "/P (B-) /St 201")
            .replacingOccurrences(of: "(Walls)", with: "(Doors)")
        try Data(b.utf8).write(to: second)
        try Data(String(decoding: Self.labelledLayeredSet(), as: UTF8.self)
            .replacingOccurrences(of: "/PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>", with: "").utf8).write(to: plain)

        let extract = box.file("extract.pdf")
        try QPDF.extractPages(input: first, output: extract, pageIndices: [1])
        // Old: "%PDF-1.3" — a new document's version, below the 1.5 optional content needs.
        #expect(try String(decoding: Data(contentsOf: extract).prefix(8), as: UTF8.self) == "%PDF-1.7")

        let merged = box.file("merged.pdf")
        try QPDF.merge(sources: [.init(first), .init(second), .init(plain)], output: merged)
        let pdf = try #require(PDFDocument(url: merged))
        #expect(pdf.pageCount == 9)
        let labels = (0..<9).map { pdf.page(at: $0)?.label ?? "" }
        // A source without labels numbers its pages as decimals from where it starts.
        #expect(labels == ["A-101", "A-102", "A-103", "B-201", "B-202", "B-203", "7", "8", "9"], "\(labels)")
        // The document stays alive while its catalog is read: the catalog belongs to it.
        let mergedDocument = try #require(CGPDFDocument(merged as CFURL))
        let catalog = try #require(mergedDocument.catalog)
        var properties: CGPDFDictionaryRef?
        var groups: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties))
        #expect(properties.map { CGPDFDictionaryGetArray($0, "OCGs", &groups) } == true)
        #expect(groups.map(CGPDFArrayGetCount) == 3, "Walls, Doors and the third file's Walls")
    }
}
