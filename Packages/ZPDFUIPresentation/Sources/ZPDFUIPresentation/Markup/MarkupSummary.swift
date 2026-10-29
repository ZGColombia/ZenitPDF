import Foundation

/// The markup families Zenit can place on a page.
public enum MarkupKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Free text.
    case text
    /// Text with a leader line.
    case callout
    /// A sticky note.
    case note
    /// A text highlight.
    case highlight
    /// A text underline.
    case underline
    /// A text strikeout.
    case strikeout
    /// A freehand ink stroke.
    case freehand
    /// A straight line.
    case line
    /// A line with an arrowhead.
    case arrow
    /// An open multi-segment line.
    case polyline
    /// A rectangle.
    case rectangle
    /// An ellipse.
    case ellipse
    /// A closed polygon.
    case polygon
    /// A cloud outline.
    case cloud
    /// A stamp.
    case stamp
    /// An embedded image.
    case image
    /// A hyperlink region.
    case hyperlink
    /// A measurement produced by one of the measurement tools.
    case measurement
    /// A count group.
    case count
    /// A revision cloud.
    case revisionCloud
    /// A tracked issue.
    case issue

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for menus, the ledger and VoiceOver.
    public var displayName: String {
        switch self {
        case .text: return NSLocalizedString("Text", comment: "Markup type name")
        case .callout: return NSLocalizedString("Callout", comment: "Markup type name")
        case .note: return NSLocalizedString("Note", comment: "Markup type name")
        case .highlight: return NSLocalizedString("Highlight", comment: "Markup type name")
        case .underline: return NSLocalizedString("Underline", comment: "Markup type name")
        case .strikeout: return NSLocalizedString("Strikeout", comment: "Markup type name")
        case .freehand: return NSLocalizedString("Freehand", comment: "Markup type name")
        case .line: return NSLocalizedString("Line", comment: "Markup type name")
        case .arrow: return NSLocalizedString("Arrow", comment: "Markup type name")
        case .polyline: return NSLocalizedString("Polyline", comment: "Markup type name")
        case .rectangle: return NSLocalizedString("Rectangle", comment: "Markup type name")
        case .ellipse: return NSLocalizedString("Ellipse", comment: "Markup type name")
        case .polygon: return NSLocalizedString("Polygon", comment: "Markup type name")
        case .cloud: return NSLocalizedString("Cloud", comment: "Markup type name")
        case .stamp: return NSLocalizedString("Stamp", comment: "Markup type name")
        case .image: return NSLocalizedString("Image", comment: "Markup type name")
        case .hyperlink: return NSLocalizedString("Hyperlink", comment: "Markup type name")
        case .measurement: return NSLocalizedString("Measurement", comment: "Markup type name")
        case .count: return NSLocalizedString("Count", comment: "Markup type name")
        case .revisionCloud: return NSLocalizedString("Revision Cloud", comment: "Markup type name")
        case .issue: return NSLocalizedString("Issue", comment: "Markup type name")
        }
    }

    /// SF Symbol name for the ledger icon column and the canvas badge.
    public var symbolName: String {
        switch self {
        case .text: return "textformat"
        case .callout: return "bubble.left.and.text.bubble.right"
        case .note: return "note.text"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .freehand: return "scribble"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .polygon: return "pentagon"
        case .cloud: return "cloud"
        case .stamp: return "seal"
        case .image: return "photo"
        case .hyperlink: return "link"
        case .measurement: return "ruler"
        case .count: return "number.circle"
        case .revisionCloud: return "cloud.bolt"
        case .issue: return "exclamationmark.bubble"
        }
    }
}

