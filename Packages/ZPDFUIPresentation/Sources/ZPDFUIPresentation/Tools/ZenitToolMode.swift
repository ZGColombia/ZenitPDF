import Foundation

/// What the armed tool *is*, in one vocabulary.
///
/// Before this type there were two parallel notions of "which tool is armed":
/// `ZenitToolIdentifier` in the toolbar, which the canvas read exactly once (to arm the
/// zoom marquee), and `MeasurementKind` in the measurement presenter, which was the only
/// thing the canvas actually obeyed. Arming Text, Callout or Shapes therefore set the
/// toolbar's idea of the tool and *nothing* the canvas could see, so the canvas stayed in
/// Select while the chip glowed.
///
/// One value now carries the whole answer, and both families are cases of it, so
/// "the toolbar shows X and the canvas does Y" is no longer expressible.
public enum ZenitToolMode: Sendable, Hashable, Codable {

    /// Pointer: click selects, drag marquees.
    case select
    /// Hand: drag moves the page.
    case pan
    /// Marquee zoom: click steps in, `⌥`-click steps out, drag zooms to the rectangle.
    case zoom
    /// Two-point scale calibration.
    case calibrate
    /// One of the twenty-two measurement tools — Length, Area, the Measure palette,
    /// Count and Cutout all live here.
    case measure(MeasurementKind)
    /// One of the markup tools — Text, Callout and the seven Shapes.
    case markup(MarkupKind)

    /// The measurement kind this mode arms, or `nil` when it is not a measurement.
    public var measurementKind: MeasurementKind? {
        guard case .measure(let kind) = self else { return nil }
        return kind
    }

    /// The markup kind this mode arms, or `nil` when it is not a markup tool.
    public var markupKind: MarkupKind? {
        guard case .markup(let kind) = self else { return nil }
        return kind
    }

    /// The name the status bar shows while the tool is armed.
    ///
    /// The rule for every tool: arming a tool must be visible
    /// and true — the toolbar shows it, the status bar names it, the cursor changes.
    public var displayName: String {
        switch self {
        case .select: return NSLocalizedString("Select", comment: "Armed tool name")
        case .pan: return NSLocalizedString("Pan", comment: "Armed tool name")
        case .zoom: return NSLocalizedString("Zoom", comment: "Armed tool name")
        case .calibrate: return NSLocalizedString("Calibrate", comment: "Armed tool name")
        case .measure(let kind): return kind.displayName
        case .markup(let kind): return kind.displayName
        }
    }

    /// The seven shapes the Shapes palette offers, in palette order.
    public static let shapePalette: [MarkupKind] = [
        .rectangle, .ellipse, .line, .arrow, .polyline, .polygon, .cloud
    ]

    /// Whether a markup kind can actually be drawn by the Shapes palette, Text or Callout.
    ///
    /// The `MarkupKind` enum is the frozen contract's full list, which includes families
    /// no tool in the product arms yet (stamps, images, hyperlinks, text-anchored markup).
    /// Arming one of those must say so rather than draw something else.
    public static func isDrawable(_ kind: MarkupKind) -> Bool {
        kind == .text || kind == .callout || shapePalette.contains(kind) || annotationPalette.contains(kind)
    }

    /// The annotation tools the Shapes palette offers below the seven shapes (round 2, markup
    /// unit): Pen (NL-MARKUP-06), Note and Hyperlink (NL-MARKUP-17).
    public static let annotationPalette: [MarkupKind] = [.freehand, .note, .hyperlink]

    /// A one-line, honest statement of what this tool will **not** do yet, or `nil` when
    /// the tool is complete.
    ///
    /// If a tool is not implemented yet, it must say so when armed rather than doing
    /// something else — an honest "not implemented" beats a polygon nobody asked for. The
    /// status bar shows this beside the tool name.
    ///
    /// **Maintenance rule:** finishing a tool means deleting its line here in the same
    /// change. A stale note is a lie in the opposite direction.
    public var limitationNote: String? {
        switch self {
        case .select, .pan, .zoom, .calibrate:
            return nil
        case .markup(let kind):
            guard Self.isDrawable(kind) else {
                return NSLocalizedString(
                    "Not implemented: this markup type cannot be drawn yet.",
                    comment: "Status bar note for an armed markup tool with no gesture"
                )
            }
            return nil
        case .measure(let kind):
            switch kind {
            // The five parameter-hungry tools used to declare themselves unfinished here,
            // because `setParameters` had no caller and the commit vanished in silence.
            // The tool options bar collects the value now, so the note
            // is gone — per the maintenance rule above, finishing a tool means deleting
            // its line. What replaces it is *conditional* and therefore not expressible
            // here: while the field is still empty the status bar shows
            // `MeasurementParameterRequirement.missingValueNote`, which names the value
            // instead of apologising for the tool.
            case .polygonCutout, .ellipseCutout:
                // No longer a limitation: the cutout resolves its parent area from its
                // first vertex and commits through `DocumentCommand.addCutout`. What the
                // note says now is the *precondition*, which is the one thing about this
                // tool a user cannot guess.
                return NSLocalizedString(
                    "Draw inside an existing area: the cutout becomes a hole in it and its net value drops.",
                    comment: "Status bar note for the cutout tools"
                )
            default:
                return nil
            }
        }
    }
}

