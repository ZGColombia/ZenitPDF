import Foundation
import ZPDFContracts
import ZPDFVectorExtraction

/// The state a page's snap index is in (`SNAP_CONTRACT` 13.11, `QUALITY_BAR` 3.6, S14).
///
/// `partial` is never presented as `available`: a truncated index reported as complete is the
/// failure mode that produces a confidently wrong snap. `unavailable` is a **normal** state —
/// grid, markup, zone, calibration and guide snapping all keep working on a scanned page, and
/// the engine emits no vector candidate for such a page at all.
///
/// The reason enums are `ZPDFVectorExtraction`'s, not re-declared here: the extractor is the
/// only thing that can know why geometry is missing, and two parallel vocabularies would drift.
public enum SnapIndexAvailability: Sendable, Hashable, Codable {

    /// The vector layer is still being extracted. The page is already usable: grid and markup
    /// snap are live and the UI reports Vector Snap as building (`QUALITY_BAR` S13).
    case building

    /// Extraction completed within budget and yielded at least one primitive after filtering.
    case available

    /// Extraction hit a budget or a known limitation. Vector Snap works on what was extracted
    /// and the UI must state that it is incomplete, with the reasons, ordered by severity.
    case partial([VectorPartialReason])

    /// Zero primitives after filtering — a scanned page, or a page whose only path was a
    /// filtered background rectangle.
    case unavailable(VectorUnavailableReason)

    /// Lifts the extractor's three-state contract into the index's four-state one.
    public init(_ availability: VectorAvailability, partialReasons: [VectorPartialReason] = []) {
        switch availability {
        case .available:
            self = .available
        case .partial(let reason):
            var reasons = partialReasons
            if !reasons.contains(reason) { reasons.append(reason) }
            self = .partial(reasons.sorted { $0.severityRank < $1.severityRank })
        case .unavailable(let reason):
            self = .unavailable(reason)
        }
    }

    /// `true` when a candidate whose `SnapKind.requiresVectorContent` is `true` may be emitted.
    ///
    /// This is the S14 gate. It is checked once per query and again per candidate, because
    /// "no vector candidate is ever emitted for that page" is an absolute.
    public var allowsVectorCandidates: Bool {
        switch self {
        case .available, .partial: true
        case .building, .unavailable: false
        }
    }

    /// A stable, locale-independent key the UI turns into user-facing wording.
    public var messageKey: String {
        switch self {
        case .building: "snap.vector.building"
        case .available: "snap.vector.available"
        case .partial(let reasons):
            "snap.vector.partial." + (reasons.first.map(Self.reasonKey) ?? "unknown")
        case .unavailable(let reason):
            switch reason {
            case .noVectorContent: "snap.vector.unavailable.noVectorContent"
            case .onlyFilteredGeometry: "snap.vector.unavailable.onlyFilteredGeometry"
            case .emptyContentStream: "snap.vector.unavailable.emptyContentStream"
            }
        }
    }

    private static func reasonKey(_ reason: VectorPartialReason) -> String {
        switch reason {
        case .budgetExceeded(let kind, _): "budgetExceeded.\(kind.name)"
        case .shadingGeometryNotExtracted: "shadingGeometryNotExtracted"
        case .type3GlyphGeometryNotExtracted: "type3GlyphGeometryNotExtracted"
        case .formNestingDepthExceeded: "formNestingDepthExceeded"
        case .cyclicFormReference: "cyclicFormReference"
        case .softMaskNotComposited: "softMaskNotComposited"
        case .malformedContentStream: "malformedContentStream"
        case .annotationAppearanceStreamsNotExtracted: "annotationAppearanceStreamsNotExtracted"
        case .inlineImageSkipped: "inlineImageSkipped"
        case .hiddenOptionalContentExcluded: "hiddenOptionalContentExcluded"
        }
    }
}
