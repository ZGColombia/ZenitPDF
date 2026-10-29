import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// CR-4, CR-8, CR-11, CR-16: four guards in the measurement palette.
///
/// Every test states what the old presenter did.
@MainActor
struct MeasurementPresenterGuardTests {

    private func makePresenter() throws -> (AppMeasurementToolPresenter, TakeoffSession, PageID) {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: pageID,
            documentID: documentID,
            index: 0,
            label: "1",
            boxes: PageBoxes(
                media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
            )
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: pageID)
        return (presenter, session, pageID)
    }

    private let lengthPoints = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0)]
    private let areaPoints = [
        PDFPointValue(x: 0, y: 0), PDFPointValue(x: 50, y: 0), PDFPointValue(x: 50, y: 50)
    ]

    // MARK: CR-4

    @Test("Picking a tool mid-capture ends the boundary capture and tells the panel")
    func toolSwitchEndsBoundaryCapture() throws {
        let (presenter, _, _) = try makePresenter()
        var cancelled: [AppMeasurementToolPresenter.BoundaryPurpose] = []
        var boundaries = 0
        var measurements: [MarkupRecord] = []
        presenter.onCancelBoundary = { cancelled.append($0) }
        presenter.onCommitBoundary = { _, _, _ in boundaries += 1 }
        presenter.onCommit = { measurements.append($0) }

        presenter.beginBoundaryCapture(.scaleRegion)
        #expect(presenter.isCapturingBoundary)

        presenter.activate(kind: .length)
        // Old state: `boundaryPurpose` still `.scaleRegion`, nothing cancelled.
        #expect(presenter.boundaryPurpose == nil)
        #expect(cancelled == [.scaleRegion])

        presenter.appendRawPoints(lengthPoints)
        presenter.commitActiveMeasurement()
        // Old behaviour: the Return went out as a boundary commit and no measurement existed.
        #expect(boundaries == 0)
        #expect(measurements.count == 1)
        #expect(measurements.first?.tool == .length)
    }

    @Test("Disarming ends a boundary capture too")
    func deactivateEndsBoundaryCapture() throws {
        let (presenter, _, _) = try makePresenter()
        var cancelled: [AppMeasurementToolPresenter.BoundaryPurpose] = []
        presenter.onCancelBoundary = { cancelled.append($0) }

        presenter.beginBoundaryCapture(.projectZone)
        presenter.deactivate()
        // Old state: `boundaryPurpose` survived as `.projectZone`.
        #expect(presenter.boundaryPurpose == nil)
        #expect(cancelled == [.projectZone])
    }

    @Test("Starting a second capture cancels the first rather than silently replacing it")
    func secondCaptureCancelsTheFirst() throws {
        let (presenter, _, _) = try makePresenter()
        var cancelled: [AppMeasurementToolPresenter.BoundaryPurpose] = []
        presenter.onCancelBoundary = { cancelled.append($0) }
        presenter.beginBoundaryCapture(.scaleRegion)
        presenter.beginBoundaryCapture(.projectZone)
        #expect(presenter.boundaryPurpose == .projectZone)
        #expect(cancelled == [.scaleRegion])
    }

    // MARK: CR-8

    @Test("A page turn finishes the count group instead of discarding it")
    func pageTurnCommitsTheCount() throws {
        let (presenter, _, pageID) = try makePresenter()
        var committed: [MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }

        presenter.activate(kind: .count)
        presenter.appendRawPoints([
            PDFPointValue(x: 10, y: 10), PDFPointValue(x: 20, y: 20), PDFPointValue(x: 30, y: 30)
        ])
        presenter.setPage(PageID(UUID()))

        // Old output: `committed` empty — ten marks placed, next sheet, ten marks gone.
        #expect(committed.count == 1)
        #expect(committed.first?.geometry?.countPoints.count == 3)
        #expect(committed.first?.pageID == pageID, "the group belongs to the sheet it was placed on")
        #expect(presenter.placedPoints.isEmpty)
    }

    @Test("A point that resolves after the tool was disarmed lands nowhere")
    func latePointNeverLandsOnADisarmedTool() throws {
        let (presenter, _, pageID) = try makePresenter()
        presenter.activate(kind: .length)
        presenter.deactivate()

        presenter.appendResolved(nil, fallback: PDFPointValue(x: 5, y: 5), pageID: pageID)
        // Old state: `placedPoints == [(5, 5)]` on a presenter with no active kind.
        #expect(presenter.placedPoints.isEmpty)

        presenter.activate(kind: .length)
        #expect(presenter.placedPoints.isEmpty, "the next arming must not inherit an orphan vertex")
    }

    // MARK: CR-11

    @Test("The palette follows the document's units when they change")
    func paletteFollowsDocumentUnits() async throws {
        let (presenter, session, _) = try makePresenter()
        #expect(presenter.lengthUnit == DisplayUnitSelection.metric.length)

        try await session.setUnits(.imperial)
        let imperial = try await session.snapshot()
        presenter.adopt(imperial)
        // Old state: still metric after a job template switched the document to imperial.
        #expect(presenter.lengthUnit == DisplayUnitSelection.imperial.length)
        #expect(presenter.areaUnit == DisplayUnitSelection.imperial.area)
        #expect(presenter.volumeUnit == DisplayUnitSelection.imperial.volume)

        // A unit picked in the palette's own menu survives refreshes that did not change the
        // document's units.
        presenter.setLengthUnit(.millimetre)
        presenter.adopt(try await session.snapshot())
        #expect(presenter.lengthUnit == .millimetre)

        try await session.setUnits(.metric)
        presenter.adopt(try await session.snapshot())
        #expect(presenter.lengthUnit == DisplayUnitSelection.metric.length)
    }

    // MARK: CR-16

    @Test("A cutout refused for want of a parent does not burn an auto-label letter")
    func refusedCutoutKeepsItsLetter() throws {
        let (presenter, _, _) = try makePresenter()
        var cutouts: [MarkupRecord] = []
        presenter.onCommitCutout = { _, record in cutouts.append(record) }

        presenter.activate(kind: .polygonCutout)
        presenter.appendRawPoints(areaPoints)
        presenter.cutoutParentID = nil
        presenter.commitActiveMeasurement()
        #expect(cutouts.isEmpty, "no parent, no cutout")

        presenter.cutoutParentID = MarkupID(UUID())
        presenter.commitActiveMeasurement()
        // Old output: "\(Shown.Kind.polygonCutout.displayName) B" — the refused commit had
        // already taken "A".
        #expect(cutouts.count == 1)
        #expect(cutouts.first?.label == "\(Shown.Kind.polygonCutout.displayName) A")
    }
}