/// Everything that travels from the toolbar to the canvas when a tool is armed.
///
/// One value, one setter, one callback. `ZenitToolbarModel` stores exactly this and derives
/// its chip highlighting from it, so a tool cannot be armed in the toolbar without the
/// canvas hearing about it.
///
/// Reuse Tool is deliberately **not** here: it is a live user setting on the Tool Library
/// presenter and the status bar, read at the moment a tool commits. Copying it into the
/// armed selection would freeze whatever it happened to be when the tool was armed.
public struct ZenitToolSelection: Sendable, Hashable {

    /// What the tool is.
    public var mode: ZenitToolMode
    /// The Tool Library preset the tool was armed from, when it came from one.
    public var presetID: UUID?
    /// A variant of the armed markup kind — the highlighter on Pen, the clouded callout on
    /// Cloud — or `nil` for the kind's plain tool (round 2, markup unit).
    public var variant: MarkupToolVariant?
    /// The stroke/fill/font the committed markup takes.
    public var style: ToolStyleSelection
    /// The count symbol a count preset chose, by name.
    public var countSymbolName: String?

    /// Creates a selection.
    public init(
        mode: ZenitToolMode = .select,
        presetID: UUID? = nil,
        style: ToolStyleSelection = .zenitInk,
        countSymbolName: String? = nil,
        variant: MarkupToolVariant? = nil
    ) {
        self.mode = mode
        self.presetID = presetID
        self.variant = variant
        self.style = style
        self.countSymbolName = countSymbolName
    }

    /// The pointer tool, unstyled — the state a window opens in.
    public static let select = ZenitToolSelection()
}

/// The drawing style an armed tool hands to the markup it commits.
///
/// A presentation-tier mirror of the contract's `MarkupStyle`: this package has no
/// dependencies by design, so the app-core tier converts it. Only the fields a tool preset
/// can actually set are here.
public struct ToolStyleSelection: Sendable, Hashable, Codable {

    /// Stroke colour.
    public var stroke: ColorRGBA
    /// Fill colour for closed shapes, or `nil` for no fill.
    public var fill: ColorRGBA?
    /// Stroke width in PDF points.
    public var lineWidth: Double
    /// Font family for text-bearing markups.
    public var fontName: String
    /// Font size in PDF points.
    public var fontSize: Double
    /// Solid, dashed, dotted, dash-dot, cloud — or `nil` for the kind's own default (a Cloud
    /// draws scallops, everything else solid). nl-markup, NL-MARKUP-04.
    public var lineStyle: MarkupLineStyle?
    /// Whole-markup opacity, 0…1.
    public var opacity: Double
    /// The start decoration of an open markup, or `nil` for the kind's default.
    public var startCap: MarkupLineCap?
    /// The end decoration of an open markup, or `nil` for the kind's default (an Arrow's head,
    /// a Callout leader's open arrow).
    public var endCap: MarkupLineCap?
    /// The text's horizontal alignment, or `nil` for leading.
    public var textAlignment: MarkupTextAlignment?
    /// Whether the ink multiplies with the drawing — the highlighter (ADR-0029).
    public var multiplyBlend: Bool
    /// A clouded outline's scallop radius in PDF points, or `nil` for automatic (ADR-0029).
    public var cloudArcSize: Double?
    /// Bold text (ADR-0029).
    public var bold: Bool
    /// Italic text (ADR-0029).
    public var italic: Bool
    /// The text colour, or `nil` for the stroke colour (ADR-0029).
    public var textColor: ColorRGBA?
    /// Whether a Text box draws a border (ADR-0029).
    public var boxBorder: Bool

    /// Creates a style.
    public init(
        stroke: ColorRGBA,
        fill: ColorRGBA? = nil,
        lineWidth: Double = 1.5,
        fontName: String = "Helvetica",
        fontSize: Double = 11,
        lineStyle: MarkupLineStyle? = nil,
        opacity: Double = 1,
        startCap: MarkupLineCap? = nil,
        endCap: MarkupLineCap? = nil,
        textAlignment: MarkupTextAlignment? = nil,
        multiplyBlend: Bool = false,
        cloudArcSize: Double? = nil,
        bold: Bool = false,
        italic: Bool = false,
        textColor: ColorRGBA? = nil,
        boxBorder: Bool = false
    ) {
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineStyle = lineStyle
        self.opacity = opacity
        self.startCap = startCap
        self.endCap = endCap
        self.textAlignment = textAlignment
        self.multiplyBlend = multiplyBlend
        self.cloudArcSize = cloudArcSize
        self.bold = bold
        self.italic = italic
        self.textColor = textColor
        self.boxBorder = boxBorder
    }

