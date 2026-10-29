import Foundation
import ZPDFContracts
import ZPDFUIPresentation

extension DocumentCommand {

    /// "Add Area", "Add Count", "Add Cloud": the add names what was added (L-09).
    ///
    /// It said "Add Markup" for everything, so undoing an Area measurement read "Undid Add
    /// Markup" — in the Edit menu, the undo toast and the History pane. A measurement or a count
    /// is named by its tool, as the palette names it; any other markup by its kind.
    static func addActionName(for record: ZPDFContracts.MarkupRecord) -> String {
        let name = record.tool.map { Shown.Kind(domain: $0).displayName }
            ?? Shown.Markup(domain: record.kind).displayName
        return String(
            format: NSLocalizedString(
                "undo.addMarkup.named",
                value: "Add %@",
                comment: "Undo action name for adding a markup; the placeholder is its tool or kind, such as Area, Count or Cloud"
            ),
            name
        )
    }
}
