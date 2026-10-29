import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Maps presentation-layer enumerations onto the design system's icon vocabulary.
///
/// The presentation package deliberately stores plain SF Symbol *names* so its value types stay
/// free of AppKit. The design system speaks in `ZPDFGlyph`. This enum covers the markup and
/// workflow vocabularies; the measurement table it used to own now lives in the design system as
/// `ZPDFIconKind.init(measurementKind:)`, shared with the toolbar and the tool options bar.
public enum WorkflowGlyphs {

    /// The Zenit-drawn measurement glyph for a measurement tool.
    public static func glyph(for kind: MeasurementKind) -> ZPDFGlyph {
        .measurement(for: kind)
    }

    /// The glyph for a preset: its measurement tool when it has one, otherwise a generic
    /// markup action symbol.
    public static func glyph(for preset: ToolPresetSummary) -> ZPDFGlyph {
        if let measurementKind = preset.measurementKind {
            return glyph(for: measurementKind)
        }
        return glyph(for: preset.markupKind)
    }

    /// A generic action glyph for a markup family.
    ///
    /// Exhaustive, with no `default`: a new markup family must choose its glyph or fail to
    /// compile. The `default` that stood here hid ten families and drew highlight, underline
    /// and strikeout — which mark *text* — as shapes. Finding BH-845.
    public static func glyph(for kind: MarkupKind) -> ZPDFGlyph {
        switch kind {
        case .text, .highlight, .underline, .strikeout: return .symbol(.text)
        case .callout, .note: return .symbol(.callout)
        case .measurement: return .symbol(.measure)
        case .count: return .measurement(.count)
        case .stamp, .image: return .symbol(.shapes)
        case .hyperlink: return .symbol(.info)
        case .issue: return .symbol(.warning)
        case .revisionCloud, .cloud: return .symbol(.revisionCompare)
        case .freehand, .line, .arrow, .polyline, .rectangle, .ellipse, .polygon: return .symbol(.shapes)
        }
    }

    /// The catalogue glyph for a tool set's mode.
    ///
    /// From ``ZPDFSymbol`` rather than from an SF Symbol name, so the three modes are drawn out
    /// of the same catalogue as every other control in the product and cannot drift into a
    /// symbol nobody vetted.
    public static func glyph(for mode: ToolSetMode) -> ZPDFGlyph {
        switch mode {
        case .draw: return .symbol(.shapes)
        case .apply: return .symbol(.options)
        case .place: return .symbol(.add)
        }
    }

    /// The severity a Tool Library panel row should be spoken with.
    public static func glyph(for panel: ToolLibraryPanel) -> ZPDFGlyph {
        switch panel {
        case .myTools: return .symbol(.toolLibrary)
        case .projectTools: return .symbol(.pages)
        case .recent: return .symbol(.undo)
        case .favorites: return .symbol(.success)
        case .sequences: return .symbol(.layers)
        case .countSymbols: return .measurement(.count)
        case .importedLibraries: return .symbol(.open)
        }
    }
}
