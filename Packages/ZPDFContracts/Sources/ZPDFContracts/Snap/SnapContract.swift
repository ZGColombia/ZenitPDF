import Foundation

/// The kind of geometric primitive stored in a page's snap index (spec 13.4).
///
/// Curves are stored **as curves**; flattening happens only for indexing and hit testing, so a
/// snap onto a curve returns the exact point on the curve rather than a point on a chord.
public enum PrimitiveKind: String, Codable, Hashable, Sendable, CaseIterable {
    case point
    case segment
    case polyline
    case cubicCurve
    case quadraticCurve
    case rectangle
    case circle
    case ellipticalArc
}

/// The geometry behind a ``SnapPrimitive``, in canonical PDF page space with the object matrix
/// and every parent form transform already applied (spec 13.4).
public enum PrimitiveGeometry: Codable, Hashable, Sendable {
    case point(PDFPoint)
    case segment(SegmentGeometry)
    case polyline(points: [PDFPoint], isClosed: Bool)
    /// A cubic Bezier: start, two controls, end.
    case cubicCurve(start: PDFPoint, control1: PDFPoint, control2: PDFPoint, end: PDFPoint)
    /// A quadratic Bezier: start, one control, end.
    case quadraticCurve(start: PDFPoint, control: PDFPoint, end: PDFPoint)
    case rectangle(PDFRect)
    case circle(CircleGeometry)
    case ellipticalArc(ArcGeometry)

    public var kind: PrimitiveKind {
        switch self {
        case .point: .point
        case .segment: .segment
        case .polyline: .polyline
        case .cubicCurve: .cubicCurve
        case .quadraticCurve: .quadraticCurve
        case .rectangle: .rectangle
        case .circle: .circle
        case .ellipticalArc: .ellipticalArc
        }
    }
}

/// One entry in a page's packed R-tree of snappable geometry (spec 13.5).
///
/// The spec sketch types `bounds` as `CGRect`. It is a ``PDFRect`` here instead: `CGRect` is a
/// view-space type with a top-left convention in flipped views, and the snap index is strictly
/// page space, bottom-left origin. Storing a view type would be the first step towards a zoom
/// value reaching the measurement engine.
public struct SnapPrimitive: Codable, Hashable, Sendable {
    /// Index-local identity, dense and small so the R-tree stays compact. Not a UUID: this is
    /// derived cache data, rebuilt from the PDF whenever the cache key changes.
    public let id: UInt64
    /// Axis-aligned bounds in page space, used as the R-tree key.
    public let bounds: PDFRect
    public let kind: PrimitiveKind
    public let geometry: PrimitiveGeometry
    /// The id of the painted path this came from, when it came from PDF content (spec 13.4):
    /// the vector extractor (`CGPDFScanner`, ZPDFVectorExtraction) numbers every painted path
    /// of a page and stamps its primitives with that number, so all primitives of one path can
    /// be found again. `nil` for markup, zone and calibration geometry. (BH-485: the earlier
    /// wording named a page-object id from a PDF library this program does not contain.)
    public let sourceObjectID: UInt64?
    /// 0...1. Lower for primitives recovered from flattened or heuristically filtered content.
    public let confidence: Float
    /// Optional layer (OCG) identity, used by the active-layer term of the candidate score.
    public let layerID: String?

    public init(
        id: UInt64,
        bounds: PDFRect,
        kind: PrimitiveKind,
        geometry: PrimitiveGeometry,
        sourceObjectID: UInt64? = nil,
        confidence: Float = 1.0,
        layerID: String? = nil
    ) {
        self.id = id
        self.bounds = bounds
        self.kind = kind
        self.geometry = geometry
        self.sourceObjectID = sourceObjectID
        self.confidence = confidence
        self.layerID = layerID
    }

    /// True when the stored `kind` agrees with the stored geometry. A mismatch means the index
    /// was built wrong, and the loader rejects the cache rather than snapping to nonsense.
    public var isConsistent: Bool { kind == geometry.kind }
}

