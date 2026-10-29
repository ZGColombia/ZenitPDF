import Foundation
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// NL-QTY-07 (ADR-0035 §4): the Tool Library preset editor's Assembly row, on every host that
/// shows the Tool Library — docked, the tool chest and the sheet all build their panel over this
/// presenter, and the panel asks it for the catalogue.
///
/// The recipes are the built-in ones and the office library's, read when the editor opens, so a
/// recipe imported a moment ago is offered; the conversions are AppCore's, the same text Apply
/// Assembly writes on a ledger row.
extension AppToolLibraryPresenter: ToolPresetAssemblyProviding {

    public var presetAssemblyCatalog: ToolPresetAssemblyCatalog? {
        let office = (try? AssemblyRecipesFlow.library?.read()) ?? []
        return ToolPresetAssemblyCatalog(
            recipes: AssemblyOffer.summaries(office: office),
            encode: { AssemblyOffer.presetDefault($0, parameters: $1, office: office) },
            decode: { AssemblyOffer.presetSelection($0) }
        )
    }
}