/// Review state of a markup.
///
/// Status is always shown as text plus a glyph; the colour is a redundant cue only.
///
/// The same eight states as the document contract, with the same raw values (NL-COLLAB-03).
/// Until 2026-09-23 this mirror had six: the contract's `inProgress` was shown as "In Review",
/// `resolved` as "Completed" and `cancelled` as "Rejected", so one markup read "Cancelled" in
/// the ledger and "Rejected" in the Inspector, and picking "Rejected" on a cancelled markup
/// silently did nothing because the collapsed value already compared equal.
public enum MarkupStatus: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// No status has been set.
    case none
    /// Raised and awaiting work.
    case open
    /// Being worked on.
    case inProgress
    /// The raised issue has been dealt with and awaits confirmation.
    case resolved
    /// Reviewed and accepted.
    case accepted
    /// Reviewed and rejected.
    case rejected
    /// Withdrawn: it will not be built or answered.
    case cancelled
    /// Work finished.
    case completed

    /// Stable identity.
    public var id: String { rawValue }

    /// Reads a stored value, including the one older builds wrote for the in-progress state
    /// (`"inReview"`), which tool presets and tool-set files still carry.
    public init?(storedValue: String) {
        if storedValue == "inReview" {
            self = .inProgress
            return
        }
        self.init(rawValue: storedValue)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let status = MarkupStatus(storedValue: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown markup status \(raw)"
            ))
        }
        self = status
    }

    /// A localized status name. The same words the ledger's Status column uses.
    public var displayName: String {
        switch self {
        case .none: return NSLocalizedString("No Status", comment: "Markup review status")
        // Its own key: "Open" is also the verb (Open a document), which Swedish translates
        // differently ("Öppna" / "Öppen"), so one catalogue entry cannot carry both.
        case .open: return NSLocalizedString("status.open", value: "Open", comment: "Markup review status")
        case .inProgress: return NSLocalizedString("In Progress", comment: "Review status")
        case .resolved: return NSLocalizedString("Resolved", comment: "Review status")
        case .accepted: return NSLocalizedString("Accepted", comment: "Markup review status")
        case .rejected: return NSLocalizedString("Rejected", comment: "Markup review status")
        case .cancelled: return NSLocalizedString("Cancelled", comment: "Review status")
        case .completed: return NSLocalizedString("Completed", comment: "Markup review status")
        }
    }

    /// SF Symbol name that carries the meaning without relying on colour.
    public var symbolName: String {
        switch self {
        case .none: return "circle.dashed"
        case .open: return "circle"
        case .inProgress: return "clock"
        case .resolved: return "flag.checkered"
        case .accepted: return "checkmark.circle"
        case .rejected: return "xmark.circle"
        case .cancelled: return "slash.circle"
        case .completed: return "checkmark.seal"
        }
    }

    /// The palette token used as a redundant colour cue, dark appearance.
    public var indicatorColor: ColorRGBA {
        switch self {
        case .none, .cancelled: return ColorRGBA.Zenit.Dark.secondary
        case .open: return ColorRGBA.Zenit.Dark.blue
        case .inProgress: return ColorRGBA.Zenit.Dark.warning
        case .accepted: return ColorRGBA.Zenit.Dark.green
        case .rejected: return ColorRGBA.Zenit.Dark.danger
        case .resolved, .completed: return ColorRGBA.Zenit.Dark.cyan
        }
    }
}

/// How a markup's stroke is drawn.
///
/// The presentation tier's mirror of the contract's `LineStyle`, in the same spirit as
/// ``MarkupKind`` and ``ColorRGBA``: the UI packages describe what they show without importing
/// the domain. `AppCore` translates.
public enum MarkupLineStyle: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case solid
    case dashed
    case dotted
    case dashDot
    case cloud

    public var id: String { rawValue }

    /// The name a person picks from a menu.
    public var displayName: String {
        switch self {
        case .solid: return NSLocalizedString("Solid", comment: "Line style")
        case .dashed: return NSLocalizedString("Dashed", comment: "Line style")
        case .dotted: return NSLocalizedString("Dotted", comment: "Line style")
        case .dashDot: return NSLocalizedString("Dash-dot", comment: "Line style")
        case .cloud: return NSLocalizedString("Cloud", comment: "Line style")
        }
    }
}

