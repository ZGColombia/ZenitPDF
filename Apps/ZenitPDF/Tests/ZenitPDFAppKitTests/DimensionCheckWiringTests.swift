import AppKit
import CoreText
import Foundation
import Testing
import ZPDFContracts
@testable import ZenitPDFAppKit

/// Feature 13's application command: measurements on the page against the dimensions
/// printed beside them. Opt-in — nothing runs until the command is chosen — and silence on
/// everything uncertain is the engine's own guarantee, proven in ZPDFMeasurementEngine.
@MainActor
@Suite(.appTierSerialised)
struct DimensionCheckWiringTests {

    /// A one-page PDF with a horizontal line and a real text run beside it — embedded
    /// text, not pixels, so PDFKit's text layer carries it with a position.
    private static func writeFixture(dimensionText: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("dimension-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 100, y: 100))
        context.addLine(to: CGPoint(x: 300, y: 100))
        context.strokePath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: dimensionText, attributes: attributes)
        )
        context.textPosition = CGPoint(x: 170, y: 110)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func makeDocument(
        dimensionText: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-dimension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try Self.writeFixture(dimensionText: dimensionText, in: directory)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)

        // 100 pt = 1 m, so the 200 pt line measures 2.000 m.
        _ = try await core.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .length,
            subject: "Wall A",
            geometry: MeasurementGeometry(
                pageID: page.id,
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)]
            ),
            createdAt: Date(),
            modifiedAt: Date()
        )))
        await core.commands.settle()
        await core.refresh()

        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        return (document, controller, directory)
    }

    @Test("A drawn dimension that disagrees raises the warning, with the tolerance named")
    func disagreementWarns() async throws {
        // Drawn 2 100 mm, measured 2 000 mm: plausibly the same measurement, 100 mm apart.
        let (document, controller, directory) = try await makeDocument(dimensionText: "2 100")
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let core = try #require(document.core)

        controller.checkDrawnDimensions(for: document)
        #expect(await AppTestSupport.wait {
            core.status.warnings.contains { $0.id == ProjectWindowController.dimensionCheckWarningID }
        }, "a 100 mm disagreement under a 10 mm tolerance must warn")
        let warning = try #require(core.status.warnings.first {
            $0.id == ProjectWindowController.dimensionCheckWarningID
        })
        #expect(warning.message.contains("Wall A") || warning.message.contains("2.1"),
                "the warning must name what disagreed")
        #expect(warning.message.contains("0.01"), "the tolerance in force must be stated")
    }

    @Test("A drawn dimension that agrees stays silent — no warning, an all-clear note instead")
    func agreementIsQuiet() async throws {
        let (document, controller, directory) = try await makeDocument(dimensionText: "2 000")
        defer {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let core = try #require(document.core)

        controller.checkDrawnDimensions(for: document)
        // The all-clear is a status note, so wait for that; the tray must stay clean.
        #expect(await AppTestSupport.wait {
            core.status.snapshot.activeToolNote?.contains("agree") == true
        }, "the all-clear note never arrived")
        #expect(!core.status.warnings.contains {
            $0.id == ProjectWindowController.dimensionCheckWarningID
        }, "an agreeing sheet must not warn — a false alarm teaches people to ignore the real one")
    }
}
