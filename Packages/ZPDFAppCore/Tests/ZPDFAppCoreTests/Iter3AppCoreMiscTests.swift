import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFQuantityLedger
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Iteration 3, appcore: Continue after a removed point (T-022), Merge Areas (T-023), rate list
/// waste (T-024), Explain totals (T-026), the Update Rates preview (T-027), a replaced Revision
/// Compare (T-028), and a cleared Subject cell (T-029).
@Suite("Iter3 appcore: misc")
@MainActor
struct Iter3AppCoreMiscTests {

    static let documentID = DocumentID(UUID(uuidString: "3E000000-0000-0000-0000-000000000001")!)

    /// One 1000 pt sheet at 1 m per point (100 pt = 100 m), so page numbers are metres.
    static func session() async throws -> (TakeoffSession, PageID) {
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 100, knownLengthUnit: .metre)
        return (session, page.id)
    }

    static func record(page: PageID, tool: MeasurementTool, geometry: MeasurementGeometry, subject: String = "Floor") -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: tool == .count ? .count : .measurement, tool: tool,
            subject: subject, author: "t", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func box(page: PageID, x: Double, width: Double = 10) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: 0), PDFPoint(x: x + width, y: 0), PDFPoint(x: x + width, y: 10), PDFPoint(x: x, y: 10)
        ], isClosed: true))])
    }

    static func place(_ presenter: AppMeasurementToolPresenter, _ x: Double, _ y: Double) async {
        presenter.placePoint(PDFPointValue(x: x, y: y))
        await presenter.settlePlacements()
    }

    // MARK: T-022

    /// Polylength A(0,0) B(10,0) C(20,0). Continue, Backspace (C goes), place D(10,10) E(30,10):
    /// the screen shows A-B-D-E, 10 + 10 + 20 = 40 m.
    @Test("T-022: Continue commits the chain on screen after a preloaded vertex is removed")
    func continuedChainAfterBackspace() async throws {
        let (session, page) = try await Self.session()
        let chain = Self.record(page: page, tool: .polylength, geometry: MeasurementGeometry(pageID: page, points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 20, y: 0)
        ]))
        _ = try await session.apply(.addMarkup(chain))
        let presenter = AppMeasurementToolPresenter(session: session, documentID: Self.documentID, pageID: page)
        var committed: MeasurementGeometry?
        presenter.onCommitContinuation = { _, geometry in committed = geometry }
        #expect(presenter.beginContinuation(of: try #require(await session.markup(chain.id))))
        presenter.removeLastPoint()
        await Self.place(presenter, 10, 10)
        await Self.place(presenter, 30, 10)
        presenter.commitActiveMeasurement()
        let geometry = try #require(committed)
        // Old output: A-B-C-E — the base kept whole and only E appended, 10 + 10 + √200 = 34.14 m.
        #expect(geometry.points == [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 10)])
        _ = try await session.apply(.editVertices(id: chain.id, geometry: geometry))
        #expect(await session.markup(chain.id)?.measurement?[.planLength]?.value == 40)

        // A continuation that changes nothing is not an edit.
        committed = nil
        #expect(presenter.beginContinuation(of: try #require(await session.markup(chain.id))))
        presenter.commitActiveMeasurement()
        #expect(committed == nil)
    }

    @Test("T-022: Continue on a count commits a mark removed with ⌥-click, keeping the others' identities")
    func continuedCountAfterRemoval() async throws {
        let (session, page) = try await Self.session()
        let marks = (0..<5).map { CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: Double($0) * 10, y: 5)) }
        let count = Self.record(page: page, tool: .count, geometry: MeasurementGeometry(pageID: page, countPoints: marks))
        _ = try await session.apply(.addMarkup(count))
        let presenter = AppMeasurementToolPresenter(session: session, documentID: Self.documentID, pageID: page)
        var committed: MeasurementGeometry?
        presenter.onCommitContinuation = { _, geometry in committed = geometry }
        #expect(presenter.beginContinuation(of: try #require(await session.markup(count.id))))
        presenter.removePoint(at: 2)
        presenter.commitActiveMeasurement()
        // Old output: nil — nothing was added, so nothing was committed, and the ledger kept 5.
        let geometry = try #require(committed)
        #expect(geometry.countPoints.map(\.id) == [marks[0].id, marks[1].id, marks[3].id, marks[4].id])
        _ = try await session.apply(.editVertices(id: count.id, geometry: geometry))
        #expect(await session.markup(count.id)?.measurement?[.count]?.value == 4)
    }

    // MARK: T-023

    /// Two touching 10 × 10 "Floor" areas, 100 m² each.
    @Test("T-023: Merge Areas refuses areas measured differently, naming what differs")
    func mergeRefusesDifferentMeasuring() async throws {
        let (session, page) = try await Self.session()

        // Repeat ×: 100 + 10 × 100 = 1 100 m² before; merged as the first, 200 m².
        let once = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 0))
        var tenTimes = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 10))
        tenTimes.customValues[RepetitionColumn.columnID] = RepetitionColumn.cellValue(count: 10)
        _ = try await session.apply(.addMarkup(once))
        _ = try await session.apply(.addMarkup(tenTimes))
        // Old output: a plan editing `once` to the 20 × 10 union and removing `tenTimes` — 200 m².
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.repeatCount)) {
            _ = try await session.mergePlan(markups: [once.id, tenTimes.id])
        }

        // A Scale Region: a 1:10-finer detail scale over the second area.
        let detail = ScaleID(UUID())
        _ = try await session.calibrate(page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre, scaleID: detail)
        let region = ScaleRegionDefinition(id: ScaleRegionID(UUID()), pageID: page, name: "Detail",
                                           boundary: [PDFPoint(x: 29, y: -1), PDFPoint(x: 41, y: -1), PDFPoint(x: 41, y: 11), PDFPoint(x: 29, y: 11)],
                                           scaleID: detail, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1))
        _ = try await session.apply(.setScaleRegions([region]))
        let plan = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 20))
        let inDetail = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 30))
        _ = try await session.apply(.addMarkup(plan))
        _ = try await session.apply(.addMarkup(inDetail))
        _ = try await session.apply(.setMarkupScaleRegion(ids: [inDetail.id], regionID: region.id, scaleID: nil))
        // 10 × 10 pt at 0.1 m/pt = 1 m².
        #expect(await session.markup(inDetail.id)?.measurement?[.netArea]?.value == 1)
        // Old output: merged and measured wholly at the page scale — 200 m² for 100 + 1.
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.scaleRegion)) {
            _ = try await session.mergePlan(markups: [plan.id, inDetail.id])
        }

        // A Volume beside an Area, and two Volumes of different depths.
        var deep = Self.record(page: page, tool: .volume, geometry: Self.box(page: page, x: 50))
        deep.parameters = MeasurementParameters(depth: ZPDFContracts.DecimalQuantity(value: Decimal(string: "0.3")!, dimension: .length))
        var shallow = Self.record(page: page, tool: .volume, geometry: Self.box(page: page, x: 60))
        shallow.parameters = MeasurementParameters(depth: ZPDFContracts.DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length))
        let flat = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 70))
        for record in [deep, shallow, flat] { _ = try await session.apply(.addMarkup(record)) }
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.parameters)) {
            _ = try await session.mergePlan(markups: [deep.id, shallow.id])
        }
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.tool)) {
            _ = try await session.mergePlan(markups: [shallow.id, flat.id])
        }
        #expect(AreaSplitRefusal.measuredDifferently(.repeatCount).message.contains("Repeat ×"))

        // Alike areas still merge: two plain page-scale areas, 100 + 100 = 200 m².
        let left = Self.record(page: page, tool: .area, geometry: Self.box(page: page, x: 100))
        let right = Self.record(page: page, tool: .rectangleArea, geometry: Self.box(page: page, x: 110))
        _ = try await session.apply(.addMarkup(left))
        _ = try await session.apply(.addMarkup(right))
        _ = try await session.applyBatch(try await session.mergePlan(markups: [left.id, right.id]).commands)
        #expect(await session.markup(left.id)?.measurement?[.netArea]?.value == 200)
    }

    // MARK: T-024

    @Test("T-024: a supplier list's bare waste numbers are read one way for the whole list")
    func wastePercentagesPerList() {
        // "Waste %" header: every bare number is a percentage. Old output: 1 → 1.0 (100 %), 0.5 → 0.5 (50 %).
        let header = RateLibraryCSV.parse("Name;Unit;Rate;Waste %\nBoard;m²;10;1\nScrew;pcs;1;0,5\nTile;m²;20;5\n", defaultCurrency: "SEK")
        #expect(header.rejected.isEmpty)
        #expect(header.entries.map(\.waste) == [Decimal(string: "0.01"), Decimal(string: "0.005"), Decimal(string: "0.05")])
        // No "%" anywhere, but a value above 1: all percentages. Old output: 1 → 1.0 (100 %).
        let above = RateLibraryCSV.parse("Name;Unit;Rate;Waste\nA;m²;10;1\nB;m²;10;2\nC;m²;10;5\n", defaultCurrency: "SEK")
        #expect(above.entries.map(\.waste) == [Decimal(string: "0.01"), Decimal(string: "0.02"), Decimal(string: "0.05")])
        // Fractions only: fractions.
        let fractions = RateLibraryCSV.parse("Name,Unit,Rate,Waste\nA,m2,10,0.1\nB,m2,10,1\n", defaultCurrency: "SEK")
        #expect(fractions.entries.map(\.waste) == [Decimal(string: "0.1"), Decimal(string: "1")])
        // A cell that says "%" is a percentage whatever the others are; a bad line does not count.
        let mixed = RateLibraryCSV.parse("Name;Unit;Rate;Spill;Pack\nA;m²;10;10 %;\nB;m²;10;0,05;\nC;m²;10;7;x\n", defaultCurrency: "SEK")
        #expect(mixed.entries.map(\.waste) == [Decimal(string: "0.10"), Decimal(string: "0.05")])
        #expect(mixed.rejected.map(\.line) == [4])
    }

    // MARK: T-026

    /// A 40 pt Wall length (4 m at 0.1 m/pt) and a Rise/Drop row whose Value is its 1 m rise.
    @Test("T-026: Explain's totals leave out a Rise/Drop rise, as the ledger does")
    func explainLeavesOutRise() async throws {
        let bugs = NLQuantitiesBugTests()
        let fixture = try await bugs.makeFixture(sizes: [])
        let page = try #require(await fixture.environment.session.pageDescriptors.first?.id)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(fixture.environment.snapshot.documentID), pageID: page, kind: .measurement,
            tool: .length, subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 300), PDFPoint(x: 40, y: 300)]),
            createdAt: stamp, modifiedAt: stamp)
        var rise = MeasurementParameters.default
        rise.slope = .total(1)
        var riseDrop = wall
        riseDrop.id = MarkupID(UUID())
        riseDrop.tool = .riseDrop
        riseDrop.subject = "Roof"
        riseDrop.parameters = rise
        riseDrop.geometry = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 400), PDFPoint(x: 30, y: 400)])
        try await fixture.environment.commands.perform(.addMarkup(wall))
        try await fixture.environment.commands.perform(.addMarkup(riseDrop))
        let explanation = await fixture.environment.explain([wall.id.rawValue, riseDrop.id.rawValue])
        #expect(explanation.rows.count == 2)
        let length = try #require(explanation.rows.first { $0.markupID == wall.id.rawValue }?.value)
        #expect(length.value == 4)
        let four = fixture.environment.ledger.projectionFormatter.textWithUnit(ZPDFUIPresentation.DecimalQuantity(value: 4, dimension: length.dimension))
        // Old output: one total of 5 m — the rise added to the length.
        #expect(explanation.totals == [four])
    }

    // MARK: T-027

    /// Two 10 × 10 pt Volumes at 0.1 m/pt (1 m² each), 0.5 m and 0.2 m deep: 0.5 m³ and 0.2 m³.
    /// Priced at 100 SEK/m³ (Total Cost 50 and 20); the list then says 120. The money the preview
    /// says a row moves is exactly the change Update Rates makes to its Total Cost. The rows where
    /// the old preview's quantity (the Value) and Total Cost disagree are pinned by
    /// ``rateUpdateSkipsRowsTheRateDoesNotPrice()``.
    @Test("T-027: the Update Rates preview moves each row's Total Cost by exactly what it says")
    func ratePreviewMatchesTotalCost() async throws {
        let bugs = NLQuantitiesBugTests()
        let fixture = try await bugs.makeFixture(sizes: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-rates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.environment.rateLibraryStore = RateLibraryStore(directory: directory)
        let page = try #require(await fixture.environment.session.pageDescriptors.first?.id)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        func volume(depth: String) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: DocumentID(fixture.environment.snapshot.documentID), pageID: page, kind: .measurement,
                tool: .volume, subject: "Footing", author: "t",
                geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
                ], isClosed: true))]),
                parameters: MeasurementParameters(depth: ZPDFContracts.DecimalQuantity(value: Decimal(string: depth)!, dimension: .length)),
                createdAt: stamp, modifiedAt: stamp)
        }
        let deep = volume(depth: "0.5")
        let shallow = volume(depth: "0.2")
        try await fixture.environment.commands.perform(.addMarkup(deep))
        try await fixture.environment.commands.perform(.addMarkup(shallow))
        let library = try #require(fixture.environment.ledger as? any LedgerRateLibraryManaging)
        _ = await library.importRateList("Name;Unit;Rate;Currency\nConcrete;m³;100;SEK\n")
        let concrete = try #require(library.rateEntries.first)
        let applied = await library.applyRateEntry(concrete.id, to: [deep.id.rawValue, shallow.id.rawValue])
        #expect(!applied.didFail, "\(applied.failureDescription ?? "")")
        let ledger = fixture.environment.ledger
        func totalCost(_ id: MarkupID) async -> Decimal? {
            await ledger.refresh()
            let row = (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.first { $0.markupID == id.rawValue }
            guard case .currency(let amount, _)? = row?.value(.totalCost) else { return nil }
            return amount
        }
        #expect(await totalCost(deep.id) == 50)
        #expect(await totalCost(shallow.id) == 20)
        _ = await library.importRateList("Name;Unit;Rate;Currency\nConcrete;m³;120;SEK\n")
        let pending = await library.pendingRateUpdates()
        // 0.5 m³ × 20 SEK and 0.2 m³ × 20 SEK.
        #expect(pending.first { $0.markupID == deep.id.rawValue }?.moneyDelta == 10)
        #expect(pending.first { $0.markupID == shallow.id.rawValue }?.moneyDelta == 4)
        _ = await library.applyRateUpdates(Set(pending.map(\.markupID)))
        #expect(await totalCost(deep.id) == 60)
        #expect(await totalCost(shallow.id) == 24)
        // The one table: the app tier reads the store's, and Total Cost prices a Volume's volume.
        #expect(LedgerStore.pricedColumn(for: .volume) == .volume)
        #expect(LedgerStore.pricedColumn(for: .riseDrop) == nil)
    }

    /// Material and Unit Cost are typed columns, so a person can put "Concrete" at 100 SEK on any
    /// row. Beside a priced 0.5 m³ Volume: a Rise/Drop whose Value is its 1 m rise (Total Cost an
    /// error cell: it prices nothing) and a 4 m Length (Total Cost a per-metre price). The list
    /// then says Concrete is 120 SEK per m³.
    ///
    /// Old output: the preview listed the Rise/Drop at 1 m × 20 = 20 SEK and the Length at
    /// 4 m × 20 = 80 SEK — money Total Cost never moves — and Update Rates wrote 120 SEK/m³ over
    /// both rows' Unit Cost. After the first T-027 fix the Rise/Drop read 0 SEK but was still
    /// listed and rewritten, and the Length still read 80 SEK.
    @Test("T-027: Update Rates leaves out rows the library's rate does not price")
    func rateUpdateSkipsRowsTheRateDoesNotPrice() async throws {
        let bugs = NLQuantitiesBugTests()
        let fixture = try await bugs.makeFixture(sizes: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3r-rates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.environment.rateLibraryStore = RateLibraryStore(directory: directory)
        let page = try #require(await fixture.environment.session.pageDescriptors.first?.id)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let document = DocumentID(fixture.environment.snapshot.documentID)
        let footing = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: document, pageID: page, kind: .measurement, tool: .volume, subject: "Footing", author: "t",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10), PDFPoint(x: 0, y: 10)
            ], isClosed: true))]),
            parameters: MeasurementParameters(depth: ZPDFContracts.DecimalQuantity(value: Decimal(string: "0.5")!, dimension: .length)),
            createdAt: stamp, modifiedAt: stamp)
        let curb = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: document, pageID: page, kind: .measurement, tool: .length, subject: "Curb", author: "t",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 300), PDFPoint(x: 40, y: 300)]),
            createdAt: stamp, modifiedAt: stamp)
        var rise = MeasurementParameters.default
        rise.slope = .total(1)
        var ramp = curb
        ramp.id = MarkupID(UUID())
        ramp.tool = .riseDrop
        ramp.subject = "Ramp"
        ramp.parameters = rise
        ramp.geometry = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 400), PDFPoint(x: 30, y: 400)])
        for record in [footing, curb, ramp] { try await fixture.environment.commands.perform(.addMarkup(record)) }

        let library: any LedgerRateLibraryManaging = fixture.environment.ledger
        _ = await library.importRateList("Name;Unit;Rate;Currency\nConcrete;m³;100;SEK\n")
        let concrete = try #require(library.rateEntries.first)
        let applied = await library.applyRateEntry(concrete.id, to: [footing.id.rawValue])
        #expect(!applied.didFail, "\(applied.failureDescription ?? "")")
        // The library refuses to price the other two itself …
        #expect(await library.applyRateEntry(concrete.id, to: [ramp.id.rawValue]).didFail)
        #expect(await library.applyRateEntry(concrete.id, to: [curb.id.rawValue]).didFail)
        // … but a person may type the same Material and Unit Cost on them.
        let typed = await fixture.environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [ramp.id.rawValue, curb.id.rawValue],
            values: [.material: .text("Concrete"), .unitCost: .currency(amount: 100, code: "SEK")]
        ))
        #expect(!typed.didFail, "\(typed.failureDescription ?? "")")

        let ledger = fixture.environment.ledger
        func row(_ id: MarkupID) async -> LedgerRow? {
            await ledger.refresh()
            return (0..<ledger.rowCount).compactMap { ledger.row(at: $0) }.first { $0.markupID == id.rawValue }
        }
        let rampBefore = try #require(await row(ramp.id))
        let curbBefore = try #require(await row(curb.id))
        // The old preview's quantity: the Value, 1 m for the rise and 4 m for the curb.
        #expect(LedgerDefaultColumns.primaryQuantity(for: rampBefore)?.value == 1)
        #expect(LedgerDefaultColumns.primaryQuantity(for: curbBefore)?.value == 4)
        // Total Cost prices nothing on the rise and prices metres on the curb.
        #expect(rampBefore.value(.unitCost) == .currency(amount: 100, code: "SEK"))
        if case .currency = rampBefore.value(.totalCost) { Issue.record("a Rise/Drop's Total Cost priced its rise") }
        #expect(curbBefore.value(.totalCost) == .currency(amount: 400, code: "SEK"))

        _ = await library.importRateList("Name;Unit;Rate;Currency\nConcrete;m³;120;SEK\n")
        let pending = await library.pendingRateUpdates()
        // Only the Volume the rate prices: 0.5 m³ × 20 SEK.
        #expect(pending.map(\.markupID) == [footing.id.rawValue])
        #expect(pending.first?.moneyDelta == 10)
        // Old: listed at 20 SEK (rise × Δrate) and 80 SEK (length × Δrate).
        #expect(pending.first { $0.markupID == ramp.id.rawValue }?.moneyDelta == nil)
        #expect(pending.first { $0.markupID == curb.id.rawValue }?.moneyDelta == nil)

        // Asked to update all three, it changes the Volume and leaves the other two as typed.
        let receipt = await library.applyRateUpdates([footing.id.rawValue, ramp.id.rawValue, curb.id.rawValue])
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(receipt.changedMarkupIDs == [footing.id.rawValue])
        #expect(await row(footing.id)?.value(.totalCost) == .currency(amount: 60, code: "SEK"))
        let rampAfter = try #require(await row(ramp.id))
        let curbAfter = try #require(await row(curb.id))
        #expect(rampAfter.value(.unitCost) == .currency(amount: 100, code: "SEK"))
        #expect(rampAfter.value(.totalCost) == rampBefore.value(.totalCost))
        #expect(rampAfter.displayValue(.totalCost) == rampBefore.displayValue(.totalCost))
        #expect(curbAfter.value(.unitCost) == .currency(amount: 100, code: "SEK"))
        #expect(curbAfter.value(.totalCost) == .currency(amount: 400, code: "SEK"))
    }

    struct GateFailure: Error {}

    /// Holds the first page-box read until the test fails it.
    actor Gate {
        private var waiting: CheckedContinuation<Void, any Error>?
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false

        func enter() async throws {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                hasEntered = true
                entered?.resume()
                entered = nil
            }
        }

        func waitUntilEntered() async {
            guard !hasEntered else { return }
            await withCheckedContinuation { entered = $0 }
        }

        func fail() {
            waiting?.resume(throwing: GateFailure())
            waiting = nil
        }
    }

    /// A source whose first page-box read waits at the gate, then fails.
    struct GatedSource: RevisionDocumentSourcing {
        let gate: Gate
        var isolation: RevisionParsingIsolation { .inProcess }

        func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
            try await gate.enter()
            return .zero
        }

        func render(_ reference: RevisionPageReference, scale: Double, maximumPixels: Int) async throws -> RenderedRevisionPage {
            throw GateFailure()
        }

        func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
            throw GateFailure()
        }
    }

    @Test("T-028: a comparison replaced while it runs leaves nothing behind when it ends")
    func replacedComparisonLeavesNothing() async throws {
        let gate = Gate()
        let presenter = AppComparePresenter(comparator: RevisionComparator(source: GatedSource(gate: gate)))
        let colour = ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1)
        let baseline = RevisionSummary(id: UUID(), documentID: UUID(), name: "A-101", revisionLabel: "A", author: "t",
                                       pageCount: 1, isBaseline: true, colorRGBA: colour, fileName: "a.pdf")
        let revised = RevisionSummary(id: UUID(), documentID: UUID(), name: "A-101", revisionLabel: "B", author: "t",
                                      pageCount: 1, colorRGBA: colour, fileName: "b.pdf")
        presenter.setRevisions([baseline, revised], pages: [
            baseline.id: RevisionPageReference(document: DocumentHandle(rawValue: 1), pageIndex: 0, label: "A"),
            revised.id: RevisionPageReference(document: DocumentHandle(rawValue: 2), pageIndex: 0, label: "B")
        ])
        presenter.compare()
        let task = try #require(presenter.compareTask)
        await gate.waitUntilEntered()
        // The person picks another pair while the first comparison is still reading.
        presenter.invalidateComparison()
        await gate.fail()
        await task.value
        // Old output: .failed(reason: "GateFailure()") — the old pair's failure written over the new
        // pair's empty review, through a `MainActor.run` hop that no cancellation check guarded.
        #expect(presenter.alignmentState == .notAligned)
        #expect(presenter.diffs.isEmpty)
    }

    // MARK: T-029

    @Test("T-029: clearing a Subject cell clears the subject")
    func clearedSubjectCell() async throws {
        let bugs = NLQuantitiesBugTests()
        let fixture = try await bugs.makeFixture(sizes: [(10, 10)])
        let id = try #require(fixture.ids.first)
        #expect(await fixture.environment.session.markup(id)?.subject == "Slab 0")
        let receipt = await fixture.environment.applyBulkEdit(LedgerBulkEditRequest(markupIDs: [id.rawValue], values: [.subject: .empty]))
        // Old output: a success receipt with nothing changed, and the subject still "Slab 0".
        #expect(!receipt.didFail)
        #expect(receipt.changedMarkupIDs == [id.rawValue])
        #expect(await fixture.environment.session.markup(id)?.subject == "")
        await fixture.environment.commands.undo()
        #expect(await fixture.environment.session.markup(id)?.subject == "Slab 0")
    }
}
