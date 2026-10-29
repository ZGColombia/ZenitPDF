import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-QTY-07-UI in the app: a recipe written in the editor and saved to the project edits the
/// document, travels in the saved file and is offered again after reopening; its unit cost prices
/// the derived row before and after. Through the shipping document class; nothing is shown.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLQty07UIAppRecipeTests {

    private func saveAsProject(_ document: ZenitPDFProjectDocument, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: destination, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Hand-derived: 100 pt = 1 m, a line from x = 80 to x = 280 is 200 pt = 2 m; the recipe's
    /// one line is `Length` at 42.50 SEK/m, so Total Cost = 2 × 42.50 = 85.00 SEK.
    @Test("Save to the project edits the document, survives save and reopen, and the line's unit cost prices the row")
    func projectRecipeRoundTrip() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Recipes.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = AssemblyRecipesFlow.library
        AssemblyRecipesFlow.library = nil      // never the user's Application Support
        defer { AssemblyRecipesFlow.library = previous }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        AssemblyRecipesFlow.wire(document)
        #expect(core.ledger.officeRecipeLibrary == nil)
        #expect(core.ledger.assemblyRecipeStores == [.project])

        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        core.measurement.activate(kind: .length)
        core.measurement.appendRawPoints([PDFPointValue(x: 80, y: 80), PDFPointValue(x: 280, y: 80)])
        core.measurement.commitActiveMeasurement()
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 1 })
        let wall = try #require(core.ledger.row(at: 0)?.markupID)

        let recipeID = UUID(uuidString: "7C1B2F3E-4444-4A2B-9C3D-000000000007")!
        let draft = LedgerAssemblyRecipeDraft(
            id: recipeID, name: "Skirting",
            inputs: [.init(name: "Length", dimension: .length)],
            lines: [.init(name: "Skirting board", formula: "Length", dimension: .length,
                          unitCost: .init(value: Decimal(string: "42.50")!, dimension: .currency("SEK")))]
        )
        document.updateChangeCount(.changeCleared)
        let saved = await core.ledger.saveAssemblyRecipe(draft, to: .project)
        #expect(!saved.didFail, "\(saved.failureDescription ?? "")")
        #expect(document.isDocumentEdited, "a project recipe is part of the document")
        let applied = await core.ledger.applyAssembly(recipeID, parameters: [:], to: [wall])
        #expect(!applied.didFail, "\(applied.failureDescription ?? "")")
        #expect(await AppTestSupport.wait { core.ledger.rowCount == 2 })
        let board = try #require((0..<core.ledger.rowCount).compactMap { core.ledger.row(at: $0) }.first { $0.markupID != wall })
        #expect(board.value(.unitCost) == .currency(amount: Decimal(string: "42.50")!, code: "SEK"))
        #expect(board.value(.totalCost) == .currency(amount: 85, code: "SEK"))

        let destination = directory.appendingPathComponent("Recipes.zpdfproj")
        try await saveAsProject(document, to: destination)
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { reopened.core != nil && !reopened.isLoading })
        let restored = try #require(reopened.core)
        #expect(restored.ledger.projectAssemblies.map(\.id) == [recipeID])
        #expect(restored.ledger.availableAssemblies.contains { $0.id == recipeID })
        #expect(restored.ledger.assemblyRecipes.first { $0.id == recipeID }?.store == .project)
        #expect(await AppTestSupport.wait { restored.ledger.rowCount == 2 })
        let reopenedBoard = try #require((0..<restored.ledger.rowCount).compactMap { restored.ledger.row(at: $0) }
            .first { $0.displayValue(.subject) == "Skirting board" })
        #expect(reopenedBoard.value(.totalCost) == .currency(amount: 85, code: "SEK"))
        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
