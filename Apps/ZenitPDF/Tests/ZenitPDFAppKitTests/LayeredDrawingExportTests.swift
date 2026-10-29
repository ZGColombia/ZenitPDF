import AppKit
import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// Feature 35's application command, panel-free: the write half `exportLayeredDrawing`
/// sheets a save panel over.
@MainActor
@Suite(.appTierSerialised)
struct LayeredDrawingExportTests {

    @Test("The layered export preserves the source bytes and adds the switchable layer")
    func layeredExportWritesTheArtefact() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Layered.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let drawing = try #require(document.drawing)
        let page = try #require(drawing.pages.first)

        _ = try await core.commands.perform(.addMarkup(MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .length,
            subject: "Layered fixture",
            geometry: MeasurementGeometry(
                pageID: page.id,
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)]
            ),
            createdAt: Date(),
            modifiedAt: Date()
        )))
        await core.commands.settle()
        await core.refresh()

        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        let destination = directory.appendingPathComponent("layered-out.pdf")
        let outcome = try await controller.writeLayeredDrawing(for: document, to: destination)
        #expect(outcome.paintedMarkupCount >= 1)

        // The promise of ADR-0013: the source's bytes are the artefact's prefix.
        let source = try Data(contentsOf: url)
        let artefact = try Data(contentsOf: destination)
        #expect(artefact.count > source.count)
        #expect(
            Data(SHA256.hash(data: artefact.prefix(source.count)))
                == Data(SHA256.hash(data: source)),
            "the drawing must be byte for byte at the front of the artefact"
        )

        // The layer is really there, and a stock reader opens the file.
        let raw = String(decoding: artefact, as: UTF8.self)
        #expect(raw.contains("/OCProperties"))
        #expect(raw.contains(LayeredMarkupExporter.defaultLayerName))
        #expect(PDFDocument(url: destination) != nil, "PDFKit must open the artefact")

        // Refusal, not silence: writing onto the source itself is refused.
        await #expect(throws: (any Error).self) {
            try await controller.writeLayeredDrawing(for: document, to: url)
        }

        await document.drawing?.rasterSource.close()
        document.close()
    }
}
