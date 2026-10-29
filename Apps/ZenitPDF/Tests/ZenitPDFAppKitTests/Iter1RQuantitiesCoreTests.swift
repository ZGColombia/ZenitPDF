import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Quality-loop iteration 1, re-fix of area "quantities-core", in the app: the chains that cross
/// packages — a preset's assembly from the editor through a tool set file into a drawn wall
/// (NL-QTY-07, ADR-0035 §4), and the Inspector's Display units row (NL-MEASURE-10).
@MainActor
@Suite(.appTierSerialised, .serialized)
struct Iter1RQuantitiesCoreTests {

    /// Old: exporting a tool set and importing it again cut the preset's 190-character assembly
    /// to 120, `LedgerAssemblyAssignment(cell:)` returned nil, and a wall drawn with the imported
    /// tool arrived with no derived rows. Now the Assembly row writes the default through the
    /// app's catalogue, the file carries it whole, and the imported tool draws a 10 m wall with
    /// its four rows: 10 × 2.4 = 24 m² wall area, ⌈10 / 0.6⌉ + 1 = 17 studs, 2 × 10 = 20 m of
    /// plates, 2 × 24 = 48 m² of board.
    @Test("NL-QTY-07: a preset's assembly survives export and import and a drawn wall gets its four rows")
    func presetAssemblyRoundTrip() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        await environment.refresh()

        // The editor's Assembly row, over the catalogue every Tool Library host gets.
        let catalog = try #require(environment.toolLibrary.presetAssemblyCatalog)
        #expect(catalog.recipes.map(\.id).contains(AssemblyDefinition.timberStudWall.id))
        var editor = ToolPresetAssemblyEditor(customDefaults: [:], catalog: catalog, lengthUnit: .metre)
        editor.selectedID = AssemblyDefinition.timberStudWall.id
        editor.parameterTexts = ["Height": "2.4", "Spacing": "0.6"]
        var defaults: [String: String] = [:]
        try editor.apply(to: &defaults, catalog: catalog)
        let written = try #require(defaults[AssemblyColumn.key])
        #expect(written.count > ToolSetImportValidator.Limits.standard.maximumTextLength)
        // What the old import left behind is not an assignment at all.
        #expect(LedgerAssemblyAssignment(cell: .text(String(written.prefix(120)))) == nil)

        // Export the preset in a tool set file and import it through the validator.
        let preset = ToolPresetSummary(
            id: UUID(), name: "Timber wall", category: "Walls", panel: .myTools,
            markupKind: .measurement, measurementKind: .length,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.6, blue: 0.9), defaultSubject: "Wall W1",
            customDefaults: defaults
        )
        let file = try ToolSetDocument(name: "Walls", exporting: [preset]).jsonData()
        let review = try ToolSetImportValidator().review(data: file, fileName: "Walls.zpdftools").get()
        let imported = try #require(review.presets.first)
        #expect(imported.customDefaults[AssemblyColumn.key] == written, "carried whole, byte for byte")
        #expect(!review.findings.contains { $0.code == .overlongText || $0.code == .invalidAssembly })

        // Draw a 10 m wall with the imported tool, through the shipping Draw path.
        environment.toolLibrary.setPresets([imported])
        environment.toolLibrary.activatePreset(id: imported.id)
        environment.measurement.setPage(page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)])
        environment.measurement.commitActiveMeasurement()
        try await Task.sleep(for: .milliseconds(50))
        await environment.commands.settle()
        await environment.ledger.refresh()

        let wall = try #require(await session.orderedMarkups.first { $0.tool == .length })
        #expect(wall.customValues[AssemblyColumn.columnID] == .text(written))
        let derived = await session.derivedRows(of: wall.id)
        #expect(derived.count == 4, "the wall's four derived rows")
        var bySubject: [String: Decimal] = [:]
        for index in 0..<environment.ledger.rowCount {
            guard let row = environment.ledger.row(at: index), row.markupID != wall.id.rawValue else { continue }
            if let quantity = LedgerDefaultColumns.primaryQuantity(for: row) { bySubject[row.displayValue(.subject)] = quantity.value }
        }
        #expect(bySubject == ["Wall area": 24, "Studs": 17, "Plates": 20, "Plasterboard both sides": 48])
    }

    /// The Inspector shows the Display units row after the value rows, as a menu of the five
    /// choices; a value row keeps its text field.
    @Test("NL-MEASURE-10: the Inspector's rows end with a Display units menu")
    func inspectorShowsDisplayUnits() throws {
        let documentID = DocumentID(UUID())
        let page = PageID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var parameters = MeasurementParameters.default
        parameters.depth = .length(Decimal(string: "0.2")!)
        parameters.displayOverride = MeasurementDisplayUnitsChoice.decimalFeet.policy
        let slab = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .volume,
            subject: "Slab", author: "t", parameters: parameters, createdAt: stamp, modifiedAt: stamp
        )
        let rows = ProjectWindowController.inspectorRows(for: [slab], lengthUnit: .millimetre)
        #expect(rows.map(\.id) == ["depth", "slope", "displayUnits"])
        #expect(rows[0].choices.isEmpty && rows[0].text == "200")
        let units = try #require(rows.last)
        #expect(units.title == "Display units")
        #expect(units.text == "decimalFeet")
        #expect(units.choiceLabel == "Decimal feet")
        #expect(units.choices.map(\.title) == ["Project units", "Metres", "Millimetres", "Feet and inches", "Decimal feet"])
        #expect(!units.help.isEmpty)
    }
}
