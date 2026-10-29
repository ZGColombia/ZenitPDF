import CoreGraphics
import Foundation

/// How forgiving page-box matching is.
public struct PageBoxAlignmentOptions: Sendable, Hashable, Codable {
    /// Two boxes whose corresponding edges differ by no more than this are the same box,
    /// and the alignment is the identity. Half a PDF point is a fortieth of a
    /// millimetre — smaller than any real re-plot difference and larger than the
    /// re-serialisation rounding a page operation introduces.
    public var edgeTolerancePoints: Double
    /// Above this relative aspect-ratio difference the two sheets are not the same
    /// drawing re-plotted, and the box match is reported with low conditioning so the
    /// caller falls back to manual alignment.
    public var aspectTolerance: Double
    /// When off, only a translation is produced and a size change is left in the
    /// residual.
    public var allowsUniformScale: Bool

    public init(
        edgeTolerancePoints: Double = 0.5,
        aspectTolerance: Double = 0.02,
        allowsUniformScale: Bool = true
    ) {
        self.edgeTolerancePoints = edgeTolerancePoints
        self.aspectTolerance = aspectTolerance
        self.allowsUniformScale = allowsUniformScale
    }

    public static let standard = PageBoxAlignmentOptions()
}

/// The cheap, deterministic first attempt at automatic alignment: put the two page
/// boxes on top of each other.
///
/// This is right far more often than it sounds. Two revisions of the same sheet almost
/// always come off the same plotter setup with the same box, in which case the answer
/// is the identity and no image processing is needed at all. The second most common
/// case is the same drawing re-plotted from ARCH-D to A1, which is a pure centred
/// uniform scale — also exactly recoverable from the boxes.
///
/// It cannot find a *shifted* drawing inside an unchanged box. That is what
/// ``VisionAutoAligner`` and manual alignment are for.
public enum PageBoxAligner {

    /// Aligns the revised box onto the baseline box.
    ///
    /// The returned transform maps revised page space onto baseline page space, and its
    /// residual is the RMS of the four box-corner mismatches after the map — zero for an
    /// exact match or an exact uniform rescale, and non-zero and honest when the two
    /// sheets have different aspect ratios.
    public static func align(
        baselineBox: CGRect,
        revisedBox: CGRect,
        options: PageBoxAlignmentOptions = .standard
    ) -> AlignmentSolution {
        let degenerate = !baselineBox.width.isFinite || !baselineBox.height.isFinite
            || !revisedBox.width.isFinite || !revisedBox.height.isFinite
            || baselineBox.width <= 0 || baselineBox.height <= 0
            || revisedBox.width <= 0 || revisedBox.height <= 0
        if degenerate {
            return AlignmentSolution(
                transform: .identity,
                model: .translation,
                provenance: .pageBox,
                residual: .zero,
                correspondenceCount: 0,
                conditioning: 0
            )
        }

        let edgeDelta = max(
            max(abs(baselineBox.minX - revisedBox.minX), abs(baselineBox.minY - revisedBox.minY)),
            max(abs(baselineBox.maxX - revisedBox.maxX), abs(baselineBox.maxY - revisedBox.maxY))
        )
        if Double(edgeDelta) <= options.edgeTolerancePoints {
            return AlignmentSolution(
                transform: .identity,
                model: .translation,
                provenance: .pageBox,
                residual: .zero,
                correspondenceCount: 0,
                conditioning: 1
            )
        }

        let baselineAspect = Double(baselineBox.width / baselineBox.height)
        let revisedAspect = Double(revisedBox.width / revisedBox.height)
        let aspectDelta = abs(baselineAspect - revisedAspect) / max(baselineAspect, revisedAspect)
        // Conditioning falls linearly from 1 at a perfect aspect match to 0 at the
        // tolerance, so a caller can threshold on one number.
        let conditioning = max(0, 1 - aspectDelta / max(options.aspectTolerance, 1e-12))

        let scale: Double
        if options.allowsUniformScale {
            // The largest uniform scale that still fits the revised sheet inside the
            // baseline sheet: a rescale never crops content.
            scale = min(
                Double(baselineBox.width / revisedBox.width),
                Double(baselineBox.height / revisedBox.height)
            )
        } else {
            scale = 1
        }
        // Centre on centre: with equal aspect ratios this maps every corner exactly.
        let revisedCentre = CGPoint(x: revisedBox.midX, y: revisedBox.midY)
        let baselineCentre = CGPoint(x: baselineBox.midX, y: baselineBox.midY)
        let transform = AlignmentTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: Double(baselineCentre.x) - scale * Double(revisedCentre.x),
            ty: Double(baselineCentre.y) - scale * Double(revisedCentre.y)
        )

        let corners = [
            (CGPoint(x: revisedBox.minX, y: revisedBox.minY), CGPoint(x: baselineBox.minX, y: baselineBox.minY)),
            (CGPoint(x: revisedBox.maxX, y: revisedBox.minY), CGPoint(x: baselineBox.maxX, y: baselineBox.minY)),
            (CGPoint(x: revisedBox.maxX, y: revisedBox.maxY), CGPoint(x: baselineBox.maxX, y: baselineBox.maxY)),
            (CGPoint(x: revisedBox.minX, y: revisedBox.maxY), CGPoint(x: baselineBox.minX, y: baselineBox.maxY))
        ].map { AlignmentCorrespondence(source: $0.0, target: $0.1) }

        return AlignmentSolution(
            transform: transform,
            model: .similarity,
            provenance: .pageBox,
            residual: AlignmentResidual.measure(of: transform, against: corners),
            correspondenceCount: 4,
            conditioning: conditioning
        )
    }
}
