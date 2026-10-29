import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer
@testable import ZenitPDFAppKit

/// NL-MEASURE-09: a dragged caption and segment lengths leave the canvas with
/// the markup — in the Marked, Annotated and snippet outputs, which all compose through
/// `SnippetSceneBuilder`.
@MainActor
@Suite("Dragged captions and segment lengths in exports", .appTierSerialised)
struct NLPDFR2CaptionExportTests {

    @Test("A caption moved 40 pt right and 30 pt up is drawn there with a dashed leader; each segment gets its length")
    func captionAndSegmentsLeaveTheCanvas() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Captions.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { Task { await document.drawing?.rasterSource.close(); document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let page = try #require(document.drawing?.pages.first)
        // 100 pt = 1 m.
        _ = try await core.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                              knownLength: 1, knownLengthUnit: .metre)
        var record = MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .polylength,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 400, y: 300), PDFPoint(x: 400, y: 500)]),
            createdAt: Date(), modifiedAt: Date()
        )
        record.style.measurementCaption = MeasurementCaption(showsSegmentLengths: true, labelOffset: PDFPoint(x: 40, y: 30))
        _ = try await core.commands.perform(.addMarkup(record))
        await core.commands.settle()
        await core.refresh()

        let job = try await FlattenedDrawingExport.job(for: document)
        let fragments = try #require(job.pages.first).markups.filter { $0.id.rawValue != record.id.rawValue || true }
        let pills = fragments.compactMap { fragment -> RenderLabelPill? in
            if case let .labelPill(pill) = fragment.shape { return pill }
            return nil
        }
        // Old behaviour: the caption printed at its automatic place and no segment lengths.
        // The polyline caption anchors at its first point (100, 300); moved by (40, 30).
        let caption = try #require(pills.first { $0.fontSizeViewPoints == SnippetSceneBuilder.pillFontSizeViewPoints })
        #expect(caption.anchorPoint == PDFPoint(x: 140, y: 330))
        let leader = fragments.contains { fragment in
            if case let .polyline(line) = fragment.shape, line.points == [PDFPoint(x: 100, y: 300), PDFPoint(x: 140, y: 330)] {
                if case .pattern = fragment.style.dash { return true }
            }
            return false
        }
        #expect(leader, "a dashed leader back to the automatic place")
        // 300 pt and 200 pt at 100 pt per metre: 3 m and 2 m.
        let segments = pills.filter { $0.fontSizeViewPoints == SnippetSceneBuilder.segmentLabelFontSize }
        #expect(segments.count == 2)
        #expect(segments.contains { $0.text.hasPrefix("3") } && segments.contains { $0.text.hasPrefix("2") }, "\(segments.map(\.text))")
    }
}
