import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Asserts that the mock presenters behave the way the UI packages rely on: selection
/// round-trips, filtering really filters, totals really re-sum, and live measurement
/// values follow the sample scale.
@MainActor
@Suite("Mock presenters")
struct MockPresenterTests {

    func makeEnvironment() -> MockPresenterEnvironment { MockPresenters.makeEnvironment() }

    // MARK: Documents

    @Test("Next and Previous walk the document and stop at both ends without wrapping")
    func relativePageNavigation() {
        let document = makeEnvironment().document
        #expect(document.pages.count == 3)

        document.goToPage(index: 0)
        #expect(document.currentPageIndex == 0)
        #expect(document.canGoToPreviousPage == false)
        #expect(document.canGoToNextPage == true)

        // Previous at the first page is a no-op, not a wrap to the last. A person holding the
        // shortcut at sheet 1 must not be teleported to the end of the set.
        document.goToPreviousPage()
        #expect(document.currentPageIndex == 0)

        document.goToNextPage()
        #expect(document.currentPageIndex == 1)
        document.goToNextPage()
        #expect(document.currentPageIndex == 2)
        #expect(document.canGoToNextPage == false)

        document.goToNextPage()
        #expect(document.currentPageIndex == 2, "Next at the last page wrapped")

        document.goToPreviousPage()
        #expect(document.currentPageIndex == 1)
    }

    @Test("First and Last jump to the ends")
    func absolutePageNavigation() {
        let document = makeEnvironment().document
        document.goToPage(index: 1)

        document.goToLastPage()
        #expect(document.currentPageIndex == document.pages.count - 1)

        document.goToFirstPage()
        #expect(document.currentPageIndex == 0)
    }

    @Test("Page navigation works by identity and by index, and ignores bad input")
    func documentNavigation() {
        let document = makeEnvironment().document
        #expect(document.pages.count == 3)
        #expect(document.currentPage?.label == "A-101")

        // A typed label is resolved by the shell's page-field rule and arrives as an index or
        // an identity (T-033); the presenter itself navigates by those two only.
        let s201 = document.pages.first { $0.label == "S-201" }
        #expect(s201 != nil)
        if let s201 { document.goToPage(id: s201.id) }
        #expect(document.currentPage?.label == "S-201")

        document.goToPage(index: 1)
        #expect(document.currentPage?.label == "A-102")

        document.goToPage(index: 99)
        #expect(document.currentPage?.label == "A-102", "out-of-range navigation is ignored")
    }

    @Test("A blocking warning cannot be dismissed")
    func nonDismissibleWarnings() {
        let document = makeEnvironment().document
        let blocking = document.warnings.filter { !$0.isDismissible }
        #expect(!blocking.isEmpty)

        for warning in document.warnings {
            document.dismissWarning(id: warning.id)
        }
        #expect(document.warnings.count == blocking.count)
    }

    @Test("Scale Regions on a page resolve highest priority first")
    func scaleRegionPriority() {
        let document = makeEnvironment().document
        let regions = document.scaleRegions(onPage: document.pages[0].id)
        #expect(regions.count == 1)
        #expect(regions.first?.scale.displayString == "1:20")
    }

    // MARK: Canvas

    @Test("Selection round-trips between the ledger and the canvas")
    func selectionRoundTrip() throws {
        let environment = makeEnvironment()
        let markup = try #require(environment.canvas.visibleMarkups.first)

        environment.ledger.select(rowIDs: [markup.id], additive: false)
        #expect(environment.canvas.selectedMarkupIDs == [markup.id])

        environment.canvas.clearSelection()
        #expect(environment.ledger.selectedRowIDs.isEmpty)
    }

    @Test("Vector Snap reports unavailable on the scanned sheet")
    func vectorSnapUnavailable() {
        let environment = makeEnvironment()
        let canvas = environment.canvas
        #expect(canvas.isVectorSnapAvailable)

        canvas.showPage(id: environment.project.pages[2].id)
        #expect(!canvas.isVectorSnapAvailable)
        #expect(canvas.snapFeedback == nil)
    }

    @Test("Zoom is clamped to the supported range")
    func zoomClamping() {
        let canvas = makeEnvironment().canvas
        canvas.setZoom(1_000)
        #expect(canvas.viewport.zoom == ViewportSnapshot.maximumZoom)
        canvas.setZoom(0)
        #expect(canvas.viewport.zoom == ViewportSnapshot.minimumZoom)
    }

