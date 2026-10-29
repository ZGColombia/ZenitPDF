import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-QTY-07-UI: recipes authored in the app, saved to the project or the office library, and a
/// unit cost per line that prices the derived rows (ADR-0020, ADR-0024). Through the shipping
/// presenter, seam and command bus.
///
/// Hand-derived: a 100 pt line at 0.1 m/pt is a 10 m wall. The recipe below at Height 2.4 m and
/// Spacing 0.6 m gives
/// - Studs: FLOOR(10 / 0.6) + 1 = FLOOR(16.67) + 1 = 17 pcs, at 45.50 SEK/pcs = 17 × 45.50 = 773.50 SEK;
/// - Plasterboard: 10 × 2.4 × 2 = 48 m², at 89.95 SEK/m² = 48 × 89.95 = 4 317.60 SEK;
/// - Plates: 10 × 2 = 20 m, no unit cost, so no Total Cost.
/// Total Cost over the ledger: 773.50 + 4 317.60 = 5 091.10 SEK.
@MainActor
final class RecipeEditCounter { var value = 0 }

@Suite("NL-QTY-07-UI — recipe editor and per-line unit cost")
@MainActor
struct NLQty07UIRecipeEditorTests {

    static let recipeID = UUID(uuidString: "7C1B2F3E-2222-4A2B-9C3D-000000000007")!

