import CoreGraphics
import CoreText
import Foundation
import Observation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFSearch
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// The add's undo name (L-09), Merge Areas and values (V-030),
/// a placed count's marks (V-031), preset defaults by column kind (V-032), a strict retype
/// (V-033), a dismissed double count (V-034), Find Scale Regions' grid (V-035), set-aside zones
/// through undo (V-038), a stale search note (V-039), the batch search scope across the set
/// (V-040) and XFDF dates (V-041). Every expected value is derived by hand next to its input.
@Suite("Iteration 5 — application core")
@MainActor
struct Iter5AppCoreTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func page(_ documentID: DocumentID, index: Int = 0, label: String = "A-101") -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: label,
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
    }

    static func record(
        _ page: ZPDFContracts.PageDescriptor, kind: ZPDFContracts.MarkupKind, tool: MeasurementTool?,
        geometry: MeasurementGeometry, subject: String = "Floor"
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: kind, tool: tool,
            subject: subject, author: "A. Berg", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    static func square(_ page: PageID, x: Double, side: Double = 10) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: 0), PDFPoint(x: x + side, y: 0), PDFPoint(x: x + side, y: side), PDFPoint(x: x, y: side)
        ], isClosed: true))])
    }

    // MARK: L-09

    /// Old output: "Add Markup" for every one of them — the undo toast read "Undid Add Markup" after
    /// an Area.
    @Test("L-09: adding a markup names its tool or kind on the undo stack")
    func addNamesTheKind() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: sheet.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre
        )
        let cases: [(ZPDFContracts.MarkupRecord, String)] = [
            (Self.record(sheet, kind: .measurement, tool: .area, geometry: Self.square(sheet.id, x: 0)), "Add Area"),
            (Self.record(sheet, kind: .measurement, tool: .rectangleArea, geometry: Self.square(sheet.id, x: 20)), "Add Rectangle Area"),
            (Self.record(sheet, kind: .count, tool: .count, geometry: MeasurementGeometry(
                pageID: sheet.id, countPoints: [CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 5, y: 5))]
            )), "Add Count"),
            (Self.record(sheet, kind: .cloud, tool: nil, geometry: Self.square(sheet.id, x: 40), subject: ""), "Add Cloud"),
            (Self.record(sheet, kind: .text, tool: nil, geometry: Self.square(sheet.id, x: 60), subject: ""), "Add Text")
        ]
        for (record, name) in cases {
            try await environment.commands.perform(.addMarkup(record))
            #expect(environment.commands.undoManager.undoActionName == name)
            #expect(DocumentCommand.addMarkup(record).undoActionName == name)
        }

        // The shipping draw path: the Area tool's commit through the measurement presenter.
        environment.measurement.setPage(sheet.id)
        environment.measurement.activate(kind: .area)
        environment.measurement.appendRawPoints([
            PDFPointValue(x: 100, y: 100), PDFPointValue(x: 200, y: 100), PDFPointValue(x: 200, y: 200)
        ])
        environment.measurement.commitActiveMeasurement()
        _ = await Iter1AppCorePresenterTests.wait(upTo: 3) { environment.commands.undoManager.undoActionName == "Add Area" }
        await environment.commands.settle()
        #expect(await session.orderedMarkups.filter { $0.tool == .area }.count == 2)
        #expect(environment.commands.undoManager.undoActionName == "Add Area")
    }

    // MARK: V-030

    /// Two touching 10 × 10 pt "Floor" areas on a sheet at 100 pt = 100 m: 100 m² each.
    @Test("V-030: Merge Areas refuses areas with a different Unit Cost, ledger value or Project Zone")
    func mergeRefusesDifferentValues() async throws {
        let (session, page) = try await Iter3AppCoreMiscTests.session()
        let unitCost = try #require(await session.ledgerColumns.columnID(standard: .unitCost))
        // A is 100 m² at 100/m², B 100 m² at 200/m²: Total Cost 10 000 + 20 000 = 30 000. Merged as
        // A the union is 200 m² × 100 = 20 000. Old output: a plan editing A and removing B.
        var cheap = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 0))
        cheap.customValues[unitCost] = .currency(amount: 100, code: "SEK")
        var dear = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 10))
        dear.customValues[unitCost] = .currency(amount: 200, code: "SEK")
        _ = try await session.apply(.addMarkup(cheap))
        _ = try await session.apply(.addMarkup(dear))
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.values(column: "Unit Cost"))) {
            _ = try await session.mergePlan(markups: [cheap.id, dear.id])
        }
        #expect(AreaMergeDifference.values(column: "Unit Cost").message.contains("“Unit Cost”"))

        // An assembly assignment is a ledger value too (ADR-0024).
        var assembled = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 30))
        assembled.customValues[AssemblyColumn.columnID] = .text("slab-200")
        let bare = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 40))
        _ = try await session.apply(.addMarkup(assembled))
        _ = try await session.apply(.addMarkup(bare))
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.values(column: "Assembly"))) {
            _ = try await session.mergePlan(markups: [assembled.id, bare.id])
        }

        // Filed in two zones: the merged row would carry B's 100 m² into A's zone.
        let east = ProjectZoneDefinition(id: ZoneID(UUID()), name: "East", kind: .floor, sortOrder: 0,
                                         colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1))
        let west = ProjectZoneDefinition(id: ZoneID(UUID()), name: "West", kind: .floor, sortOrder: 1,
                                         colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1))
        _ = try await session.apply(.setProjectZones([east, west]))
        var inEast = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 60))
        inEast.zoneID = east.id
        var inWest = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 70))
        inWest.zoneID = west.id
        _ = try await session.apply(.addMarkup(inEast))
        _ = try await session.apply(.addMarkup(inWest))
        await #expect(throws: AreaSplitRefusal.measuredDifferently(.zone)) {
            _ = try await session.mergePlan(markups: [inEast.id, inWest.id])
        }
        #expect(await session.markup(inWest.id) != nil, "a refused merge changes nothing")

        // Alike values still merge; an explicit empty cell is no value: 100 + 100 = 200 m² at 100/m².
        var left = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 100))
        left.customValues[unitCost] = .currency(amount: 100, code: "SEK")
        left.zoneID = east.id
        var right = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: Iter3AppCoreMiscTests.box(page: page, x: 110))
        right.customValues[unitCost] = .currency(amount: 100, code: "SEK")
        right.customValues[AssemblyColumn.columnID] = .empty
        right.zoneID = east.id
        _ = try await session.apply(.addMarkup(left))
        _ = try await session.apply(.addMarkup(right))
        _ = try await session.applyBatch(try await session.mergePlan(markups: [left.id, right.id]).commands)
        let merged = try #require(await session.markup(left.id))
        #expect(merged.measurement?[.netArea]?.value == 200)
        #expect(merged.customValues[unitCost] == .currency(amount: 100, code: "SEK"))
        #expect(merged.zoneID == east.id)
    }

    // MARK: V-031

    static func countPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: "Door Count", category: "Openings", panel: .myTools, markupKind: .count,
            measurementKind: .count, colorRGBA: ColorRGBA(red: 0, green: 0.4, blue: 1), defaultSubject: "Doors"
        )
    }

    /// Old output: the placed mark in `points`; Continue + one mark committed a count of 1 (the
    /// placed mark dropped), and Number Marks returned no command for it.
    @Test("V-031: a count placed from a preset keeps its mark in countPoints, so Continue and Number Marks see it")
    func placedCountContinuesAndNumbers() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await session.setPresetScale(page: sheet.id, ratioDenominator: 100)
        let receipt = await environment.placePreset(Self.countPreset(), at: PDFPointValue(x: 120, y: 240), pageID: sheet.id.rawValue)
        let placedID = try #require(receipt.markupID)
        let placed = try #require(await session.markup(MarkupID(placedID)))
        #expect(placed.geometry?.countPoints.map(\.position) == [PDFPoint(x: 120, y: 240)])
        #expect(placed.geometry?.points.isEmpty == true)
        #expect(placed.measurement?[.count]?.value == 1)

        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: sheet.id)
        var committed: MeasurementGeometry?
        presenter.onCommitContinuation = { _, geometry in committed = geometry }
        #expect(presenter.beginContinuation(of: placed))
        await Iter3AppCoreMiscTests.place(presenter, 300, 240)
        presenter.commitActiveMeasurement()
        let continued = try #require(committed)
        #expect(continued.countPoints.map(\.position) == [PDFPoint(x: 120, y: 240), PDFPoint(x: 300, y: 240)])
        #expect(continued.countPoints.first?.id == placed.geometry?.countPoints.first?.id, "the placed mark keeps its identity")
        _ = try await session.apply(.editVertices(id: placed.id, geometry: continued))
        #expect(await session.markup(placed.id)?.measurement?[.count]?.value == 2, "1 placed + 1 continued")

        let (commands, turnsOn) = CountNumbering.toggleCommands(for: [try #require(await session.markup(placed.id))])
        #expect(turnsOn && commands.count == 1)
    }

    /// A count saved before the fix: its one mark in `points`, written as a polyline blob.
    @Test("V-031: a count saved with its marks in points reopens, continues and numbers with them")
    func legacyPointCount() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID)
        let legacy = MeasurementGeometry(pageID: sheet.id, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 10)])
        // The save writes it as a blob with no sidecar; the open reads a count's blob as marks.
        let encoded = try TakeoffGeometryCodec.encode(legacy)
        #expect(encoded.json == nil)
        let reopened = try #require(try TakeoffGeometryCodec.decode(blob: encoded.blob, json: nil, pageID: sheet.id, tool: .count))
        #expect(reopened.countPoints.map(\.position) == legacy.points)
        #expect(reopened.points.isEmpty)
        // A length is untouched by the rule.
        let length = try TakeoffGeometryCodec.decode(blob: encoded.blob, json: nil, pageID: sheet.id, tool: .length)
        #expect(length?.points == legacy.points && length?.countPoints.isEmpty == true)

        // In memory (a session opened before the fix): Continue keeps both marks and adds the third.
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        _ = try await session.setPresetScale(page: sheet.id, ratioDenominator: 100)
        let count = Self.record(sheet, kind: .count, tool: .count, geometry: legacy, subject: "Doors")
        _ = try await session.apply(.addMarkup(count))
        #expect(await session.markup(count.id)?.measurement?[.count]?.value == 2)
        let presenter = AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: sheet.id)
        var committed: MeasurementGeometry?
        presenter.onCommitContinuation = { _, geometry in committed = geometry }
        #expect(presenter.beginContinuation(of: try #require(await session.markup(count.id))))
        await Iter3AppCoreMiscTests.place(presenter, 30, 10)
        presenter.commitActiveMeasurement()
        let continued = try #require(committed)
        #expect(continued.countPoints.map(\.position) == legacy.points + [PDFPoint(x: 30, y: 10)])
        #expect(continued.points.isEmpty, "the marks are all in countPoints; none is left to be counted twice")
        _ = try await session.apply(.editVertices(id: count.id, geometry: continued))
        #expect(await session.markup(count.id)?.measurement?[.count]?.value == 3)

        // Number Marks on a points-only count moves the marks and numbers them 1, 2.
        let (commands, _) = CountNumbering.toggleCommands(for: [count])
        guard case .editVertices(_, let numbered)? = commands.first else { Issue.record("no command"); return }
        #expect(numbered.countPoints.map(\.sequenceNumber) == [1, 2])
        #expect(numbered.countPoints.map(\.position) == legacy.points && numbered.points.isEmpty)
    }

    // MARK: V-032

    @Test("V-032: preset defaults are read by column kind — number, Unit Cost, choice, checkbox, date, Repeat ×")
    func presetDefaultsByKind() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let oak = ChoiceOption(id: ChoiceOptionID(UUID()), value: "Oak")
        let pieces = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.pieces", title: "Pieces", kind: .number, dimension: .ratio)
        let finish = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.finish", title: "Finish", kind: .choice, choices: [oak])
        let fitted = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.fitted", title: "Fitted", kind: .checkbox)
        let due = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.due", title: "Due", kind: .date)
        try await session.addCustomColumns([pieces, finish, fitted, due])
        await environment.refresh()
        let columns = await session.ledgerColumns
        let unitCost = try #require(columns.columnID(standard: .unitCost))
        let unitCostKey = try #require(columns.columns.first { $0.id == unitCost }?.key)

        let resolved = AppCoreEnvironment.resolvedCustomValues([
            "custom.pieces": "2", unitCostKey: "12.50", "custom.finish": "oak", "custom.fitted": "true",
            "custom.due": "2026-09-27", RepetitionColumn.key: "3",
            // Refused, and reported: a word for a number, a prefix-only number, an option the
            // column does not offer, a key the document has no column for.
            "custom.missing": "1"
        ], columns: columns, currencyCode: "EUR")
        // Old output: every one but none skipped — ["custom.due", "custom.finish", "custom.fitted",
        // "custom.missing", "custom.pieces", "custom.zenit.repeat", <unit cost>].
        #expect(resolved.skipped == ["custom.missing"])
        #expect(resolved.values[pieces.id] == .number(ZPDFContracts.DecimalQuantity(value: 2, dimension: .ratio)))
        #expect(resolved.values[unitCost] == .currency(amount: Decimal(string: "12.5")!, code: "EUR"))
        #expect(resolved.values[finish.id] == .choice(oak.id))
        #expect(resolved.values[fitted.id] == .checkbox(true))
        // The start of the typed day in the zone the ledger shows dates in (W-028), not GMT midnight.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        #expect(resolved.values[due.id] == .date(try #require(local.date(from: DateComponents(year: 2026, month: 9, day: 27)))))
        var probe = Self.record(sheet, kind: .count, tool: .count, geometry: MeasurementGeometry(pageID: sheet.id))
        probe.customValues = resolved.values
        #expect(RepetitionColumn.count(of: probe) == 3)

        let refused = AppCoreEnvironment.resolvedCustomValues([
            "custom.pieces": "two", unitCostKey: "12-5", "custom.finish": "Pine", "custom.fitted": "maybe", RepetitionColumn.key: "2.5"
        ], columns: columns, currencyCode: "EUR")
        #expect(refused.values.isEmpty)
        #expect(refused.skipped.count == 5)

        // End to end: a Place click carries the Unit Cost default in the ledger's own currency.
        var preset = Self.countPreset()
        preset.customDefaults = [unitCostKey: "12.50", "custom.pieces": "2"]
        let receipt = await environment.placePreset(preset, at: PDFPointValue(x: 50, y: 50), pageID: sheet.id.rawValue)
        #expect(receipt.skippedCustomColumns.isEmpty)
        let placedID = try #require(receipt.markupID)
        let placed = try #require(await session.markup(MarkupID(placedID)))
        #expect(placed.customValues[unitCost] == .currency(amount: Decimal(string: "12.5")!, code: environment.ledger.defaultCurrencyCode))
        #expect(placed.customValues[pieces.id] == .number(ZPDFContracts.DecimalQuantity(value: 2, dimension: .ratio)))
    }

    // MARK: V-033

    /// Old output: "12-5" → 12, "5-" → 5, "-" → 0, "--3" → 0 (a prefix parser behind a character filter).
    @Test("V-033: a retype to Number refuses text the strict decimal rule cannot read whole")
    func retypeIsStrict() {
        for text in ["12-5", "5-", "-", "--3", "1.2.3", "12 m", "1,234.5"] {
            #expect(LedgerColumnValueConversion.number(of: .text(text)) == nil, "\(text)")
        }
        // The grammar reads a bare leading or trailing point whole: ".5" is 0.5, "5." is 5.
        #expect(LedgerColumnValueConversion.number(of: .text(".5"))?.value == Decimal(string: "0.5"))
        #expect(LedgerColumnValueConversion.number(of: .text("5."))?.value == 5)
        #expect(LedgerColumnValueConversion.number(of: .text("12,5"))?.value == Decimal(string: "12.5"))
        #expect(LedgerColumnValueConversion.number(of: .text(" -3 "))?.value == -3)
        #expect(LedgerColumnValueConversion.number(of: .text("40"))?.value == 40)
        let text = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.note", title: "Note", kind: .text)
        let number = LedgerColumnDefinition(id: text.id, key: "custom.note", title: "Note", kind: .number)
        let money = LedgerColumnDefinition(id: text.id, key: "custom.note", title: "Note", kind: .currency,
                                           dimension: .currency("SEK"))
        #expect(LedgerColumnValueConversion.convert(.text("12-5"), from: text, to: number) == nil)
        #expect(LedgerColumnValueConversion.convert(.text("5-"), from: text, to: money) == nil)
        #expect(LedgerColumnValueConversion.convert(.text("7"), from: text, to: number) == .number(.count(7)))
        #expect(LedgerColumnValueConversion.convert(.text("7,25"), from: text, to: money)
                == .currency(amount: Decimal(string: "7.25")!, code: "SEK"))
    }

    // MARK: V-034

    /// Two 100 pt Slab squares overlapping by 50 × 100 pt at 100 pt = 10 m: 5 000 pt² = 50 m².
    @Test("V-034: a dismissed double-count warning stays dismissed until what it says changes")
    func dismissedDoubleCountStaysDismissed() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await session.calibrate(
            page: sheet.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre
        )
        let left = Iter4AppCoreMiscTests.square(on: sheet, x: 0, side: 100, label: "Room 1")
        let right = Iter4AppCoreMiscTests.square(on: sheet, x: 50, side: 100, label: "Room 2")
        _ = try await session.apply(.addMarkup(left))
        _ = try await session.apply(.addMarkup(right))
        await environment.refresh()
        func doubleCounts() -> [AppWarning] {
            environment.document.warnings.filter { $0.source == AppCoreEnvironment.doubleCountWarningSource }
        }
        await environment.refreshDoubleCountWarnings(enabled: true)
        let warning = try #require(doubleCounts().first)
        #expect(warning.message.contains("50"))

        environment.document.dismissWarning(id: warning.id)
        #expect(doubleCounts().isEmpty)
        _ = try await session.apply(.changeStyle(id: left.id, style: MarkupStyle.default))
        await environment.refreshDoubleCountWarnings(enabled: true)
        // Old output: the warning back, with a new timestamp, after an unrelated style edit.
        #expect(doubleCounts().isEmpty)

        // What it says changed — 25 × 100 pt = 25 m² shared — so it is news again.
        _ = try await session.apply(.moveMarkup(id: right.id, dx: 25, dy: 0))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts().first?.message.contains("25") == true)

        // Dismissed, moved apart (forgotten), moved back: a new overlap is raised afresh.
        environment.document.dismissWarning(id: warning.id)
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts().isEmpty)
        _ = try await session.apply(.moveMarkup(id: right.id, dx: 500, dy: 0))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts().isEmpty)
        _ = try await session.apply(.moveMarkup(id: right.id, dx: -500, dy: 0))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(doubleCounts().first?.message.contains("25") == true)
    }

    // MARK: V-038

    /// The zone a set-aside markup is filed in, or `nil` when it is unfiled or not set aside.
    static func setAsideZone(_ session: TakeoffSession, _ id: MarkupID) async -> ZoneID? {
        let aside = await session.setAsideMarkups
        return aside[id]?.record.zoneID
    }

    /// Old output: after the three undos the markup stood on its restored sheet unfiled.
    @Test("V-038: undoing a restore, a zone deletion and a removal brings the zone filing back")
    func setAsideZoneFilingSurvivesUndo() async throws {
        let documentID = DocumentID(UUID())
        let first = Self.page(documentID, index: 0, label: "A-101")
        let second = Self.page(documentID, index: 1, label: "A-102")
        let session = try TakeoffSession(documentID: documentID, pages: [first, second])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let zone = ProjectZoneDefinition(id: ZoneID(UUID()), name: "East", kind: .floor, sortOrder: 0,
                                         colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1))
        try await environment.commands.perform(.setProjectZones([zone]))
        var filed = Self.record(second, kind: .rectangle, tool: nil, geometry: Self.square(second.id, x: 0), subject: "Note")
        filed.zoneID = zone.id
        try await environment.commands.perform(.addMarkup(filed))
        #expect(await session.markup(filed.id)?.zoneID == zone.id)

        try await environment.commands.perform(.setPagesExcluded([second.id], excluded: true))
        try await environment.commands.perform(.setProjectZones([]))
        try await environment.commands.perform(.setPagesExcluded([second.id], excluded: false))
        #expect(await session.markup(filed.id)?.zoneID == nil, "a zone deleted while the sheet was out files it nowhere")

        await environment.commands.undo()
        await environment.commands.settle()
        #expect(await Self.setAsideZone(session, filed.id) == zone.id, "set aside filed again")
        await environment.commands.undo()
        await environment.commands.settle()
        #expect(await session.projectZoneDefinitions.map(\.id) == [zone.id])
        await environment.commands.undo()
        await environment.commands.settle()
        #expect(await session.markup(filed.id)?.zoneID == zone.id)

        // And forward again: the restore unfiles it once more, and a further undo refiles it.
        for _ in 0..<3 {
            await environment.commands.redo()
            await environment.commands.settle()
        }
        #expect(await session.markup(filed.id)?.zoneID == nil)
        #expect(await session.projectZoneDefinitions.isEmpty)
        await environment.commands.undo()
        await environment.commands.settle()
        #expect(await Self.setAsideZone(session, filed.id) == zone.id)
        #expect(await session.orderedMarkups.contains { $0.id == filed.id } == false)
    }
}

