import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// NL-PDF-17: text, check box, radio and choice fields read, filled into a copy, and read back
/// with their values and generated appearances; XFA refused.
@Suite("Form fields (NL-PDF-17)", .serialized)
struct NLPDFFormFieldsTests {

    /// An RFI form: Project (text), Urgent (check box), Discipline (radio: Structural /
    /// Electrical), Status (combo: Open / Closed).
    static func rfiForm(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.stroke(CGRect(x: 10, y: 10, width: 380, height: 280)); context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let text = PDFAnnotation(bounds: CGRect(x: 40, y: 230, width: 200, height: 22), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text; text.fieldName = "Project"
        page.addAnnotation(text)
        let check = PDFAnnotation(bounds: CGRect(x: 40, y: 190, width: 16, height: 16), forType: .widget, withProperties: nil)
        check.widgetFieldType = .button; check.widgetControlType = .checkBoxControl; check.fieldName = "Urgent"
        page.addAnnotation(check)
        for (index, option) in ["Structural", "Electrical"].enumerated() {
            let radio = PDFAnnotation(bounds: CGRect(x: 40 + CGFloat(index) * 60, y: 150, width: 16, height: 16), forType: .widget, withProperties: nil)
            radio.widgetFieldType = .button; radio.widgetControlType = .radioButtonControl; radio.fieldName = "Discipline"
            radio.buttonWidgetStateString = option
            page.addAnnotation(radio)
        }
        let choice = PDFAnnotation(bounds: CGRect(x: 40, y: 110, width: 120, height: 22), forType: .widget, withProperties: nil)
        choice.widgetFieldType = .choice; choice.fieldName = "Status"; choice.choices = ["Open", "Closed"]; choice.isListChoice = false
        page.addAnnotation(choice)
        #expect(document.write(to: url))
    }

    @Test("Four kinds read; values written into a copy come back, with appearances; the source is unchanged")
    func fillsACopy() throws {
        let directory = try Corpus.scratchDirectory("nlpdf-forms")
        let source = directory.appendingPathComponent("rfi.pdf"), filled = directory.appendingPathComponent("rfi filled.pdf")
        try Self.rfiForm(at: source)
        let before = try Data(contentsOf: source)
        // Old behaviour: form fields were detected as a hazard only; nothing could fill them.
        let fields = try PDFFormFields.fields(ofFileAt: source)
        #expect(fields.map(\.name) == ["Project", "Urgent", "Discipline", "Status"])
        #expect(fields[0].kind == .text(multiline: false))
        #expect(fields[1].kind == .checkBox)
        #expect(fields[2].kind == .radio(options: ["Structural", "Electrical"]))
        #expect(fields[3].kind == .choice(options: ["Open", "Closed"], editable: true))

        let changed = try PDFFormFields.fill(source: source, values: [
            "Project": .text("Level 3 slab"), "Urgent": .checked(true), "Discipline": .option("Electrical"), "Status": .option("Closed")
        ], to: filled)
        #expect(changed == 4)
        #expect(try Data(contentsOf: source) == before)
        let back = try PDFFormFields.fields(ofFileAt: filled)
        #expect(back[0].value == "Level 3 slab")
        #expect(back[1].isOn)
        #expect(back[2].value == "Electrical")
        #expect(back[3].value == "Closed")
        // Another reader draws the filled text: the widget carries an appearance stream.
        let document = try #require(CGPDFDocument(filled as CFURL))
        let page = try #require(document.page(at: 1)?.dictionary)
        var annots: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(page, "Annots", &annots))
        var withAppearance = 0
        for index in 0..<CGPDFArrayGetCount(annots!) {
            var annotation: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(annots!, index, &annotation), CGPDFDictionaryGetDictionary(annotation!, "AP", &appearance) { withAppearance += 1 }
        }
        #expect(withAppearance >= 4, "\(withAppearance) widgets carry /AP")
        withExtendedLifetime(document) {}
    }

    @Test("An XFA form is refused in words")
    func xfaRefused() throws {
        let directory = try Corpus.scratchDirectory("nlpdf-xfa")
        let url = directory.appendingPathComponent("xfa.pdf")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] /XFA (template) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
        #expect(throws: PDFFormFields.Refusal.xfa) { try PDFFormFields.fields(ofFileAt: url) }
        #expect(PDFFormFields.Refusal.xfa.description.contains("XFA"))
    }
}
