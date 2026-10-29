import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// Batch sheet numbers by set position (W-026), review
/// round deltas from the ledger (W-027), day-only dates in the local zone (W-028), job template
/// columns through the table (W-029), markup presets drawn with their row defaults (W-030), one
/// number grammar (W-032) and one translation rule (W-038). Every expected value is derived by hand
/// next to its input, and every regression test names the old output.
@Suite("Iteration 6 — application core")
@MainActor
struct Iter6AppCoreTests {

    static let instant = Date(timeIntervalSince1970: 1_790_000_000)

    static func page(_ documentID: DocumentID, index: Int, label: String) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: label,
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
    }

    static func box(_ page: PageID, x: Double, y: Double, width: Double, height: Double) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: x, y: y), PDFPoint(x: x + width, y: y),
            PDFPoint(x: x + width, y: y + height), PDFPoint(x: x, y: y + height)
        ], isClosed: true))])
    }

    static func record(
        _ documentID: DocumentID, _ page: PageID, kind: ZPDFContracts.MarkupKind = .measurement,
        tool: MeasurementTool?, subject: String, geometry: MeasurementGeometry
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: kind, tool: tool,
            subject: subject, author: "A. Berg", geometry: geometry, createdAt: instant, modifiedAt: instant
        )
    }

    static func depth(_ metres: String) -> MeasurementParameters {
        MeasurementParameters(depth: ZPDFContracts.DecimalQuantity(value: Decimal(string: metres)!, dimension: .length))
    }

    // MARK: W-026

    /// Drawing A (ten sheets, PDF indices 0-9) then drawing B (five, PDF indices 0-4), one set.
    @Test("W-026: a batch {n} numbers sheets by their place in the set, across drawings and after a reorder")
    func headerNumbersBySetPosition() async throws {
        let a = DocumentID(UUID()), b = DocumentID(UUID())
        let drawingA = (0..<10).map { Self.page(a, index: $0, label: "A-\($0 + 1)") }
        let drawingB = (0..<5).map { Self.page(b, index: $0, label: "B-\($0 + 1)") }
        let session = try TakeoffSession(documentID: a, pages: drawingA + drawingB)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: a)

        /// Runs one batch and returns the captions it placed, in set order.
        func stamp(_ template: String) async throws -> [String] {
            let producer = try #require(environment.headerFooterBatchProducer(
                template: template, now: Self.instant, author: "A. Berg"
            ))
            let plan = environment.planBatchApply(
                producer, request: BatchApplyRequest(scope: .allPages, anchor: .corner(.topLeft, insetX: 24, insetY: 18))
            )
            _ = await environment.runBatchApply(producer, plan: plan)
            await environment.refresh()
            let placed = await session.orderedMarkups.filter { $0.label == template }
            return environment.snapshot.pages.compactMap { page in
                placed.first { $0.pageID.rawValue == page.id }?.caption
            }
        }

        // Old output: "1" … "10", then "1" … "5" again — drawing B's PDF indices restart at 0.
        #expect(try await stamp("{n}") == (1...15).map(String.init))

        // B-5, the fifteenth sheet, moved to the front of the set.
        try await environment.commands.perform(.reorderPage(from: 14, to: 0))
        await environment.refresh()
        #expect(environment.snapshot.pages.first?.label == "B-5")
        // Old output: B-5 read "Sheet 5" (its PDF index 4) and A-1 "Sheet 1".
        #expect(try await stamp("Sheet {n}") == (1...15).map { "Sheet \($0)" })
    }

    // MARK: W-027

    /// 1 pt = 1 cm (`SharedReviewSyncTests.machine`). Wall A 100 × 50 pt = 1 m × 0.5 m = 0.5 m², perimeter
    /// 2 × (1 + 0.5) = 3 m. Bolt: one mark. Slab 200 × 100 pt = 2 m², its opening 50 × 50 pt = 0.25 m².
    /// Footing 100 × 100 pt = 1 m² at 0.3 m deep = 0.3 m³, then 0.5 m deep = 0.5 m³.
    private struct RoundFixture {
        let environment: AppCoreEnvironment
        let database: ProjectDatabaseActor
        let directory: URL
        let round: ReviewRound
    }

    private func runRound(storingTotals: Bool) async throws -> (RoundFixture, ReviewRoundDiff) {
        let (environment, database, directory) = try await SharedReviewSyncTests.machine()
        let documentID = SharedReviewSyncTests.documentID
        let page = SharedReviewSyncTests.pageID
        let wall = Self.record(documentID, page, tool: .area, subject: "Wall A",
                               geometry: Self.box(page, x: 0, y: 0, width: 100, height: 50))
        let bolt = Self.record(documentID, page, kind: .count, tool: .count, subject: "Bolt",
                               geometry: MeasurementGeometry(pageID: page, countPoints: [
                                   CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 600, y: 600))
                               ]))
        let slab = Self.record(documentID, page, tool: .area, subject: "Slab",
                               geometry: Self.box(page, x: 0, y: 200, width: 200, height: 100))
        var footing = Self.record(documentID, page, tool: .volume, subject: "Footing",
                                  geometry: Self.box(page, x: 300, y: 0, width: 100, height: 100))
        footing.parameters = Self.depth("0.3")
        for record in [wall, bolt, slab, footing] { try await environment.commands.perform(.addMarkup(record)) }
        await environment.history.settle()
        if !storingTotals {
            // A round closed by a build that did not store the ledger's totals.
            environment.review.ledgerTotalsProvider = nil
        }
        environment.review.closeRound(named: "Issued")
        await environment.review.settle()
        let round = try #require(environment.review.rounds.first)

        try await environment.commands.perform(.editSubject(id: wall.id, subject: "Wall B"))
        try await environment.commands.perform(.editCustomValue(
            id: bolt.id, column: RepetitionColumn.columnID, value: RepetitionColumn.cellValue(count: 3)
        ))
        let opening = Self.record(documentID, page, kind: .polygon, tool: .polygonCutout, subject: "Opening",
                                  geometry: Self.box(page, x: 20, y: 220, width: 50, height: 50))
        try await environment.commands.perform(.addCutout(parent: slab.id, cutout: opening))
        try await environment.commands.perform(.editParameters(id: footing.id, parameters: Self.depth("0.5")))
        await environment.history.settle()
        let fixture = RoundFixture(environment: environment, database: database, directory: directory, round: round)
        return (fixture, environment.review.changes(since: round))
    }

    private static func delta(_ diff: ReviewRoundDiff, _ subject: String, _ field: String) -> Decimal? {
        diff.quantityDeltas.first { $0.subject == subject && $0.field == field }?.delta
    }

    @Test("W-027: a round's quantity deltas are the ledger's — a rename, Repeat ×, a cutout, a depth")
    func roundDeltasAreTheLedgers() async throws {
        let (fixture, diff) = try await runRound(storingTotals: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Old output: no Wall line at all — the whole delta went under "Wall B", 0.5 − 0.5 = 0.
        #expect(Self.delta(diff, "Wall A", "Plan Area") == Decimal(string: "-0.5"))
        #expect(Self.delta(diff, "Wall B", "Plan Area") == Decimal(string: "0.5"))
        #expect(Self.delta(diff, "Wall A", "Perimeter") == -3)
        #expect(Self.delta(diff, "Wall B", "Perimeter") == 3)
        // Old output: no Bolt line — Repeat × is a column value the History does not record. 3 − 1 = +2.
        #expect(Self.delta(diff, "Bolt", "Count") == 2)
        // The slab's Plan Area loses the opening: 2 − 0.25 = 1.75, −0.25. Old output also booked the
        // cutout's own measured values under "Opening" (Plan Area +0.25 m², Perimeter +2 m).
        #expect(Self.delta(diff, "Slab", "Plan Area") == Decimal(string: "-0.25"))
        #expect(!diff.quantityDeltas.contains { $0.subject == "Opening" })
        // 0.5 − 0.3 = +0.2 m³. Old output also summed the depth: "Footing Depth +0.2 m".
        #expect(Self.delta(diff, "Footing", "Volume") == Decimal(string: "0.2"))
        #expect(!diff.quantityDeltas.contains { $0.field == "Depth" })
        #expect(diff.added.count == 1 && diff.changed.count >= 4)
        try? await fixture.database.close()
    }

    @Test("W-027: a round closed without stored totals still splits a rename and skips cutouts and depth")
    func roundWithoutTotalsFoldsTheHistoryCorrectly() async throws {
        let (fixture, diff) = try await runRound(storingTotals: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // The History records the rename on its row: −0.5 m² leaves Wall A, +0.5 m² joins Wall B.
        #expect(Self.delta(diff, "Wall A", "Plan Area") == Decimal(string: "-0.5"))
        #expect(Self.delta(diff, "Wall B", "Plan Area") == Decimal(string: "0.5"))
        #expect(!diff.quantityDeltas.contains { $0.subject == "Opening" })
        #expect(Self.delta(diff, "Footing", "Volume") == Decimal(string: "0.2"))
        #expect(!diff.quantityDeltas.contains { $0.field == "Depth" })
        try? await fixture.database.close()
    }

    /// 1 pt = 1 cm. 300 rooms of 25 × 25 pt = 0.25 m × 0.25 m = 0.0625 m², perimeter 1 m, on a 50 pt
    /// grid so none overlaps, each under its own ~210-character subject: the ledger's totals alone
    /// pass the 64 KiB a review entry may carry. The slab, 100 × 50 pt, is 0.5 m² and 3 m.
    @Test("W-027: a round over a ledger too large to store its totals is saved, survives a reload and still compares")
    func roundOverALargeLedgerIsSaved() async throws {
        let (environment, database, directory) = try await SharedReviewSyncTests.machine()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentID = SharedReviewSyncTests.documentID
        let page = SharedReviewSyncTests.pageID
        let padding = String(repeating: "x", count: 200)
        let rooms = (0..<300).map { index in
            Self.record(documentID, page, tool: .area, subject: String(format: "Room %03d ", index) + padding,
                        geometry: Self.box(page, x: Double(index % 20) * 50, y: Double(index / 20) * 50, width: 25, height: 25))
        }
        try await environment.commands.performBatch(rooms.map { .addMarkup($0) }, actionName: "Add Rooms")
        await environment.refresh()
        await environment.history.settle()
        // The precondition: the totals the old code stored are over the cap on their own.
        let totals = try #require(environment.review.ledgerTotalsProvider?())
        #expect(totals.bySubject.count == 300)
        #expect(try JSONEncoder().encode(totals.encoded).count > ReviewEntryStore.maximumBodyBytes)

        environment.review.closeRound(named: "Issued")
        await environment.review.settle()

        // Reload the entries from the file. Old output: the upsert threw "review entry body over
        // 65536 bytes", the write queue swallowed it, and the reloaded list had no round at all.
        let projectID = documentID.rawValue.uuidString
        environment.review.attach(database: database, projectID: projectID)
        await environment.review.settle()
        let round = try #require(environment.review.rounds.first)
        #expect(round.name == "Issued")
        let stored = try await database.read { db in
            try ReviewEntryStore.entries(project: projectID, in: db)
        }.filter { $0.kind == "round" }
        #expect(stored.count == 1)
        let row = try #require(stored.first)
        #expect(row.body.utf8.count <= ReviewEntryStore.maximumBodyBytes)
        // The totals did not fit, so the round compares by the History, as a pre-W-027 round does.
        #expect(try #require(AppReviewPresenter.roundBody(of: row)).ledgerTotals == nil)

        // Room 000 renamed and a slab added: the History fold books both.
        try await environment.commands.perform(.editSubject(id: rooms[0].id, subject: "Lobby"))
        let slab = Self.record(documentID, page, tool: .area, subject: "Slab",
                               geometry: Self.box(page, x: 0, y: 800, width: 100, height: 50))
        try await environment.commands.perform(.addMarkup(slab))
        await environment.history.settle()
        let diff = environment.review.changes(since: round)
        #expect(Self.delta(diff, rooms[0].subject, "Plan Area") == Decimal(string: "-0.0625"))
        #expect(Self.delta(diff, "Lobby", "Plan Area") == Decimal(string: "0.0625"))
        #expect(Self.delta(diff, "Lobby", "Perimeter") == 1)
        #expect(Self.delta(diff, "Slab", "Plan Area") == Decimal(string: "0.5"))
        #expect(Self.delta(diff, "Slab", "Perimeter") == 3)
        #expect(diff.added == [slab.id.rawValue] && diff.removed.isEmpty && diff.changed.contains(rooms[0].id.rawValue))

        // A small ledger still stores its totals (the two W-027 tests above compare by them).
        let small = ReviewRoundTotals(encoded: ["Slab": ["netArea": "0.5"]])
        let text = try #require(AppReviewPresenter.roundBodyText(name: "Small", historySequence: 3, ledgerTotals: small))
        #expect(try JSONDecoder().decode(AppReviewPresenter.RoundBody.self, from: Data(text.utf8)).ledgerTotals == ["Slab": ["netArea": "0.5"]])
        // A name the row cannot hold is refused, never shown and then lost.
        let long = String(repeating: "n", count: ReviewEntryStore.maximumBodyBytes)
        #expect(AppReviewPresenter.roundBodyText(name: long, historySequence: 3, ledgerTotals: nil) == nil)
        try? await database.close()
    }

    // MARK: W-028

    @Test("W-028: a day-only preset default or retype is the typed day where the ledger shows and filters it")
    func dayOnlyDatesAreLocalDays() throws {
        let due = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.due", title: "Due", kind: .date)
        for identifier in ["America/Bogota", "Europe/Stockholm", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let zone = try #require(TimeZone(identifier: identifier))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parsed = try #require(LedgerColumnValueConversion.date(fromText: "2026-09-27", timeZone: zone))
            // Old output: 2026-09-27T00:00Z — in Bogotá 26 Sep 19:00, shown "Sep 26, 2026", and the
            // equality filter for 27 Sep (local midnight to midnight) did not match it.
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
            #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 9, 27, 0, 0], "\(identifier)")
            #expect(calendar.startOfDay(for: parsed) == parsed, "\(identifier)")
            let shown = parsed.formatted(Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"), timeZone: zone
            ))
            #expect(shown == "Sep 27, 2026", "\(identifier)")
            // Retyped to text: the same day. Old output east of GMT: "2026-09-26" for the local midnight.
            #expect(LedgerColumnValueConversion.text(of: .date(parsed), in: due, timeZone: zone) == "2026-09-27", "\(identifier)")
        }
        // The preset path, in the zone this process runs in. Old output on a machine east of GMT
        // (this one, CEST): 02:00 local, not the start of the day.
        guard case .date(let typed)? = AppCoreEnvironment.typedDefault("2026-09-27", for: due, currencyCode: "EUR") else {
            Issue.record("a date default was not read as a date")
            return
        }
        #expect(Calendar.current.startOfDay(for: typed) == typed)
        #expect(Calendar.current.dateComponents([.year, .month, .day], from: typed) == DateComponents(year: 2026, month: 9, day: 27))
    }

    // MARK: W-029

    /// What `LedgerTableController` does with a presenter's columns: the default order first
    /// (`LedgerDefaultColumns.arranged`), then whatever it is given.
    @MainActor
    final class TableStandIn {
        var columns: [LedgerColumn]
        init(columns: [LedgerColumn]) { self.columns = columns }
    }

    @Test("W-029: a job template is captured from the table and applied to it, and a refresh keeps it")
    func jobTemplateColumnsGoThroughTheTable() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID, index: 0, label: "A-101")
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let ledger = environment.ledger
        let table = TableStandIn(columns: LedgerDefaultColumns.arranged(ledger.columns))
        ledger.tableArrangement = LedgerTableArrangement(read: { table.columns }, apply: { table.columns = $0 })

        // Old output: the column definitions — every built-in in definition order with its
        // definition's visibility, and no Value or Unit column, which only the table has.
        let captured = JobTemplateApplier.capture(
            name: "Shown", toolLibrary: environment.toolLibrary, ledger: ledger, units: .metric
        )
        #expect(captured.columnPreferences.map(\.columnID) == table.columns.map(\.id.rawValue))
        #expect(captured.columnPreferences.map(\.visible) == table.columns.map(\.visible))
        #expect(captured.columnPreferences.contains { $0.columnID == LedgerDefaultColumns.valueColumnID.rawValue })
        #expect(table.columns.first { $0.id == .planArea }?.visible == false, "an extra starts hidden in the table")

        let definitions = ledger.columns
        var template = JobTemplate(name: "Rearranged")
        template.columnPreferences = [
            JobTemplateColumnPreference(columnID: LedgerColumnID.planArea.rawValue, visible: true),
            JobTemplateColumnPreference(columnID: LedgerColumnID.subject.rawValue, visible: false),
            JobTemplateColumnPreference(columnID: "custom.notInThisProject", visible: true)
        ]
        let receipt = JobTemplateApplier.apply(template, toolLibrary: environment.toolLibrary, ledger: ledger)
        // `ZenitPDFProjectDocument.applyJobTemplate` refreshes straight after the apply.
        await environment.refresh()

        // Old output: the table unchanged — Plan Area hidden, Subject shown — because the template
        // went to the presenter's columns, which the refresh reset from the projection.
        #expect(table.columns[0].id == .planArea && table.columns[0].visible)
        #expect(table.columns[1].id == .subject && !table.columns[1].visible)
        #expect(table.columns.count == LedgerDefaultColumns.arranged(definitions).count, "arranged, never added or removed")
        #expect(receipt.appliedColumnIDs == [LedgerColumnID.planArea.rawValue, LedgerColumnID.subject.rawValue])
        #expect(receipt.unknownColumnIDs == ["custom.notInThisProject"])
        #expect(ledger.columns == definitions, "the definitions are not the arrangement")
    }

    // MARK: W-030

    @Test("W-030: drawing with a markup preset writes its label, status and ledger values, as Place does")
    func markupPresetDrawCarriesRowDefaults() async throws {
        let documentID = DocumentID(UUID())
        let sheet = Self.page(documentID, index: 0, label: "A-101")
        let session = try TakeoffSession(documentID: documentID, pages: [sheet])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let costCode = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.costCode", title: "Cost code", kind: .text)
        try await session.addCustomColumns([costCode])
        await environment.refresh()

        let revision = ToolPresetSummary(
            id: UUID(), name: "Revision box", category: "Test", panel: .myTools, markupKind: .rectangle,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.1, blue: 0.1), defaultSubject: "Revisions",
            labelPattern: "Rev C", defaultStatus: .open, customDefaults: ["custom.costCode": "1234"]
        )
        let kerb = ToolPresetSummary(
            id: UUID(), name: "Kerb", category: "Test", panel: .myTools, markupKind: .measurement,
            measurementKind: .length, colorRGBA: ColorRGBA(red: 0.2, green: 0.6, blue: 0.9), defaultSubject: "Kerb"
        )
        environment.toolLibrary.setPresets([revision, kerb])
        environment.toolLibrary.activatePreset(id: revision.id)
        var committed: [ZPDFContracts.MarkupRecord] = []
        environment.markup.onCommit = { committed.append($0) }
        environment.markup.setPage(sheet.id)
        environment.markup.placePoint(PDFPointValue(x: 10, y: 10))
        environment.markup.placePoint(PDFPointValue(x: 60, y: 40))
        environment.markup.commit()

        // Old output: subject "Revisions", label "", status .none, customValues [:].
        let drawn = try #require(committed.first)
        #expect(drawn.subject == "Revisions")
        #expect(drawn.label == "Rev C")
        #expect(drawn.status == .open)
        #expect(drawn.customValues[costCode.id] == .text("1234"))

        // The same preset placed makes the same row.
        let receipt = await environment.placePreset(revision, at: PDFPointValue(x: 300, y: 300), pageID: sheet.id.rawValue)
        let placedID = try #require(receipt.markupID)
        let placed = try #require(await session.markup(MarkupID(placedID)))
        #expect(placed.label == drawn.label && placed.status == drawn.status && placed.customValues == drawn.customValues)

        // Disarming clears all four, and so does arming a measurement preset after it.
        environment.toolLibrary.clearActivePreset()
        #expect(environment.markup.defaultSubject.isEmpty && environment.markup.defaultLabel.isEmpty)
        #expect(environment.markup.defaultStatus == .none && environment.markup.defaultCustomValues.isEmpty)
        environment.toolLibrary.activatePreset(id: revision.id)
        #expect(environment.markup.defaultLabel == "Rev C")
        environment.toolLibrary.activatePreset(id: kerb.id)
        #expect(environment.markup.defaultSubject.isEmpty && environment.markup.defaultLabel.isEmpty)
        #expect(environment.markup.defaultStatus == .none && environment.markup.defaultCustomValues.isEmpty)
    }

    // MARK: W-032

    @Test("W-032: a preset default and a column retype read a number with the ledger cell's grammar")
    func oneNumberGrammar() {
        let cases: [(String, Decimal?)] = [
            ("1 250", 1_250),                                  // old output: nil — a space was not grouping
            ("1\u{00A0}250,5", Decimal(string: "1250.5")),     // old output: nil
            ("\u{2212}12,50", Decimal(string: "-12.5")),       // old output: nil — U+2212 was not a minus
            ("1e3", nil),                                      // old output: 1000 — the cell refuses it
            ("12,5", Decimal(string: "12.5")),
            (" -3 ", -3),
            ("1,234.5", nil),
            ("12-5", nil),
            ("40", 40)
        ]
        for (text, expected) in cases {
            #expect(LedgerColumnValueConversion.decimal(fromText: text) == expected, "\(text)")
            // The grammar `ZPDFDecimalParser` — what a ledger cell reads with — forwards to.
            #expect(TypedDecimalGrammar.decimal(text) == expected, "\(text)")
        }
        let pieces = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.pieces", title: "Pieces", kind: .number, dimension: .ratio)
        #expect(AppCoreEnvironment.typedDefault("1 250", for: pieces, currencyCode: "EUR") == .number(1_250))
        #expect(AppCoreEnvironment.typedDefault("1e3", for: pieces, currencyCode: "EUR") == nil)
        let note = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.note", title: "Note", kind: .text)
        let number = LedgerColumnDefinition(id: note.id, key: "custom.note", title: "Note", kind: .number)
        #expect(LedgerColumnValueConversion.convert(.text("\u{2212}12,50"), from: note, to: number) == .number(.count(Decimal(string: "-12.5")!)))
        #expect(LedgerColumnValueConversion.convert(.text("1e3"), from: note, to: number) == nil)
    }

    // MARK: W-038

    @Test("W-038: a committed move and a paste are the drag preview's translation, field for field")
    func moveAndPasteUseThePreviewTranslation() async throws {
        let (session, page) = try await Iter3AppCoreMiscTests.session()
        let group = CountGroupID(UUID())
        let count = Iter3AppCoreMiscTests.record(page: page, tool: .count, geometry: MeasurementGeometry(pageID: page, countPoints: [
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 10, y: 10), sequenceNumber: 1, groupID: group, symbolID: SymbolID(UUID())),
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 30, y: 15), sequenceNumber: 2, groupID: group, symbolID: SymbolID(UUID()))
        ]))
        let area = Iter3AppCoreMiscTests.record(page: page, tool: .area, geometry: MeasurementGeometry(pageID: page, polygons: [
            PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 160, y: 100), PDFPoint(x: 160, y: 140), PDFPoint(x: 100, y: 140)
            ], isClosed: true, bulges: [0, 0.25, 0, 0]))
        ]))
        for record in [count, area] { _ = try await session.apply(.addMarkup(record)) }
        for id in [count.id, area.id] {
            let before = try #require(await session.markup(id)?.geometry)
            _ = try await session.apply(.moveMarkup(id: id, dx: 12.5, dy: -4))
            let after = try #require(await session.markup(id)?.geometry)
            #expect(after == MarkupVertexEditing.translating(before, dx: 12.5, dy: -4))
        }

        // A paste offset: the marks land where the preview rule puts them, symbols and numbers kept.
        let source = try #require(await session.markup(count.id))
        let pasted = MarkupClipboard.prepared(
            MarkupClipboardPayload(sourceDocumentID: Iter3AppCoreMiscTests.documentID.rawValue, sourcePageID: page.rawValue, records: [source]),
            targetPageID: page.rawValue, targetDocumentID: Iter3AppCoreMiscTests.documentID.rawValue,
            dx: 7, dy: 3, now: Self.instant, author: "A. Berg", newID: { UUID() }
        )
        let expected = MarkupVertexEditing.translating(try #require(source.geometry), dx: 7, dy: 3)
        let geometry = try #require(pasted.first?.geometry)
        #expect(geometry.countPoints.map(\.position) == expected.countPoints.map(\.position))
        #expect(geometry.countPoints.map(\.symbolID) == expected.countPoints.map(\.symbolID))
        #expect(geometry.countPoints.map(\.sequenceNumber) == expected.countPoints.map(\.sequenceNumber))
    }
}
