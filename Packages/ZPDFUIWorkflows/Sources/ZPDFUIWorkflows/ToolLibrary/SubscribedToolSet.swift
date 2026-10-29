import Foundation
import ZPDFUIPresentation

/// The one rule for "a tool a subscription owns" (NL-PLAT-15).
///
/// The application lists the office's subscribed tool sets in Imported Libraries, read-only,
/// with ``categorySuffix`` on the set's name so it reads "Office (read-only)". A refresh puts
/// every subscribed tool back, so removing one would last only until the application next came
/// to the front; those tools are edited by duplicating them into My Tools, never removed.
///
/// X-031: the rule lives here, below the application, because the Tool Library's Remove needs
/// it — a set imported by hand is read-only too, and it used to be impossible to remove. The
/// application's subscription reader asks this type, so the two cannot disagree on which tools
/// are subscribed.
public enum SubscribedToolSet {

    /// The suffix every subscribed tool's set carries.
    public static let categorySuffix = "(read-only)"

    /// Whether a subscription owns `preset`: read-only, in Imported Libraries, and in a set
    /// whose name carries ``categorySuffix``.
    public static func owns(_ preset: ToolPresetSummary) -> Bool {
        preset.panel == .importedLibraries && preset.isReadOnly && preset.category.hasSuffix(categorySuffix)
    }
}
