import Foundation

/// How a measurement's geometry was captured: drawn by a person, or proposed by a detector and
/// accepted by one (NL-AUTO-18, ADR-0031).
///
/// Carried on ``MeasurementProvenance/captureMethod``. Absent means ``Kind/manual`` — the only
/// way any measurement was captured before ADR-0031 — so every stored record decodes unchanged,
/// the same pattern ADR-0012 used for quantity provenance. A detector records what it assumed:
/// the gaps it bridged, the residual of a symbol match, the confidence of a scan. That is what
/// makes an automated quantity defensible in front of a client: every number says whether a
/// person or a detector drew it, and on what evidence.
///
/// The capture method describes the **geometry**, not the calculation. It survives a
/// recalculation (a new scale, a new formula version) for as long as the geometry is the one it
/// describes, and falls back to ``Kind/manual`` the moment a person edits that geometry.
///
/// A flat value type with optional fields rather than an enum with payloads, so the frozen
/// document can describe every field and a newer kind survives an older reader as text.
public struct CaptureMethod: Codable, Hashable, Sendable {

    /// The capture kinds this build writes. Stored as text.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Drawn point by point by a person.
        case manual
        /// Traced from the drawing's vector linework, possibly bridging gaps the person confirmed.
        case autoTraced
        /// Found by matching a boxed example symbol.
        case symbolMatched
        /// Found as an exact repeat of a CAD block (the same form drawing).
        case exactBlock
        /// Detected as a room by the whole-page room detector.
        case roomDetected
        /// Captured from a scanned (raster) sheet, not from vector linework.
        case fromScan
        /// A wall's centreline chained from a parallel pair of lines.
        case wallCentreline
        /// Read from a measurement annotation in a PDF file (NL-MEASURE-16): the geometry is the
        /// file's, the number is Zenit's own, measured again at the page's scale.
        case importedAnnotation
        /// Written by a newer build with a kind this one does not know. Never written for a
        /// capture this build made; it keeps an older reader from calling a detector's work a
        /// person's, and from refusing the whole record.
        case unrecognised

        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: text) ?? .unrecognised
        }
    }

    public var kind: Kind
    /// For ``Kind/autoTraced``: how many gaps the trace bridged with closing lines.
    public var bridgedGapCount: Int?
    /// For ``Kind/autoTraced``: the widest bridged gap, in PDF points.
    public var largestGapPoints: Double?
    /// For ``Kind/autoTraced``: the width of each closing line the person confirmed, in PDF points.
    public var closureWidthsPoints: [Double]?
    /// For ``Kind/symbolMatched``: the match residual, 0 for a perfect match.
    public var residualRatio: Double?
    /// For ``Kind/symbolMatched``: whether the match is the example's mirror image.
    public var isMirrored: Bool?
    /// For ``Kind/symbolMatched``: the match's scale relative to the example.
    public var matchScale: Double?
    /// For ``Kind/symbolMatched`` and ``Kind/exactBlock``: the digest of the example matched.
    public var exemplarDigest: String?
    /// For ``Kind/fromScan``: the detector's confidence, 0 to 1.
    public var confidence: Double?
    /// For ``Kind/wallCentreline``: the wall thickness the pair was chained at, in metres.
    public var wallThicknessMetres: Decimal?

    public init(
        kind: Kind,
        bridgedGapCount: Int? = nil,
        largestGapPoints: Double? = nil,
        closureWidthsPoints: [Double]? = nil,
        residualRatio: Double? = nil,
        isMirrored: Bool? = nil,
        matchScale: Double? = nil,
        exemplarDigest: String? = nil,
        confidence: Double? = nil,
        wallThicknessMetres: Decimal? = nil
    ) {
        self.kind = kind
        self.bridgedGapCount = bridgedGapCount
        self.largestGapPoints = largestGapPoints
        self.closureWidthsPoints = closureWidthsPoints
        self.residualRatio = residualRatio
        self.isMirrored = isMirrored
        self.matchScale = matchScale
        self.exemplarDigest = exemplarDigest
        self.confidence = confidence
        self.wallThicknessMetres = wallThicknessMetres
    }

    /// Drawn by a person.
    public static let manual = CaptureMethod(kind: .manual)

    /// Traced, with the closing lines a person confirmed.
    public static func autoTraced(closureWidthsPoints: [Double]) -> CaptureMethod {
        CaptureMethod(kind: .autoTraced, bridgedGapCount: closureWidthsPoints.count,
                      largestGapPoints: closureWidthsPoints.max(), closureWidthsPoints: closureWidthsPoints)
    }
}

extension MeasurementProvenance {

    /// The capture method in force: the recorded one, or ``CaptureMethod/manual`` when none was
    /// recorded (ADR-0031: absent means manual).
    public var capture: CaptureMethod { captureMethod ?? .manual }

    /// The same derivation with another capture method.
    public func with(captureMethod: CaptureMethod?) -> MeasurementProvenance {
        MeasurementProvenance(
            geometryDigest: geometryDigest, scaleID: scaleID, scalePageID: scalePageID, scaleVersion: scaleVersion,
            scaleSource: scaleSource, calibrationEvidence: calibrationEvidence, slope: slope, parameters: parameters,
            formulaVersion: formulaVersion, engineVersion: engineVersion, computedAt: computedAt, layerName: layerName,
            captureMethod: captureMethod)
    }
}
