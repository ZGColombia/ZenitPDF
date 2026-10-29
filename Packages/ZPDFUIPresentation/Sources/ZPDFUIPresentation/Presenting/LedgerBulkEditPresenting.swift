import Foundation

/// A change to a markup's appearance, stated as "only these fields".
///
/// Every field is optional and `nil` means **leave it alone**, which is what lets one edit reach a
/// selection the user has not made uniform: setting the line width of twelve markups in three
/// colours must not also make them one colour.
///
/// `color` on ``LedgerBulkEditRequest`` predates this and stays where it is — the ledger's bulk
/// edit sheet writes it — so a request can carry either or both. They compose: both end up in the
/// same `.changeStyle` command per markup.
public struct MarkupStyleEdit: Hashable, Sendable {

    /// Stroke colour.
    public var color: ColorRGBA?
    /// Stroke width in page points.
    public var lineWidth: Double?
    /// Stroke opacity, 0…1.
    public var opacity: Double?
    /// Solid, dashed, dotted, dash-dot, cloud.
    public var lineStyle: MarkupLineStyle?
    /// Point size of the markup's text.
    public var fontSize: Double?
    /// Fill colour to set. `nil` leaves the fill alone; use ``removesFill`` to clear it.
    public var fill: ColorRGBA?
    /// Clears the fill, making the markup unfilled. Ignored when ``fill`` is set.
    public var removesFill: Bool
    /// The decoration at the first vertex of an open markup (nl-markup, NL-MARKUP-07).
    public var startCap: MarkupLineCap?
    /// The decoration at the last vertex of an open markup.
    public var endCap: MarkupLineCap?
    /// The text's font family (nl-markup, NL-MARKUP-08).
    public var fontName: String?
    /// The text's horizontal alignment.
    public var textAlignment: MarkupTextAlignment?
    /// Bold text (ADR-0029, NL-MARKUP-08).
    public var bold: Bool?
    /// Italic text (ADR-0029).
    public var italic: Bool?
    /// The text colour to set. `nil` leaves it alone; use ``removesTextColor`` to go back to
    /// the stroke colour.
    public var textColor: ColorRGBA?
    /// Returns the text to the stroke colour. Ignored when ``textColor`` is set.
    public var removesTextColor: Bool = false
    /// Whether a Text box draws its border (ADR-0029).
    public var boxBorder: Bool?
    /// A clouded outline's scallop radius in page points (ADR-0029, NL-MARKUP-16).
    public var cloudArcSize: Double?
    /// Returns the scallops to the automatic size. Ignored when ``cloudArcSize`` is set.
    public var resetsCloudArcSize: Bool = false
    /// The rotation about the box centre in degrees (ADR-0029, NL-MARKUP-18).
    public var rotationDegrees: Double?

    public init(
        color: ColorRGBA? = nil,
        lineWidth: Double? = nil,
        opacity: Double? = nil,
        lineStyle: MarkupLineStyle? = nil,
        fontSize: Double? = nil,
        fill: ColorRGBA? = nil,
        removesFill: Bool = false,
        startCap: MarkupLineCap? = nil,
        endCap: MarkupLineCap? = nil,
        fontName: String? = nil,
        textAlignment: MarkupTextAlignment? = nil
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.lineStyle = lineStyle
        self.fontSize = fontSize
        self.fill = fill
        self.removesFill = removesFill
        self.startCap = startCap
        self.endCap = endCap
        self.fontName = fontName
        self.textAlignment = textAlignment
    }

    /// Whether the edit names no field at all.
    public var isEmpty: Bool {
        color == nil && lineWidth == nil && opacity == nil && lineStyle == nil && fontSize == nil
            && fill == nil && !removesFill
            && startCap == nil && endCap == nil && fontName == nil && textAlignment == nil
            && bold == nil && italic == nil && textColor == nil && !removesTextColor && boxBorder == nil
            && cloudArcSize == nil && !resetsCloudArcSize && rotationDegrees == nil
    }
}

/// One bulk edit, stated as a value before anything is written.
///
/// The panel builds this, the app tier turns it into document commands, and the test
/// suite drives it without a view existing. Keeping it a value is what lets the
/// confirmation the user reads and the mutation the engine performs be the same object.
public struct LedgerBulkEditRequest: Hashable, Sendable {

    /// The markups the edit applies to.
    public var markupIDs: Set<UUID>
    /// The cells being written, keyed by column. A column absent here is left alone —
    /// that is how a field the selection disagrees about stays mixed.
    public var values: [LedgerColumnID: LedgerCellValue]
    /// A colour to write onto every selected markup, or `nil` to leave colours alone.
    public var color: ColorRGBA?
    /// Appearance fields to write. Empty leaves appearance alone. See ``MarkupStyleEdit``.
    public var style: MarkupStyleEdit
    /// The Edit-menu name of the step, when the caller knows a better verb than the fields
    /// do ("Paste Style"). `nil` derives the name from the fields (nl-markup).
    public var actionName: String?

    /// Creates a request.
    public init(
        markupIDs: Set<UUID>,
        values: [LedgerColumnID: LedgerCellValue] = [:],
        color: ColorRGBA? = nil,
        style: MarkupStyleEdit = MarkupStyleEdit(),
        actionName: String? = nil
    ) {
        self.markupIDs = markupIDs
        self.values = values
        self.color = color
        self.style = style
        self.actionName = actionName
    }

    /// Whether applying the request would do nothing.
    public var isEmpty: Bool {
        markupIDs.isEmpty || (values.isEmpty && color == nil && style.isEmpty)
    }
}

/// What a bulk edit actually did, after it ran.
///
/// Returned rather than published so the panel can state the outcome in the same breath
/// as the confirmation it showed beforehand — "applies 3 fields to 12 markups" followed
/// by "changed 11, one is locked" is a far better failure than eleven silent successes.
public struct LedgerBulkEditReceipt: Hashable, Sendable {

    /// Markups the engine actually changed.
    public var changedMarkupIDs: Set<UUID>
    /// Audit entries appended. ADR-0007 §2 wants one per affected markup.
    public var auditEntryCount: Int
    /// The name that appears after "Undo" in the Edit menu.
    public var undoActionName: String
    /// The engine's own description of a refusal, when the edit was refused whole.
    public var failureDescription: String?

    /// Creates a receipt.
    public init(
        changedMarkupIDs: Set<UUID> = [],
        auditEntryCount: Int = 0,
        undoActionName: String = "",
        failureDescription: String? = nil
    ) {
        self.changedMarkupIDs = changedMarkupIDs
        self.auditEntryCount = auditEntryCount
        self.undoActionName = undoActionName
        self.failureDescription = failureDescription
    }

    /// Whether the edit was refused.
    public var didFail: Bool { failureDescription != nil }

    /// A receipt for an edit that was refused before anything was written.
    public static func failure(_ description: String) -> LedgerBulkEditReceipt {
        LedgerBulkEditReceipt(failureDescription: description)
    }
}

/// A ledger presenter that can write one bulk edit as a single undoable step.
///
/// Reached by a conditional cast from `any LedgerPresenting`, exactly as
/// ``LedgerAuditPresenting`` is: the shell keeps one presenter reference and a presenter
/// that cannot service bulk edits simply is not cast, so the panel disables Apply rather
/// than the shell growing a second presenter it has to keep in step.
@MainActor
public protocol LedgerBulkEditPresenting: LedgerPresenting {

    /// Applies the request. One undo entry for the whole batch, one audit entry per
    /// affected markup (ADR-0007 §2).
    func applyBulkEdit(_ request: LedgerBulkEditRequest) async -> LedgerBulkEditReceipt
}
