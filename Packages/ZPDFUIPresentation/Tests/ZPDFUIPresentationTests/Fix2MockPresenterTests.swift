import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2: the mock presenters every UI test runs against must behave like the product.
@Suite("Fix2 mock presenters")
@MainActor
struct Fix2MockPresenterTests {

    private func rule(_ column: LedgerColumnID, _ comparison: LedgerFilterComparison, _ operand: LedgerFilterOperand) -> LedgerFilterGroup {
        LedgerFilterGroup(id: UUID(), rules: [LedgerFilterRule(id: UUID(), column: column, comparison: comparison, operand: operand)])
    }

    // MARK: - Ledger

    /// BH-271. Old output: a filter reassigned sequences and dropped the events of filtered-out
    /// markups; `derivation(for:)` answered nil for a filtered-out markup.
    @Test("The audit trail does not change with the filter")
    func auditTrailIgnoresTheFilter() throws {
        let ledger = MockLedgerPresenter()
        let before = ledger.auditEvents(matching: LedgerAuditFilter())
        let target = try #require(ledger.row(at: 0)).markupID
        ledger.setFilter(rule(.subject, .equals, .text("no such subject")))
        #expect(ledger.rowCount == 0)
        #expect(ledger.auditEvents(matching: LedgerAuditFilter()) == before)
        #expect(ledger.derivation(for: target) != nil)
    }