// MARK: - V-035

/// Find Scale Regions' grouping: the bounded grid gives exactly the drawings a pairwise test gives.
struct Iter5ViewportGridTests {

    static func line(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPrimitive {
        SymbolCountReviewTests.linePrimitive(id, CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
    }

    /// Every pair within 12 pt on both axes, linked; the groups' extents, sorted.
    static func bruteForce(_ primitives: [VectorPrimitive], pageBox: PDFRectValue) -> [[Double]] {
        let limit = max(pageBox.size.width, pageBox.size.height) * ViewportScaleDetector.furnitureShare
        let parts = primitives.filter { max($0.bounds.width, $0.bounds.height) <= limit }
        var parent = Array(parts.indices)
        func find(_ x: Int) -> Int { parent[x] == x ? x : find(parent[x]) }
        for i in parts.indices {
            for j in parts.indices where j > i {
                let a = parts[i].bounds, b = parts[j].bounds
                let gapX = max(0, max(b.minX - a.maxX, a.minX - b.maxX))
                let gapY = max(0, max(b.minY - a.maxY, a.minY - b.maxY))
                if gapX <= ViewportScaleDetector.linkGap, gapY <= ViewportScaleDetector.linkGap {
                    let ra = find(i), rb = find(j)
                    if ra != rb { parent[rb] = ra }
                }
            }
        }
        var extents: [Int: [Double]] = [:]
        for (index, part) in parts.enumerated() {
            let b = part.bounds, root = find(index)
            if let e = extents[root] {
                extents[root] = [min(e[0], b.minX), min(e[1], b.minY), max(e[2], b.maxX), max(e[3], b.maxY)]
            } else {
                extents[root] = [b.minX, b.minY, b.maxX, b.maxY]
            }
        }
        return extents.values.sorted { $0.lexicographicallyPrecedes($1) }
    }

    static func sorted(_ clusters: [ViewportScaleDetector.Extent]) -> [[Double]] {
        clusters.map { [$0.minX, $0.minY, $0.maxX, $0.maxY] }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// A deterministic generator, so a failure names the same sheet every run.
    struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    @Test("V-035: the grid's drawings equal a pairwise 12 pt test on random linework, corners and edges included")
    func gridMatchesPairwise() {
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        for seed in [1, 7, 42] as [UInt64] {
            var random = Generator(state: seed)
            var primitives: [VectorPrimitive] = []
            for id in 0..<900 {
                let x = random.next() * 2384, y = random.next() * 1684
                let long = random.next() < 0.1
                // On the page: linework far off it is not grouped by design (no title can name it).
                let dx = min(max((random.next() - 0.5) * (long ? 600 : 40), -x), 2384 - x)
                let dy = min(max((random.next() - 0.5) * (long ? 600 : 40), -y), 1684 - y)
                // Some exactly 12 pt apart on a cell corner, some axis-aligned, some points.
                switch id % 5 {
                case 0: primitives.append(Self.line(UInt64(id), x, y, x + dx, y))
                case 1: primitives.append(Self.line(UInt64(id), x, y, x, y + dy))
                case 2: primitives.append(Self.line(UInt64(id), x, y, x, y))
                default: primitives.append(Self.line(UInt64(id), x, y, x + dx, y + dy))
                }
            }
            // A diagonal chain whose links are only corner to corner, 12 pt apart on both axes.
            for step in 0..<20 {
                let base = 100 + Double(step) * 24
                primitives.append(Self.line(UInt64(10_000 + step), base, base, base + 12, base + 12))
            }
            // Linework that sticks off the page stays grouped with what it touches on the page.
            primitives.append(Self.line(20_000, -40, 500, 30, 500))
            primitives.append(Self.line(20_001, 36, 490, 36, 510))
            let grid = Self.sorted(ViewportScaleDetector.clusters(primitives, pageBox: a1))
            #expect(grid == Self.bruteForce(primitives, pageBox: a1), "seed \(seed)")
        }
    }

    /// Old code: each 636 pt diagonal registered in ~2 800 cells and gap-tested every earlier
    /// occupant of ~3 000 cells — minutes on the main actor; a crafted page box let one part
    /// touch ~10⁸ dictionary cells.
    @Test("V-035: dense diagonals and a crafted page box group quickly and stay bounded")
    func denseAndCraftedSheets() async {
        let a0 = PDFRectValue(x: 0, y: 0, width: 3370, height: 2384)
        var primitives: [VectorPrimitive] = []
        for index in 0..<2_000 {
            let x = Double(index % 40) * 60, y = Double(index / 40) * 30
            primitives.append(Self.line(UInt64(index), x, y, x + 636, y + 636))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let clusters = ViewportScaleDetector.clusters(primitives, pageBox: a0)
        let elapsed = clock.now - start
        #expect(clusters.count == 1, "every diagonal overlaps its neighbours")
        #expect(elapsed < .seconds(20), "\(elapsed)")

        // A 400 000 pt page box: parts up to 120 000 pt. Two far apart stay two drawings.
        let crafted = PDFRectValue(x: 0, y: 0, width: 400_000, height: 400_000)
        let far = [Self.line(1, 0, 0, 100_000, 100_000), Self.line(2, 250_000, 250_000, 350_000, 350_000)]
        #expect(ViewportScaleDetector.clusters(far, pageBox: crafted).count == 2)

        // Off the main actor, the same proposals.
        let a1 = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let lines = [RecognisedTextLine(text: "DETALJ 3 SKALA 1:20", boundsInPageSpace: PDFRectValue(x: 740, y: 370, width: 120, height: 12))]
        let detail = ViewportScaleDetectorTests.box(10, 700, 400, 900, 600)
        let background = await ViewportScaleDetector().proposalsInBackground(lines: lines, pageBox: a1, primitives: detail)
        #expect(background == ViewportScaleDetector().proposals(lines: lines, pageBox: a1, primitives: detail))
        #expect(background.first?.region == PDFRectValue(x: 700, y: 400, width: 200, height: 200))
    }
}

// MARK: - V-039, V-040

@Suite("Iteration 5 — search")
@MainActor
struct Iter5AppCoreSearchTests {

    /// Collects the summary each time the leading hit changes — the last thing a republish does.
    @MainActor final class SummaryProbe { var seen: [String] = [] }

    static func indexedDrawing(
        in directory: URL, name: String, pages count: Int, documentUUID: UUID = UUID()
    ) async throws -> (DocumentSearchIndex, [ZPDFContracts.PageDescriptor]) {
        let pdf = directory.appendingPathComponent("\(name).pdf")
        // Page n says "FLOOR n SCREED".
        try Iter1AppCorePresenterTests.writeTextPDF(pages: count, to: pdf)
        let pages = DocumentSearchIndexTests.pages(count: count, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("\(name).sqlite"), drawingAt: pdf, displayName: name, pages: pages
        )
        _ = try await index.indexDrawingText()
        return (index, pages)
    }

    static func directory(_ tag: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it5-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Old output: "… — “SCREED” was not excluded: …" beside DOOR's first result from another drawing.
    @Test("V-039: a new word's first results from another drawing carry no note from the previous query")
    func noStaleExclusionNote() async throws {
        let directory = try Self.directory("stale-note")
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentUUID = UUID()
        let (index, pages) = try await Self.indexedDrawing(in: directory, name: "Floors", pages: 2, documentUUID: documentUUID)
        defer { Task { await index.shutDown() } }
        let presenter = AppSearchPresenter(
            service: index.service, projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Floors", pages: pages, currentPageIndex: 0),
            scope: SearchScope(location: .currentDocument)
        )
        presenter.debounce = .zero
        let door = ZPDFUIPresentation.SearchHit(
            id: UUID(), documentID: UUID(), documentTitle: "Level 2", pageID: UUID(), pageIndex: 0, pageLabel: "B-1",
            source: .pdfText, snippet: "DOOR 12"
        )
        presenter.externalSources = [ProjectSearchSource(documentID: UUID(), title: "Level 2") { text, _ in
            text == "DOOR" ? [door] : []
        }]
        presenter.searchesAllDrawings = true
        let note = AppSearchPresenter.droppedExclusionNote(["SCREED"])

        presenter.query = "FLOOR OR NOT SCREED"
        presenter.runSearch()
        #expect(await Iter1AppCorePresenterTests.wait(upTo: 3) { !presenter.isSearching && presenter.resultSummary.contains(note) })

        let probe = SummaryProbe()
        withObservationTracking({ _ = presenter.activeHitID }, onChange: {
            MainActor.assumeIsolated { probe.seen.append(presenter.resultSummary) }
        })
        presenter.query = "DOOR"
        presenter.runSearch()
        #expect(await Iter1AppCorePresenterTests.wait(upTo: 3) { !probe.seen.isEmpty })
        // The other drawing answers first: its task was queued before this drawing's query.
        #expect(probe.seen.first?.contains(note) == false, "\(probe.seen)")
        #expect(await Iter1AppCorePresenterTests.wait(upTo: 3) { !presenter.isSearching })
        #expect(!presenter.resultSummary.contains(note))
        #expect(presenter.hits.map(\.id) == [door.id])
    }

    /// Old output: the two primary pages only — the added drawing's three FLOOR sheets left out.
    @Test("V-040: 'Pages containing text' counts every drawing of the set")
    func batchScopeCoversTheSet() async throws {
        let directory = try Self.directory("batch-set")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID()
        let (primary, primaryPages) = try await Self.indexedDrawing(in: directory, name: "Plans", pages: 2, documentUUID: project)
        let (added, addedPages) = try await Self.indexedDrawing(in: directory, name: "Details", pages: 3)
        defer { Task { await primary.shutDown(); await added.shutDown() } }
        let member = BatchSearchScopeResolver.Drawing(index: added, documentUUID: project, title: "Details", pages: addedPages)
        let resolver = BatchSearchScopeResolver(
            service: primary.service, projectID: primary.projectKey, documentID: primary.documentKey,
            identity: primary.identityMap(documentUUID: project, documentTitle: "Plans", pages: primaryPages, currentPageIndex: 0),
            addedDrawings: { [member] }
        )
        let all = await resolver.resolve(term: "FLOOR")
        #expect(all.isAvailable)
        #expect(all.pageIDs == Set((primaryPages + addedPages).map(\.id.rawValue)))
        // "FLOOR 3" is on the added drawing's third sheet only.
        let third = await resolver.resolve(term: "FLOOR 3")
        #expect(third.pageIDs == [addedPages[2].id.rawValue])
        // The exclusion note is said once for the set.
        let note = await resolver.resolve(term: "FLOOR OR NOT SCREED")
        #expect(note.droppedExclusions == ["SCREED"])
        #expect(note.pageIDs.count == 5)

        // With no added drawing the primary alone answers, as before.
        let single = BatchSearchScopeResolver(
            service: primary.service, projectID: primary.projectKey, documentID: primary.documentKey,
            identity: primary.identityMap(documentUUID: project, documentTitle: "Plans", pages: primaryPages, currentPageIndex: 0)
        )
        #expect(await single.resolve(term: "FLOOR").pageIDs == Set(primaryPages.map(\.id.rawValue)))
    }

    /// A password-protected drawing whose page n says "FLOOR n SCREED", drawn through CoreText.
    static func writeLockedTextPDF(pages count: Int, password: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let options: [CFString: Any] = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password]
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, options as CFDictionary))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for page in 0..<count {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "FLOOR \(page + 1) SCREED", attributes: [.font: font])
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The re-fix: the app handed the resolver only the drawings whose index was open, so a
    /// drawing whose open failed was dropped. Old output: the primary's two pages, available.
    @Test("V-040: an added drawing with sheets in the set and no index makes the scope unavailable, naming it")
    func drawingWithoutIndexIsNamed() async throws {
        let directory = try Self.directory("batch-no-index")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID()
        let (primary, primaryPages) = try await Self.indexedDrawing(in: directory, name: "Plans", pages: 2, documentUUID: project)
        defer { Task { await primary.shutDown() } }
        func resolver(_ added: [BatchSearchScopeResolver.Drawing]) -> BatchSearchScopeResolver {
            BatchSearchScopeResolver(
                service: primary.service, projectID: primary.projectKey, documentID: primary.documentKey,
                identity: primary.identityMap(documentUUID: project, documentTitle: "Plans", pages: primaryPages, currentPageIndex: 0),
                addedDrawings: { added }
            )
        }
        let one = await resolver([.withoutIndex(title: "Details")]).resolve(term: "FLOOR")
        #expect(!one.isAvailable)
        #expect(one.pageIDs.isEmpty, "no count at all, not the primary's 2 pages")
        #expect(one.unavailableReason == "The text of “Details” could not be searched: its text index is not open. This scope cannot be previewed.")
        let two = await resolver([.withoutIndex(title: "Details"), .withoutIndex(title: "Level 2")]).resolve(term: "FLOOR")
        #expect(two.unavailableReason == "The text of “Details”, “Level 2” could not be searched: their text indexes are not open. This scope cannot be previewed.")
    }

    /// Old output: the index opened the drawing without its password, every page read as "not
    /// permitted", and the scope counted the primary's 2 pages as if the drawing had no FLOOR.
    @Test("V-040: a password-protected added drawing is searched with its password; opened without it, it is named")
    func lockedDrawingIsSearchedWithItsPassword() async throws {
        let directory = try Self.directory("batch-locked")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID()
        let (primary, primaryPages) = try await Self.indexedDrawing(in: directory, name: "Plans", pages: 2, documentUUID: project)
        let password = "zenit-it5r-locked"
        let pdf = directory.appendingPathComponent("Details.pdf")
        try Self.writeLockedTextPDF(pages: 3, password: password, to: pdf)
        let addedPages = DocumentSearchIndexTests.pages(count: 3, documentID: DocumentID(UUID()))
        let unlocked = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("unlocked.sqlite"), drawingAt: pdf, displayName: "Details",
            pages: addedPages, password: password
        )
        let locked = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("locked.sqlite"), drawingAt: pdf, displayName: "Details", pages: addedPages
        )
        defer { Task { await primary.shutDown(); await unlocked.shutDown(); await locked.shutDown() } }
        func resolver(_ index: DocumentSearchIndex) -> BatchSearchScopeResolver {
            let member = BatchSearchScopeResolver.Drawing(index: index, documentUUID: project, title: "Details", pages: addedPages)
            return BatchSearchScopeResolver(
                service: primary.service, projectID: primary.projectKey, documentID: primary.documentKey,
                identity: primary.identityMap(documentUUID: project, documentTitle: "Plans", pages: primaryPages, currentPageIndex: 0),
                addedDrawings: { [member] }
            )
        }
        // With the password: 2 primary + 3 added pages; "FLOOR 3" on the added third sheet only.
        let all = await resolver(unlocked).resolve(term: "FLOOR")
        #expect(all.isAvailable)
        #expect(all.pageIDs == Set((primaryPages + addedPages).map(\.id.rawValue)))
        #expect(await resolver(unlocked).resolve(term: "FLOOR 3").pageIDs == [addedPages[2].id.rawValue])
        // Without it: every page not permitted — named, never counted as "no match".
        let report = try await locked.indexDrawingText()
        #expect(report.pagesNotPermitted == [0, 1, 2])
        let refused = await resolver(locked).resolve(term: "FLOOR")
        #expect(!refused.isAvailable)
        #expect(refused.pageIDs.isEmpty, "not the primary's 2 pages")
        #expect(refused.unavailableReason == "The text of “Details” could not be read, so this scope cannot be previewed.")
    }
}

// MARK: - V-041

struct Iter5XFDFDateTests {