    @Test("A cursor inside a Scale Region switches the active scale")
    func cursorSwitchesScale() throws {
        let environment = makeEnvironment()
        let canvas = environment.canvas
        let firstPageID = environment.project.pages[0].id
        let candidate = environment.project.scaleRegions.first(where: { $0.pageID == firstPageID })
        let region = try #require(candidate)
        let bounds = try #require(region.boundsInPageSpace)
        let inside = bounds.center

        canvas.updateCursor(pagePoint: inside)
        #expect(canvas.activeScaleRegion?.id == region.id)
        #expect(canvas.activeScale?.displayString == "1:20")

        canvas.updateCursor(pagePoint: PDFPointValue(x: 20, y: 20))
        #expect(canvas.activeScaleRegion == nil)
        #expect(canvas.activeScale?.displayString == "1:50")
    }

    // MARK: Ledger

    @Test("Rebuilt totals match the pre-baked totals")
    func rebuiltTotals() {
        let environment = makeEnvironment()
        let ledger = environment.ledger
        let expected = environment.project.grandTotals

        // An empty filter forces a full rebuild without removing any row.
        ledger.setFilter(LedgerFilterGroup(id: UUID()))

        #expect(ledger.rowCount == expected.rowCount)
        #expect(ledger.grandTotals.rowCount == expected.rowCount)
        for column in ledger.columns where column.aggregate == .sum {
            #expect(
                ledger.grandTotals.total(column.id)?.value == expected.total(column.id)?.value,
                "column \(column.id.rawValue)"
            )
        }
    }

    @Test("Filtering reduces the rows and the totals, and groups still reconcile")
    func filtering() throws {
        let environment = makeEnvironment()
        let ledger = environment.ledger
        let unfilteredCount = ledger.rowCount
        let unfilteredCost = try #require(ledger.grandTotals.total(.totalCost)).value

        let rule = LedgerFilterRule(
            id: UUID(),
            column: .subject,
            comparison: .contains,
            operand: .text("Screed")
        )
        ledger.setFilter(LedgerFilterGroup(id: UUID(), conjunction: .all, rules: [rule]))

        #expect(ledger.rowCount < unfilteredCount)
        #expect(ledger.rowCount > 0)
        #expect((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.allSatisfy {
            $0.displayValue(.subject) == "Floor Screed"
        })

        let filteredCost = try #require(ledger.grandTotals.total(.totalCost)).value
        #expect(filteredCost < unfilteredCost)

        // Group totals summed by hand (R-138 removed `LedgerTotals.merging`).
        let groupRows = ledger.rootGroups.reduce(0) { $0 + $1.totals.rowCount }
        let groupCost = ledger.rootGroups.compactMap { $0.totals.total(.totalCost)?.value }.reduce(0, +)
        #expect(groupRows == ledger.grandTotals.rowCount)
        #expect(groupCost == filteredCost)
    }

    @Test("Sorting orders quantities in both directions")
    func sorting() {
        let ledger = makeEnvironment().ledger
        // Display order is group order (IM-011); ungrouped, the sort spans the whole ledger.
        ledger.setGrouping([])
        ledger.sort(by: .totalCost, ascending: true)
        let ascending = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.compactMap { $0.quantity(.totalCost)?.value }
        #expect(ascending == ascending.sorted())

        ledger.sort(by: .totalCost, ascending: false)
        let descending = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.compactMap { $0.quantity(.totalCost)?.value }
        #expect(descending == descending.sorted(by: >))
    }

    @Test("Rows are addressed by index, and identity round-trips through the index")
    func indexAddressedRows() throws {
        let ledger = makeEnvironment().ledger
        #expect(ledger.rowCount > 0)
        #expect(!ledger.isEmpty)

        // Every in-range index answers, and every out-of-range index answers `nil` rather
        // than trapping: the table asks for the window it is about to draw, not for a
        // window it has checked first.
        for position in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: position))
            #expect(ledger.index(of: row.markupID) == position)
        }
        #expect(ledger.row(at: -1) == nil)
        #expect(ledger.row(at: ledger.rowCount) == nil)
        #expect(ledger.index(of: UUID()) == nil)

        // A scroll window costs the window, not the ledger.
        let window = (1..<3).compactMap { ledger.row(at: $0) }
        #expect(window.count == min(2, ledger.rowCount - 1))
        #expect(window.first?.markupID == ledger.row(at: 1)?.markupID)
        #expect((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.count == ledger.rowCount)
        #expect((ledger.rowCount..<(ledger.rowCount + 50)).compactMap { ledger.row(at: $0) }.isEmpty)

        // Identity lookup is what the canvas uses to reveal a markup.
        let first = try #require(ledger.row(at: 0))
        let last = try #require(ledger.row(at: ledger.rowCount - 1))
        let pair = ledger.rows(withIDs: [last.markupID, first.markupID])
        #expect(pair.map(\.markupID) == [first.markupID, last.markupID])
    }

    /// The band itself is the table's (`LedgerTableController.prefetchVisibleBand`, tested in
    /// ZPDFUILedger's IM-014 test); the presenter warms what it is handed.
    @Test("Prefetch warms the band it is handed, and a rebuild invalidates it")
    func prefetchBand() {
        let ledger = makeEnvironment().ledger
        ledger.prefetchRows(in: 0..<ledger.rowCount)
        #expect(ledger.prefetchedRange == 0..<ledger.rowCount)

        // A rebuild invalidates the band; nothing is left claiming to be warm.
        ledger.sort(by: .subject, ascending: true)
        #expect(ledger.prefetchedRange.isEmpty)
    }

    @Test("Hiding a column keeps its total, because the export still needs it")
    func hidingAColumn() {
        let ledger = makeEnvironment().ledger
        #expect(ledger.grandTotals.total(.volume) != nil)
        ledger.setColumnVisible(false, columnID: .volume)
        #expect(!ledger.visibleColumns.contains { $0.id == .volume })
        #expect(ledger.grandTotals.total(.volume) != nil)
    }

    // MARK: Tool Library

    @Test("The reuse-tool switch drives the status bar")
    func reuseToolSwitch() {
        let environment = makeEnvironment()
        environment.toolLibrary.setReuseToolEnabled(false)
        #expect(!environment.status.snapshot.reuseToolEnabled)
        environment.toolLibrary.setReuseToolEnabled(true)
        #expect(environment.status.snapshot.reuseToolEnabled)
    }

    @Test("Read-only presets cannot be favorited")
    func readOnlyPresets() throws {
        let library = makeEnvironment().toolLibrary
        let candidate = library.presets.first(where: { $0.isReadOnly })
        let readOnly = try #require(candidate)
        library.toggleFavorite(id: readOnly.id)
        let updated = library.presets.first(where: { $0.id == readOnly.id })
        let after = try #require(updated)
        #expect(!after.isFavorite)
    }

    @Test("Panel filtering honours the search text")
    func presetSearch() {
        let library = makeEnvironment().toolLibrary
        #expect(library.presets(in: .myTools).count == 2)
        library.setSearchText("screed")
        #expect(library.presets(in: .myTools).count == 1)
    }

    // MARK: Search

    @Test("Search honours the source scope and navigates the document")
    func search() throws {
        let environment = makeEnvironment()
        let search = environment.search

        search.query = "screed"
        #expect(!search.hits.isEmpty)
        // L-20: recognised text is in the default scope, and its hit brings the disclaimer.
        // Old: the default left `.ocrText` out, so the sample's recognised hit was never listed.
        #expect(search.hits.contains { $0.source == .ocrText }, "recognised text is searched by default")
        #expect(search.showsOCRDisclaimer)

        // Unticking OCR Text leaves the recognised hit, and its disclaimer, out.
        search.scope = SearchScope(location: .entireProject, sources: [.pdfText, .markups, .comments, .labels])
        #expect(!search.hits.isEmpty)
        #expect(!search.hits.contains { $0.source == .ocrText })
        #expect(!search.showsOCRDisclaimer, "OCR is not in this scope")

        search.scope = SearchScope(location: .entireProject, sources: Set(SearchSource.allCases))
        #expect(search.showsOCRDisclaimer)

        let ocrCandidate = search.hits.first(where: { $0.source == .ocrText })
        let ocrHit = try #require(ocrCandidate)
        search.selectHit(id: ocrHit.id)
        #expect(environment.document.currentPageID == ocrHit.pageID)

        search.clear()
        #expect(search.hits.isEmpty)
        #expect(search.resultSummary == "Type to search")
    }

    // MARK: Compare

    @Test("Blinking is refused while Reduce Motion is on")
    func reduceMotionBlocksBlinking() {
        let compare = makeEnvironment().compare
        compare.prefersReducedMotion = true
        compare.setBlinking(true)
        #expect(!compare.isBlinking)

        compare.prefersReducedMotion = false
        compare.setBlinking(true)
        #expect(compare.isBlinking)
    }

    @Test("Accepting every difference promotes them all")
    func acceptAllDiffs() {
        let compare = makeEnvironment().compare
        let pendingBefore = compare.diffs.filter { !$0.isAccepted }
        #expect(!pendingBefore.isEmpty)
        compare.acceptAllDiffs()
        let pendingAfter = compare.diffs.filter { !$0.isAccepted }
        #expect(pendingAfter.isEmpty)
        #expect(compare.diffs.allSatisfy { $0.promotedMarkupID != nil })
    }

    // MARK: Measurement

    @Test("Live length follows the active scale")
    func liveLength() throws {
        let measurement = makeEnvironment().measurement
        let scale = try #require(measurement.activeScale)

        measurement.activate(kind: .length)
        #expect(!measurement.canCommit)
        measurement.placePoint(PDFPointValue(x: 100, y: 100))
        measurement.placePoint(PDFPointValue(x: 1_100, y: 100))
        #expect(measurement.canCommit)

        let field = try #require(measurement.livePrimaryField)
        #expect(field.field == .planLength)
        #expect(field.quantity.dimension == .length)
        let metres = NSDecimalNumber(decimal: field.quantity.value).doubleValue
        #expect(abs(metres - 1_000 * scale.sx) < 1e-9)
        #expect(field.displayUnitSymbol == "m")
    }

    @Test("Live area uses the shoelace formula and the scale's area factor")
    func liveArea() throws {
        let measurement = makeEnvironment().measurement
        let scale = try #require(measurement.activeScale)

        measurement.activate(kind: .area)
        for point in [
            PDFPointValue(x: 0, y: 0),
            PDFPointValue(x: 400, y: 0),
            PDFPointValue(x: 400, y: 300),
            PDFPointValue(x: 0, y: 300)
        ] {
            measurement.placePoint(point)
        }

        let field = try #require(measurement.livePrimaryField)
        #expect(field.quantity.dimension == .area)
        let squareMetres = NSDecimalNumber(decimal: field.quantity.value).doubleValue
        #expect(abs(squareMetres - 400 * 300 * scale.areaFactor) < 1e-9)
    }

    @Test("Committing a measurement adds it to the canvas")
    func commitAddsMarkup() {
        let environment = makeEnvironment()
        let before = environment.canvas.visibleMarkups.count

        environment.measurement.activate(kind: .polylength)
        environment.measurement.placePoint(PDFPointValue(x: 200, y: 200))
        environment.measurement.placePoint(PDFPointValue(x: 900, y: 200))
        environment.measurement.commitActiveMeasurement()

        #expect(environment.canvas.visibleMarkups.count == before + 1)
        #expect(environment.measurement.placedPoints.isEmpty)
    }

    @Test("Temporary measurements stay off the canvas until promoted")
    func temporaryMeasurements() {
        let environment = makeEnvironment()
        let measurement = environment.measurement
        let before = environment.canvas.visibleMarkups.count

        measurement.activate(kind: .temporaryMeasure)
        #expect(measurement.isTemporaryMeasurement)
        measurement.placePoint(PDFPointValue(x: 100, y: 400))
        measurement.placePoint(PDFPointValue(x: 700, y: 400))
        measurement.commitActiveMeasurement()

        #expect(measurement.temporaryMeasurements.count == 1)
        #expect(environment.canvas.visibleMarkups.count == before)

        measurement.promoteTemporaryMeasurementsToMarkups()
        #expect(measurement.temporaryMeasurements.isEmpty)
        #expect(environment.canvas.visibleMarkups.count == before + 1)
    }

    // MARK: Status

    @Test("Status bar snap toggles and warning severity")
    func statusBar() {
        let status = makeEnvironment().status
        status.setGridSnapEnabled(true)
        #expect(status.snapshot.gridSnapEnabled)
        status.setVectorSnapEnabled(false)
        #expect(!status.snapshot.vectorSnapEnabled)
        #expect(status.highestSeverity == .danger)
    }
}
