import Foundation

/// What the pointer must look like over the canvas, named by the **verb** rather than by the
/// tool.
///
/// # The defect this type exists to make unrepresentable
///
/// Apply and Place deliberately disarm both drawing families — a brush that also armed Area
/// would draw a new area on the first click that missed a markup. The consequence was that the
/// canvas fell back to the Select cursor, so the pointer told the estimator *"this click
/// selects"* while the next click was about to write properties onto forty markups or drop a
/// stamp. The status bar said otherwise; the pointer is what a person looks at.
///
/// The cursor is therefore resolved from two things at once — the armed tool **and** the armed
/// set's mode — in one total function, so "armed in Place, drawn as Select" has no spelling.
/// The rule shared by every tool already says the cursor must change when a tool is armed; a
/// mode is a tool as far as that rule is concerned.
public enum CanvasCursorKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Pointer. A click selects, a drag marquees.
    case select
    /// Open hand. A drag moves the page.
    case pan
    /// Crosshair over the zoom marquee.
    case zoom
    /// Crosshair. A click places a vertex of something new.
    case draw
    /// A brush over a crosshair. A click writes the armed preset's properties onto the markup
    /// underneath, and changes no geometry.
    case apply
    /// A stamp over a crosshair. A click drops a complete copy of the armed preset's markup.
    case place

    /// Stable identity.
    public var id: String { rawValue }

    /// The cursor for an armed tool and the mode its set is in.
    ///
    /// - Parameters:
    ///   - tool: what the canvas has armed right now.
    ///   - setMode: the mode of the set the armed preset belongs to
    ///     (``ToolLibraryPresenting/armedSetMode``).
    ///   - hasArmedPreset: whether a preset is actually armed. Without one there is nothing to
    ///     apply and nothing to place, so the mode is ignored and the tool decides alone —
    ///     which is exactly the rule `armedSetMode` already follows.
    public static func resolve(
        tool: ZenitToolMode,
        setMode: ToolSetMode,
        hasArmedPreset: Bool
    ) -> CanvasCursorKind {
        // BH-281: Pan and Zoom own the click — the canvas routes the press to the pan drag or
        // the zoom marquee before a preset could ever be applied or placed — so their cursor
        // wins over an armed preset. The stamp badge used to promise a drop the click never made.
        switch tool {
        case .pan: return .pan
        case .zoom: return .zoom
        default: break
        }
        if hasArmedPreset {
            switch setMode {
            case .apply: return .apply
            case .place: return .place
            case .draw: break
            }
        }
        switch tool {
        case .select: return .select
        case .pan: return .pan
        case .zoom: return .zoom
        case .calibrate, .measure, .markup: return .draw
        }
    }

    /// A localized description of what a click will do, for VoiceOver and for the help tag.
    ///
    /// Every cursor has one. A pointer shape is a signal a screen-reader user never receives,
    /// so the same sentence has to exist in words.
    public var verbDescription: String {
        switch self {
        case .select:
            return NSLocalizedString(
                "Click selects; drag marquees.",
                comment: "What a click does with the Select cursor"
            )
        case .pan:
            return NSLocalizedString(
                "Drag moves the page.",
                comment: "What a drag does with the Pan cursor"
            )
        case .zoom:
            return NSLocalizedString(
                "Click zooms in; drag zooms to the rectangle.",
                comment: "What a click does with the Zoom cursor"
            )
        case .draw:
            return NSLocalizedString(
                "Click places a point.",
                comment: "What a click does with a drawing cursor"
            )
        case .apply:
            return NSLocalizedString(
                "Click writes this tool's properties onto the markup underneath.",
                comment: "What a click does with the Apply cursor"
            )
        case .place:
            return NSLocalizedString(
                "Click drops a copy of this tool's markup.",
                comment: "What a click does with the Place cursor"
            )
        }
    }

    /// The SF Symbol badged onto the crosshair for the two mode cursors, or `nil` when the
    /// platform's own cursor is the right one.
    ///
    /// Kept here rather than in the AppKit layer so the table of verbs and the table of
    /// pictures cannot drift apart, and so a test can assert both without importing AppKit.
    public var badgeSymbolName: String? {
        switch self {
        case .select, .pan, .zoom, .draw: return nil
        case .apply: return "paintbrush.pointed.fill"
        case .place: return "plus.app.fill"
        }
    }
}
