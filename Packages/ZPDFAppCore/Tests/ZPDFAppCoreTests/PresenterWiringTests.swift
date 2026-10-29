import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFUIPresentation

/// How the presenters are joined, and the actor discipline that joins them.
@Suite("Presenter wiring")
struct PresenterWiringTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page)
    }

    private static func slab(documentID: DocumentID, pageID: PageID, id: MarkupID) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 10, y: 10),
                    PDFPoint(x: 110, y: 10),
                    PDFPoint(x: 110, y: 90),
                    PDFPoint(x: 10, y: 90)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    @Test("Selecting in the ledger selects on the canvas, and back, without echoing")
    @MainActor
    func selectionTravelsBothWays() async throws {
        let (environment, session, page) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.slab(documentID: session.documentID, pageID: page.id, id: id))
        )
        await environment.refresh()

        environment.ledger.select(rowIDs: [id.rawValue], additive: false)
        #expect(environment.canvas.selectedMarkupIDs == [id.rawValue])

        environment.canvas.clearSelection()
        #expect(environment.ledger.selectedRowIDs.isEmpty)

        environment.canvas.select(markupIDs: [id.rawValue], additive: false)
        #expect(environment.ledger.selectedRowIDs == [id.rawValue])
        #expect(environment.canvas.selectedMarkups.count == 1, "and the canvas kept its own")
    }

    @Test("A committed measurement goes through the bus, so it is on the undo stack")
    @MainActor
    func measurementCommitsThroughTheBus() async throws {
        let (environment, session, page) = try await makeEnvironment()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)

        environment.measurement.activate(kind: .area)
        environment.measurement.defaultSubject = "Floor"
        #expect(environment.measurement.activeKind == .area)
        #expect(!environment.measurement.canCommit, "no points yet")

        for point in [
            PDFPointValue(x: 10, y: 10),
            PDFPointValue(x: 110, y: 10),
            PDFPointValue(x: 110, y: 90)
        ] {
            environment.measurement.placePoint(point)
        }
        // `placePoint` hands each snap resolve to the session, so the points land one hop
        // later — and in the order they were clicked, because the placements are chained.
        await environment.measurement.settlePlacements()
        #expect(environment.measurement.placedPoints.count == 3)
        #expect(environment.measurement.canCommit)

        environment.measurement.commitActiveMeasurement()
        // The commit posts a command; give the bus its hop, then let the refresh land.
        for _ in 0..<8 { await Task.yield() }
        await environment.commands.settle()
        await environment.refresh()

        #expect(await session.orderedMarkups.count == 1)
        #expect(environment.ledger.rowCount == 1)
        #expect(environment.commands.undoManager.canUndo, "drawing is undoable")
        #expect(environment.measurement.placedPoints.isEmpty, "the in-progress state is cleared")
    }

    @Test("A Temporary Measure never becomes a ledger row")
    @MainActor
    func temporaryMeasurementsStayOutOfTheLedger() async throws {
        let (environment, session, page) = try await makeEnvironment()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)

        environment.measurement.activate(kind: .temporaryMeasure)
        #expect(environment.measurement.isTemporaryMeasurement)
        environment.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        environment.measurement.placePoint(PDFPointValue(x: 110, y: 10))
        await environment.measurement.settlePlacements()

        environment.measurement.commitActiveMeasurement()
        for _ in 0..<4 { await Task.yield() }
        await environment.refresh()

        #expect(environment.measurement.temporaryMeasurements.count == 1)
        #expect(await session.orderedMarkups.isEmpty, "spec 12.14: never stored")
        #expect(environment.ledger.rowCount == 0)

        // Promoting is a real commit through the bus, so it is undoable.
        environment.measurement.promoteTemporaryMeasurementsToMarkups()
        for _ in 0..<8 { await Task.yield() }
        await environment.commands.settle()
        await environment.refresh()
        #expect(environment.measurement.temporaryMeasurements.isEmpty)
        #expect(await session.orderedMarkups.count == 1, "now it is a markup")
        #expect(environment.commands.undoManager.canUndo)

        environment.measurement.clearTemporaryMeasurements()
        #expect(environment.measurement.temporaryMeasurements.isEmpty)
    }

    @Test("Zoom to fit uses the page size and the view size, and clamps to the legal range")
    @MainActor
    func zoomToFit() async throws {
        let (environment, _, page) = try await makeEnvironment()
        let shown = ZPDFUIPresentation.PageDescriptor(domain: page)
        environment.canvas.showPage(shown)

        // A 612 × 792 page in an 800 × 600 view: height is the binding dimension.
        environment.canvas.viewSize = CGSize(width: 800, height: 600)
        environment.canvas.zoomToFit()
        #expect(abs(environment.canvas.viewport.zoom - 600.0 / 792.0) < 1e-12)

        environment.canvas.zoomToFitWidth()
        #expect(abs(environment.canvas.viewport.zoom - 800.0 / 612.0) < 1e-12)

        // Without a view size there is nothing to fit to, and the zoom is left alone rather
        // than being reset to some arbitrary value.
        let before = environment.canvas.viewport.zoom
        environment.canvas.viewSize = .zero
        environment.canvas.zoomToFit()
        #expect(environment.canvas.viewport.zoom == before)

        environment.canvas.setZoom(10_000)
        #expect(environment.canvas.viewport.zoom == PageViewLayout.maximumZoom)
        environment.canvas.setZoom(0)
        #expect(environment.canvas.viewport.zoom == PageViewLayout.minimumZoom)
    }

    @Test("The measurement palette re-renders on a unit change without asking the engine")
    @MainActor
    func unitChangeReformatsWithoutRecomputing() async throws {
        let (environment, _, _) = try await makeEnvironment()
        environment.measurement.applyPreview(
            MeasurementResult(values: [.planArea: .area(Decimal(string: "100")!)]),
            tool: .area,
            units: .metric
        )
        let metric = try #require(environment.measurement.liveFields.first { $0.field == .planArea })
        #expect(metric.displayText == "100.00")
        #expect(metric.displayUnitSymbol == "m²")

        environment.measurement.setAreaUnit(.squareFoot)
        let imperial = try #require(environment.measurement.liveFields.first { $0.field == .planArea })
        #expect(imperial.displayUnitSymbol == "ft²")
        #expect(imperial.displayText == "1,076.39")
        #expect(
            imperial.quantity.value == metric.quantity.value,
            "the SI value is untouched — only the rendering changed"
        )
    }

    @Test("The canvas hides or dims filtered-out markups as the ledger asks")
    @MainActor
    func canvasHonoursTheLedgerFilter() async throws {
        let (environment, session, page) = try await makeEnvironment()
        let kept = MarkupID(UUID())
        let dropped = MarkupID(UUID())
        for id in [kept, dropped] {
            try await environment.commands.perform(
                .addMarkup(Self.slab(documentID: session.documentID, pageID: page.id, id: id))
            )
        }
        await environment.refresh()
        #expect(environment.canvas.visibleMarkups.count == 2)

        environment.canvas.setFilterMatches([kept.rawValue])
        #expect(environment.canvas.visibleMarkups.count == 2, "dimmed, not hidden, by default")

        environment.canvas.setFilterBehavior(.hideNonMatching)
        #expect(environment.canvas.visibleMarkups.map(\.id) == [kept.rawValue])

        environment.canvas.setFilterMatches(nil)
        #expect(environment.canvas.visibleMarkups.count == 2)
    }

    @Test("A cursor move never blocks: the answer arrives as a snapshot, stale ones are dropped")
    @MainActor
    func cursorMovesAreAsynchronous() async throws {
        let (environment, session, page) = try await makeEnvironment()
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        environment.canvas.showPage(ZPDFUIPresentation.PageDescriptor(domain: page))

        // Returns immediately with the cursor recorded and no feedback yet — there has been
        // no opportunity to await anything.
        environment.canvas.updateCursor(pagePoint: PDFPointValue(x: 40, y: 40))
        #expect(environment.canvas.viewport.cursorPagePoint == PDFPointValue(x: 40, y: 40))

        // A resolution from an older sample is ignored rather than drawn a frame late.
        environment.canvas.updateCursor(pagePoint: PDFPointValue(x: 41, y: 41))
        environment.canvas.applySnap(nil, sequence: 99, pageID: page.id)
        environment.canvas.applySnap(nil, sequence: 1, pageID: page.id)
        #expect(environment.canvas.snapFeedback == nil)

        environment.canvas.updateCursor(pagePoint: nil)
        #expect(environment.canvas.viewport.cursorPagePoint == nil)
        #expect(environment.canvas.snapFeedback == nil)
    }

    /// R-063: the highlight a reveal draws is static (`CanvasPageView.searchHighlights`), not a
    /// flash, so no accessibility flag withholds it; the flags that did were never set in
    /// production, and the zoom animation checks Reduce Motion in the canvas itself.
    @Test("Revealing a markup selects it and marks it out with a static highlight")
    @MainActor
    func revealMarksOutTheMarkup() async throws {
        let (environment, session, page) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(
            .addMarkup(Self.slab(documentID: session.documentID, pageID: page.id, id: id))
        )
        await environment.refresh()

        var highlighted: Bool?
        var revealed: PDFRectValue?
        environment.canvas.onScrollTo = { rect, highlight in
            revealed = rect
            highlighted = highlight
        }

        environment.canvas.zoomTo(markupID: id.rawValue)
        #expect(highlighted == true)
        #expect(revealed != nil, "the canvas is asked to show the markup's bounds")
        #expect(environment.canvas.selectedMarkupIDs == [id.rawValue], "and it is revealed as the selection")
    }

    @Test("A long operation reports progress and stops when cancelled")
    @MainActor
    func operationsAreCancellable() async {
        let handle = OperationHandle(title: "Recognising text")
        #expect(handle.progress.stage == .pending)
        #expect(handle.isRunning)

        let sink = ProgressSink(handle: handle)
        sink(.counting(30, of: 120, detail: "page 30"))
        await Task.yield()
        #expect(handle.progress.completedUnits == 30)
        #expect(handle.progress.fraction == 0.25)

        handle.cancel()
        #expect(handle.progress.stage == .cancelled)
        #expect(!handle.isRunning)

        // A late report from work that has not noticed the cancellation yet cannot
        // resurrect a finished progress row.
        sink(.counting(31, of: 120))
        await Task.yield()
        #expect(handle.progress.stage == .cancelled)
    }

    @Test("Reuse-tool is one decision, honoured by the palette and shown in the status bar")
    @MainActor
    func reuseToolIsOneDecision() async throws {
        let (environment, _, _) = try await makeEnvironment()
        let preset = ToolPresetSummary(
            id: UUID(),
            name: "Concrete slab",
            category: "Concrete",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.9),
            defaultSubject: "Slab",
            sortIndex: 0
        )
        environment.toolLibrary.setPresets([preset])
        environment.toolLibrary.activatePreset(id: preset.id)
        #expect(environment.measurement.activeKind == .area)
        #expect(environment.measurement.defaultSubject == "Slab")

        // Reuse-tool is **on** by default since 2026-08-26, so committing keeps the preset armed
        // and the estimator can take the next measurement without re-picking the tool.
        environment.toolLibrary.markupCommitted()
        #expect(environment.toolLibrary.activePresetID == preset.id, "reuse-tool keeps it armed")

        // Turned off, it disarms — the behaviour this test used to assert as the default.
        environment.toolLibrary.setReuseToolEnabled(false)
        #expect(environment.status.snapshot.reuseToolEnabled == false, "the status bar follows the library")
        environment.toolLibrary.markupCommitted()
        #expect(environment.toolLibrary.activePresetID == nil, "reuse-tool is off, so it disarms")

        // …and back on again, so the switch is proved in both directions.
        environment.toolLibrary.setReuseToolEnabled(true)
        #expect(environment.status.snapshot.reuseToolEnabled, "the status bar follows the library")
        environment.toolLibrary.activatePreset(id: preset.id)
        environment.toolLibrary.markupCommitted()
        #expect(environment.toolLibrary.activePresetID == preset.id, "reuse-tool keeps it armed")
    }

    @Test("Closing a tab with unsaved work asks first")
    @MainActor
    func closingATabAsks() async throws {
        let (environment, _, _) = try await makeEnvironment()
        let tab = DocumentTabSummary(
            id: UUID(),
            title: "Tender set",
            fileName: "tender.zpdfproj",
            pageCount: 4,
            hasUnsavedChanges: true,
            isActive: true,
            mode: .project,
            symbolName: "doc"
        )
        environment.document.setTabs([tab], active: tab.id)

        environment.document.shouldCloseTab = { _ in false }
        environment.document.closeTab(tab.id)
        #expect(environment.document.tabs.count == 1, "unsaved work is not discarded silently")

        environment.document.shouldCloseTab = { _ in true }
        environment.document.closeTab(tab.id)
        #expect(environment.document.tabs.isEmpty)
    }

    /// A typed sheet reference (number, label, position) is resolved by the shell's one rule,
    /// `StatusBarDisplay.pageDestination(forTyped:pages:)`, and reaches the presenter as an
    /// index; its label assertions live in `Iter3UIShellFixTests` (T-033).
    @Test("Page navigation by identity and by index")
    @MainActor
    func pageNavigationByIdentityAndIndex() async throws {
        let documentID = DocumentID(UUID())
        let pages = ["A-101", "A-102", "A-103"].enumerated().map { index, label in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: label,
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)

        let a103 = try #require(environment.document.pages.first { $0.label == "A-103" })
        environment.document.goToPage(id: a103.id)
        #expect(environment.document.currentPage?.index == 2)

        environment.document.goToPage(index: 0)
        #expect(environment.document.currentPage?.label == "A-101")

        environment.document.goToPage(index: 3)
        #expect(environment.document.currentPage?.label == "A-101", "out-of-range navigation is ignored")
    }
}
