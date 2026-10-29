import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-DOCS-07 (rotate, remove from set) and NL-DOCS-16 (view crop) through the Navigator's
/// hooks, and the "No scale" badge state (NL-MEASURE-02). Headless; the removal
/// question is answered through `ZenitModalPresenter`. 100 pt = 1 m.
@MainActor
@Suite("Documents — arranging the set in the app", .appTierSerialised)
struct NextLevelDocumentsArrangementAppTests {

    private func length(on pageID: PageID, documentID: DocumentID, points: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: pageID, kind: .measurement, tool: .polylength,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 100 + points, y: 100)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test("Rotate turns the sheet on screen, not its quantity; crop shows part of it; each is one undo")
    func rotateAndCrop() async throws {
        let harness = try await Fix2Harness.make("Turn.pdf", pageCount: 2)
        defer { harness.tearDown() }
        let core = harness.core
        let first = try #require(await core.session.firstPageID)
        let documentID = try #require(harness.document.drawing?.documentID)
        _ = try await core.commands.perform(.addMarkup(length(on: first, documentID: documentID, points: 350)))
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(string: "3.5"))
        let upright = try #require(core.document.pages.first)
        let sizeBefore = upright.viewSize

        let rotate = try #require(harness.shell.onRotatePages, "the window wires Rotate")
        rotate([first.rawValue], 90)
        #expect(await AppTestSupport.wait { core.document.pages.first?.viewRotation == 90 })
        let turned = try #require(core.document.pages.first)
        #expect(turned.viewSize.width == sizeBefore.height && turned.viewSize.height == sizeBefore.width, "the sheet stands turned")
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(string: "3.5"), "a turn changes no quantity")

        await harness.document.cropPage(first, to: PDFRectValue(x: 10, y: 20, width: 200, height: 100))
        let cropped = try #require(core.document.pages.first)
        #expect(cropped.viewBox == PDFRectValue(x: 10, y: 20, width: 200, height: 100))
        #expect(cropped.viewRotation == 90, "the crop keeps the turn")
        #expect(cropped.viewSize.width == 100 && cropped.viewSize.height == 200)
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(string: "3.5"), "a crop changes no quantity")

        await core.commands.undo()
        await core.refresh()
        #expect(core.document.pages.first?.viewCrop == nil, "one ⌘Z takes the crop back")
        #expect(core.document.pages.first?.viewRotation == 90)
    }

    @Test("Remove from Set asks when the sheet is measured, drops its rows, lists it; Restore brings all back")
    func removeAndRestore() async throws {
        let harness = try await Fix2Harness.make("Remove.pdf", pageCount: 2)
        defer {
            ZenitModalPresenter.handler = nil
            harness.tearDown()
        }
        let core = harness.core
        let first = try #require(await core.session.firstPageID)
        let documentID = try #require(harness.document.drawing?.documentID)
        _ = try await core.commands.perform(.addMarkup(length(on: first, documentID: documentID, points: 200)))
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(2))

        // Declined: nothing changes.
        var asked: [String] = []
        ZenitModalPresenter.handler = { request in asked.append(request.identifier); return .button(1) }
        let remove = try #require(harness.shell.onSetPagesRemoved, "the window wires Remove from Set")
        remove([first.rawValue], true)
        #expect(await AppTestSupport.wait { !asked.isEmpty })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(core.document.pages.count == 2, "Cancel leaves the sheet in the set")

        // Confirmed: out of the set and out of the ledger, listed under the cards.
        ZenitModalPresenter.handler = { _ in .button(0) }
        remove([first.rawValue], true)
        #expect(await AppTestSupport.wait { core.document.pages.count == 1 })
        #expect(asked.first == ZenitPDFProjectDocument.removeMeasuredSheetsAlertIdentifier)
        #expect(core.ledger.grandTotals.total("planLength")?.value ?? 0 == 0, "its 2 m leave the ledger")
        #expect(await AppTestSupport.wait { harness.shell.removedSheets.map(\.id) == [first.rawValue] })

        remove([first.rawValue], false)
        #expect(await AppTestSupport.wait { core.document.pages.count == 2 })
        #expect(core.document.pages.first?.id == first.rawValue, "back in its place")
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(2), "and its 2 m with it")
        #expect(await AppTestSupport.wait { harness.shell.removedSheets.isEmpty })
    }

    @Test("A sheet with no scale is marked; calibrating it clears the mark")
    func noScaleBadge() async throws {
        let harness = try await Fix2Harness.make("Badge.pdf", pageCount: 2)   // calibrates sheet 1
        defer { harness.tearDown() }
        let pages = harness.core.document.pages
        #expect(await AppTestSupport.wait { harness.shell.unscaledPageIDs == [pages[1].id] }, "only the uncalibrated sheet")
        _ = try await harness.core.commands.calibrate(
            page: PageID(pages[1].id), first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        await harness.core.refresh()
        #expect(await AppTestSupport.wait { harness.shell.unscaledPageIDs.isEmpty })
    }
}
