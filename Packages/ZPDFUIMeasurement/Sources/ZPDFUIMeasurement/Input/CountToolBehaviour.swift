import Foundation
import ZPDFUIPresentation

// The Count tool's contract: one click places one count point. Each further click adds another
// point to the same count group, and the running total shows on screen while counting. Escape
// ends the group; clicking an existing point with ⌥ removes it. **It must never draw a
// polygon.**
//
// A polygon through count points is a *rendering* fact, not an arithmetic one: the live overlay
// strokes a path through the placed vertices whenever there are two or more of them
// (`CanvasPageView.drawLiveMeasurement`). Nothing in the input model ever said "these points
// are not a path", so the canvas had no way to know. ``MeasurementKind/isPointPlacement`` is
// that missing statement; the canvas reads it through ``ZenitToolGesture/isPointPlacement``
// instead of guessing.

extension MeasurementKind {

    /// Whether the tool's vertices are *independent placements* rather than a path.
    ///
    /// Count is the only such tool: its points are a set of marks, and stroking a line between
    /// them is not a stylistic choice but a lie about what was measured. Every renderer that
    /// draws in-progress geometry must consult this before joining two vertices.
    public var isPointPlacement: Bool { self == .count }

    /// Whether Escape *ends* the tool's work rather than throwing it away.
    ///
    /// A count group is finished, not cancelled: the estimator has placed twenty marks and
    /// wants them, so the key that means "I am done here" must commit. Every other tool keeps
    /// the two-stage Escape — discard the geometry, then disarm.
    public var endsGroupOnEscape: Bool { isPointPlacement }

    /// Whether the tool subtracts from a parent area and therefore needs one resolved before
    /// it can commit: a cutout is a hole in an existing area markup.
    public var requiresParentArea: Bool { isCutout }
}

// MARK: - Count symbols

/// The symbol drawn at every point of a count group.
///
/// The catalogue is closed and `Sendable` so that a preset, the input state and the renderer
/// all name the same mark. Only the SF Symbol name crosses into AppKit; the identity that
/// travels through the state machine and into the markup style is the `rawValue`.
public enum CountSymbol: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// A filled disc — the historical default, and what an unconfigured count still draws.
    case dot
    /// An open circle.
    case circle
    /// A filled square.
    case square
    /// A filled triangle.
    case triangle
    /// A diamond.
    case diamond
    /// A cross.
    case cross
    /// A star.
    case star
    /// A flag, for punch-list style counting.
    case flag

    public var id: String { rawValue }

    /// The shipped default.
    public static let `default` = CountSymbol.dot

    /// SF Symbol name the canvas and the palette draw.
    public var symbolName: String {
        switch self {
        case .dot: return "circle.fill"
        case .circle: return "circle"
        case .square: return "square.fill"
        case .triangle: return "triangle.fill"
        case .diamond: return "diamond.fill"
        case .cross: return "xmark"
        case .star: return "star.fill"
        case .flag: return "flag.fill"
        }
    }

    /// A localized name for the palette, the inspector and VoiceOver.
    public var displayName: String {
        switch self {
        case .dot: return NSLocalizedString("Dot", comment: "Count symbol name")
        case .circle: return NSLocalizedString("Circle", comment: "Count symbol name")
        case .square: return NSLocalizedString("Square", comment: "Count symbol name")
        case .triangle: return NSLocalizedString("Triangle", comment: "Count symbol name")
        case .diamond: return NSLocalizedString("Diamond", comment: "Count symbol name")
        case .cross: return NSLocalizedString("Cross", comment: "Count symbol name")
        case .star: return NSLocalizedString("Star", comment: "Count symbol name")
        case .flag: return NSLocalizedString("Flag", comment: "Count symbol name")
        }
    }
}

// MARK: - Running total

/// The running total of a count group, as VoiceOver hears it.
///
/// The input machine announces ``accessibilityLabel`` when ⌥-click takes a mark away. The
/// canvas caption draws its own "… placed" readout from the presenter's points
/// (`CanvasLiveState.displayedCaption` in the app); this value does not render it.
public struct CountRunningTotal: Hashable, Sendable {

    /// How many points are in the group so far.
    public let points: Int
    /// The symbol each of them is drawn with.
    public let symbol: CountSymbol

    public init(points: Int, symbol: CountSymbol = .default) {
        self.points = max(0, points)
        self.symbol = symbol
    }

    /// The short on-canvas string, for example `"7"`. The pill is small; the number carries it.
    public var displayText: String {
        NumberFormatter.localizedString(from: NSNumber(value: points), number: .none)
    }

    /// The spoken form, including the symbol so a blind estimator knows which group is open.
    public var accessibilityLabel: String {
        String(
            format: NSLocalizedString(
                "%1$@ counted, %2$@ symbol. Escape ends the group.",
                comment: "VoiceOver running total: number counted, symbol name"
            ),
            displayText,
            symbol.displayName
        )
    }
}

// MARK: - Presenter seam

// `CountPointEditing` — removing a count mark that is not the last one — is declared in
// ZPDFUIPresentation beside `MeasurementToolPresenting`, so the application core can adopt it
// without depending on this UI package (IM-019).
