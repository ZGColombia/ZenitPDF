import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// Edit ▸ Copy Style / Paste Style (NL-UX-08): take the look of one markup — colour, fill,
/// width, opacity, line style, text size — and give it to others in one undo step.
///
/// The clipboard is the application's, not the pasteboard: a style is not something another
/// program can use, and keeping it off the pasteboard leaves Copy (rows) and Copy Snippet
/// (picture) untouched.
@MainActor
enum StyleClipboard {

    /// The copied look, or `nil`.
    static var copied: MarkupStyleEdit?

    /// A paste the bulk-edit bus refused, carrying its sentence.
    struct Refusal: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The style edit that reproduces a markup's look exactly, fill removal included.
    static func style(of markup: MarkupSummary) -> MarkupStyleEdit {
        MarkupStyleEdit(
            color: markup.colorRGBA,
            lineWidth: markup.lineWidth,
            opacity: markup.opacity,
            lineStyle: markup.lineStyle,
            fontSize: markup.fontSize,
            fill: markup.fillRGBA,
            removesFill: markup.fillRGBA == nil,
            // nl-markup (NL-MARKUP-09): the ends, font and alignment travel too; the bulk edit
            // skips each field a target kind cannot hold (`MarkupStyleFit`).
            startCap: markup.startCap,
            endCap: markup.endCap,
            fontName: markup.fontName,
            textAlignment: markup.textAlignment
        )
    }

    /// Copies the look of the single selected markup. Returns whether a style was taken.
    @discardableResult
    static func copy(from core: AppCoreEnvironment) -> Bool {
        let selected = core.canvas.selectedMarkupIDs
        guard selected.count == 1, let id = selected.first,
              let markup = core.snapshot.markups.first(where: { $0.id == id }) else { return false }
        copied = style(of: markup)
        return true
    }

    /// Gives the copied look to the selection, through the bulk-edit bus: one undo step, named
    /// for what changed, refused whole over a locked markup.
    static func paste(into core: AppCoreEnvironment) async -> LedgerBulkEditReceipt? {
        guard let copied, !core.canvas.selectedMarkupIDs.isEmpty else { return nil }
        return await core.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: core.canvas.selectedMarkupIDs,
            style: copied,
            actionName: NSLocalizedString("Paste Style", comment: "Undo action name: a copied markup style given to the selection")
        ))
    }
}
