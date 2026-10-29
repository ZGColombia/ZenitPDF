import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
@testable import ZenitPDFAppKit

/// Measurement overlay export and import through `MeasurementOverlayTransfer`, the File menu's
/// route to them. Panels are answered by injection; nothing reaches the screen.
@MainActor
@Suite("Measurement overlay export and import", .appTierSerialised)
struct MeasurementOverlayTransferTests {

    @Test("Export, then import onto a renamed copy: the measurements are redrawn once, in one undo, with the rename noted")
    func roundTripOntoRenamedCopy() async throws {
        let source = try await Fix2Harness.make("Overlay A-101.pdf", pageCount: 2)
        defer { source.tearDown() }
        let length = try await source.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100)])
        }, subject: "Wall")
        _ = try await source.addMarkup(tool: .area, geometry: { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300),
            ], isClosed: true))])
        }, subject: "Slab", pageIndex: 1)

        let data = try #require(try await MeasurementOverlayTransfer.overlayData(for: source.document))
        let overlayURL = source.directory.appendingPathComponent("A-101.zpdfoverlay")
        try data.write(to: overlayURL)

        // The same bytes under another name, opened as a second document.
        let copyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copyDirectory) }
        let copyURL = copyDirectory.appendingPathComponent("Renamed plan.pdf")
        try FileManager.default.copyItem(at: try #require(source.document.drawing?.url), to: copyURL)
        let target = try await Fix2Harness.make("unused.pdf", fixture: copyURL)
        defer { target.document.close() }

        ZenitModalPresenter.reset()
        let plan = try #require(await MeasurementOverlayTransfer.importOverlay(from: overlayURL, into: target.document))
        #expect(ZenitModalPresenter.recorded.isEmpty, "a matching overlay raises nothing")
        #expect(plan.records.count == 2)
        #expect(plan.skipped.isEmpty)
        #expect(plan.match == .renamed(from: "Overlay A-101.pdf", to: "Renamed plan.pdf"))
        await target.settle()
        let records = await target.records()
        #expect(records.count == 2)
        let importedLength = try #require(records.first { $0.tool == .length })
        #expect(importedLength.geometry?.points == length.geometry?.points)
        #expect(importedLength.subject == "Wall")
        // The area went to page 2 of the target, by index.
        let area = try #require(records.first { $0.tool == .area })
        let pages = try #require(target.document.drawing?.pages)
        #expect(area.pageID == pages[1].id)
        #expect(area.geometry?.pageID == pages[1].id)
        #expect(target.core.document.warnings.contains { $0.id == MeasurementOverlayTransfer.resultNoteID })

        // One undo removes both.
        target.document.undoManager?.undo()
        await target.settle()
        #expect(await target.records().isEmpty)
    }

    @Test("An overlay made on a different drawing is refused naming both files, and nothing is added")
    func differentDrawingRefused() async throws {
        let source = try await Fix2Harness.make("Plan one.pdf")
        defer { source.tearDown() }
        _ = try await source.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)])
        })
        let data = try #require(try await MeasurementOverlayTransfer.overlayData(for: source.document))
        let overlayURL = source.directory.appendingPathComponent("one.zpdfoverlay")
        try data.write(to: overlayURL)

        let other = try await Fix2Harness.make("Plan two.pdf", pageCount: 3)
        defer { other.tearDown() }
        ZenitModalPresenter.reset()
        let plan = await MeasurementOverlayTransfer.importOverlay(from: overlayURL, into: other.document)
        #expect(plan == nil)
        let refusal = try #require(ZenitModalPresenter.lastRecorded)
        #expect(refusal.identifier == MeasurementOverlayTransfer.refusalIdentifier)
        #expect(refusal.detail.contains("Plan one.pdf") && refusal.detail.contains("Plan two.pdf"), "\(refusal.detail)")
        #expect(await other.records().isEmpty)
    }

    @Test("Export and import go through injected panels, and both commands sit under File after Export")
    func commandsAndPanels() async throws {
        let harness = try await Fix2Harness.make("Panels.pdf")
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.handler = nil }
        MeasurementOverlayTransfer.export(document: harness.document, window: nil)
        MeasurementOverlayTransfer.importOverlay(document: harness.document, window: nil)
        #expect(ZenitModalPresenter.didRequest(MeasurementOverlayTransfer.exportPanelIdentifier))
        #expect(ZenitModalPresenter.didRequest(MeasurementOverlayTransfer.importPanelIdentifier))
        let slots = ZenitAppCommandTable.specs.filter { $0.slot == .fileAfterExport }.map(\.command)
        #expect(slots.contains(.exportMeasurementOverlay) && slots.contains(.importMeasurementOverlay))
    }

    /// X-042, cycle 2. An overlay exported by a build before X-042 can carry an Arc Length at four
    /// points. Made here from a real export of the three-point arc (100, 100), (150, 150),
    /// (200, 100) with a fourth point (250, 150) written into its geometry. The import lands it as
    /// the three it was measured on: the semicircle of r = 50 pt, 50π pt = 0.5π m at 100 pt = 1 m.
    /// Old output: the engine refused the fourth point, the one batch threw, and the whole file was
    /// turned away — "“Arc A-1.zpdfoverlay” was not imported", nothing added.
    @Test("X-042 c2: an overlay carrying a four-point Arc Length imports it as its first three points")
    func olderOverlayWithFourPointArcLength() async throws {
        let harness = try await Fix2Harness.make("Arc A-1.pdf")
        defer { harness.tearDown() }
        let original = try await harness.addMarkup(tool: .arcLength, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 150, y: 150), PDFPoint(x: 200, y: 100)])
        }, subject: "Kerb")
        let exported = try #require(try await MeasurementOverlayTransfer.overlayData(for: harness.document))
        // The exporter writes each coordinate as `Double`'s own description, pretty-printed.
        let text = String(decoding: exported, as: UTF8.self)
        let thirdPoint = try NSRegularExpression(pattern: #"("x":\s*"200\.0",\s*"y":\s*"100\.0"\s*\})"#)
        let range = NSRange(text.startIndex..., in: text)
        #expect(thirdPoint.numberOfMatches(in: text, range: range) == 1)
        let older = thirdPoint.stringByReplacingMatches(in: text, range: range, withTemplate: #"$1, {"x": "250.0", "y": "150.0"}"#)
        let overlayURL = harness.directory.appendingPathComponent("Arc A-1.zpdfoverlay")
        try Data(older.utf8).write(to: overlayURL)

        ZenitModalPresenter.reset()
        let plan = try #require(await MeasurementOverlayTransfer.importOverlay(from: overlayURL, into: harness.document))
        #expect(ZenitModalPresenter.recorded.isEmpty, "nothing refused")
        #expect(plan.records.count == 1 && plan.skipped.isEmpty)
        await harness.settle()
        let imported = try #require(await harness.records().first { $0.id != original.id && $0.tool == .arcLength })
        #expect(imported.geometry?.points == original.geometry?.points)
        let value = try #require(imported.measurement?[.arcLength]?.value)
        let metres = NSDecimalNumber(decimal: value).doubleValue
        #expect(Swift.abs(metres - 0.5 * Double.pi) <= 0.5 * Double.pi * 1e-12, "\(metres)")
    }

    @Test("Without a placement, only shapes that name their tool are redrawn; the rest are listed")
    func olderOverlayInference() {
        let page = PageID(UUID())
        #expect(MeasurementOverlayTransfer.inferredTool(for: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0)])) == .length)
        #expect(MeasurementOverlayTransfer.inferredTool(for: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)])) == .polylength)
        #expect(MeasurementOverlayTransfer.inferredTool(for: MeasurementGeometry(pageID: page, countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 1, y: 1))])) == .count)
        // Mixed shapes could be several tools: never guessed.
        #expect(MeasurementOverlayTransfer.inferredTool(for: MeasurementGeometry(
            pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0)], countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 1, y: 1))])) == nil)
    }
}
