import Foundation

/// What a click does while a tool set is active.
///
/// A set is in exactly one mode at a time. The mode belongs to the *set*, not to the preset:
/// "these forty areas are all Foundation" is a decision about how the estimator is working
/// right now, and making it per-preset would mean re-making it for every tool in the set.
///
/// The three modes are not three tools. They are three answers to one question — *what does
/// the next click mean?* — and keeping them in one closed enumeration is what lets the canvas
/// be total over them rather than growing a fourth silent path.
public enum ToolSetMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// The next drawing gesture creates a new markup carrying every stored property.
    ///
    /// The everyday case, and the default: *measure the next wall as an exterior wall*.
    case draw

    /// The preset is a brush. Clicking an existing markup writes the preset's properties onto
    /// it, over a whole multi-selection in one action.
    ///
    /// Re-classifying after the fact is most of a real takeoff review, and it is the one thing
    /// a drawing tool cannot do at all.
    case apply

    /// A single click drops a complete copy of the preset's markup at that point, with no
    /// drawing gesture. Stamps, symbols, count marks, detail bubbles, revision tags.
    case place

    /// Stable identity.
    public var id: String { rawValue }

    /// What a set is in until somebody changes it.
    public static let `default`: ToolSetMode = .draw

    /// A localized name for the mode switch and for VoiceOver.
    public var displayName: String {
        switch self {
        case .draw: return NSLocalizedString("Draw", comment: "Tool set mode")
        case .apply: return NSLocalizedString("Apply", comment: "Tool set mode")
        case .place: return NSLocalizedString("Place", comment: "Tool set mode")
        }
    }

    /// One line saying what the next click will do, for the switch's help and the status bar.
    public var shortHelp: String {
        switch self {
        case .draw:
            return NSLocalizedString(
                "Draw a new markup with this tool's properties.",
                comment: "Tool set mode help"
            )
        case .apply:
            return NSLocalizedString(
                "Click a markup to write this tool's properties onto it. Geometry is never changed.",
                comment: "Tool set mode help"
            )
        case .place:
            return NSLocalizedString(
                "Click once to drop a copy of this tool's markup.",
                comment: "Tool set mode help"
            )
        }
    }

    /// Whether the mode collects a drawing gesture. Only Draw does; the other two spend a
    /// single click and are done.
    public var collectsDrawingGesture: Bool { self == .draw }
}
