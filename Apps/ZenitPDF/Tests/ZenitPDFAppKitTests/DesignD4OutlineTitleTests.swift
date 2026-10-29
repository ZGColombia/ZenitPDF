import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFContracts
@testable import ZenitPDFAppKit

/// Design round d4 follow-up: the drawing's outline titles become the Navigator's sheet names.
/// Headless: files are written to the temporary directory and read back; nothing is shown.
@Suite("Design d4 — outline titles from the drawing", .appTierSerialised)
struct DesignD4OutlineTitleTests {

    /// Three ARCH D sheets; an "Architectural" section pointing at sheet 1 with two children,
    /// "A1.01 - Floor Plan" (sheet 1) and "A1.02 - Roof Plan" (sheet 3). Sheet 2 has no entry.
    private func makeDrawing() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("d4-outline-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 2592, height: 1728)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let document = try #require(PDFDocument(url: url))
        let root = PDFOutline()
        let section = PDFOutline()
        section.label = "Architectural"
        section.destination = PDFDestination(page: try #require(document.page(at: 0)), at: .zero)
        let floor = PDFOutline()
        floor.label = "A1.01 - Floor Plan"
        floor.destination = PDFDestination(page: try #require(document.page(at: 0)), at: .zero)
        let roof = PDFOutline()
        roof.label = "A1.02 - Roof Plan"
        roof.destination = PDFDestination(page: try #require(document.page(at: 2)), at: .zero)
        section.insertChild(floor, at: 0)
        section.insertChild(roof, at: 1)
        root.insertChild(section, at: 0)
        document.outlineRoot = root
        #expect(document.write(to: url))
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
