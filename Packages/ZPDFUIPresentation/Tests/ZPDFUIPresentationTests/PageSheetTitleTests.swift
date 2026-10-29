import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Design round d4 follow-up: a page's sheet title, resolved own label (when a name) → outline → nil.
@Suite("Page sheet title")
struct PageSheetTitleTests {

    private func page(label: String, sheetTitle: String? = nil) -> PageDescriptor {
        let box = PDFRectValue(x: 0, y: 0, width: 2592, height: 1728)
        return PageDescriptor(
            id: UUID(), index: 0, label: label, mediaBox: box, cropBox: box,
            rotation: .degrees0, sheetTitle: sheetTitle
        )
    }

    /// Documents bug 4 (the page label when it differs from the
    /// number, else the outline title). The old code put the outline first and returned
    /// "Floor Plan" here, losing the sheet number "A-101".
    @Test("A named page label wins over the outline title; a bare-number label never does")
    func labelWinsOverOutline() {
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "Floor Plan", label: "A-101") == "A-101")
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "A1.01 - Floor Plan", label: "A-101") == "A-101")
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "  Roof Plan \n", label: "1") == "Roof Plan")
    }

    @Test("An outline title that already contains the label is used whole, so nothing is lost")
    func outlineContainingLabel() {
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "A-101 Floor Plan", label: "A-101") == "A-101 Floor Plan")
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "Sheet a-101 – Floor", label: "A-101") == "Sheet a-101 – Floor")
    }

    @Test("Without an outline title the page's own label is the title; a bare number never is")
    func labelFallback() {
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: nil, label: "A-101") == "A-101")
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: "   ", label: "S-201") == "S-201")
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: nil, label: "3") == nil)
        #expect(PageDescriptor.resolvedSheetTitle(outlineTitle: nil, label: "") == nil)
    }

    @Test("A descriptor carries its title, keeps everything else when retitled, and decodes without one")
    func descriptorCarriesTitle() throws {
        let plain = page(label: "1")
        #expect(plain.sheetTitle == nil)
        let titled = plain.withSheetTitle("Floor Plan")
        #expect(titled.sheetTitle == "Floor Plan")
        #expect(titled.id == plain.id && titled.label == plain.label && titled.cropBox == plain.cropBox)

        // An encoding from before the field existed still decodes, as untitled.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        json.removeValue(forKey: "sheetTitle")
        let old = try JSONDecoder().decode(PageDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.sheetTitle == nil)
        #expect(try JSONDecoder().decode(PageDescriptor.self, from: JSONEncoder().encode(titled)).sheetTitle == "Floor Plan")
    }
}
