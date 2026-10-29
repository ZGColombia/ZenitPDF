import Foundation

/// The decoration at one end of an open markup — a line, an arrow, a polyline, a callout's
/// leader (nl-markup, NL-MARKUP-07).
///
/// The presentation tier's mirror of the contract's `LineCapStyle`, like ``MarkupLineStyle``:
/// the UI packages describe what they show without importing the domain, and `AppCore`
/// translates.
public enum MarkupLineCap: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case openArrow
    case closedArrow
    case circle
    case square
    case diamond
    case slash
    case butt
    case round

    public var id: String { rawValue }

    /// The ends a menu offers. `butt` and `round` are stroke ends a file can carry, drawn
    /// faithfully, but not offered: next to "None" they read as the same choice.
    public static let offered: [MarkupLineCap] = [.none, .closedArrow, .openArrow, .circle, .square, .diamond, .slash]

    /// The name a person picks from a menu.
    public var displayName: String {
        switch self {
        case .none: return NSLocalizedString("None", comment: "Line end: no decoration")
        case .openArrow: return NSLocalizedString("Open Arrow", comment: "Line end")
        case .closedArrow: return NSLocalizedString("Arrow", comment: "Line end: filled arrowhead")
        case .circle: return NSLocalizedString("Dot", comment: "Line end: filled circle")
        case .square: return NSLocalizedString("Square", comment: "Line end")
        case .diamond: return NSLocalizedString("Diamond", comment: "Line end")
        case .slash: return NSLocalizedString("Tick", comment: "Line end: a short 45 degree slash")
        case .butt: return NSLocalizedString("Flat", comment: "Line end: flat stroke end")
        case .round: return NSLocalizedString("Round", comment: "Line end: round stroke end")
        }
    }
}

/// Horizontal alignment of a markup's text (nl-markup, NL-MARKUP-08). Mirrors the contract's
/// `TextAlignment`.
public enum MarkupTextAlignment: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case leading
    case center
    case trailing
    case justified

    public var id: String { rawValue }

    /// The name a person picks from a menu.
    public var displayName: String {
        switch self {
        case .leading: return NSLocalizedString("Left", comment: "Text alignment")
        case .center: return NSLocalizedString("Centre", comment: "Text alignment")
        case .trailing: return NSLocalizedString("Right", comment: "Text alignment")
        case .justified: return NSLocalizedString("Justified", comment: "Text alignment")
        }
    }

    /// The SF Symbol for a segmented control.
    public var symbolName: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        case .justified: return "text.justify"
        }
    }
}

/// The type families the markup text controls offer: faces that ship with every supported
/// macOS, so a project opened on another Mac draws the same letters (NL-MARKUP-08).
public enum MarkupFontFamilies {

    /// The stored name that means the interface's system face.
    public static let system = "System"

    /// Every offered family, in menu order.
    public static let all: [String] = [
        system, "Helvetica", "Helvetica Neue", "Arial", "Avenir Next",
        "Times New Roman", "Georgia", "Courier New", "Menlo"
    ]

    /// The menu title of a stored family name.
    public static func displayName(_ family: String) -> String {
        family == system
            ? NSLocalizedString("System", comment: "Font family: the interface's own face")
            : family
    }
}

extension ToolStyleSelection {

    /// The whole look of a markup, as a tool style: what *Set as Default* captures
    /// (NL-MARKUP-04) and what a preset captured from a selection carries (NL-MARKUP-15).
    public init(markup: MarkupSummary) {
        self.init(
            stroke: markup.colorRGBA,
            fill: markup.fillRGBA,
            lineWidth: markup.lineWidth,
            fontName: markup.fontName ?? "Helvetica",
            fontSize: markup.fontSize,
            lineStyle: markup.lineStyle,
            opacity: markup.opacity,
            startCap: markup.startCap,
            endCap: markup.endCap,
            textAlignment: markup.textAlignment,
            // Round 2 (ADR-0029): the rest of the look a preset or a default carries.
            multiplyBlend: markup.multiplyBlend ?? false,
            cloudArcSize: markup.cloudArcSize,
            bold: markup.bold ?? false,
            italic: markup.italic ?? false,
            textColor: markup.textColorRGBA,
            boxBorder: markup.boxBorder ?? false
        )
    }
}
