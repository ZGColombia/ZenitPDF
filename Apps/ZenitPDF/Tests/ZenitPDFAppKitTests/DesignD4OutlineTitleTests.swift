import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZenitPDFAppKit

/// Design round d4 follow-up: the drawing's outline titles become the Navigator's sheet names.
/// Headless: files are written to the temporary directory and read back; nothing is shown.
@Suite("Design d4 — outline titles from the drawing", .appTierSerialised)
struct DesignD4OutlineTitleTests {

    /// Three ARCH D sheets; an "Architectural" section pointing at sheet 1 with two children,
    /// "A1.01 - Floor Plan" (sheet 1) and "A1.02 - Roof Plan" (sheet 3). Sheet 2 has no entry.
    ///
    /// Written as raw PDF bytes, as `Iter1RExportPDFAppTests.drawing(at:…outline:)` writes its
    /// bookmarks, so the file is the same on every macOS and only the reader is under test.
    /// It used to be saved through PDFKit — opened from the file, `outlineRoot` set, written back —
    /// and macOS 27's PDFKit writes such a document with no outline at all while `write(to:)`
    /// still returns `true`, which left the reader nothing to read.
    private func makeDrawing() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("d4-outline-\(UUID().uuidString).pdf")
        // Objects: 1 catalog, 2 page tree, 3–5 the sheets, 6 the outline root, 7 the section,
        // 8–9 its two sheet entries (PDF 32000-1 §12.3.3).
        let sheet = "/Type /Page /Parent 2 0 R /MediaBox [0 0 2592 1728] /Resources << >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< \(sheet) >>",
            "<< \(sheet) >>",
            "<< \(sheet) >>",
            "<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 3 >>",
            "<< /Title (Architectural) /Parent 6 0 R /First 8 0 R /Last 9 0 R /Count 2 /Dest [3 0 R /XYZ 0 0 null] >>",
            "<< /Title (A1.01 - Floor Plan) /Parent 7 0 R /Next 9 0 R /Dest [3 0 R /XYZ 0 0 null] >>",
            "<< /Title (A1.02 - Roof Plan) /Parent 7 0 R /Prev 8 0 R /Dest [5 0 R /XYZ 0 0 null] >>"
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        try pdf.write(to: url)
        return url
    }

    @Test("A section entry never names the sheet it points at; a page without an entry has none")
    func readsOutlineTitles() throws {
        let url = try makeDrawing()
        defer { try? FileManager.default.removeItem(at: url) }
        let titles = DocumentSessionLoader.readOutlineTitles(at: url, password: nil)
        #expect(titles == [0: "A1.01 - Floor Plan", 2: "A1.02 - Roof Plan"])
    }

    @Test("A drawing with no outline gives no titles, and a bad destination is ignored")
    func noOutline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("d4-no-outline-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        #expect(DocumentSessionLoader.readOutlineTitles(at: url, password: nil).isEmpty)

        let outline: [String: Any] = [
            kCGPDFOutlineChildren as String: [
                [kCGPDFOutlineTitle as String: "Off the end", kCGPDFOutlineDestination as String: 9],
                [kCGPDFOutlineTitle as String: "   ", kCGPDFOutlineDestination as String: 1],
                [kCGPDFOutlineTitle as String: "Cover", kCGPDFOutlineDestination as String: 1]
            ]
        ]
        #expect(DocumentSessionLoader.outlineTitles(from: outline, pageCount: 2) == [0: "Cover"])
    }

    /// A sheet entry with its own detail bookmarks (same page) keeps
    /// the sheet's name. The old "deepest wins" rule returned "Detail 1" for sheet 1.
    @Test("A sheet bookmark with detail children on the same page keeps the sheet's name")
    func sheetEntryBeatsItsDetails() {
        let outline: [String: Any] = [
            kCGPDFOutlineChildren as String: [
                [
                    kCGPDFOutlineTitle as String: "Architectural",
                    kCGPDFOutlineDestination as String: 1,
                    kCGPDFOutlineChildren as String: [
                        [
                            kCGPDFOutlineTitle as String: "A-101 Floor Plan",
                            kCGPDFOutlineDestination as String: 1,
                            kCGPDFOutlineChildren as String: [
                                [kCGPDFOutlineTitle as String: "Detail 1", kCGPDFOutlineDestination as String: 1],
                                [kCGPDFOutlineTitle as String: "Detail 3", kCGPDFOutlineDestination as String: 1]
                            ]
                        ],
                        [kCGPDFOutlineTitle as String: "A-102 Roof Plan", kCGPDFOutlineDestination as String: 2]
                    ]
                ],
                // A lone section pointing at a page nothing else names still names it.
                [
                    kCGPDFOutlineTitle as String: "Structural",
                    kCGPDFOutlineDestination as String: 3,
                    kCGPDFOutlineChildren as String: [
                        [kCGPDFOutlineTitle as String: "S-201", kCGPDFOutlineDestination as String: 4]
                    ]
                ]
            ]
        ]
        #expect(DocumentSessionLoader.outlineTitles(from: outline, pageCount: 4)
            == [0: "A-101 Floor Plan", 1: "A-102 Roof Plan", 2: "Structural", 3: "S-201"])
    }

    @Test("Titles are keyed by the drawing's page identities")
    func keyedByPageID() async throws {
        let url = try makeDrawing()
        defer { try? FileManager.default.removeItem(at: url) }
        let drawing = try await DocumentSessionLoader.load(pdfAt: url)
        let titles = DocumentSessionLoader.sheetOutlineTitles(for: drawing, password: nil)
        #expect(titles[drawing.pages[0].id.rawValue] == "A1.01 - Floor Plan")
        #expect(titles[drawing.pages[1].id.rawValue] == nil)
        #expect(titles[drawing.pages[2].id.rawValue] == "A1.02 - Roof Plan")
    }
}
