import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-QTY-05: the rate library. Hand-derived: 10 × 10 pt at 0.1 m/pt is 1 m², so a row priced
/// at 89.50 SEK/m² totals 89.50 SEK, and a rate change to 95 moves each row by 5.50 SEK.
@Suite("Quantities — rate library")
@MainActor
struct NLQuantitiesRateLibraryTests {

    let bugs = NLQuantitiesBugTests()

    func temporaryStore() throws -> (RateLibraryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-rates-\(UUID().uuidString)", isDirectory: true)
        return (RateLibraryStore(directory: directory), directory)
    }

    @Test("A pasted Swedish list reads decimal commas, percentages and units; a bad line is named, not guessed")
    func parsesSupplierLists() {
        let swedish = """
        Namn\tEnhet\tÀ-pris\tValuta\tSpill\tFörpackning\tKontokod\tYrke
        Gipsskiva 13 mm\tm²\t89,50\tSEK\t10 %\t2,88\t15.S\tBygg
        Reglar 45x70\tm\t18,20\tSEK\t0,05\t\t15.R\tBygg
        Trasig rad\tkg\t12\tSEK\t\t\t\t
        """
        let (entries, rejected) = RateLibraryCSV.parse(swedish, defaultCurrency: "SEK")
        #expect(entries.count == 2)
        #expect(entries[0].basis == .area)
        #expect(entries[0].rate == Decimal(string: "89.50")!)
        #expect(entries[0].waste == Decimal(string: "0.10")!)
        #expect(entries[0].packSize == Decimal(string: "2.88")!)
        #expect(entries[0].costCode == "15.S")
        #expect(entries[1].basis == .length)
        #expect(entries[1].waste == Decimal(string: "0.05")!)
        #expect(rejected.map(\.line) == [4], "the kg line is named by its number")

        let english = "Name,Unit,Rate\nPaint,m2,45.5\nNo rate,m2,abc"
        let parsed = RateLibraryCSV.parse(english, defaultCurrency: "EUR")
        #expect(parsed.entries.map(\.currencyCode) == ["EUR"])
        #expect(parsed.rejected.map(\.line) == [3])
    }

    @Test("Import 200 items; price 40 areas with one entry in one step; a library change waits for Update Rates")
    func libraryAcceptance() async throws {
        let fixture = try await bugs.makeFixture(sizes: Array(repeating: (10, 10), count: 40))
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        fixture.environment.rateLibraryStore = store
        // A Waste column so the entry's waste has somewhere to go.
        _ = await (fixture.environment.ledger as any LedgerColumnManaging).applyColumnSpecs(
            [LedgerColumnSpec(id: .custom(UUID().uuidString), title: "Waste", kind: .number, dimension: .ratio)],
            actionName: "Add Column"
        )

        var list = "Name;Unit;Rate;Currency;Waste;Cost Code;Trade\n"
        for index in 0..<199 { list += "Item \(index);m²;\(index),25;SEK;;C\(index);Bygg\n" }
        list += "Gypsum 13 mm;m²;89,50;SEK;10 %;15.S;Drywall\n"
        let library = try #require(fixture.environment.ledger as? any LedgerRateLibraryManaging)
        let imported = await library.importRateList(list)
        #expect(imported.imported == 200)
        #expect(imported.rejectedLines.isEmpty)
        let gypsum = try #require(library.rateEntries.first { $0.name == "Gypsum 13 mm" })

        let rows = Set(fixture.ids.map(\.rawValue))
        let receipt = await library.applyRateEntry(gypsum.id, to: rows)
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        await fixture.environment.ledger.refresh()
        let ledger = fixture.environment.ledger
        let waste = try #require(ledger.columns.first { $0.title == "Waste" })
        for index in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: index))
            #expect(row.value(.material) == .text("Gypsum 13 mm"))
            #expect(row.value(.unitCost) == .currency(amount: Decimal(string: "89.50")!, code: "SEK"))
            #expect(row.value(.costCode) == .text("15.S"))
            #expect(row.value(.trade) == .text("Drywall"))
            #expect(row.value(waste.id) == .number(Decimal(string: "0.10")!))
            // 1 m² × 89.50 = 89.50 SEK.
            #expect(row.value(.totalCost) == .currency(amount: Decimal(string: "89.50")!, code: "SEK"))
        }
        // One step: a single undo clears all forty.
        await fixture.environment.commands.undo()
        await ledger.refresh()
        #expect(try #require(ledger.row(at: 0)).value(.material) == .empty)
        await fixture.environment.commands.redo()
        await ledger.refresh()

        // The office raises the rate to 95.00. The priced project does not move.
        let raise = await library.importRateList("Name;Unit;Rate;Currency;Waste;Cost Code;Trade\nGypsum 13 mm;m²;95,00;SEK;10 %;15.S;Drywall\n")
        #expect(raise.imported == 1)
        #expect(try #require(ledger.row(at: 0)).value(.unitCost) == .currency(amount: Decimal(string: "89.50")!, code: "SEK"))

        // Update Rates shows every row's before and after, and the money it moves: 1 × 5.50.
        let pending = await library.pendingRateUpdates()
        #expect(pending.count == 40)
        #expect(pending.allSatisfy { $0.before == Decimal(string: "89.50")! && $0.after == 95 })
        #expect(pending.allSatisfy { $0.moneyDelta == Decimal(string: "5.50")! })
        let updated = await library.applyRateUpdates(Set(pending.map(\.markupID)))
        #expect(!updated.didFail)
        await ledger.refresh()
        #expect(try #require(ledger.row(at: 0)).value(.unitCost) == .currency(amount: 95, code: "SEK"))
        #expect(await library.pendingRateUpdates().isEmpty)
        // 40 × 95 = 3 800 SEK in Total Cost.
        #expect(ledger.grandTotals.quantities[.totalCost]?.value == 3_800)
    }

    @Test("A per-m² entry on a length row is refused, naming the unit")
    func basisMismatchRefused() async throws {
        let wallTests = NLQuantitiesAssemblyTests()
        let wall = try await wallTests.makeWall()
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        wall.environment.rateLibraryStore = store
        let library = try #require(wall.environment.ledger as? any LedgerRateLibraryManaging)
        _ = await library.importRateList("Name,Unit,Rate\nPaint,m2,45.5\n")
        let paint = try #require(library.rateEntries.first)
        let receipt = await library.applyRateEntry(paint.id, to: [wall.wall.rawValue])
        #expect(receipt.didFail)
        #expect(receipt.failureDescription?.contains("m²") == true)
    }
}
