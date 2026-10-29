import AppKit
import CoreText
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Feature 31's application flow, end to end and panel-free: region in, review model out,
/// accept lands `.read` rows with their columns in the ledger. The presenter is injected —
/// no sheet touches the screen.
@MainActor
@Suite(.appTierSerialised)
struct TableImportWiringTests {

    /// A page carrying a printed two-column schedule as REAL text: a header row and two
    /// data rows, columns aligned so the engine's text-alignment fallback finds them.
    private static func writeScheduleFixture(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("schedule.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black
        ]
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        draw("Littera", x: 100, y: 700)
        draw("Antal", x: 260, y: 700)
        draw("D01", x: 100, y: 680)
        draw("2", x: 260, y: 680)
        draw("F01", x: 100, y: 660)
        draw("4", x: 260, y: 660)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test("Region → review model → accept: read rows and their columns land in the ledger")
    func regionToReadRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-table-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try Self.writeScheduleFixture(in: directory)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)

        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })

        // The presenter is the test: capture the model instead of sheeting it.
        var captured: TableImportReviewModel?
        let previous = ProjectWindowController.tableReviewPresenter
        defer { ProjectWindowController.tableReviewPresenter = previous }
        ProjectWindowController.tableReviewPresenter = { model, _ in captured = model; return {} }

        // Arm and drag: the command's own region path, fired directly.
        controller.beginTableImport(for: document)
        let canvas = try #require(controller.canvasController(for: document))
        canvas.onSnippetRegion?(PDFRectValue(x: 80, y: 640, width: 260, height: 90))

        #expect(await AppTestSupport.wait { captured != nil }, "the review panel never arrived")
        let model = try #require(captured)
        #expect(model.refusal == nil, "a clean two-column schedule must not be refused")
        #expect(model.columns.count == 2)
        #expect(model.rows.count == 2, "the header row is the header, not data")

        let markupsBefore = await core.session.orderedMarkups.count
        model.accept()

        var landed = false
        for _ in 0..<100 {
            if await core.session.orderedMarkups.count == markupsBefore + 2 { landed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(landed, "accepting never landed the rows")
        let markups = await core.session.orderedMarkups
        let readRows = markups.filter { $0.provenance == .read }
        #expect(readRows.count == 2, "imported rows must carry the read claim (ADR-0012)")
        #expect(Set(readRows.map(\.subject)) == ["D01", "F01"],
                "the subject column classifies the rows")
        for row in readRows {
            #expect(row.derivation != nil, "a read row without its derivation is invalid")
        }

        // The minted columns joined the ledger's set, under their reviewed titles —
        // read through the projection, the same surface the pane renders from.
        let projection = try await core.session.ledgerProjection(.flat)
        #expect(projection.columns.contains { $0.title == "Littera" })
        #expect(projection.columns.contains { $0.title == "Antal" })

        document.close()
    }
}