    /// BH-769. Old output: rows past the 24th, and Count/Volume/Perimeter rows, had
    /// `hasProvenance == true` with an empty values section and no history.
    @Test("Every row's derivation carries its values and history")
    func everyDerivationHasContent() throws {
        let ledger = MockLedgerPresenter()
        for position in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: position))
            let model = try #require(ledger.derivation(for: row.markupID))
            let values = model.sections.first { $0.key == "values" }?.facts ?? []
            #expect(model.hasProvenance == (!values.isEmpty && !model.history.isEmpty))
            #expect(!model.history.isEmpty, "row \(position) has no history")
            #expect(!values.isEmpty, "row \(position) (\(row.measurementKind?.rawValue ?? "?")) has no values")
        }
    }

    /// BH-272. Old output: Status "is any of [inReview]" matched zero rows (the display text was
    /// "In Review"; since NL-COLLAB-03 the state is `inProgress`, "In Progress").
    @Test("Choice filters compare the stored value")
    func choiceFiltersUseTheStoredValue() {
        let ledger = MockLedgerPresenter()
        ledger.setFilter(rule(.status, .isAnyOf, .choices([MarkupStatus.inProgress.rawValue])))
        #expect(ledger.rowCount > 0)
        ledger.setFilter(rule(.status, .equals, .text(MarkupStatus.inProgress.rawValue)))
        #expect(ledger.rowCount > 0)
    }

    /// BH-273. Old output: "Count is 12" (`.equals, .number`) kept every row.
    @Test("Numeric, boolean and date equality filter rows")
    func equalityOperandsFilter() {
        let ledger = MockLedgerPresenter()
        let total = ledger.rowCount
        ledger.setFilter(rule(.count, .equals, .number(987_654)))
        #expect(ledger.rowCount == 0)
        ledger.setFilter(rule(ZenitSampleProject.approvedColumn, .equals, .boolean(true)))
        #expect(ledger.rowCount > 0 && ledger.rowCount < total)
        ledger.setFilter(rule(.created, .equals, .date(Date(timeIntervalSince1970: 0))))
        #expect(ledger.rowCount == 0)
    }

    /// BH-274. Old output: after writing Unit Cost 500 the cell still displayed "780.00", and a
    /// Status of `.choice("accepted")` displayed the raw "accepted".
    @Test("Bulk edit refreshes the display strings in the column's format")
    func bulkEditRefreshesDisplay() async throws {
        let ledger = MockLedgerPresenter()
        let row = try #require((0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.first { !$0.locked })
        _ = await ledger.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [row.markupID], values: [
            .unitCost: .currency(amount: 500, code: "SEK"),
            .status: .choice(MarkupStatus.accepted.rawValue)
        ]))
        let position = try #require(ledger.index(of: row.markupID))
        let edited = try #require(ledger.row(at: position))
        #expect(edited.displayValue(.unitCost) == "500.00")
        #expect(edited.displayValue(.status) == MarkupStatus.accepted.displayName)
    }

    /// BH-770. Old output: row 0 was the first seed ("Interior Partition") while the header
    /// advertised Subject ascending. Since C-04 the display order is group order (IM-011), so
    /// the advertised sort holds inside every group, and ungrouped across the whole ledger.
    @Test("Fresh rows obey the advertised sort")
    func initialRowsAreSorted() {
        let ledger = MockLedgerPresenter()
        var start = 0
        for group in ledger.rootGroups {
            let subjects = (start..<(start + group.totals.rowCount)).compactMap { ledger.row(at: $0)?.displayValue(.subject) }
            #expect(subjects == subjects.sorted(), "\(group.title)")
            start += group.totals.rowCount
        }
        #expect(start == ledger.rowCount)
        let colours = ledger.rootGroups.map(\.colorRGBA)
        ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(ledger.rootGroups.map(\.colorRGBA) == colours, "zone colours survive a rebuild")
        #expect(colours.allSatisfy { $0 != nil })

        ledger.setGrouping([])
        let flat = (0..<ledger.rowCount).compactMap { ledger.row(at: $0)?.displayValue(.subject) }
        #expect(flat.count == ledger.rowCount)
        #expect(flat == flat.sorted())
    }

    /// BH-771. Old output: an empty nested group under "any" made every row match.
    @Test("An empty nested group constrains nothing")
    func emptyNestedGroupIsSkipped() {
        let ledger = MockLedgerPresenter()
        let screed = LedgerFilterRule(id: UUID(), column: .subject, comparison: .contains, operand: .text("Screed"))
        ledger.setFilter(LedgerFilterGroup(id: UUID(), conjunction: .any, rules: [screed], groups: [LedgerFilterGroup(id: UUID())]))
        let withEmpty = ledger.rowCount
        ledger.setFilter(LedgerFilterGroup(id: UUID(), conjunction: .any, rules: [screed]))
        #expect(withEmpty == ledger.rowCount)
        #expect(withEmpty < ledger.unfilteredRowCount)
    }

    /// BH-772. Old output: a style-only request changed nothing and reported success with zero
    /// markups; a value edit over locked rows changed them.
    @Test("Bulk edit applies style and refuses locked rows")
    func bulkEditStyleAndLocks() async {
        let ledger = MockLedgerPresenter()
        let rows = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }
        let unlocked = rows.filter { !$0.locked }.map(\.markupID)
        let locked = rows.filter(\.locked).map(\.markupID)
        let style = await ledger.applyBulkEdit(LedgerBulkEditRequest(markupIDs: Set(unlocked.prefix(3)), style: MarkupStyleEdit(lineWidth: 3)))
        #expect(style.changedMarkupIDs.count == 3)
        if !locked.isEmpty {
            let refused = await ledger.applyBulkEdit(LedgerBulkEditRequest(markupIDs: Set(locked), values: [.comment: .text("x")]))
            #expect(refused.changedMarkupIDs.isEmpty)
            #expect(refused.failureDescription != nil)
        }
    }

    /// BH-780. Old output: `SampleFormatting.string(ratio 0.25)` was "0".
    @Test("Ratios format with fraction digits")
    func ratiosKeepDigits() {
        #expect(SampleFormatting.string(DecimalQuantity(value: Decimal(string: "0.25")!, dimension: .ratio)) == "0.25")
        #expect(SampleFormatting.string(DecimalQuantity.count(3)) == "3")
    }

    // MARK: - Measurement

    private func square(_ measurement: MockMeasurementToolPresenter) {
        for point in [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 400, y: 0), PDFPointValue(x: 400, y: 300), PDFPointValue(x: 0, y: 300)] {
            measurement.placePoint(point)
        }
    }

    /// BH-275. Old output: 1100 pt × scale for a 400 × 300 rectangle (three sides).
    @Test("Perimeter includes the closing segment")
    func perimeterIsClosed() throws {
        let measurement = MockPresenterEnvironment().measurement
        let scale = try #require(measurement.activeScale)
        measurement.activate(kind: .perimeter)
        square(measurement)
        let field = try #require(measurement.livePrimaryField)
        #expect(abs(NSDecimalNumber(decimal: field.quantity.value).doubleValue - 1_400 * scale.sx) < 1e-9)
    }

    /// BH-276 / BH-774. Old output: Volume with depth "0.60" reported the hard-coded 0.30 m;
    /// "0,30" parsed as 0 and bypassed the missing-value refusal.
    @Test("Volume and Wall Area use the typed parameter")
    func volumeUsesTheTypedDepth() throws {
        let measurement = MockPresenterEnvironment().measurement
        measurement.activate(kind: .volume)
        square(measurement)
        measurement.setParameterText("0,60")
        let depth = try #require(measurement.liveFields.first { $0.field == .depth })
        #expect(depth.quantity.value == Decimal(string: "0.6"))
        #expect(MockMeasurementToolPresenter.parseParameter("0,30") == Decimal(string: "0.3"))
        #expect(MockMeasurementToolPresenter.parseParameter("0,3.0") == nil)
        #expect(MockMeasurementToolPresenter.parseParameter("abc") == nil)

        measurement.activate(kind: .wallArea)
        measurement.placePoint(PDFPointValue(x: 0, y: 0))
        measurement.placePoint(PDFPointValue(x: 1000, y: 0))
        measurement.setParameterText("2.7")
        let wall = try #require(measurement.livePrimaryField)
        #expect(wall.field == .wallArea)
        #expect(wall.quantity.value > 0, "a two-point run times a height is not zero")
    }

    /// BH-277 / BH-773. Old output: a measurement committed on sheet two was stamped sheet one
    /// and dropped by the canvas; the scale never followed the Scale Region.
    @Test("A commit lands on the current page at the scale in force")
    func commitFollowsPageAndScale() throws {
        let environment = MockPresenterEnvironment()
        let second = environment.project.pages[1]
        environment.document.goToPage(id: second.id)
        let before = environment.canvas.visibleMarkups.count
        environment.measurement.activate(kind: .length)
        environment.measurement.placePoint(PDFPointValue(x: 10, y: 10))
        environment.measurement.placePoint(PDFPointValue(x: 110, y: 10))
        environment.measurement.commitActiveMeasurement()
        #expect(environment.canvas.visibleMarkups.count == before + 1)
        #expect(environment.canvas.visibleMarkups.last?.pageID == second.id)

        let first = environment.project.pages[0]
        environment.document.goToPage(id: first.id)
        let region = try #require(environment.project.scaleRegions.first { $0.pageID == first.id })
        environment.canvas.updateCursor(pagePoint: try #require(region.boundsInPageSpace).center)
        environment.measurement.activate(kind: .length)
        environment.measurement.placePoint(PDFPointValue(x: 0, y: 0))
        environment.measurement.placePoint(PDFPointValue(x: 100, y: 0))
        #expect(environment.measurement.activeScale == region.scale)
    }

    /// BH-775. Old output: with feet selected the caption still said "m".
    @Test("Live fields follow the display unit")
    func liveFieldsFollowTheUnit() throws {
        let measurement = MockPresenterEnvironment().measurement
        measurement.activate(kind: .length)
        measurement.setLengthUnit(.foot)
        measurement.placePoint(PDFPointValue(x: 0, y: 0))
        measurement.placePoint(PDFPointValue(x: 1000, y: 0))
        #expect(try #require(measurement.livePrimaryField).displayUnitSymbol == "ft")
    }

    /// BH-776. Old output: an Angle published a Count field "3", so livePrimaryField was nil.
    @Test("Angle publishes an angle")
    func angleIsAnAngle() throws {
        let measurement = MockPresenterEnvironment().measurement
        measurement.activate(kind: .angle)
        for point in [PDFPointValue(x: 100, y: 0), PDFPointValue(x: 0, y: 0), PDFPointValue(x: 0, y: 100)] {
            measurement.placePoint(point)
        }
        let field = try #require(measurement.livePrimaryField)
        #expect(field.field == .angle)
        #expect(field.displayText == "90.0")
    }

    // MARK: - Documents, status, compare, sample

    /// BH-777. Old output: after closing the active tab no remaining tab had `isActive`.
    @Test("Closing the active tab activates the next one")
    func closeTabKeepsTheFlag() throws {
        let document = MockDocumentPresenter()
        let active = try #require(document.activeTabID)
        document.closeTab(active)
        #expect(document.tabs.filter(\.isActive).map(\.id) == [document.activeTabID].compactMap { $0 })
    }

    /// BH-778. Old output: turning to the scan left `.ready`, and Vector Snap could be enabled.
    @Test("The geometry index follows the page")
    func geometryIndexFollowsThePage() {
        let environment = MockPresenterEnvironment()
        environment.document.goToPage(id: environment.project.pages[2].id)
        #expect(environment.status.snapshot.geometryIndexStatus == .unavailable)
        environment.status.setVectorSnapEnabled(true)
        #expect(!environment.status.snapshot.vectorSnapEnabled)
    }

    /// BH-779. Old output: accept b, reject a, accept c — both promoted as sampleID(3001).
    @Test("Promoted markup identities never collide")
    func promotedIDsAreUnique() throws {
        let compare = MockComparePresenter()
        guard compare.diffs.count >= 3 else { return }
        let (a, b, c) = (compare.diffs[0].id, compare.diffs[1].id, compare.diffs[2].id)
        compare.acceptDiff(id: b)
        compare.rejectDiff(id: a)
        compare.acceptDiff(id: c)
        let promotedB = compare.diffs.first { $0.id == b }?.promotedMarkupID
        let promotedC = compare.diffs.first { $0.id == c }?.promotedMarkupID
        #expect(promotedB != nil && promotedC != nil)
        #expect(promotedB != promotedC)
        let all = compare.diffs.compactMap(\.promotedMarkupID)
        #expect(Set(all).count == all.count)
    }

    /// BH-781 / BH-782 / BH-783 / BH-784.
    @Test("Sample data is self-consistent")
    func sampleDataIsConsistent() throws {
        #expect(ZenitSampleProject.column(for: .circumference) != .diameter)
        #expect(ZenitSampleProject.column(for: .angle) != .slopeAngle)
        #expect(ZenitSampleProject.column(for: .arcLength) != .planLength)

        let project = ZenitSampleProject.shared
        let hit = try #require(project.searchHits.first { $0.id == SampleFormatting.sampleID(800) })
        let utf16 = Array(hit.snippet.utf16)
        let range = try #require(hit.highlightRange)
        #expect(String(utf16CodeUnits: Array(utf16[range]), count: range.count) == "screed")

        for markup in project.markups {
            guard let zoneName = markup.zone,
                  let zone = project.zones.first(where: { $0.name == zoneName }),
                  let rect = Self.rect(zone.boundary) else { continue }
            #expect(rect.contains(markup.boundsInPageSpace), "\(markup.subject) is outside \(zoneName)")
            if let regionName = markup.scaleRegionName,
               let region = project.scaleRegions.first(where: { $0.name == regionName }),
               let regionRect = Self.rect(region.boundary) {
                #expect(regionRect.contains(markup.boundsInPageSpace), "\(markup.subject) is outside \(regionName)")
            }
        }
    }

    private struct Box {
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        func contains(_ rect: PDFRectValue) -> Bool {
            rect.minX >= minX && rect.minY >= minY
                && rect.minX + rect.size.width <= maxX && rect.minY + rect.size.height <= maxY
        }
    }

    private static func rect(_ outline: [PDFPointValue]) -> Box? {
        guard let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
              let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max() else { return nil }
        return Box(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
