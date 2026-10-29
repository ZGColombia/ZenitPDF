import AppKit
import Foundation
import PDFKit
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// r2-pdf: in a project of several drawings the Marked, Annotated and print
/// outputs carry the whole set, in set order, and a sheet link is a /Link GoTo to its sheet.
@MainActor
@Suite("Exports of a project with several drawings", .appTierSerialised)
struct NLPDFR2SetExportTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test("Two drawings (A: 2 sheets, B: 1 sheet dropped first): Marked has 3 pages with each sheet's ink; Annotated has 3 pages, a sheet link GoTo and a web link URI; print lays out 3 sheets")
    func wholeSetIsWritten() async throws {
        let harness = try await Fix2Harness.make("Set A.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        try await save(harness.document, to: harness.directory.appendingPathComponent("Set.zpdfproj"))
        let b = try AppTestSupport.writeFixturePDF(named: "Set B.pdf", pageCount: 1)
        defer { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
        let document = harness.document
        let core = harness.core
        #expect(await document.addDrawingToSet(fileAt: b, at: 0))
        let pages = await core.session.pageDescriptors  // B1 A1 A2
        #expect(pages.count == 3)

        // One line on each sheet, at a height that says which sheet it is (y = 100, 200, 300).
        for (position, page) in pages.enumerated() {
            let y = Double(100 * (position + 1))
            _ = try await core.commands.perform(.addMarkup(MarkupRecord(
                id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
                geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: y), PDFPoint(x: 400, y: y)]),
                createdAt: Date(), modifiedAt: Date()
            )))
        }
        // A sheet link on B1 to A2, and a web link on A1.
        var sheetLink = MarkupRecord(
            id: MarkupID(UUID()), documentID: pages[0].documentID, pageID: pages[0].id, kind: .hyperlink, tool: nil,
            geometry: MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 50, y: 50), PDFPoint(x: 150, y: 80)]),
            createdAt: Date(), modifiedAt: Date()
        )
        sheetLink.link = MarkupLinkTarget(pageID: pages[2].id)
        var webLink = MarkupRecord(
            id: MarkupID(UUID()), documentID: pages[1].documentID, pageID: pages[1].id, kind: .hyperlink, tool: nil,
            geometry: MeasurementGeometry(pageID: pages[1].id, points: [PDFPoint(x: 50, y: 50), PDFPoint(x: 150, y: 80)]),
            createdAt: Date(), modifiedAt: Date()
        )
        webLink.link = MarkupLinkTarget(url: "https://example.org/spec")
        for record in [sheetLink, webLink] { _ = try await core.commands.perform(.addMarkup(record)) }
        await core.commands.settle()
        await core.refresh()

        // Old behaviour: every export wrote the primary drawing only — 2 pages, B missing.
        let marked = harness.directory.appendingPathComponent("marked.pdf")
        try await harness.controller.writeDrawing(.flattened, for: document, to: marked)
        let markedDocument = try #require(PDFDocument(url: marked))
        #expect(markedDocument.pageCount == 3)
        for position in 0..<3 {
            let points = FlattenedDrawingExportTests.pathPoints(in: try Data(contentsOf: marked), page: position + 1)
            let y = Double(100 * (position + 1))
            #expect(points.contains { abs(Double($0.y) - y) < 1.5 }, "sheet \(position + 1) carries its own line at y \(y)")
        }

        let annotated = harness.directory.appendingPathComponent("annotated.pdf")
        _ = try await harness.controller.writeAnnotatedDrawing(for: document, to: annotated)
        let annotatedDocument = try #require(PDFDocument(url: annotated))
        #expect(annotatedDocument.pageCount == 3)
        let goTo = try #require(annotatedDocument.page(at: 0)?.annotations.first { $0.type == "Link" })
        let target = try #require(goTo.destination?.page)
        #expect(annotatedDocument.index(for: target) == 2, "the sheet link lands on A2, the set's third sheet")
        let uri = try #require(annotatedDocument.page(at: 1)?.annotations.first { $0.type == "Link" })
        #expect((uri.action as? PDFActionURL)?.url?.absoluteString == "https://example.org/spec")

        // Print: the job for the set has three sheets, B's first.
        let set = try #require(await DrawingSetOutput.make(for: document))
        defer { set.cleanUp() }
        let job = try await FlattenedDrawingExport.job(for: document, set: set)
        #expect(job.pages.map(\.page.id) == pages.map(\.id))
        #expect(job.pages.map(\.sourcePageIndex) == [0, 1, 2])
    }
}
