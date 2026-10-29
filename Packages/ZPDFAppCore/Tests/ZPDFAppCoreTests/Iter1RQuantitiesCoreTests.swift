import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Quantities core in AppCore, re-fixed: the Display units row
/// that sets NL-MEASURE-10's override (ADR-0035 §1.3), and the one assignment text a preset's
/// Assembly row and Apply Assembly both write (NL-QTY-07, ADR-0035 §4).
@Suite("Iteration 1 re-fix — quantities core, AppCore")
@MainActor
struct Iter1RQuantitiesCoreTests {

    /// A session calibrated at 1 m per point, with the environment the app drives it through.
    static func environment() async throws -> (AppCoreEnvironment, TakeoffSession, PageID, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 100, knownLengthUnit: .metre
        )
        await environment.refresh()
        return (environment, session, page.id, documentID)
    }

    /// A 3.81 m line (3.81 pt at 1 m/pt): exactly 12.5 ft, so 12'-6" in feet and inches.
    static func line(_ page: PageID, documentID: DocumentID, tool: MeasurementTool = .length, override: DisplayUnitPolicy? = nil) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: tool,
            subject: "Rebar", author: "t",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 3.81, y: 0)]),
            parameters: MeasurementParameters(displayOverride: override),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    // MARK: - NL-MEASURE-10: the Display units row

    /// Old: nothing in the program could set `displayOverride`. Now the Inspector's Display units
    /// row writes it through `editParameters` in one undoable step: the ledger row of a metric
    /// project reads 12'-6" / ft after choosing Feet and inches, the stored 3.81 m is untouched,
    /// and one ⌘Z takes the row back to 3.81 m.
    @Test("NL-MEASURE-10: Display units writes displayOverride as one undoable editParameters step")
    func displayUnitsRowSetsTheOverride() async throws {
        let (environment, session, page, documentID) = try await Self.environment()
        let rebar = Self.line(page, documentID: documentID)
        _ = try await environment.commands.perform(.addMarkup(rebar))
        let record = try #require(await session.markup(rebar.id))
        let planLength = try #require(record.measurement?[.planLength])

        let row = try #require(ParameterEditing.displayUnitsRow(for: [record]))
        #expect(row.kind == .displayUnits)
        #expect(row.text == MeasurementDisplayUnitsChoice.project.rawValue)
        #expect(!row.isMixed)
        #expect(row.choices.map(\.id) == MeasurementDisplayUnitsChoice.allCases.map(\.rawValue))
        // The value rows are unchanged by it: a plain length has none.
        #expect(ParameterEditing.rows(for: [record], lengthUnit: .metre).isEmpty)

        let commands = try ParameterEditing.commands(setting: .displayUnits, to: "feetAndInches", on: [record], lengthUnit: .metre)
        #expect(commands.count == 1)
        guard case .editParameters(let editedID, let edited)? = commands.first else {
            Issue.record("Display units is an editParameters command")
            return
        }
        #expect(editedID == rebar.id)
        #expect(edited == MeasurementParameters(displayOverride: MeasurementDisplayUnitsChoice.feetAndInches.policy))
        let outcome = try await environment.commands.performBatch(commands, actionName: "Edit Display units")
        #expect(outcome != nil, "an override is a change a person sees: one undo step")
        await environment.ledger.refresh()

        let changed = try #require(await session.markup(rebar.id))
        #expect(changed.parameters?.displayOverride == DisplayUnitSelection.imperial.domainPolicy)
        #expect(changed.measurement?[.planLength] == planLength, "metadata only: the SI value is unchanged")
        #expect(ParameterEditing.displayUnitsRow(for: [changed])?.text == "feetAndInches")
        let planColumn = LedgerColumnID(StandardLedgerColumn.planLength.rawValue)
        let shown = try #require((0..<environment.ledger.rowCount).compactMap { environment.ledger.row(at: $0) }.first { $0.markupID == rebar.id.rawValue })
        #expect(shown.displayValue(planColumn) == "12'-6\"")
        #expect(shown.displayValue(LedgerDefaultColumns.unitColumnID) == "ft")

        // Choosing what is already set is no command at all.
        #expect(try ParameterEditing.commands(setting: .displayUnits, to: "feetAndInches", on: [changed], lengthUnit: .metre).isEmpty)

        await environment.commands.undo()
        await environment.ledger.refresh()
        #expect(await session.markup(rebar.id)?.parameters?.displayOverride == nil)
        let restored = try #require((0..<environment.ledger.rowCount).compactMap { environment.ledger.row(at: $0) }.first { $0.markupID == rebar.id.rawValue })
        #expect(restored.displayValue(LedgerDefaultColumns.unitColumnID) == "m")
    }

    @Test("NL-MEASURE-10: who gets the row, mixed and custom values, and refused text")
    func displayUnitsRules() throws {
        let page = PageID(UUID())
        let documentID = DocumentID(UUID())
        let plain = Self.line(page, documentID: documentID)
        let metres = Self.line(page, documentID: documentID, override: MeasurementDisplayUnitsChoice.metres.policy)
        // A count has no unit to show; a cutout child is edited through its parent.
        #expect(ParameterEditing.displayUnitsRow(for: [Self.line(page, documentID: documentID, tool: .count)]) == nil)
        var child = Self.line(page, documentID: documentID)
        child.parentMarkupID = plain.id
        #expect(ParameterEditing.displayUnitsRow(for: [child]) == nil)
        #expect(ParameterEditing.displayUnitsRow(for: []) == nil)

        let mixed = try #require(ParameterEditing.displayUnitsRow(for: [plain, metres]))
        #expect(mixed.isMixed && mixed.text.isEmpty)
        // One step sets both.
        #expect(try ParameterEditing.commands(setting: .displayUnits, to: "decimalFeet", on: [plain, metres], lengthUnit: .metre).count == 2)
        // Back to the project's units clears the override.
        let cleared = try ParameterEditing.commands(setting: .displayUnits, to: "project", on: [metres], lengthUnit: .metre)
        guard case .editParameters(_, let parameters)? = cleared.first, cleared.count == 1 else {
            Issue.record("choosing Project units is one editParameters command")
            return
        }
        #expect(parameters.displayOverride == nil)

        // An override none of the choices wrote shows as custom and is never rewritten silently.
        let yards = DisplayUnitPolicy(length: .yard, area: .squareYard, volume: .cubicYard, precision: .decimalPlaces(3))
        #expect(MeasurementDisplayUnitsChoice(policy: yards) == nil)
        #expect(ParameterEditing.displayUnitsRow(for: [Self.line(page, documentID: documentID, override: yards)])?.text == "")

        #expect(throws: ParameterEditing.Refusal.unreadable("furlongs")) {
            _ = try ParameterEditing.commands(setting: .displayUnits, to: "furlongs", on: [plain], lengthUnit: .metre)
        }
        // Every choice reads back as itself, and the four overrides are four distinct policies.
        for choice in MeasurementDisplayUnitsChoice.allCases {
            #expect(MeasurementDisplayUnitsChoice(policy: choice.policy) == choice)
        }
        #expect(Set(MeasurementDisplayUnitsChoice.allCases.compactMap(\.policy)).count == 4)
        #expect(MeasurementDisplayUnitsChoice.decimalFeet.policy?.length == .foot)
        #expect(MeasurementDisplayUnitsChoice.decimalFeet.policy?.precision == .decimalPlaces(2))
        #expect(MeasurementDisplayUnitsChoice.millimetres.policy?.length == .millimetre)
        #expect(MeasurementParameterRowKind.valueKinds.contains(.displayUnits) == false)
    }

    // MARK: - NL-QTY-07: the preset default is Apply Assembly's text

    /// The preset's `zenit.assembly` default and the cell Apply Assembly writes are the same bytes,
    /// and read back to the same recipe and values.
    @Test("NL-QTY-07: a preset's assembly default is byte-identical to Apply Assembly's cell and reads back")
    func presetDefaultIsTheAssignmentText() throws {
        let height = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "2.4")!, dimension: .length)
        let spacing = ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: "0.6")!, dimension: .length)
        let text = try #require(AssemblyOffer.presetDefault(
            AssemblyDefinition.timberStudWall.id, parameters: ["Height": height, "Spacing": spacing], office: []
        ))
        let applied = LedgerAssemblyAssignment(
            assemblyID: AssemblyDefinition.timberStudWall.id,
            parameters: ["Height": .length(Decimal(string: "2.4")!), "Spacing": .length(Decimal(string: "0.6")!)]
        )
        #expect(ZPDFContracts.LedgerCellValue.text(text) == applied.cellValue)
        #expect(text.count > 120, "longer than the import validator's text limit — the ADR-0035 §4 defect")
        let read = try #require(AssemblyOffer.presetSelection(text))
        #expect(read.recipeID == AssemblyDefinition.timberStudWall.id)
        #expect(read.parameters == ["Height": height, "Spacing": spacing])

        // An office recipe travels inside the text; an unknown one is refused.
        let timber = AssemblyDefinition.timberStudWall
        let office = AssemblyDefinition(id: UUID(), name: "Office wall", inputs: timber.inputs, lines: timber.lines)
        let carried = try #require(AssemblyOffer.presetDefault(office.id, parameters: [:], office: [office]))
        #expect(LedgerAssemblyAssignment(cell: .text(carried))?.definition == office)
        #expect(AssemblyOffer.presetDefault(UUID(), parameters: [:], office: [office]) == nil)
        #expect(AssemblyOffer.presetSelection("{\"assembly\": 1}") == nil)
        // The ledger's offer and the preset editor's are one list.
        #expect(AssemblyOffer.summaries(office: [office]).map(\.id) == LedgerAssemblyLibrary.standard.map(\.id) + [office.id])
    }
}
