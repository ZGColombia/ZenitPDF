import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFQPDF

/// NL-DOCS-08: Split into Sheets writes one file per sheet,
/// and extracting them one call at a time opened the drawing once per sheet. `extractPageGroups`
/// parses it once. Old behaviour: 300 sheets of a 2 MB layered set took 22.7 s in qpdf alone,
/// over the 20 s budget for the whole split.
@Suite("Iteration 1 re-fix — page groups from one parse (NL-DOCS-08)")
struct Iter1RQPDFPageGroupTests {

    /// `pageCount` sheets labelled A-101…, each with 200 lines in layer "Walls" and
    /// `formsPerSheet` forms of its own — the object count of a real set, not of a toy.
    static func layeredSet(pageCount: Int, formsPerSheet: Int) -> Data {
        var objects: [(String, Data?)] = [
            ("<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D /P (A-) /St 101 >>] >>"
                + " /OCProperties << /OCGs [3 0 R] /D << /Order [3 0 R] /ON [] /OFF [3 0 R] >> >> >>", nil),
            ("", nil),
            ("<< /Type /OCG /Name (Walls) >>", nil),
        ]
        var kids: [String] = []
        for index in 0..<pageCount {
            var content = "/OC /L1 BDC 0 0 0 RG 1 w\n"
            for step in 0..<200 { content += "\(10 + step) 10 m \(10 + step) \(150 + index % 40) l S\n" }
            content += "EMC\n"
            var forms: [String] = []
            for form in 0..<formsPerSheet {
                let body = Data("0 0 1 RG \(form) 0 m \(form) 20 l S\n".utf8)
                objects.append(("<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Length \(body.count) >>", body))
                forms.append("/F\(form) \(objects.count) 0 R")
                content += "q 1 0 0 1 \(20 + form * 3) 160 cm /F\(form) Do Q\n"
            }
            let data = Data(content.utf8)
            objects.append(("<< /Length \(data.count) >>", data))
            let contents = objects.count
            objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents \(contents) 0 R"
                + " /Resources << /Properties << /L1 3 0 R >> /XObject << \(forms.joined(separator: " ")) >> >> >>", nil))
            kids.append("\(objects.count) 0 R")
        }
        objects[1].0 = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pageCount) >>"
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object.0)\n".utf8))
            if let stream = object.1 {
                pdf.append(Data("stream\n".utf8))
                pdf.append(stream)
                pdf.append(Data("\nendstream\n".utf8))
            }
            pdf.append(Data("endobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    /// The `/St` and `/P` of the one label range a single-sheet copy carries, read from the
    /// catalog (PDFKit does not number a sheet of such a small file by its label).
    static func label(_ url: URL) throws -> String? {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var labels: CGPDFDictionaryRef?
        var nums: CGPDFArrayRef?
        var range: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "PageLabels", &labels), let labels,
              CGPDFDictionaryGetArray(labels, "Nums", &nums), let nums,
              CGPDFArrayGetDictionary(nums, 1, &range), let range else { return nil }
        var start: CGPDFInteger = 1
        _ = CGPDFDictionaryGetInteger(range, "St", &start)
        var prefix: CGPDFStringRef?
        let text = CGPDFDictionaryGetString(range, "P", &prefix) ? (prefix.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "") : ""
        return text + String(start)
    }

    static func hasLayerDefinitions(_ url: URL) throws -> Bool {
        let document = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(document.catalog)
        var properties: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "OCProperties", &properties)
    }

    @Test("Each group becomes its own file, in group order, with its labels and the layer definitions")
    func groupsInOrder() throws {
        let box = try Sandbox("it1r-groups")
        let input = box.file("set.pdf")
        try Self.layeredSet(pageCount: 3, formsPerSheet: 1).write(to: input)
        let files = try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "sheet",
                                               pageGroups: [[2], [0], [1, 2]])
        #expect(files.map(\.lastPathComponent) == ["sheet-0001.pdf", "sheet-0002.pdf", "sheet-0003.pdf"])
        #expect(try files.map { try Self.label($0) } == ["A-103", "A-101", "A-102"])
        #expect(PDFDocument(url: files[2])?.pageCount == 2)
        for file in files { #expect(try Self.hasLayerDefinitions(file)) }
    }

    @Test("A bad group is refused before anything is written; a collision writes nothing")
    func refusals() throws {
        let box = try Sandbox("it1r-groups-refused")
        let input = box.file("set.pdf")
        try Self.layeredSet(pageCount: 3, formsPerSheet: 0).write(to: input)
        #expect(throws: QPDFError.self) { try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "a", pageGroups: [[0], [3]]) }
        #expect(throws: QPDFError.self) { try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "a", pageGroups: [[1, 1]]) }
        #expect(throws: QPDFError.self) { try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "a", pageGroups: [[0], []]) }
        #expect(throws: QPDFError.self) { try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "a/b", pageGroups: [[0]]) }
        try Data("taken".utf8).write(to: box.file("b-0002.pdf"))
        #expect(throws: QPDFError.self) { try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "b", pageGroups: [[0], [1]]) }
        #expect(!FileManager.default.fileExists(atPath: box.file("b-0001.pdf").path), "nothing before the collision is left")
        let names = try FileManager.default.contentsOfDirectory(atPath: box.url.path).filter { $0.hasPrefix("a-") }
        #expect(names.isEmpty)
    }

    @Test("300 sheets of a 2 MB layered set, one file each, from one parse")
    func threeHundredSheetsFromOneParse() throws {
        let box = try Sandbox("it1r-groups-300")
        let input = box.file("set.pdf")
        let data = Self.layeredSet(pageCount: 300, formsPerSheet: 12)
        try data.write(to: input)
        let clock = ContinuousClock()
        var files: [URL] = []
        let elapsed = try clock.measure {
            files = try QPDF.extractPageGroups(input: input, outputDirectory: box.url, basename: "sheet",
                                               pageGroups: (0..<300).map { [$0] })
        }
        print("[timing] extractPageGroups: 300 sheets of a \(data.count)-byte layered set: \(elapsed)")
        #expect(files.count == 300)
        // Old: one extractPages call per sheet, 22.7 s for the set measured the same way.
        #expect(elapsed < .seconds(5))
        #expect(try Self.label(files[149]) == "A-250")
        #expect(try Self.hasLayerDefinitions(files[299]))
    }
}
