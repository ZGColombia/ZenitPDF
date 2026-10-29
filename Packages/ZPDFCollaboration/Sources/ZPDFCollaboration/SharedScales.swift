import Foundation
import ZPDFContracts

/// A page's scale as the Shared Review Folder carries it (NL-COLLAB-12, round 2).
///
/// Scale changes are operations like any other: a person calibrates a sheet, the change is
/// published, and every participant installs the same transform on the same page — then
/// recomputes every measurement on that page **locally**, from geometry and scale. Values never
/// travel; that is what keeps two machines' ledgers identical.
///
/// The matrix, unit policy, label and source travel. The picked calibration points do not: they
/// are evidence of a calibration that happened on one machine, and citing them on another would be
/// a calibration that did not happen there — the same rule a scale copied to another page follows.
public struct SharedPageScale: Codable, Hashable, Sendable {
    public var pageID: PageID
    public var matrix: AffineScaleMatrix
    public var units: ScaleUnitPolicy
    public var label: String?
    public var source: ScaleSource

    public init(pageID: PageID, matrix: AffineScaleMatrix, units: ScaleUnitPolicy, label: String?, source: ScaleSource) {
        self.pageID = pageID
        self.matrix = matrix
        self.units = units
        self.label = label
        self.source = source
    }

    /// The page scale a session holds, as shared; `nil` for a scale with no page.
    public init?(scale: ScaleTransform) {
        guard let page = scale.pageID else { return nil }
        self.init(pageID: page, matrix: scale.matrix, units: scale.units, label: scale.label, source: scale.source)
    }

    /// Whether two page scales measure alike: the same transform under the same label. The unit
    /// policy and the source are how a scale is shown and where it came from, not what it measures.
    public func measuresLike(_ other: SharedPageScale) -> Bool {
        pageID == other.pageID && matrix == other.matrix && label == other.label
    }

    /// The transform to install on this machine: the shared matrix under the local page scale's
    /// identity (so it replaces the page's scale rather than adding a second one), one version on.
    public func transform(replacing local: ScaleTransform?) -> ScaleTransform {
        ScaleTransform(
            id: local?.id ?? ScaleID(UUID()), pageID: pageID, version: (local?.version ?? 0) + 1,
            matrix: matrix, units: units, source: source, label: label)
    }
}
