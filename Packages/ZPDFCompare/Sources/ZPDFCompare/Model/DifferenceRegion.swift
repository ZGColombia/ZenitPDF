import CoreGraphics
import Foundation

/// What happened in a region between the baseline and the revision.
public enum DifferenceClassification: String, Sendable, Hashable, Codable, CaseIterable {
    /// Ink present on the revision and absent on the baseline.
    case added
    /// Ink present on the baseline and absent on the revision.
    case removed
    /// Both: something was replaced, moved a little, or redrawn.
    case changed
    /// Within tolerance everywhere. Never emitted as a region — the value exists so a
    /// per-pixel or per-primitive classification can name it.
    case unchanged
}

/// Which of the two independent comparisons produced a region.
///
/// This is not decoration. A raster region says "these pixels differ", which on a
/// re-plotted CAD sheet is as easily a hinting or antialiasing artefact as a design
/// change. A vector region says "this line is not in the other drawing", which is a
/// statement about the geometry itself. The UI must be able to tell the two apart, so
/// the two are carried in separate arrays *and* tagged.
public enum DifferenceSignal: String, Sendable, Hashable, Codable, CaseIterable {
    case raster
    case vector
}

/// What the vector comparison found, for a region whose ``DifferenceRegion/signal`` is
/// ``DifferenceSignal/vector``.
public enum VectorDifferenceKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A primitive on the revision with no counterpart on the baseline.
    case added
    /// A primitive on the baseline with no counterpart on the revision.
    case removed
    /// The same shape, translated. The offset is exact and is reported.
    case moved
    /// A primitive anchored in the same place whose shape or stroke width changed.
    case reshaped

    public var classification: DifferenceClassification {
        switch self {
        case .added: return .added
        case .removed: return .removed
        case .moved, .reshaped: return .changed
        }
    }
}

/// The geometry behind a vector difference.
public struct VectorDifferenceDetail: Sendable, Hashable, Codable {
    public let kind: VectorDifferenceKind
    /// Identifiers from the baseline page's ``ZPDFVectorExtraction`` extraction.
    public let baselinePrimitiveIDs: [UInt64]
    /// Identifiers from the revised page's extraction.
    public let revisedPrimitiveIDs: [UInt64]
    /// For ``VectorDifferenceKind/moved``: the translation in baseline page points.
    public let translation: CGPoint?
    /// For ``VectorDifferenceKind/reshaped``: the largest single-vertex displacement,
    /// in baseline page points.
    public let maximumVertexDisplacement: Double?
    /// Stroke width difference in page points, when both sides have one.
    public let strokeWidthDelta: Double?

    public init(
        kind: VectorDifferenceKind,
        baselinePrimitiveIDs: [UInt64],
        revisedPrimitiveIDs: [UInt64],
        translation: CGPoint? = nil,
        maximumVertexDisplacement: Double? = nil,
        strokeWidthDelta: Double? = nil
    ) {
        self.kind = kind
        self.baselinePrimitiveIDs = baselinePrimitiveIDs
        self.revisedPrimitiveIDs = revisedPrimitiveIDs
        self.translation = translation
        self.maximumVertexDisplacement = maximumVertexDisplacement
        self.strokeWidthDelta = strokeWidthDelta
    }
}

/// One place on the sheet where the two revisions do not agree.
///
/// Bounds are in **baseline page space** — PDF points, y up — so the UI can put a
/// marker on the page it is already showing without knowing anything about how the
/// comparison was rendered.
public struct DifferenceRegion: Sendable, Hashable, Codable, Identifiable {
    /// Stable within one comparison and reproducible across repeats of it: regions are
    /// numbered in a deterministic scan order, not in whatever order a hash set yielded.
    public let id: Int
    public let signal: DifferenceSignal
    public let classification: DifferenceClassification
    /// Baseline page space, PDF points.
    public let pageBounds: CGRect
    /// The bitmap rectangle the region occupied, for a raster region. `nil` for a vector
    /// region, which never touched a bitmap.
    public let pixelBounds: CGRect?
    /// Differing pixels inside the region, excluding the pixels the grouping dilation
    /// added. Zero for a vector region.
    public let changedPixelCount: Int
    public let addedPixelCount: Int
    public let removedPixelCount: Int
    /// `0…1`. See ``RasterDifferenceConfidence`` and ``VectorDifferenceConfidence`` for
    /// the two rules, which are different because the two signals mean different things.
    public let confidence: Double
    public let vectorDetail: VectorDifferenceDetail?

    public init(
        id: Int,
        signal: DifferenceSignal,
        classification: DifferenceClassification,
        pageBounds: CGRect,
        pixelBounds: CGRect? = nil,
        changedPixelCount: Int = 0,
        addedPixelCount: Int = 0,
        removedPixelCount: Int = 0,
        confidence: Double,
        vectorDetail: VectorDifferenceDetail? = nil
    ) {
        self.id = id
        self.signal = signal
        self.classification = classification
        self.pageBounds = pageBounds
        self.pixelBounds = pixelBounds
        self.changedPixelCount = changedPixelCount
        self.addedPixelCount = addedPixelCount
        self.removedPixelCount = removedPixelCount
        self.confidence = confidence
        self.vectorDetail = vectorDetail
    }
}

/// The raster confidence rule, written once so it is auditable.
///
/// Confidence is not a probability that the change is real. It is a fixed statement of
/// how far the region is from the two things that produce false positives — a handful
/// of pixels, and differences that only just cross the tolerance:
///
/// ```text
/// confidence = 0.5 · strongFraction + 0.5 · min(1, changedPixels / (4 · minimumRegionPixels))
/// ```
///
/// where `strongFraction` is the share of the region's differing pixels whose gray-level
/// difference exceeds `strongDifferenceMultiplier × intensityTolerance`. A large region
/// of solidly black-on-white difference scores 1; a twelve-pixel smudge that only just
/// exceeded the tolerance scores near 0.
public enum RasterDifferenceConfidence {
    public static func value(
        strongPixelCount: Int,
        changedPixelCount: Int,
        minimumRegionPixelCount: Int
    ) -> Double {
        guard changedPixelCount > 0 else { return 0 }
        let strongFraction = Double(strongPixelCount) / Double(changedPixelCount)
        let sizeFloor = Double(max(1, 4 * minimumRegionPixelCount))
        let sizeFactor = min(1, Double(changedPixelCount) / sizeFloor)
        return min(1, max(0, 0.5 * strongFraction + 0.5 * sizeFactor))
    }
}

/// The vector confidence rule.
///
/// The extractor already publishes a per-primitive confidence — a stroked path scores
/// 1.0, a fill-only boundary 0.95, a clip-derived path 0.5 — and that is the right
/// starting point, because a difference is only as trustworthy as the geometry it was
/// computed from. It is then multiplied by a factor for how unambiguous the match was:
///
/// | Kind | Factor | Why |
/// |---|---|---|
/// | added, removed | `1.00` | nothing matched it; there is no ambiguity to discount |
/// | moved | `1.00` | every vertex moved by the same vector, which is not a coincidence |
/// | reshaped | `0.80` | "same anchor, different shape" is a judgement, not an identity |
public enum VectorDifferenceConfidence {
    public static func factor(for kind: VectorDifferenceKind) -> Double {
        switch kind {
        case .added, .removed, .moved: return 1.0
        case .reshaped: return 0.8
        }
    }

    public static func value(kind: VectorDifferenceKind, primitiveConfidence: Float) -> Double {
        min(1, max(0, Double(primitiveConfidence) * factor(for: kind)))
    }
}