/// The snap types the product offers (spec 13.1).
public enum SnapKind: String, Codable, Hashable, Sendable, CaseIterable {
    case endpoint
    case midpoint
    case intersection
    case nearestPointOnSegment
    case perpendicularProjection
    case parallelGuide
    case center
    case quadrant
    case tangent
    case grid
    case angleIncrement
    case markupVertex
    case markupEdge
    case markupCenter
    case pdfVectorContent
    case zoneBoundary
    case calibrationPoint

    /// The default priority order (spec 13.7): lower sorts first, and a lower number wins ties
    /// at equal screen distance.
    public var defaultPriority: Int {
        switch self {
        case .markupVertex: 0
        case .calibrationPoint: 1
        case .intersection: 2
        case .endpoint: 3
        case .midpoint: 4
        case .center: 5
        case .quadrant: 6
        case .tangent: 7
        case .perpendicularProjection: 8
        case .nearestPointOnSegment: 9
        case .markupEdge: 10
        case .markupCenter: 11
        case .zoneBoundary: 12
        case .pdfVectorContent: 13
        case .parallelGuide: 14
        case .angleIncrement: 15
        case .grid: 16
        }
    }

    /// True when the snap needs vector content on the page and is therefore unavailable on a
    /// scanned sheet (spec 13.11).
    public var requiresVectorContent: Bool {
        // Exhaustive on purpose (BH-492): a new kind must say whether a scanned sheet can offer
        // it, or the snap target generator drops it on every scanned page without a word.
        switch self {
        case .grid, .angleIncrement, .markupVertex, .markupEdge, .markupCenter,
             .zoneBoundary, .calibrationPoint, .parallelGuide:
            false
        case .endpoint, .midpoint, .intersection, .nearestPointOnSegment,
             .perpendicularProjection, .center, .quadrant, .tangent, .pdfVectorContent:
            true
        }
    }
}

/// Where a snap candidate's geometry came from (spec 13.2).
public enum SnapGeometrySource: String, Codable, Hashable, Sendable, CaseIterable {
    case pdfPathObject
    case pdfFormObject
    case zenitMarkup
    case zoneBoundary
    case scaleRegionBoundary
    case grid
    case temporaryGuide
}

/// A single scored snap candidate for the current cursor position (spec 13.7).
public struct SnapCandidate: Codable, Hashable, Sendable {
    public let kind: SnapKind
    /// The snapped position in page space.
    public let position: PDFPoint
    /// The primitive that produced it, when one did.
    public let primitiveID: UInt64?
    public let source: SnapGeometrySource
    /// Distance from the raw cursor to ``position``, in **logical screen pixels**. Scoring is in
    /// pixels because the user's sense of "near" is on screen, not on the sheet.
    public let screenDistancePixels: Double
    /// The primitive's confidence, carried through to the score.
    public let confidence: Float
    /// True when the candidate lies on the currently active layer.
    public let isOnActiveLayer: Bool
    /// True when the candidate satisfies an active direction constraint (Shift).
    public let satisfiesDirectionConstraint: Bool
    /// True when this candidate was the previous frame's winner and is being held by hysteresis
    /// (spec 13.9).
    public let isHeldByHysteresis: Bool
    /// The composed score. Lower is better.
    public let score: Double

    public init(
        kind: SnapKind,
        position: PDFPoint,
        primitiveID: UInt64? = nil,
        source: SnapGeometrySource,
        screenDistancePixels: Double,
        confidence: Float = 1.0,
        isOnActiveLayer: Bool = true,
        satisfiesDirectionConstraint: Bool = true,
        isHeldByHysteresis: Bool = false,
        score: Double
    ) {
        self.kind = kind
        self.position = position
        self.primitiveID = primitiveID
        self.source = source
        self.screenDistancePixels = screenDistancePixels
        self.confidence = confidence
        self.isOnActiveLayer = isOnActiveLayer
        self.satisfiesDirectionConstraint = satisfiesDirectionConstraint
        self.isHeldByHysteresis = isHeldByHysteresis
        self.score = score
    }
}

