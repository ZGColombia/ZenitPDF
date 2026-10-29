import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFFormulaEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-QTY-07 round 2 in the app: a `.zpdfassembly` file imported through the (answered, never
/// shown) open panel lands in the office library and is offered by the ledger at once.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLQuantitiesR2AssemblyRecipeTests {

    @Test("Import Recipes… adds the file's recipe to the library and to the Apply Assembly list")
    func importThroughTheWindowHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-recipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = try await Fix2Harness.make("Recipe Host.pdf", calibrate: false)
        let previous = AssemblyRecipesFlow.library
        AssemblyRecipesFlow.library = AssemblyRecipeLibrary(directory: directory.appendingPathComponent("Library", isDirectory: true))
        defer {
            AssemblyRecipesFlow.library = previous
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let recipe = AssemblyDefinition(
            id: UUID(uuidString: "7C1B2F3E-2222-4A2B-9C3D-000000000002")!, name: "Skirting", note: nil,
            inputs: [AssemblyInput(name: "Perimeter", dimension: .length)],
            lines: [AssemblyLine(name: "Skirting board", source: "Perimeter", outputDimension: .length)]
        )
        let file = directory.appendingPathComponent("office.zpdfassembly")
        try AssemblyRecipeLibrary.encode([recipe]).write(to: file)

        AssemblyRecipesFlow.wire(harness.document)
        let shell = try #require(harness.document.shell)
        let run = try #require(shell.onImportAssemblyRecipes)
        #expect(shell.onExportAssemblyRecipes != nil)
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == AssemblyRecipesFlow.importPanelIdentifier ? .urls([file]) : .dismissed
        }
        let offered = try #require(await run())
        #expect(offered.map(\.name).contains("Skirting"))
        #expect(offered.map(\.name).contains("Timber stud wall"), "the built-ins stay")
        #expect(harness.core.ledger.officeAssemblies.map(\.id) == [recipe.id])
        #expect(try AssemblyRecipesFlow.library?.read().map(\.name) == ["Skirting"])
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }
}
