import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFTestingSupport
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// Feature 11 — *measure once, applies to every storey* — built as a reserved custom column.
///
/// The invariant is the whole test plan: *the multiplier is on the row, in the
/// export, and in the audit entry — or a total is inflated with nothing on screen saying why.*
/// So what is asserted here is that the multiplier is **carried**, not that it is hidden:
/// a stable key nothing may quietly re-mint, a summary that surfaces it, and a save-and-reopen
/// that brings it back digit for digit through the ordinary `custom_values_json` path.
struct RepetitionColumnTests {

    // MARK: - Identity

    @Test("The repeat column's key and id are fixed, not generated")
    func columnIdentityIsStable() {
        // The literal is the point. If a refactor changes the derivation, this test fails and
        // somebody has to notice that every project saved before the change now carries a
        // `Repeat ×` column the new build reads as an unrelated user column.
        #expect(RepetitionColumn.key == "custom.zenit.repeat")
        #expect(RepetitionColumn.name == "zenit.repeat")
        #expect(RepetitionColumn.namespace == "zenit.pdf/ledger/reserved-column/v1")

        // Derived, therefore identical on every machine and in every process.
        let recomputed = ColumnID(
            LedgerIdentifiers.deterministicUUID(
                namespace: "zenit.pdf/ledger/reserved-column/v1",
                name: "zenit.repeat"
            )
        )
        #expect(RepetitionColumn.columnID == recomputed)
        #expect(RepetitionColumn.columnID == RepetitionColumn.columnID)

        // …and it is not one of the built-ins wearing a custom key.
        for standard in StandardLedgerColumn.allCases {
            #expect(LedgerIdentifiers.columnID(for: standard) != RepetitionColumn.columnID,
                    "the reserved repeat column collides with the built-in \(standard.rawValue)")
        }
    }

    @Test("The presentation column id follows the custom-column idiom and matches the key")
    func presentationIdentityMatchesTheKey() {
        #expect(RepetitionColumn.presentationID == LedgerColumnID.custom("zenit.repeat"))
        #expect(RepetitionColumn.presentationID.isCustom)
        // `LedgerBridge` builds a presentation id as `LedgerColumnID(definition.key)`. If these
        // two ever disagree the ledger draws a column the presenter cannot address.
        #expect(RepetitionColumn.presentationID
                == LedgerColumnID(RepetitionColumn.definition().key))
    }

    @Test("The column definition is an editable, dimensionless integer that never sums")
    func definitionIsAnIntegerColumn() {
        let definition = RepetitionColumn.definition()
        #expect(definition.id == RepetitionColumn.columnID)
        #expect(definition.key == RepetitionColumn.key)
        #expect(definition.title == "Repeat ×")
        #expect(definition.kind == .number)
        #expect(definition.standard == nil, "it is a reserved custom column, not a built-in")
        #expect(definition.dimension == .ratio)
        #expect(definition.precision == .decimalPlaces(0), "half a repetition is not a thing")
        #expect(definition.isEditable)

        // A column of repeat counts added together is a number that means nothing
        // (QUALITY_BAR A14), and the bridge is what refuses it.
        #expect(LedgerBridge.aggregate(for: definition) == nil)

        // The validator the contract runs over every column accepts it.
        #expect(throws: Never.self) { try definition.validate() }
    }

    // MARK: - Reading a record

    private static func record(customValues: [ColumnID: ZPDFContracts.LedgerCellValue]) -> ZPDFContracts.MarkupRecord {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(UUID()),
            pageID: PageID(UUID()),
            kind: .measurement,
            tool: .area,
            subject: "Screed",
            author: "Repetition",
            customValues: customValues,
            createdAt: now,
            modifiedAt: now
        )
    }

    @Test("Absent is nil, and nil counts as once")
    func absentReadsAsUnset() {
        let bare = Self.record(customValues: [:])
        #expect(RepetitionColumn.repeatCount(of: bare) == nil)
        #expect(RepetitionColumn.count(of: bare) == 1)
        #expect(!RepetitionColumn.isRepeated(bare))
    }

    @Test("A stored count reads back exactly")
    func storedCountReadsBack() {
        let six = Self.record(customValues: [
            RepetitionColumn.columnID: RepetitionColumn.cellValue(count: 6)
        ])
        #expect(RepetitionColumn.repeatCount(of: six) == 6)
        #expect(RepetitionColumn.count(of: six) == 6)
        #expect(RepetitionColumn.isRepeated(six))
    }

    @Test("A count that would erase or negate a quantity is refused, not honoured")
    func corruptCountsAreRefused() {
        for bad in [0, -3] {
            let record = Self.record(customValues: [
                RepetitionColumn.columnID: .number(
                    ZPDFContracts.DecimalQuantity(value: Decimal(bad), dimension: .ratio)
                )
            ])
            #expect(RepetitionColumn.repeatCount(of: record) == nil,
                    "a repeat of \(bad) is corrupt data, not an instruction")
            #expect(RepetitionColumn.count(of: record) == 1)
        }

        // A value of the wrong shape entirely — somebody's text in the repeat column.
        let text = Self.record(customValues: [RepetitionColumn.columnID: .text("six")])
        #expect(RepetitionColumn.repeatCount(of: text) == nil)

        // …and writing goes through a clamp, so nothing can store a zero in the first place.
        #expect(RepetitionColumn.cellValue(count: 0)
                == .number(ZPDFContracts.DecimalQuantity(value: 1, dimension: .ratio)))
    }

    @Test("A fractional count floors rather than inventing a storey")
    func fractionalCountFloors() {
        let record = Self.record(customValues: [
            RepetitionColumn.columnID: .number(
                ZPDFContracts.DecimalQuantity(
                    value: Decimal(string: "2.9", locale: nil)!,
                    dimension: .ratio
                )
            )
        ])
        #expect(RepetitionColumn.repeatCount(of: record) == 2)
    }

    // MARK: - Arithmetic

    @Test("Repeating a value is exact, and equals summing that many copies of it")
    func repeatedTotalIsExact() {
        let value = Decimal(string: "12.345", locale: nil)!
        #expect(RepetitionColumn.repeatedTotal(value: value, count: 6)
                == Decimal(string: "74.07", locale: nil)!)

        // Exactness is the property that lets a repeated row and a subtotal agree: six
        // repetitions must equal six additions, with no drift to round away at the boundary.
        var summed = Decimal(0)
        for _ in 0..<6 { summed += value }
        #expect(RepetitionColumn.repeatedTotal(value: value, count: 6) == summed)

        #expect(RepetitionColumn.repeatedTotal(value: value, count: 1) == value)
        #expect(RepetitionColumn.repeatedTotal(value: value, count: 0) == value,
                "a count below one is clamped, never allowed to shrink a quantity")
    }

    @Test("Repeating a quantity scales the magnitude and leaves the unit alone")
    func repeatedTotalKeepsTheDimension() {
        let area = ZPDFContracts.DecimalQuantity(value: 12, dimension: .area)
        let repeated = RepetitionColumn.repeatedTotal(value: area, count: 6)
        #expect(repeated.value == 72)
        #expect(repeated.dimension == .area, "six of a 12 m² floor is 72 m², not 72 m⁶")
    }

    @Test("The badge reads ×N, and says nothing at all for a markup that repeats once")
    func badgeIsSilentAtOne() {
        #expect(RepetitionColumn.badgeText(count: 6) == "×6")
        #expect(RepetitionColumn.badgeText(count: 1) == nil)
        #expect(RepetitionColumn.badgeText(count: 0) == nil)
    }

    // MARK: - The summary

    @Test("A markup with Repeat = 6 reaches the UI carrying 6; one without carries nil")
    func summaryCarriesTheRepeatCount() {
        let formatter = QuantityFormatter()
        let names = ProjectNameTable()

        let six = Self.record(customValues: [
            RepetitionColumn.columnID: RepetitionColumn.cellValue(count: 6)
        ])
        let summary = MarkupBridge.summary(of: six, names: names, formatter: formatter)
        #expect(summary.repeatCount == 6)
        #expect(summary.repetitionText == "×6")
        #expect(summary.accessibilityLabel.contains("repeats 6 times"),
                "a multiplier that only a sighted user can see is still invisible")

        let bare = MarkupBridge.summary(of: Self.record(customValues: [:]), names: names, formatter: formatter)
        #expect(bare.repeatCount == nil)
        #expect(bare.repetitionText == nil, "no badge on a markup nobody has repeated")
        #expect(!bare.accessibilityLabel.contains("repeats"))

        // Deliberately set to once is still no badge — one is not a multiplier.
        let once = Self.record(customValues: [
            RepetitionColumn.columnID: RepetitionColumn.cellValue(count: 1)
        ])
        let onceSummary = MarkupBridge.summary(of: once, names: names, formatter: formatter)
        #expect(onceSummary.repeatCount == 1)
        #expect(onceSummary.repetitionText == nil)
    }

    @Test("MarkupSummary's new field is additive: an existing construction still compiles and reads nil")
    func summaryFieldIsAdditive() {
        // Written with the exact argument list callers used before feature 11 existed. If
        // `repeatCount` had been anything but a defaulted trailing parameter, this would not
        // build — which is the assertion.
        let summary = MarkupSummary(
            id: UUID(),
            kind: .measurement,
            subject: "Screed",
            label: "Office 101",
            pageLabel: "A-101",
            pageID: UUID(),
            pageIndex: 0,
            author: "Repetition",
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: .zero
        )
        #expect(summary.repeatCount == nil)
        #expect(summary.repetitionText == nil)
    }

    // MARK: - Round trip

    @Test("Repeat = 6 set through the ordinary command survives save, quit and reopen")
    func repeatCountSurvivesTheArchive() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-repeat-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )

        let pageID = fixture.firstPage.id
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let markup = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Flat type A",
            label: "Storey 1",
            author: "Repetition",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100, y: 100),
                    PDFPoint(x: 400, y: 100),
                    PDFPoint(x: 400, y: 300),
                    PDFPoint(x: 100, y: 300)
                ], isClosed: true))]
            ),
            createdAt: now,
            modifiedAt: now
        )
        _ = try await session.apply(.addMarkup(markup))

        // No new command case: the repeat count is written by the same `.editCustomValue` a
        // bulk edit already produces, so it undoes, redoes and audits like any other cell.
        _ = try await session.apply(RepetitionColumn.edit(markupID: markup.id, count: 6))

        let live = try #require(await session.takeoffState().markups.first { $0.id == markup.id })
        #expect(RepetitionColumn.repeatCount(of: live) == 6,
                "the command did not land in customValues")
        #expect(live.customValues[RepetitionColumn.columnID]
                == .number(ZPDFContracts.DecimalQuantity(value: 6, dimension: .ratio)))

        // ── Save through the real package pipeline ──────────────────────────────────
        let stateBefore = await session.takeoffState()
        let packageURL = workspace.appendingPathComponent("Repeat.zpdfproj", isDirectory: true)
        let package = try await ProjectPackage.create(
            at: packageURL, displayName: "Repeat", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(stateBefore, into: package)
        _ = try await package.save()
        try await package.close()

        // ── Reopen, exactly as the application does ─────────────────────────────────
        guard case .opened(let reopened) = try await ProjectPackage.open(at: packageURL) else {
            Issue.record("reopen required recovery")
            return
        }
        let storedTakeoff = try #require(try await TakeoffArchive.read(from: reopened))
        let freshPages = fixture.pages.map { page in
            var fresh = page
            fresh.id = PageID(UUID())
            return fresh
        }
        let adopted = TakeoffArchive.adoptingStoredPageIDs(freshPages, stored: storedTakeoff)
        let restored = try TakeoffSession(
            documentID: DocumentID(UUID()),
            pages: adopted,
            units: .metric
        )
        try await restored.hydrate(
            markups: storedTakeoff.markups,
            scales: storedTakeoff.scales,
            pageScaleIDs: storedTakeoff.pageScaleIDs
        )

        let hydrated = try #require(await restored.takeoffState().markups.first { $0.id == markup.id })
        #expect(RepetitionColumn.repeatCount(of: hydrated) == 6,
                "the repeat count did not survive save and reopen")
        #expect(hydrated.customValues == live.customValues,
                "the repeat cell did not round-trip digit for digit")

        // And it is still visible on the far side: a multiplier that survives the file but not
        // the summary would be invisible again the moment the drawing was reopened.
        let summary = MarkupBridge.summary(
            of: hydrated,
            names: ProjectNameTable(),
            formatter: QuantityFormatter()
        )
        #expect(summary.repeatCount == 6)
        #expect(summary.repetitionText == "×6")

        try await reopened.close()
    }

    // MARK: - Totals

    @Test("Repeat = 6 multiplies the area cell and the grand total by exactly six")
    func repeatMultipliesTheLedgerTotals() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-repeat-totals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: workspace)
        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        _ = try await session.calibrate(
            page: try #require(await session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        let pageID = fixture.firstPage.id
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let markup = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()),
            documentID: fixture.documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Flat type A",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100, y: 100),
                    PDFPoint(x: 400, y: 100),
                    PDFPoint(x: 400, y: 300),
                    PDFPoint(x: 100, y: 300)
                ], isClosed: true))]
            ),
            createdAt: now,
            modifiedAt: now
        )
        _ = try await session.apply(.addMarkup(markup))

        let areaColumn: LedgerColumnID = .planArea
        let before = try await session.ledgerProjection(.flat)
        let single = try #require(before.grandTotals.total(areaColumn)?.value)
        #expect(single > 0, "the fixture markup must measure a real area")

        // The reserved column is part of every session's set — visible, editable, exportable.
        #expect(before.columns.contains { $0.id == RepetitionColumn.presentationID },
                "the Repeat × column is missing from the session's column set")

        _ = try await session.apply(RepetitionColumn.edit(markupID: markup.id, count: 6))
        let after = try await session.ledgerProjection(.flat)
        let repeated = try #require(after.grandTotals.total(areaColumn)?.value)
        #expect(repeated == single * Decimal(6),
                "repeat 6 must multiply the grand total by exactly six")

        // Undo is the ordinary cell-edit undo: back to once, back to the single total.
        _ = try await session.apply(RepetitionColumn.edit(markupID: markup.id, count: 1))
        let reverted = try await session.ledgerProjection(.flat)
        #expect(try #require(reverted.grandTotals.total(areaColumn)?.value) == single)
    }
}