/// Snap radius and behaviour settings (spec 13.6, 13.8, 13.9).
///
/// Radii are in logical screen pixels and are converted to page points on every event, because
/// the zoom can change between two mouse moves.
public struct SnapSettings: Codable, Hashable, Sendable {
    /// Working radius, in logical screen pixels.
    public var defaultPixels: Double
    /// Floor the user can tune down to.
    public var minimumPixels: Double
    /// Ceiling the user can tune up to.
    public var maximumPixels: Double
    /// Extra distance the cursor must travel before the held candidate is released (spec 13.9).
    public var hysteresisPixels: Double
    /// Which snap kinds are live.
    public var enabledKinds: Set<SnapKind>
    /// Priority overrides; kinds absent here use ``SnapKind/defaultPriority``.
    public var priorityOverrides: [SnapKind: Int]
    /// Grid spacing in PDF points, when grid snap is enabled.
    public var gridSpacingPoints: Double
    /// Angle constraint increment in degrees, applied while Shift is held (spec 13.8).
    public var angleIncrementDegrees: Double
    /// Whether snapping is globally on. Command toggles it temporarily (spec 13.8).
    public var isEnabled: Bool

    public init(
        defaultPixels: Double = SnapSettings.specDefaultPixels,
        minimumPixels: Double = SnapSettings.specMinimumPixels,
        maximumPixels: Double = SnapSettings.specMaximumPixels,
        hysteresisPixels: Double = SnapSettings.specHysteresisPixels,
        enabledKinds: Set<SnapKind> = Set(SnapKind.allCases),
        priorityOverrides: [SnapKind: Int] = [:],
        gridSpacingPoints: Double = 36.0,
        angleIncrementDegrees: Double = 15.0,
        isEnabled: Bool = true
    ) {
        self.defaultPixels = defaultPixels
        self.minimumPixels = minimumPixels
        self.maximumPixels = maximumPixels
        self.hysteresisPixels = hysteresisPixels
        self.enabledKinds = enabledKinds
        self.priorityOverrides = priorityOverrides
        self.gridSpacingPoints = gridSpacingPoints
        self.angleIncrementDegrees = angleIncrementDegrees
        self.isEnabled = isEnabled
    }

    /// The frozen defaults from spec 13.6.
    public static let specDefaultPixels: Double = 10
    public static let specMinimumPixels: Double = 4
    public static let specMaximumPixels: Double = 24
    public static let specHysteresisPixels: Double = 4

    public static let `default` = SnapSettings()

    /// The effective priority of a kind under these settings.
    public func priority(of kind: SnapKind) -> Int {
        priorityOverrides[kind] ?? kind.defaultPriority
    }

    public func validate() throws {
        guard minimumPixels > 0,
              minimumPixels <= defaultPixels,
              defaultPixels <= maximumPixels else {
            throw SnapError.invalidRadiusRange(
                minimum: minimumPixels,
                preferred: defaultPixels,
                maximum: maximumPixels
            )
        }
        guard hysteresisPixels >= 0 else { throw SnapError.negativeHysteresis(hysteresisPixels) }
        if enabledKinds.contains(.grid), !(gridSpacingPoints > 0) {
            throw SnapError.nonPositiveGridSpacing(gridSpacingPoints)
        }
        if enabledKinds.contains(.angleIncrement),
           !(angleIncrementDegrees > 0 && angleIncrementDegrees <= 180) {
            throw SnapError.invalidAngleIncrement(degrees: angleIncrementDegrees)
        }
    }

    /// The radius clamped into the settings' own range.
    public func clampedRadiusPixels(_ pixels: Double) -> Double {
        Swift.min(maximumPixels, Swift.max(minimumPixels, pixels))
    }
}

/// The state a page's snap index can be in (spec 13.11).
public enum SnapAvailability: String, Codable, Hashable, Sendable, CaseIterable {
    /// Vector primitives are indexed and Vector Snap works.
    case vectorAvailable
    /// The page is a scan; only grid, markup and zone snapping are offered.
    case vectorUnavailableScannedPage
    /// The index is still being built.
    case indexing
    /// Index construction failed; the reason is carried alongside.
    case failed
}

extension SnapKind: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        ContractIdentifierCodingKey(stringValue: rawValue)
    }

    public init?<Key>(codingKey: Key) where Key: CodingKey {
        self.init(rawValue: codingKey.stringValue)
    }
}
