import Foundation
import Observation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The three questions the drawing's own geometry can answer (NL-AUTO-24).
public enum GeometryQueryKind: String, CaseIterable, Identifiable, Sendable {
    /// Circles of a radius — downlights, sprinklers, columns.
    case circles
    /// Straight lines of a length.
    case lines
    /// Pairs of parallel lines a distance apart — wall faces.
    case parallelPairs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .circles: return NSLocalizedString("Circles of radius", comment: "Geometry query kind")
        case .lines: return NSLocalizedString("Lines of length", comment: "Geometry query kind")
        case .parallelPairs: return NSLocalizedString("Parallel lines apart by", comment: "Geometry query kind")
        }
    }

    /// Whether the matches can become a quantity. Parallel pairs are highlights only: two faces
    /// facing each other are not a measured wall and must never be totalled.
    public var canCount: Bool { self == .circles }
    public var canMeasure: Bool { self == .lines }
}

/// What a query found, as the panel shows it.
public struct GeometryQueryPanelResult: Hashable, Sendable {
    public let matchBounds: [PDFRectValue]
    public let truncated: Bool
    /// A refusal in words (a nonsense value), or `nil`.
    public let refusal: String?

    public init(matchBounds: [PDFRectValue], truncated: Bool, refusal: String? = nil) {
        self.matchBounds = matchBounds
        self.truncated = truncated
        self.refusal = refusal
    }
}

/// Drives the geometry query panel: ask, see highlights, and — only for circles and lines —
/// commit the matches as a count or as lengths. A search result is a highlight until a person
/// commits it.
@MainActor @Observable
public final class GeometryQueryPanelModel {

    public var kind: GeometryQueryKind = .circles { didSet { result = nil } }
    public var valueText = ""
    public var toleranceText = ""
    /// The unit values are entered in: "mm" on a calibrated page, "pt" on one that is not.
    public let unitLabel: String
    public private(set) var result: GeometryQueryPanelResult?
    public private(set) var isRunning = false

    @ObservationIgnored private let onRun: @MainActor (GeometryQueryKind, Double, Double) async -> GeometryQueryPanelResult
    @ObservationIgnored private let onCommit: @MainActor (GeometryQueryKind) -> Void
    @ObservationIgnored private let onClose: @MainActor () -> Void

    public init(
        unitLabel: String,
        onRun: @escaping @MainActor (GeometryQueryKind, Double, Double) async -> GeometryQueryPanelResult,
        onCommit: @escaping @MainActor (GeometryQueryKind) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.unitLabel = unitLabel
        self.onRun = onRun
        self.onCommit = onCommit
        self.onClose = onClose
    }

    /// The entered value, read by the one decimal rule every Zenit field uses.
    public var value: Double? { ZPDFDecimalParser.decimal(valueText).map { NSDecimalNumber(decimal: $0).doubleValue } }
    /// The tolerance, defaulting to 2 % of the value when left empty.
    public var tolerance: Double? {
        if toleranceText.trimmingCharacters(in: .whitespaces).isEmpty { return value.map { $0 * 0.02 } }
        return ZPDFDecimalParser.decimal(toleranceText).map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    public var canRun: Bool { !isRunning && (value ?? 0) > 0 && (tolerance ?? -1) >= 0 }

    public func run() async {
        guard canRun, let value, let tolerance else { return }
        isRunning = true
        result = await onRun(kind, value, tolerance)
        isRunning = false
    }

    public var matchCount: Int { result?.matchBounds.count ?? 0 }

    public var canCommit: Bool { matchCount > 0 && (kind.canCount || kind.canMeasure) && result?.refusal == nil }

    /// "Count These" for circles, "Measure These" for lines.
    public func commit() {
        guard canCommit else { return }
        onCommit(kind)
    }

    public func close() { onClose() }

    public var resultText: String? {
        guard let result else { return nil }
        if let refusal = result.refusal { return refusal }
        var text = String(
            format: NSLocalizedString("%d found, highlighted on the sheet.", comment: "Geometry query result count"),
            result.matchBounds.count
        )
        if result.truncated {
            text += " " + NSLocalizedString(
                "The search stopped at its limit; there may be more.",
                comment: "Geometry query truncated"
            )
        }
        if kind == .parallelPairs, !result.matchBounds.isEmpty {
            text += " " + NSLocalizedString(
                "Parallel pairs are highlights only: two facing lines are not a measured wall.",
                comment: "Geometry query: parallel pairs cannot be committed"
            )
        }
        return text
    }
}
