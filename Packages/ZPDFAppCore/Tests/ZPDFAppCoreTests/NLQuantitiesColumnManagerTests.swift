import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-QTY-02 (Column Manager) and NL-QTY-03 (formula columns on the one engine), driven
/// through the shipping presenter seam and command bus. Expected values are hand-derived:
/// 40 × 30 pt at 0.1 m/pt = 12 m²; 20 × 10 pt = 2 m².
@Suite("Quantities — Column Manager and formula columns")
@MainActor
struct NLQuantitiesColumnManagerTests {

    let bugs = NLQuantitiesBugTests()

    func manager(_ fixture: NLQuantitiesBugTests.Fixture) throws -> any LedgerColumnManaging {
        try #require(fixture.environment.ledger as? any LedgerColumnManaging)
    }

    static func option(_ value: String, _ color: ColorRGBA, order: Int) -> LedgerChoiceOption {
        LedgerChoiceOption(id: UUID(), value: value, title: value, colorRGBA: color, order: order)
    }

    // MARK: NL-QTY-02

    @Test("Add a Choice and an m² Number column, save, reopen, rename one, delete the other — each one ⌘Z")
    func columnManagerAcceptance() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let columns = try manager(fixture)
        #expect(columns.userColumnSpecs.isEmpty)

        let grade = LedgerColumnSpec(
            id: .custom(UUID().uuidString), title: "Grade", kind: .choice,
            choices: [
                Self.option("A", ColorRGBA.Zenit.Dark.green, order: 0),
                Self.option("B", ColorRGBA.Zenit.Dark.warning, order: 1),
                Self.option("C", ColorRGBA.Zenit.Dark.danger, order: 2)
            ]
        )
        var receipt = await columns.applyColumnSpecs([grade], actionName: "Add Column")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let screed = LedgerColumnSpec(id: .custom(UUID().uuidString), title: "Screed", kind: .number, dimension: .area)
        receipt = await columns.applyColumnSpecs([grade, screed], actionName: "Add Column")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(columns.userColumnSpecs.map(\.title) == ["Grade", "Screed"])
        #expect(columns.userColumnSpecs[0].choices.map(\.value) == ["A", "B", "C"])
        #expect(columns.userColumnSpecs[1].dimension == .area)
        let presented = try #require(fixture.environment.ledger.columns.first { $0.id == screed.id })
        #expect(presented.isUserDefined && presented.holdsUserValues)

        // Each add was one step: one ⌘Z takes Screed away and leaves Grade.
        await fixture.environment.commands.undo()
        await fixture.environment.ledger.refresh()
        #expect(columns.userColumnSpecs.map(\.title) == ["Grade"])
        await fixture.environment.commands.redo()
        await fixture.environment.ledger.refresh()
        #expect(columns.userColumnSpecs.map(\.title) == ["Grade", "Screed"])

