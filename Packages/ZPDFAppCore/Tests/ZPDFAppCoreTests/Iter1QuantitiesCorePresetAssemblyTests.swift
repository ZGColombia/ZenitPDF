import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// NL-QTY-07's tool-preset half (ADR-0035 §4).
///
/// A tool preset carries its assembly as the `customDefaults` entry under the reserved column key
/// `zenit.assembly` — the same `LedgerAssemblyAssignment` text Apply Assembly writes. Draw mode
/// already commits a preset's custom defaults onto the new markup, so a wall drawn with the preset
/// arrives with its assembly and the ledger derives the set at once.
///
/// Hand-derived as `NLQuantitiesAssemblyTests`: a 100 pt line at 0.1 m/pt is a 10 m wall; the
/// timber stud wall at 2.4 m / 0.6 m gives wall area 24 m², studs FLOOR(10 / 0.6) + 1 = 17,
/// plates 20 m and plasterboard 48 m² — four derived rows under the wall.
@Suite("Iteration 1 — quantities core, preset assemblies")
@MainActor
struct Iter1QuantitiesCorePresetAssemblyTests {

    @Test("NL-QTY-07: a wall drawn with an assembly preset arrives with its four derived rows")
    func drawModeProducesTheAssemblySet() async throws {
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

        let assignment = LedgerAssemblyAssignment(
            assemblyID: AssemblyDefinition.timberStudWall.id,
            parameters: ["Height": .length(Decimal(string: "2.4")!), "Spacing": .length(Decimal(string: "0.6")!)]
        )
        guard case .text(let assignmentText) = assignment.cellValue else {
            Issue.record("an assignment is stored as text")
            return
        }
        let preset = ToolPresetSummary(
            id: UUID(), name: "Timber wall", category: "Walls", panel: .myTools,
            markupKind: .measurement, measurementKind: .length,
            colorRGBA: ColorRGBA(red: 0.2, green: 0.6, blue: 0.9), defaultSubject: "Wall W1",
            customDefaults: [AssemblyColumn.key: assignmentText]
        )
        environment.toolLibrary.setPresets([preset])
        environment.toolLibrary.activatePreset(id: preset.id)
        environment.measurement.setPage(page.id)
        environment.measurement.appendRawPoints([PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)])
        environment.measurement.commitActiveMeasurement()
        try await Task.sleep(for: .milliseconds(50))
        await environment.commands.settle()
        await environment.ledger.refresh()

        let wall = try #require(await session.orderedMarkups.first { $0.tool == .length })
        #expect(wall.customValues[AssemblyColumn.columnID] == assignment.cellValue)
        let derived = await session.derivedRows(of: wall.id)
        #expect(derived.count == 4, "the wall's four derived rows")
        #expect(derived.allSatisfy { $0.provenance == .derived })
        // The ledger shows them with their hand-derived primary quantities.
        let ledger = environment.ledger
        #expect(ledger.rowCount == 5, "the wall and its four derived rows")
        var bySubject: [String: Decimal] = [:]
        for index in 0..<ledger.rowCount {
            guard let row = ledger.row(at: index), row.markupID != wall.id.rawValue else { continue }
            if let quantity = LedgerDefaultColumns.primaryQuantity(for: row) { bySubject[row.displayValue(.subject)] = quantity.value }
        }
        #expect(bySubject["Wall area"] == 24)
        #expect(bySubject["Studs"] == 17)
        #expect(bySubject["Plates"] == 20)
        #expect(bySubject["Plasterboard both sides"] == 48)
    }
}