/// A read-only view of one markup, sized for lists, the canvas and the inspector.
///
/// Everything the UI needs is denormalised into the summary so that rendering a
/// hundred-thousand-row ledger never issues a follow-up query.
public struct MarkupSummary: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the markup.
    public let id: UUID
    /// Markup family.
    public var kind: MarkupKind
    /// Which measurement tool produced it, or `nil` for non-measuring markups.
    public var measurementKind: MeasurementKind?
    /// Takeoff subject, the primary grouping key, for example `"Floor Screed"`.
    public var subject: String
    /// Short instance label, for example `"Office 101"`.
    public var label: String
    /// Free-text comment.
    public var comment: String
    /// Page label the markup lives on, for example `"A-101"`.
    public var pageLabel: String
    /// Identity of the page the markup lives on.
    public var pageID: PageDescriptor.ID
    /// Zero-based page index, kept for sorting.
    public var pageIndex: Int
    /// Name of the Project Zone the markup is assigned to, or `nil`.
    public var zone: String?
    /// Identity of the Project Zone, or `nil`.
    public var zoneID: UUID?
    /// Name of the Scale Region that governed the measurement, or `nil` for the page default.
    public var scaleRegionName: String?
    /// Review status.
    public var status: MarkupStatus
    /// Author display name.
    public var author: String
    /// Whether the markup is locked against edits.
    public var locked: Bool
    /// Whether the markup is hidden on the canvas.
    public var hidden: Bool
    /// Stroke colour.
    public var colorRGBA: ColorRGBA
    /// Fill colour, or `nil` for an unfilled markup (`MarkupStyle.fill`). Closed shapes and
    /// areas draw it on the canvas; the Inspector's Fill Colour row edits it.
    public var fillRGBA: ColorRGBA?
    /// The stroke width in page points.
    ///
    /// The Inspector could not show a line width until 2026-08-27, let alone change one, because
    /// this summary carried only the colour, so neither the colour nor the size of an arrow
    /// could be changed. `MarkupStyle` has held all of these since it was written; the
    /// presentation tier simply never carried them up.
    public var lineWidth: Double
    /// Stroke opacity, 0…1.
    public var opacity: Double
    /// Solid, dashed, dotted.
    public var lineStyle: MarkupLineStyle
    /// Point size of the markup's text, for the kinds that carry text.
    public var fontSize: Double
    /// Measured outputs, empty for non-measuring markups.
    public var measurementFields: [MeasurementFieldSummary]
    /// Markup layer name.
    public var layer: String?
    /// Creation timestamp.
    public var created: Date
    /// Last modification timestamp.
    public var modified: Date
    /// Bounds on the page, used to zoom to the markup from the ledger.
    public var boundsInPageSpace: PDFRectValue
    /// Parent markup for a cutout, or `nil`.
    public var parentID: UUID?
    /// The measurement parameters the markup was computed with, or `nil` when it has none.
    ///
    /// Here so that "make this a tool" can capture the *maths* and not only the ink.
    /// Dropping these on capture is precisely the mistake that makes a tool library feel
    /// useless, and without them on the summary the Tool Library — which
    /// never sees a `MarkupRecord` — had no way to avoid making it.
    public var measurementDefaults: ToolPresetMeasurementDefaults?

    /// The stamp template this markup was placed from, when it is a stamp.
    ///
    /// Only the template's identity, not its resolved text: the summary is what the batch
    /// planner asks *"does this page already carry the same stamp?"* of, once per markup,
    /// and identity is the whole of that question. The resolved values stay on the record.
    public var stampTemplateID: UUID?

    /// How many times this measurement repeats across the sheets it was applied to, or `nil`
    /// when nobody has said (feature 11).
    ///
    /// Derived, not stored: the count lives in the markup's reserved `Repeat ×` ledger cell,
    /// and `AppCore` reads it here so that the canvas, the inspector and every list can show
    /// the multiplier without any of them learning what a custom column is.
    ///
    /// `nil` means "not set", which counts as once. It is deliberately *not* defaulted to `1`:
    /// a row that has said nothing about repetition and a row that deliberately says once are
    /// different claims, and ``repetitionText`` shows a badge for neither.
    ///
    /// Optional and defaulted, so every existing construction of a summary compiles and decodes
    /// unchanged — the synthesized decoder reads an absent key for an `Optional` as `nil`.
    public var repeatCount: Int?

    /// The largest repeat count a markup can carry — the one bound the application's
    /// `RepetitionColumn.maximumCount` reads, and the Inspector's Repeat stepper's ceiling.
    /// X-021: the stepper stopped at 999 while the store held up to this, so one click on a
    /// markup stored at ×1500 asked for ×999.
    public static let maximumRepeatCount = 10_000

    /// The words a Text or Callout draws on the sheet, or `nil` for a kind that draws none
    /// (NL-COLLAB-18). Separate from ``comment``, which is the review note: before the split a
    /// note written on a text box rewrote the text drawn on the sheet. Optional and defaulted,
    /// so every existing construction compiles and decodes unchanged.
    public var drawnText: String?

    /// The stored start and end decorations (`MarkupStyle.startCap` / `endCap`), or `nil`
    /// when the producer did not carry them, which reads as none (nl-markup, NL-MARKUP-07).
    /// Optional and defaulted, so every existing construction compiles and decodes unchanged.
    public var startCap: MarkupLineCap?
    public var endCap: MarkupLineCap?
    /// The stored font family and text alignment (nl-markup, NL-MARKUP-08), `nil` when not
    /// carried.
    public var fontName: String?
    public var textAlignment: MarkupTextAlignment?
    /// Round 2 (ADR-0029): bold, italic, text colour and Text-box border; `nil` when not
    /// carried or plain. Optional and defaulted like the fields above.
    public var bold: Bool?
    public var italic: Bool?
    public var textColorRGBA: ColorRGBA?
    public var boxBorder: Bool?
    /// A clouded outline's stored scallop radius, `nil` for automatic.
    public var cloudArcSize: Double?
    /// The rotation about the box centre in degrees, `nil` for none.
    public var rotationDegrees: Double?
    /// The markup group, `nil` when ungrouped (NL-MARKUP-11).
    public var groupID: UUID?
    /// A hyperlink's web address, or its target page (NL-MARKUP-17).
    public var linkURL: String?
    public var linkPageID: UUID?
    /// Whether the ink multiplies — a highlighter stroke.
    public var multiplyBlend: Bool?
    /// The markup layer's identity (ADR-0032), `nil` when the producer did not carry it.
    public var layerID: UUID?
    /// Whether the markup's *layer* is hidden or locked (ADR-0032). ``hidden`` and ``locked``
    /// already include the layer's share; these say where it came from, so the Inspector can
    /// explain a lock the markup's own switch cannot lift. Optional and defaulted like the rest.
    public var layerHidden: Bool?
    public var layerLocked: Bool?

    /// Creates a markup summary.
    public init(
        id: UUID,
        kind: MarkupKind,
        measurementKind: MeasurementKind? = nil,
        subject: String,
        label: String,
        comment: String = "",
        pageLabel: String,
        pageID: PageDescriptor.ID,
        pageIndex: Int,
        zone: String? = nil,
        zoneID: UUID? = nil,
        scaleRegionName: String? = nil,
        status: MarkupStatus = .none,
        author: String,
        locked: Bool = false,
        hidden: Bool = false,
        colorRGBA: ColorRGBA,
        lineWidth: Double = 2,
        opacity: Double = 1,
        lineStyle: MarkupLineStyle = .solid,
        fontSize: Double = 12,
        measurementFields: [MeasurementFieldSummary] = [],
        layer: String? = nil,
        created: Date,
        modified: Date,
        boundsInPageSpace: PDFRectValue,
        parentID: UUID? = nil,
        measurementDefaults: ToolPresetMeasurementDefaults? = nil,
        stampTemplateID: UUID? = nil,
        repeatCount: Int? = nil,
        fillRGBA: ColorRGBA? = nil
    ) {
        self.id = id
        self.kind = kind
        self.measurementKind = measurementKind
        self.subject = subject
        self.label = label
        self.comment = comment
        self.pageLabel = pageLabel
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.zone = zone
        self.zoneID = zoneID
        self.scaleRegionName = scaleRegionName
        self.status = status
        self.author = author
        self.locked = locked
        self.hidden = hidden
        self.colorRGBA = colorRGBA
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.lineStyle = lineStyle
        self.fontSize = fontSize
        self.measurementFields = measurementFields
        self.layer = layer
        self.created = created
        self.modified = modified
        self.boundsInPageSpace = boundsInPageSpace
        self.parentID = parentID
        self.measurementDefaults = measurementDefaults
        self.stampTemplateID = stampTemplateID
        self.repeatCount = repeatCount
        self.fillRGBA = fillRGBA
    }

    /// The multiplier badge — `"×6"` — or `nil` for a markup that repeats once or not at all.
    ///
    /// Shown on the row, on the canvas pill and in the inspector. The rule is that a multiplier
    /// is never invisible: a total inflated six-fold with
    /// nothing on screen saying why is the failure this string exists to prevent. Which is also
    /// why it is `nil` at one — a `×1` on every row is noise, and noise is how the row that
    /// says `×6` stops being read.
    public var repetitionText: String? {
        guard let repeatCount, repeatCount > 1 else { return nil }
        let format = NSLocalizedString(
            "×%d",
            comment: "Repetition badge: the multiplication sign and how many times a measurement repeats"
        )
        return String(format: format, repeatCount)
    }

    /// The field a measurement tool considers its headline value, if present.
    public var primaryField: MeasurementFieldSummary? {
        guard let measurementKind else { return nil }
        return field(measurementKind.primaryField)
    }

    /// Looks up one measured field.
    public func field(_ field: MeasurementField) -> MeasurementFieldSummary? {
        measurementFields.first { $0.field == field }
    }

    /// The blocking and non-blocking warnings attached to any field, de-duplicated.
    public var warnings: [MeasurementWarningSummary] {
        var seen = Set<MeasurementWarningSummary>()
        var ordered: [MeasurementWarningSummary] = []
        for summary in measurementFields {
            guard let warning = summary.warning, seen.insert(warning).inserted else { continue }
            ordered.append(warning)
        }
        return ordered
    }

    /// A localized VoiceOver label: subject, label, page and headline quantity — plus the
    /// repetition count when there is one.
    ///
    /// A multiplier that is only a visual badge is invisible to a screen reader, and "invisible"
    /// is precisely what feature 11 may never be. The clause is appended only when the markup
    /// actually repeats, so every unrepeated markup reads exactly as it always did.
    public var accessibilityLabel: String {
        let quantity = primaryField?.displayTextWithUnit ?? ""
        let base: String
        if quantity.isEmpty {
            let format = NSLocalizedString(
                "%1$@, %2$@, page %3$@",
                comment: "VoiceOver label for a markup: subject, label, page label"
            )
            base = String(format: format, subject, label, pageLabel)
        } else {
            let format = NSLocalizedString(
                "%1$@, %2$@, %3$@, page %4$@",
                comment: "VoiceOver label for a measured markup: subject, label, quantity, page label"
            )
            base = String(format: format, subject, label, quantity, pageLabel)
        }
        guard let repeatCount, repeatCount > 1 else { return base }
        let repeated = NSLocalizedString(
            "%1$@, repeats %2$d times",
            comment: "VoiceOver suffix for a markup applied to several sheets: description, repeat count"
        )
        return String(format: repeated, base, repeatCount)
    }
}