    static func sek(_ text: String) -> ZPDFUIPresentation.DecimalQuantity {
        ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: text)!, dimension: .currency("SEK"))
    }

    /// The draft the editor would hand over.
    static func draft(plasterboardCost: String = "89.95") -> LedgerAssemblyRecipeDraft {
        LedgerAssemblyRecipeDraft(
            id: recipeID,
            name: "Priced stud wall",
            note: "Studs and board, priced.",
            inputs: [
                .init(name: "Length", dimension: .length),
                .init(name: "Height", dimension: .length),
                .init(name: "Spacing", dimension: .length)
            ],
            lines: [
                .init(name: "Studs", formula: "FLOOR(Length / Spacing) + 1", dimension: .count, unitCost: sek("45.50")),
                .init(name: "Plasterboard", formula: "Length * Height * 2", dimension: .area, unitCost: sek(plasterboardCost)),
                .init(name: "Plates", formula: "Length * 2", dimension: .length)
            ]
        )
    }

    static let parameters: [String: ZPDFUIPresentation.DecimalQuantity] = [
        "Height": .init(value: Decimal(string: "2.4")!, dimension: .length),
        "Spacing": .init(value: Decimal(string: "0.6")!, dimension: .length)
    ]

    func editing(_ wall: NLQuantitiesAssemblyTests.Wall) throws -> any LedgerAssemblyRecipeEditing {
        try #require(wall.environment.ledger as? any LedgerAssemblyRecipeEditing)
    }

    /// Each derived row's Unit Cost and Total Cost, by subject.
    func costs(_ wall: NLQuantitiesAssemblyTests.Wall) -> [String: (unit: ZPDFUIPresentation.LedgerCellValue, total: ZPDFUIPresentation.LedgerCellValue)] {
        var result: [String: (unit: ZPDFUIPresentation.LedgerCellValue, total: ZPDFUIPresentation.LedgerCellValue)] = [:]
        let ledger = wall.environment.ledger
        for index in 0..<ledger.rowCount {
            guard let row = ledger.row(at: index), row.markupID != wall.wall.rawValue else { continue }
            result[row.displayValue(.subject)] = (row.value(.unitCost), row.value(.totalCost))
        }
        return result
    }

    static func money(_ text: String) -> ZPDFUIPresentation.LedgerCellValue {
        .currency(amount: Decimal(string: text)!, code: "SEK")
    }

    // MARK: - Saving to the project, pricing the rows

    @Test("A recipe saved to the project is offered, derives priced rows, and Total Cost = quantity × unit cost exactly")
    func projectRecipePricesDerivedRows() async throws {
        let base = NLQuantitiesAssemblyTests()
        let wall = try await base.makeWall()
        let editor = try editing(wall)
        #expect(editor.assemblyRecipeStores == [.project], "no office library is installed in a test")
        #expect(editor.checkAssemblyRecipe(Self.draft()).isValid)

        let edited = RecipeEditCounter()
        wall.environment.ledger.onProjectAssembliesChanged = { edited.value += 1 }
        let saved = await editor.saveAssemblyRecipe(Self.draft(), to: .project)
        #expect(!saved.didFail, "\(saved.failureDescription ?? "")")
        #expect(edited.value == 1, "the document is told its project recipes changed")
        #expect(await wall.session.projectAssemblyRecipes.recipes.map(\.id) == [Self.recipeID])
        let entry = try #require(editor.assemblyRecipes.first { $0.id == Self.recipeID })
        #expect(entry.store == .project)
        #expect(entry.draft.lines[1].unitCost == Self.sek("89.95"))
        #expect(editor.availableAssemblies.contains { $0.id == Self.recipeID })

        let applied = await editor.applyAssembly(Self.recipeID, parameters: Self.parameters, to: [wall.wall.rawValue])
        #expect(!applied.didFail, "\(applied.failureDescription ?? "")")
        #expect(base.derived(wall) == ["Studs": 17, "Plasterboard": 48, "Plates": 20])

        let rows = costs(wall)
        #expect(rows["Studs"]?.unit == Self.money("45.50"))
        #expect(rows["Studs"]?.total == Self.money("773.50"))          // 17 × 45.50
        #expect(rows["Plasterboard"]?.unit == Self.money("89.95"))
        #expect(rows["Plasterboard"]?.total == Self.money("4317.60"))  // 48 × 89.95
        #expect(rows["Plates"]?.unit == .empty)
        #expect(rows["Plates"]?.total == .empty)
        // 773.50 + 4 317.60 = 5 091.10, exact Decimal.
        #expect(wall.environment.ledger.grandTotals.total(.totalCost) == Self.sek("5091.10"))
    }

    @Test("Editing the unit cost brings the rows that use the recipe up to date in one undo step")
    func editUpdatesRowsInOneUndo() async throws {
        let base = NLQuantitiesAssemblyTests()
        let wall = try await base.makeWall()
        let editor = try editing(wall)
        _ = await editor.saveAssemblyRecipe(Self.draft(), to: .project)
        _ = await editor.applyAssembly(Self.recipeID, parameters: Self.parameters, to: [wall.wall.rawValue])

        // 48 m² at 95.00 = 4 560.00; total 773.50 + 4 560.00 = 5 333.50.
        let receipt = await editor.saveAssemblyRecipe(Self.draft(plasterboardCost: "95.00"), to: .project)
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(receipt.updatedRowCount == 1, "the one wall carrying the recipe")
        #expect(costs(wall)["Plasterboard"]?.total == Self.money("4560"))
        #expect(wall.environment.ledger.grandTotals.total(.totalCost) == Self.sek("5333.50"))
        #expect(wall.environment.commands.undoManager.undoActionName == "Update Assembly Recipe")

        await wall.environment.commands.undo()
        await wall.environment.ledger.refresh()
        #expect(costs(wall)["Plasterboard"]?.total == Self.money("4317.60"))
        #expect(wall.environment.ledger.grandTotals.total(.totalCost) == Self.sek("5091.10"))

        // A locked row keeps its copy and is counted, never silently skipped.
        await wall.environment.commands.redo()
        _ = try await wall.environment.commands.perform(.setLocked(ids: [wall.wall], locked: true))
        let locked = await editor.saveAssemblyRecipe(Self.draft(plasterboardCost: "99"), to: .project)
        #expect(!locked.didFail)
        #expect(locked.updatedRowCount == 0)
        #expect(locked.lockedRowCount == 1)
        await wall.environment.ledger.refresh()
        #expect(costs(wall)["Plasterboard"]?.total == Self.money("4560"), "still the copy it carried")
    }

    // MARK: - The importer's rule

    @Test("The editor refuses exactly what a recipe import refuses, in the same words")
    func editorValidatesAsTheImporterDoes() async throws {
        let wall = try await NLQuantitiesAssemblyTests().makeWall()
        let editor = try editing(wall)
        var noName = Self.draft(); noName.name = "  "
        var noLines = Self.draft(); noLines.lines = []
        var twins = Self.draft(); twins.lines[2].name = "studs "
        var builtIn = Self.draft(); builtIn.id = LedgerAssemblyLibrary.standard[0].id
        var broken = Self.draft(); broken.lines[0].formula = "Length *"
        var typo = Self.draft(); typo.lines[1].formula = "Lenght * Height"
        var undeclared = Self.draft(); undeclared.lines[1].formula = "Area * 2"
        var wrongUnit = Self.draft(); wrongUnit.lines[2].dimension = .area   // Length * 2 is a length
        var notMoney = Self.draft(); notMoney.lines[0].unitCost = .init(value: 5, dimension: .length)
        var aggregate = Self.draft(); aggregate.lines[2].formula = "SUM(Length)"

        for bad in [noName, noLines, twins, builtIn, broken, typo, undeclared, wrongUnit, notMoney, aggregate] {
            let recipe = AssemblyRecipeDrafting.definition(of: bad)
            var imported: String?
            do { _ = try AssemblyRecipeLibrary.decode(try AssemblyRecipeLibrary.encode([recipe])) } catch {
                imported = String(describing: error)
            }
            let importerWords = try #require(imported, "the importer refuses \(bad.name) / \(bad.lines.map(\.formula))")
            #expect(!editor.checkAssemblyRecipe(bad).isValid)
            let saved = await editor.saveAssemblyRecipe(bad, to: .project)
            #expect(saved.failureDescription == importerWords)
        }
        #expect(await wall.session.projectAssemblyRecipes.recipes.isEmpty, "nothing refused was kept")

        // The live check names the line and the reason in the formula engine's words.
        let check = editor.checkAssemblyRecipe(typo)
        #expect(check.refusal == nil)
        #expect(check.lineProblems.keys.sorted() == [1])
        #expect(check.lineProblems[1]?.contains("Lenght") == true)
        #expect(editor.checkAssemblyRecipe(wrongUnit).lineProblems[2]?.contains("declared to produce") == true)
        #expect(editor.checkAssemblyRecipe(builtIn).refusal?.contains("built-in") == true)
        #expect(editor.checkAssemblyRecipe(Self.draft()).measuredInputs == [0, 1], "Length and Height are measured; Spacing is typed")

        // A built-in recipe is listed read-only and cannot be saved over or deleted.
        #expect(editor.assemblyRecipes.first { $0.id == LedgerAssemblyLibrary.standard[0].id }?.isReadOnly == true)
        var copy = AssemblyRecipeDrafting.draft(of: LedgerAssemblyLibrary.standard[0])
        #expect(await editor.saveAssemblyRecipe(copy, to: .project).didFail)
        #expect(await editor.deleteAssemblyRecipe(copy.id, from: .builtIn).didFail)
        // Its duplicate — a new identity — saves.
        copy.id = UUID()
        copy.name = "Timber stud wall copy"
        #expect(!(await editor.saveAssemblyRecipe(copy, to: .project).didFail))
    }

    // MARK: - Office library and delete

    @Test("A recipe saved to the office library is in the file with its unit cost; delete removes it and rows keep their copy")
    func officeLibrarySaveAndDelete() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-recipes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = NLQuantitiesAssemblyTests()
        let wall = try await base.makeWall()
        let library = AssemblyRecipeLibrary(directory: directory)
        wall.environment.ledger.officeRecipeLibrary = library
        let editor = try editing(wall)
        #expect(editor.assemblyRecipeStores == [.office, .project])

        let saved = await editor.saveAssemblyRecipe(Self.draft(), to: .office)
        #expect(!saved.didFail, "\(saved.failureDescription ?? "")")
        #expect(await wall.session.projectAssemblyRecipes.recipes.isEmpty, "the office library, not the project")
        let onDisk = try AssemblyRecipeLibrary.decode(Data(contentsOf: library.fileURL))
        #expect(onDisk.map(\.id) == [Self.recipeID])
        #expect(onDisk[0].lines[1].unitCost == ZPDFContracts.DecimalQuantity(value: Decimal(string: "89.95")!, dimension: .currency("SEK")))
        #expect(onDisk[0].lines[2].unitCost == nil)
        #expect(editor.assemblyRecipes.first { $0.id == Self.recipeID }?.store == .office)

        _ = await editor.applyAssembly(Self.recipeID, parameters: Self.parameters, to: [wall.wall.rawValue])
        let deleted = await editor.deleteAssemblyRecipe(Self.recipeID, from: .office)
        #expect(!deleted.didFail)
        #expect(try library.read().isEmpty)
        #expect(!editor.availableAssemblies.contains { $0.id == Self.recipeID })
        await wall.environment.ledger.refresh()
        #expect(costs(wall)["Studs"]?.total == Self.money("773.50"), "the row carries its copy of the recipe")
        #expect(await editor.deleteAssemblyRecipe(Self.recipeID, from: .office).didFail, "already gone")
    }

    // MARK: - Saved with the project

    @Test("Project recipes survive save and reopen; an unreadable stored list is kept byte for byte and refused as a target")
    func projectRecipesPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-project-recipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let recipe = AssemblyRecipeDrafting.definition(of: Self.draft())
        await session.setProjectAssemblyRecipes([recipe])

        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Recipes.zpdfproj", isDirectory: true),
            displayName: "Recipes", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        let read = try #require(try await TakeoffArchive.read(from: package))
        #expect(read.projectAssemblyRecipes.isReadable)
        #expect(read.projectAssemblyRecipes.recipes == [recipe])
        #expect(read.projectAssemblyRecipes.recipes.first?.lines[0].unitCost?.value == Decimal(string: "45.50")!)

        // Reopened: the environment offers the project's recipe.
        let reopened = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        await reopened.restoreProjectAssemblyRecipes(read.projectAssemblyRecipes)
        let environment = try await AppCoreEnvironment.make(session: reopened, documentID: fixture.documentID)
        #expect(environment.ledger.availableAssemblies.contains { $0.id == Self.recipeID })

        // A list a newer build wrote, which this one cannot read.
        let projectId = try await ToolPresetArchive.projectIdentifier(of: package)
        let newer = #"{"format":"zenit.assembly","schemaVersion":99,"recipes":[]}"#
        try await package.write { db in
            try MarkupLayerStore.setSetting(ProjectAssemblyRecipeArchive.key, json: newer, project: projectId, in: db)
        }
        let unreadable = try #require(try await TakeoffArchive.read(from: package))
        #expect(!unreadable.projectAssemblyRecipes.isReadable)
        let later = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        await later.restoreProjectAssemblyRecipes(unreadable.projectAssemblyRecipes)
        try await TakeoffArchive.write(await later.takeoffState(), into: package)
        let kept = try await package.read { db in
            try MarkupLayerStore.setting(ProjectAssemblyRecipeArchive.key, project: projectId, in: db)
        }
        #expect(kept == newer, "a save never replaces recipes it could not read")
        let laterEnvironment = try await AppCoreEnvironment.make(session: later, documentID: fixture.documentID)
        let refused = await laterEnvironment.saveAssemblyRecipe(recipe, to: .project)
        #expect(refused.failureDescription?.contains("newer Zenit PDF") == true)

        // Deleting the last project recipe removes the key on the next save.
        await session.setProjectAssemblyRecipes([])
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        let removed = try await package.read { db in
            try MarkupLayerStore.setting(ProjectAssemblyRecipeArchive.key, project: projectId, in: db)
        }
        #expect(removed == nil)
        try await package.close()
    }

    @Test("A project list too large for the file is refused before anything is kept")
    func projectListBound() async throws {
        let wall = try await NLQuantitiesAssemblyTests().makeWall()
        let editor = try editing(wall)
        var huge = Self.draft()
        huge.note = String(repeating: "n", count: ProjectAssemblyRecipeArchive.maximumByteCount)
        let refused = await editor.saveAssemblyRecipe(huge, to: .project)
        #expect(refused.failureDescription?.contains("KB") == true)
        #expect(await wall.session.projectAssemblyRecipes.recipes.isEmpty)
    }
}
