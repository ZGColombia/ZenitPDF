import Foundation
import ZPDFPDFKitBridge

/// Why an alignment could not be solved.
///
/// Every case names the numbers that made it impossible, so a UI can say "your three
/// points are almost on a line" rather than "alignment failed".
public enum AlignmentFault: Error, Sendable, Hashable, CustomStringConvertible {
    /// Fewer correspondences than the model needs.
    case insufficientCorrespondences(model: AlignmentModel, required: Int, given: Int)
    /// More correspondences than a single solve is allowed to consider.
    case tooManyCorrespondences(given: Int, limit: Int)
    /// Two source or two target points are the same point.
    case coincidentPoints(indexA: Int, indexB: Int, separation: Double)
    /// The point set is too close to degenerate for the model: collinear for the affine
    /// model, coincident for the similarity model. `conditioning` is the measured value
    /// and `minimum` the threshold that rejected it.
    case degenerateConfiguration(model: AlignmentModel, conditioning: Double, minimum: Double)
    /// A coordinate was infinite or NaN.
    case nonFiniteInput(index: Int)
    /// The normal equations were singular to working precision.
    case singularSystem(model: AlignmentModel)
    /// A solved transform has a zero or non-finite determinant, so it cannot be inverted.
    case nonInvertibleTransform(determinant: Double)

    public var description: String {
        switch self {
        case let .insufficientCorrespondences(model, required, given):
            return "\(model.rawValue) alignment needs \(required) point pairs, got \(given)"
        case let .tooManyCorrespondences(given, limit):
            return "\(given) point pairs exceeds the solver limit of \(limit)"
        case let .coincidentPoints(a, b, separation):
            return "point pairs \(a) and \(b) are \(separation) apart, effectively the same point"
        case let .degenerateConfiguration(model, conditioning, minimum):
            return "\(model.rawValue) alignment is degenerate: conditioning \(conditioning) < \(minimum)"
        case let .nonFiniteInput(index):
            return "point pair \(index) has a non-finite coordinate"
        case let .singularSystem(model):
            return "\(model.rawValue) normal equations are singular"
        case let .nonInvertibleTransform(determinant):
            return "transform determinant \(determinant) is not invertible"
        }
    }
}

/// Everything Revision Compare can refuse to do, as a typed value.
///
/// Untrusted input never produces an untyped error, a hang or an unbounded allocation:
/// each case below is a bound that was hit or a precondition that was not met.
public enum CompareFault: Error, Sendable, Hashable, CustomStringConvertible {
    /// The task was cancelled between two stages.
    case cancelled
    /// Alignment could not be solved.
    case alignment(AlignmentFault)
    /// The PDF engine refused.
    case render(PDFBridgeError)
    /// A raster would exceed the pixel budget before anything is allocated.
    case pixelBudgetExceeded(requestedPixels: Int, limit: Int)
    /// Two rasters that must share a frame do not.
    case mismatchedRasterGeometry(baseline: String, revised: String)
    /// An image had a zero or negative dimension, or its buffer length did not match.
    case malformedRaster(reason: String)
    /// CoreGraphics would not give us a bitmap context or an image.
    case coreGraphicsFailure(operation: String)
    /// A page has no file URL, so the vector pass cannot run on it.
    case vectorSourceUnavailable(label: String)
    /// Vector extraction failed on one of the two pages.
    case vectorExtraction(label: String, reason: String)
    /// More primitives on one page than the vector diff is allowed to consider.
    case vectorPrimitiveBudgetExceeded(count: Int, limit: Int)
    /// The requested render scale is not a usable positive finite number.
    case invalidRenderScale(Double)
    /// An overlay layer named a source image that was not supplied, or vice versa.
    case overlayLayerMismatch(reason: String)

    public var description: String {
        switch self {
        case .cancelled: return "cancelled"
        case let .alignment(fault): return "alignment: \(fault)"
        case let .render(error): return "render: \(error)"
        case let .pixelBudgetExceeded(requested, limit):
            return "raster of \(requested) pixels exceeds the limit of \(limit)"
        case let .mismatchedRasterGeometry(baseline, revised):
            return "rasters do not share a frame: baseline \(baseline), revised \(revised)"
        case let .malformedRaster(reason): return "malformed raster: \(reason)"
        case let .coreGraphicsFailure(operation): return "CoreGraphics failed during \(operation)"
        case let .vectorSourceUnavailable(label): return "no file URL for \(label)"
        case let .vectorExtraction(label, reason): return "vector extraction failed for \(label): \(reason)"
        case let .vectorPrimitiveBudgetExceeded(count, limit):
            return "\(count) primitives exceeds the vector diff limit of \(limit)"
        case let .invalidRenderScale(scale): return "render scale \(scale) is not usable"
        case let .overlayLayerMismatch(reason): return "overlay layers do not match sources: \(reason)"
        }
    }
}

/// Throws ``CompareFault/cancelled`` when the surrounding task was cancelled.
@inline(__always)
func checkCompareCancellation() throws {
    if Task.isCancelled { throw CompareFault.cancelled }
}