    /// The formatter both directions used to build for every date — the reference.
    static func reference() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }

    @Test("V-041: PDF dates read and write exactly as the per-date formatter did, without one")
    func datesMatchTheFormatter() {
        let formatter = Self.reference()
        var random = Iter5ViewportGridTests.Generator(state: 2026)
        // 1600 … 2400, fractional seconds included; plus leap days and the epoch.
        var dates = (0..<2_000).map { _ in Date(timeIntervalSince1970: -11_676_096_000 + random.next() * 25_245_000_000) }
        dates += [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 951_782_400.75), Date(timeIntervalSince1970: 4_107_542_399)]
        for date in dates {
            let written = XFDF.pdfDate(date)
            #expect(written == "D:" + formatter.string(from: date) + "Z", "\(date)")
            let digits = String(written.dropFirst(2).prefix(14))
            #expect(XFDFParserDelegate.date(written) == formatter.date(from: digits), "\(written)")
        }
        // The strict formatter's refusals: no 13th month, no 30 February, no hour 24, no letters,
        // too few digits, no prefix. 29 February 2024 is a real day; 29 February 2023 is not.
        for text in ["D:20241301000000Z", "D:20230230120000", "D:20240101240000", "D:2024010112ab00",
                     "D:2024010112", "20240101120000", "D:20230229000000"] {
            #expect(XFDFParserDelegate.date(text) == nil, "\(text)")
            #expect(formatter.date(from: String(text.dropFirst(2).prefix(14))) == nil || !text.hasPrefix("D:"), "\(text)")
        }
        #expect(XFDFParserDelegate.date("D:20240229235959+01'00'") == formatter.date(from: "20240229235959"))
        #expect(XFDFParserDelegate.date(nil) == nil)
    }
}
