import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MEASURE-02: Measure ▸ Apply Scale to Pages… presents the built `BulkScaleSheet`, previews
/// what it would change, and applies the page's scale to the target in one ⌘Z.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureBulkScaleTests {

    private func descriptor(_ index: Int, width: Double, height: Double) -> ZPDFUIPresentation.PageDescriptor {
        let box = PDFRectValue(x: 0, y: 0, width: width, height: height)
        return ZPDFUIPresentation.PageDescriptor(
            id: UUID(), index: index, label: "P\(index + 1)", mediaBox: box, cropBox: box, rotation: .degrees0
        )
    }

    /// Four pages: A1, A1, A4, A1. From page 1, "same dimensions" is pages 1, 2, 4; a range
    /// 2–3 is pages 2 and 3; a reversed range is nothing.
    @Test("Targets resolve to the pages the sheet names")
    func targets() {
        let pages = [
            descriptor(0, width: 1_684, height: 2_384), descriptor(1, width: 1_684, height: 2_384),
            descriptor(2, width: 595, height: 842), descriptor(3, width: 1_684.2, height: 2_384)
        ]
        let ids = pages.map(\.id)
        #expect(BulkScaleTargets.pages(for: BulkScaleSelection(kind: .matchingDimensions), current: ids[0], selected: [], pages: pages)
                == [ids[0], ids[1], ids[3]])
        #expect(BulkScaleTargets.pages(for: BulkScaleSelection(kind: .pageRange, rangeStart: 2, rangeEnd: 3), current: ids[0], selected: [], pages: pages)
                == [ids[1], ids[2]])
        #expect(BulkScaleTargets.pages(for: BulkScaleSelection(kind: .pageRange, rangeStart: 3, rangeEnd: 2), current: ids[0], selected: [], pages: pages)
                .isEmpty)
        #expect(BulkScaleTargets.pages(for: BulkScaleSelection(kind: .selectedPages), current: ids[0], selected: [ids[3], ids[1]], pages: pages)
                == [ids[1], ids[3]])
        #expect(BulkScaleTargets.pages(for: BulkScaleSelection(kind: .entireDocument), current: ids[0], selected: [], pages: pages) == ids)
    }

    /// A three-page A4 set, page 1 calibrated at 100 pt = 10 m and a length of 100 pt on page 3.
    /// Applying to "same dimensions" writes pages 2 and 3 in one step: page 3's length becomes
    /// 10 m; one undo takes both pages back to no scale.
    @Test("Apply Scale to Pages copies the scale in one undoable step, with an honest preview")
    func applyToSameSizePages() async throws {
        ZenitModalPresenter.reset()
        let url = try AppTestSupport.writeFixturePDF(named: "Bulk Set.pdf", pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil && document.drawing != nil })
        document.addWindowController(controller)
        defer {
            controller.window?.close()
            document.updateChangeCount(.changeCleared)
            document.close()
            ZenitModalPresenter.reset()
        }
        let core = try #require(document.core)
        #expect(await AppTestSupport.wait { core.document.currentPageID != nil && core.snapshot.pages.count == 3 })
        let pages = core.snapshot.pages.map { PageID($0.id) }
        _ = try await core.commands.calibrate(
            page: pages[0], first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let length = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: pages[2],
            kind: .measurement, tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: pages[2], points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(length))
        await core.refresh()

        let sheet = try #require(controller.presentBulkScaleSheet(for: document))
        #expect(ZenitModalPresenter.didRequest(BulkScaleCoordinator.modalIdentifier))
        #expect(sheet.model.selection.kind == .matchingDimensions)
        await sheet.settlePreview()
        #expect(sheet.model.impact.pageCount == 2, "the source page is not a target")
        #expect(sheet.model.impact.affectedMeasurementCount == 1)

        await sheet.apply(sheet.model.selection)
        #expect(sheet.isFinished)
        #expect(sheet.appliedPages == [pages[1], pages[2]])
        let copied = try #require(await core.session.scale(onPage: pages[2]))
        #expect(copied.source == .inherited)
        #expect(copied.matrix.a == Decimal(10) / Decimal(100))
        #expect(await core.session.markup(length.id)?.measurement?[.planLength]?.value == 10)

        await core.commands.undo()
        #expect(await core.session.isCalibrated(page: pages[1]) == false)
        #expect(await core.session.isCalibrated(page: pages[2]) == false)
        #expect(await core.session.isCalibrated(page: pages[0]), "the source page keeps its calibration")
    }

    /// A page with no scale has nothing to apply: the calibration sheet opens instead.
    @Test("Apply Scale to Pages on an uncalibrated page opens the calibration sheet")
    func uncalibratedSourceOpensCalibration() async throws {
        ZenitModalPresenter.reset()
        let url = try AppTestSupport.writeFixturePDF(named: "Bulk None.pdf", pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil && document.drawing != nil })
        document.addWindowController(controller)
        defer {
            ScaleSheetCoordinator.active(for: document)?.cancel()
            controller.window?.close()
            document.close()
            ZenitModalPresenter.reset()
        }
        #expect(await AppTestSupport.wait { document.core?.document.currentPageID != nil })
        #expect(controller.presentBulkScaleSheet(for: document) == nil)
        #expect(ScaleSheetCoordinator.active(for: document) != nil)
    }
}