    private enum CodingKeys: String, CodingKey {
        case stroke, fill, lineWidth, fontName, fontSize, lineStyle, opacity, startCap, endCap, textAlignment
        case multiplyBlend, cloudArcSize, bold, italic, textColor, boxBorder
    }

    /// Writes only the fields a style uses, so a style saved by this build without the round-2
    /// fields reads the same in an older build.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stroke, forKey: .stroke)
        try container.encodeIfPresent(fill, forKey: .fill)
        try container.encode(lineWidth, forKey: .lineWidth)
        try container.encode(fontName, forKey: .fontName)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encodeIfPresent(lineStyle, forKey: .lineStyle)
        try container.encode(opacity, forKey: .opacity)
        try container.encodeIfPresent(startCap, forKey: .startCap)
        try container.encodeIfPresent(endCap, forKey: .endCap)
        try container.encodeIfPresent(textAlignment, forKey: .textAlignment)
        if multiplyBlend { try container.encode(true, forKey: .multiplyBlend) }
        try container.encodeIfPresent(cloudArcSize, forKey: .cloudArcSize)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
        try container.encodeIfPresent(textColor, forKey: .textColor)
        if boxBorder { try container.encode(true, forKey: .boxBorder) }
    }

    /// Decodes a style, reading a value saved before nl-markup (stroke, fill, width, font)
    /// with today's defaults for the fields it did not have.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            stroke: try container.decode(ColorRGBA.self, forKey: .stroke),
            fill: try container.decodeIfPresent(ColorRGBA.self, forKey: .fill),
            lineWidth: try container.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 1.5,
            fontName: try container.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica",
            fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 11,
            lineStyle: try container.decodeIfPresent(MarkupLineStyle.self, forKey: .lineStyle),
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            startCap: try container.decodeIfPresent(MarkupLineCap.self, forKey: .startCap),
            endCap: try container.decodeIfPresent(MarkupLineCap.self, forKey: .endCap),
            textAlignment: try container.decodeIfPresent(MarkupTextAlignment.self, forKey: .textAlignment),
            multiplyBlend: try container.decodeIfPresent(Bool.self, forKey: .multiplyBlend) ?? false,
            cloudArcSize: try container.decodeIfPresent(Double.self, forKey: .cloudArcSize),
            bold: try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false,
            italic: try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false,
            textColor: try container.decodeIfPresent(ColorRGBA.self, forKey: .textColor),
            boxBorder: try container.decodeIfPresent(Bool.self, forKey: .boxBorder) ?? false
        )
    }

    /// The highlighter's style: a wide, translucent yellow stroke that multiplies with the
    /// drawing (NL-MARKUP-06). A default only; the person's own highlighter style wins.
    public static let highlighter = ToolStyleSelection(
        stroke: ColorRGBA(red: 1, green: 0.84, blue: 0.0, alpha: 1),
        lineWidth: 12,
        opacity: 0.4,
        startCap: MarkupLineCap.none,
        endCap: MarkupLineCap.none,
        multiplyBlend: true
    )

    /// The Zenit ink — the `#1A55CF` blue of the 2026-09-23 mockup, the same default the
    /// measurement tools commit with, so markup and measurement tools share one default —
    /// with the matching 20 % fill for closed shapes. It replaced the `#50D6DE` cyan, which
    /// measured about 1.6:1 against the white sheet (design round d7, decided
    /// 2026-09-23). A default only: a stored markup keeps its colour.
    public static let zenitInk = ToolStyleSelection(
        stroke: ColorRGBA(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 1),
        fill: ColorRGBA(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 0.20)
    )
}


/// A variant of a markup tool that is not a markup kind of its own (round 2, markup unit).
///
/// A highlighter is a freehand stroke with a highlighter style (ADR-0029 §2.5); a clouded
/// callout is a cloud carrying a leader and a text box (ADR-0029 §2.4). Neither is a new
/// contract kind, so the tool names the kind it commits and says how it differs.
public enum MarkupToolVariant: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Pen with the highlighter style.
    case highlighter
    /// Cloud with a leader and a text box, drawn by one drag.
    case cloudedCallout

    public var id: String { rawValue }

    /// The markup kind the variant commits.
    public var kind: MarkupKind {
        switch self {
        case .highlighter: .freehand
        case .cloudedCallout: .cloud
        }
    }

    /// The name the palette and the status bar show.
    public var displayName: String {
        switch self {
        case .highlighter: NSLocalizedString("Highlighter", comment: "Markup tool: freehand highlighter")
        case .cloudedCallout: NSLocalizedString("Clouded Callout", comment: "Markup tool: a cloud with a leader and a text box")
        }
    }
}
