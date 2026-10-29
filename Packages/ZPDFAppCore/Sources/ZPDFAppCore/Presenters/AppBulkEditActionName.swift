import Foundation
import ZPDFUIPresentation

/// The Edit-menu name of one bulk edit, derived from what the request changes (NL-UX-12).
///
/// Every Inspector edit goes through the ledger's bulk-edit path, so every one of them used to
/// read "Undo Bulk Edit" — one colour on one markup included. The name now says what Cmd-Z is
/// about to take back:
///
/// - one kind of field: that field's verb — "Change Colour", "Change Line Width", "Change
///   Status", "Edit Label";
/// - several appearance fields and nothing else: "Change Appearance";
/// - anything wider (the ledger panel's multi-field apply): "Bulk Edit", as before, because
///   naming one field of a step that also rewrote four others is a lie about the step;
/// - more than one markup: the count is appended to a named step — "Change Colour (12 Markups)".
extension AppCoreEnvironment {

    /// One field kind a bulk edit can change, for naming.
    enum BulkEditField: Hashable, CaseIterable {
        case colour, lineWidth, opacity, lineStyle, textSize, fill
        case lineEnds, font, alignment
        case textFormat, arcSize, rotation
        case status, subject, label, notes, customValue

        var isAppearance: Bool {
            switch self {
            case .colour, .lineWidth, .opacity, .lineStyle, .textSize, .fill,
                 .lineEnds, .font, .alignment, .textFormat, .arcSize, .rotation: return true
            default: return false
            }
        }

        var actionName: String {
            switch self {
            case .colour:
                return NSLocalizedString("Change Colour", comment: "Undo action name: markup colour changed")
            case .lineWidth:
                return NSLocalizedString("Change Line Width", comment: "Undo action name: markup line width changed")
            case .opacity:
                return NSLocalizedString("Change Opacity", comment: "Undo action name: markup opacity changed")
            case .lineStyle:
                return NSLocalizedString("Change Line Style", comment: "Undo action name: markup line style changed")
            case .textSize:
                return NSLocalizedString("Change Text Size", comment: "Undo action name: markup text size changed")
            case .fill:
                return NSLocalizedString("Change Fill", comment: "Undo action name: markup fill changed or removed")
            case .lineEnds:
                return NSLocalizedString("Change Line Ends", comment: "Undo action name: markup line ends (arrowheads) changed")
            case .font:
                return NSLocalizedString("Change Font", comment: "Undo action name: markup text font changed")
            case .alignment:
                return NSLocalizedString("Change Alignment", comment: "Undo action name: markup text alignment changed")
            case .textFormat:
                return NSLocalizedString("Change Text Format", comment: "Undo action name: bold, italic, text colour or box border changed")
            case .arcSize:
                return NSLocalizedString("Change Arc Size", comment: "Undo action name: a cloud's scallop size changed")
            case .rotation:
                return NSLocalizedString("Rotate", comment: "Undo action name: markups rotated")
            case .status:
                return NSLocalizedString("Change Status", comment: "Undo action name for a batch status change")
            case .subject:
                return NSLocalizedString("Edit Subject", comment: "Undo action name for renaming a markup's subject")
            case .label:
                return NSLocalizedString("Edit Label", comment: "Undo action name for rewriting a markup's label")
            case .notes:
                return NSLocalizedString("Edit Notes", comment: "Undo action name for rewriting a markup's comment (the Inspector's Notes)")
            case .customValue:
                return NSLocalizedString("Edit Value", comment: "Undo action name for editing a ledger cell")
            }
        }
    }

    /// The field kinds a request touches.
    static func fields(of request: LedgerBulkEditRequest) -> Set<BulkEditField> {
        var fields = Set<BulkEditField>()
        if request.color != nil || request.style.color != nil { fields.insert(.colour) }
        if request.style.lineWidth != nil { fields.insert(.lineWidth) }
        if request.style.opacity != nil { fields.insert(.opacity) }
        if request.style.lineStyle != nil { fields.insert(.lineStyle) }
        if request.style.fontSize != nil { fields.insert(.textSize) }
        if request.style.fill != nil || request.style.removesFill { fields.insert(.fill) }
        if request.style.startCap != nil || request.style.endCap != nil { fields.insert(.lineEnds) }
        if request.style.fontName != nil { fields.insert(.font) }
        if request.style.textAlignment != nil { fields.insert(.alignment) }
        if request.style.bold != nil || request.style.italic != nil || request.style.textColor != nil
            || request.style.removesTextColor || request.style.boxBorder != nil { fields.insert(.textFormat) }
        if request.style.cloudArcSize != nil || request.style.resetsCloudArcSize { fields.insert(.arcSize) }
        if request.style.rotationDegrees != nil { fields.insert(.rotation) }
        for key in request.values.keys {
            switch key {
            case .status: fields.insert(.status)
            case .subject: fields.insert(.subject)
            case .label: fields.insert(.label)
            case .comment: fields.insert(.notes)
            default: if key.isCustom { fields.insert(.customValue) }
            }
        }
        return fields
    }

    /// The Edit-menu name of a bulk edit over `markupCount` markups.
    public static func undoActionName(for request: LedgerBulkEditRequest, markupCount: Int) -> String {
        let fields = fields(of: request)
        let base: String
        // A caller that knows the verb better — Paste Style — names the step itself.
        if let named = request.actionName, !named.isEmpty {
            base = named
        } else if fields.count == 1, let only = fields.first {
            base = only.actionName
        } else if !fields.isEmpty, fields.allSatisfy(\.isAppearance) {
            base = NSLocalizedString("Change Appearance", comment: "Undo action name: several appearance fields of markups changed")
        } else {
            // The ledger panel's multi-field apply keeps its name, without a count: it is the
            // step the confirmation already counted for the reviewer.
            return bulkEditUndoActionName
        }
        guard markupCount > 1 else { return base }
        return String(
            format: NSLocalizedString(
                "%1$@ (%2$ld Markups)",
                comment: "Undo action name with the number of markups it covers, e.g. Change Colour (12 Markups)"
            ),
            base,
            markupCount
        )
    }
}
