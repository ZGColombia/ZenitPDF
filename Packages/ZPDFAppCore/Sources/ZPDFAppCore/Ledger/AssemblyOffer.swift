import Foundation
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The assembly recipes on offer and the one text an assignment is stored as (NL-QTY-07).
///
/// Two surfaces assign an assembly: Apply Assembly on ledger rows (ADR-0024) and a Tool Library
/// preset's `zenit.assembly` column default, which Draw, Place and Apply copy onto every markup
/// the preset makes (ADR-0035 §4). Both offer the same recipes and write the same
/// ``LedgerAssemblyAssignment`` text, from here, so a wall drawn with the preset and a wall given
/// the assembly afterwards carry byte-identical cells.
public enum AssemblyOffer {

    /// The built-in recipes, then this project's own (NL-QTY-07-UI), then every office recipe —
    /// each id once: a built-in's id is never taken over, and a project's copy of a recipe wins
    /// over the office's in its own project.
    public static func definitions(office: [AssemblyDefinition], project: [AssemblyDefinition] = []) -> [AssemblyDefinition] {
        var taken = Set(LedgerAssemblyLibrary.standard.map(\.id))
        var offered = LedgerAssemblyLibrary.standard
        for recipe in project + office where taken.insert(recipe.id).inserted { offered.append(recipe) }
        return offered
    }

    /// ``definitions(office:project:)`` as the interface lists them.
    public static func summaries(office: [AssemblyDefinition], project: [AssemblyDefinition] = []) -> [LedgerAssemblySummary] {
        LedgerAssemblyLibrary.descriptions(of: definitions(office: office, project: project)).map { description in
            LedgerAssemblySummary(
                id: description.id,
                name: description.name,
                note: description.note,
                inputs: description.inputs.map {
                    LedgerAssemblySummary.Input(
                        name: $0.name, dimension: Shown.Dimension(domain: $0.dimension),
                        isFreeParameter: $0.isFreeParameter, note: $0.note
                    )
                },
                lines: description.lines.map {
                    LedgerAssemblySummary.Line(name: $0.name, formula: $0.formula, dimension: Shown.Dimension(domain: $0.dimension))
                }
            )
        }
    }

    /// The assignment of `assemblyID` with `parameters` (SI base units), as the cell and the
    /// preset default store it; `nil` for a recipe neither built in nor in `office`. An office
    /// recipe travels inside the assignment, so the rows derive where that library is absent.
    public static func assignment(
        _ assemblyID: UUID,
        parameters: [String: Domain.Quantity],
        office: [AssemblyDefinition],
        project: [AssemblyDefinition] = []
    ) -> LedgerAssemblyAssignment? {
        if LedgerAssemblyLibrary.definition(id: assemblyID) != nil {
            return LedgerAssemblyAssignment(assemblyID: assemblyID, parameters: parameters)
        }
        guard let carried = (project + office).first(where: { $0.id == assemblyID }) else { return nil }
        return LedgerAssemblyAssignment(assemblyID: assemblyID, parameters: parameters, definition: carried)
    }

    /// A preset's `zenit.assembly` default for `assemblyID`, or `nil` for an unknown recipe.
    public static func presetDefault(
        _ assemblyID: UUID,
        parameters: [String: Shown.Quantity],
        office: [AssemblyDefinition]
    ) -> String? {
        guard let assignment = assignment(assemblyID, parameters: parameters.mapValues { Domain.Quantity(shown: $0) }, office: office),
              case .text(let text) = assignment.cellValue else { return nil }
        return text
    }

    /// A stored preset default read back, or `nil` when it is not an assignment.
    public static func presetSelection(_ text: String) -> (recipeID: UUID, parameters: [String: Shown.Quantity])? {
        guard let assignment = LedgerAssemblyAssignment(cell: .text(text)) else { return nil }
        return (assignment.assemblyID, assignment.parameters.mapValues { Shown.Quantity(domain: $0) })
    }
}