        // Save and reopen: the definitions come back, colours and dimension included.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-colman-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Columns.zpdfproj", isDirectory: true),
            displayName: "Columns", originalPDF: pdf.url
        )
        defer { Task { try? await package.close() } }
        try await TakeoffArchive.write(await fixture.session.takeoffState(), into: package)
        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.customColumns.map(\.title) == ["Grade", "Screed"])
        #expect(stored.customColumns[0].choices.map { $0.color != nil } == [true, true, true])
        #expect(stored.customColumns[1].dimension == .area)
        let reopened = try TakeoffSession(documentID: pdf.documentID, pages: pdf.pages)
        #expect(await reopened.restoreCustomColumns(stored.customColumns).count == 2)

        // Rename Grade (its key and values stay), then delete Screed; each is one ⌘Z.
        var renamed = columns.userColumnSpecs
        renamed[0].title = "Quality grade"
        receipt = await columns.applyColumnSpecs(renamed, actionName: "Edit Column")
        #expect(!receipt.didFail)
        #expect(columns.userColumnSpecs[0].id == grade.id)
        receipt = await columns.applyColumnSpecs([columns.userColumnSpecs[0]], actionName: "Delete Column")
        #expect(!receipt.didFail)
        #expect(columns.userColumnSpecs.map(\.title) == ["Quality grade"])

        await fixture.environment.commands.undo()
        await fixture.environment.ledger.refresh()
        #expect(columns.userColumnSpecs.map(\.title) == ["Quality grade", "Screed"])
        await fixture.environment.commands.undo()
        await fixture.environment.ledger.refresh()
        #expect(columns.userColumnSpecs.map(\.title) == ["Grade", "Screed"])
    }

    @Test("A column a formula reads refuses deletion, naming the formula")
    func deletionReadByFormulaIsRefused() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let columns = try manager(fixture)
        let rate = LedgerColumnSpec(
            id: .custom(UUID().uuidString), title: "Rate", kind: .currency,
            dimension: .init(lengthPower: -2, currencyCode: "SEK")
        )
        let cost = LedgerColumnSpec(
            id: .custom(UUID().uuidString), title: "Board cost", kind: .formula, formulaSource: "Area * [Rate]"
        )
        var receipt = await columns.applyColumnSpecs([rate, cost], actionName: "Add Column")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        receipt = await columns.applyColumnSpecs([cost], actionName: "Delete Column")
        #expect(receipt.didFail)
        #expect(receipt.failureDescription?.contains("Board cost") == true, "\(receipt.failureDescription ?? "")")
        #expect(columns.userColumnSpecs.count == 2, "nothing changed")
    }

    @Test("A retype converts stored values in the same step, or refuses with a count")
    func retypeConvertsOrRefuses() async throws {
        let fixture = try await bugs.makeFixture()
        let columns = try manager(fixture)
        let key = LedgerColumnID.custom(UUID().uuidString)
        var receipt = await columns.applyColumnSpecs(
            [LedgerColumnSpec(id: key, title: "Boards", kind: .text)], actionName: "Add Column"
        )
        #expect(!receipt.didFail)
        let column = try #require(await fixture.session.ledgerColumns.column(key: key.rawValue))
        for (id, text) in zip(fixture.ids, ["12", "3,5", "about ten"]) {
            try await fixture.environment.commands.perform(.editCustomValue(id: id, column: column.id, value: .text(text)))
        }
        var number = columns.userColumnSpecs
        number[0].kind = .number
        number[0].dimension = .count
        receipt = await columns.applyColumnSpecs(number, actionName: "Edit Column")
        // "about ten" is not a number: refused whole, with the count, nothing converted.
        #expect(receipt.didFail)
        #expect(receipt.failureDescription?.contains("1") == true)
        #expect(try #require(await fixture.session.markup(fixture.ids[0])).customValues[column.id] == .text("12"))

        try await fixture.environment.commands.perform(.editCustomValue(id: fixture.ids[2], column: column.id, value: .text("10")))
        receipt = await columns.applyColumnSpecs(number, actionName: "Edit Column")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(try #require(await fixture.session.markup(fixture.ids[1])).customValues[column.id]
            == .number(.count(Decimal(string: "3.5")!)))
        // 12 + 3.5 + 10 = 25.5, now a total on screen.
        await fixture.environment.ledger.refresh()
        #expect(fixture.environment.ledger.grandTotals.quantities[key]?.value == Decimal(string: "25.5")!)

        // One ⌘Z restores the text column and every text value together.
        await fixture.environment.commands.undo()
        #expect(try #require(await fixture.session.markup(fixture.ids[1])).customValues[column.id] == .text("3,5"))
        #expect(await fixture.session.ledgerColumns.column(key: key.rawValue)?.kind == .text)
    }

    @Test("An empty or duplicate name and an option-less choice are refused with a reason")
    func invalidSpecsAreRefused() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let columns = try manager(fixture)
        let blank = await columns.applyColumnSpecs(
            [LedgerColumnSpec(id: .custom("a"), title: "  ", kind: .text)], actionName: "Add Column"
        )
        #expect(blank.didFail)
        let duplicate = await columns.applyColumnSpecs([
            LedgerColumnSpec(id: .custom("a"), title: "Note", kind: .text),
            LedgerColumnSpec(id: .custom("b"), title: "note", kind: .text)
        ], actionName: "Add Column")
        #expect(duplicate.failureDescription?.contains("note") == true || duplicate.failureDescription?.contains("Note") == true)
        let noOptions = await columns.applyColumnSpecs(
            [LedgerColumnSpec(id: .custom("c"), title: "Grade", kind: .choice)], actionName: "Add Column"
        )
        #expect(noOptions.didFail)
        #expect(columns.userColumnSpecs.isEmpty)
    }

    // MARK: NL-QTY-03

    @Test("=Area * UnitCost shows SEK per row and a SEK total, equal to Total Cost to the digit")
    func formulaColumnOnTheOneEngine() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30), (20, 10)])
        let columns = try manager(fixture)
        let key = LedgerColumnID.custom(UUID().uuidString)
        let receipt = await columns.applyColumnSpecs(
            [LedgerColumnSpec(id: key, title: "Cost", kind: .formula, formulaSource: "Area * UnitCost")],
            actionName: "Add Column"
        )
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        _ = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: Set(fixture.ids.map(\.rawValue)),
            values: [.unitCost: .currency(amount: 450, code: "SEK")]
        ))
        await fixture.environment.ledger.refresh()
        let ledger = fixture.environment.ledger

        // Row values: 12 × 450 = 5 400 SEK and 2 × 450 = 900 SEK, the unit cost read as a rate
        // per m² (ADR-0020), and exactly what Total Cost shows on the same rows.
        for index in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: index))
            guard case .quantity(let cost) = row.value(key) else {
                Issue.record("formula cell is \(row.value(key)), display \(row.displayValue(key))")
                continue
            }
            #expect(cost.dimension.currencyCode == "SEK")
            #expect(cost.dimension.lengthPower == 0)
            guard case .currency(let total, _) = row.value(.totalCost) else {
                Issue.record("Total Cost missing")
                continue
            }
            #expect(cost.value == total)
        }
        // The column total: 5 400 + 900 = 6 300 SEK, the same as the Total Cost total.
        #expect(ledger.grandTotals.quantities[key]?.value == 6_300)
        #expect(ledger.grandTotals.quantities[key]?.dimension.currencyCode == "SEK")
        #expect(ledger.grandTotals.quantities[.totalCost]?.value == 6_300)
    }

    @Test("=Area + Length is refused at definition time naming both dimensions; a cycle names the cycle")
    func formulaRefusals() async throws {
        let fixture = try await bugs.makeFixture(sizes: [(40, 30)])
        let columns = try manager(fixture)
        let mixed = await columns.applyColumnSpecs(
            [LedgerColumnSpec(id: .custom("m"), title: "Mixed", kind: .formula, formulaSource: "Area + Length")],
            actionName: "Add Column"
        )
        let reason = try #require(mixed.failureDescription).lowercased()
        #expect(reason.contains("area"), "\(reason)")
        #expect(reason.contains("length"), "\(reason)")
        #expect(columns.checkFormula("Area + Length", forColumn: nil, specs: []) != nil)
        #expect(columns.checkFormula("Area * 2", forColumn: nil, specs: []) == nil)

        let cycle = await columns.applyColumnSpecs([
            LedgerColumnSpec(id: .custom("p"), title: "Ping", kind: .formula, formulaSource: "[Pong] + Area"),
            LedgerColumnSpec(id: .custom("q"), title: "Pong", kind: .formula, formulaSource: "[Ping] + Area")
        ], actionName: "Add Column")
        let cycleReason = try #require(cycle.failureDescription)
        #expect(cycleReason.contains("Ping") && cycleReason.contains("Pong"), "\(cycleReason)")
        #expect(columns.userColumnSpecs.isEmpty)
    }

    // MARK: NL-QTY-06

    @Test("97.3 m² with 10 % waste and a 2.88 m² board: net 97.3, gross 107.03, order 38")
    func wasteAndOrder() async throws {
        // 97.3 × 100 pt at 0.1 m/pt = 9.73 m × 10 m = 97.3 m².
        let fixture = try await bugs.makeFixture(sizes: [(97.3, 100)])
        let columns = try manager(fixture)
        let waste = LedgerColumnID.custom(UUID().uuidString)
        let pack = LedgerColumnID.custom(UUID().uuidString)
        let gross = LedgerColumnID.custom(UUID().uuidString)
        let order = LedgerColumnID.custom(UUID().uuidString)
        // The same four specs the Column Manager's "Waste and Order by Area" adds (ADR-0039:
        // Pack size never sums, Order is a count; the totals are Iter4LedgerWasteAndOrderTotalsTests').
        let receipt = await columns.applyColumnSpecs([
            LedgerColumnSpec(id: waste, title: "Waste", kind: .number, dimension: .ratio, decimalPlaces: 2),
            LedgerColumnSpec(id: pack, title: "Pack size", kind: .number, dimension: .area, neverSums: true),
            LedgerColumnSpec(id: gross, title: "Gross", kind: .formula, formulaSource: "Area * (1 + COALESCE([Waste], 0))"),
            LedgerColumnSpec(id: order, title: "Order", kind: .formula, decimalPlaces: 0, formulaSource: "CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)")
        ], actionName: "Add Waste and Order Columns")
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let editor = try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
        let edit = await editor.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue],
            values: [waste: .number(Decimal(string: "0.10")!), pack: .quantity(DecimalQuantity(value: Decimal(string: "2.88")!, dimension: .area))]
        ))
        #expect(!edit.didFail, "\(edit.failureDescription ?? "")")
        await fixture.environment.ledger.refresh()
        let row = try #require(fixture.environment.ledger.row(at: 0))
        // Net stays 97.3 m² — never overwritten.
        #expect(row.quantity(.planArea)?.value == Decimal(string: "97.3")!)
        // Gross: 97.3 × 1.10 = 107.03 m², exact.
        guard case .quantity(let grossValue) = row.value(gross) else {
            Issue.record("gross is \(row.value(gross)) / \(row.displayValue(gross))"); return
        }
        #expect(grossValue.value == Decimal(string: "107.03")!)
        #expect(grossValue.dimension == .area)
        // Order: 107.03 / 2.88 = 37.16… boards, rounded up to 38.
        let orderValue: Decimal? = {
            switch row.value(order) {
            case .number(let value): return value
            case .quantity(let quantity): return quantity.value
            default: return nil
            }
        }()
        #expect(orderValue == 38, "order is \(row.value(order)) / \(row.displayValue(order))")
    }
}
