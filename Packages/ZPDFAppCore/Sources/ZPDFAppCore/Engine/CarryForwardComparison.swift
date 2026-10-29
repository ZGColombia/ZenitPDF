import CoreGraphics
import Foundation
import ZPDFCompare
import ZPDFContracts

/// Revision Compare feeding carry-forward (NL-DOCS-12).
///
/// Carry Forward to Revision paired each old sheet with its new revision by the identity and no
/// change regions, so every carried measurement was classified `unchanged` — including one whose
/// linework the revision had redrawn. Each pair now comes from a comparison of the two sheets: the
/// regions where the drawings differ (raster and vector signals both) become the pair's changed
/// regions, in the new sheet's space, so a measurement over one is carried as `needsReview`.
///
/// The carry keeps its geometry where it was drawn (the identity), as before: a sheet is never
/// moved by an automatic alignment nobody checked. The comparison reports its regions in the old
/// (baseline) sheet's space, which is then also the carried geometry's, so they are the carry's
/// changed regions as they stand. When the comparison had to align the sheets — the new drawing
/// sits elsewhere on its sheet, or was re-plotted at another paper size — or could not be made at
/// all, every carried measurement stands on linework that moved: the pair reviews everything
/// (``CarryPair/reviewsEverything``), and each one asks for review wherever it lies. A region
/// the size of the new sheet said the same thing only for geometry inside that sheet: a
/// measurement carried beyond a smaller new sheet met no region and read `unchanged`.
public enum CarryForwardComparison {

    /// The pair for carrying onto `target`, compared through `comparator`. `raster` and
    /// `minimumAreaInSquarePoints` are Revision Compare's own settings, so the carry flags what the
    /// review pane and the set compare report list — no more, no less.
    public static func pair(
        target: PageID,
        baseline: RevisionPageReference,
        revised: RevisionPageReference,
        comparator: RevisionComparator,
        raster: RasterDiffOptions = .standard,
        minimumAreaInSquarePoints: Double = 0,
        renderScale: Double = 1
    ) async -> CarryPair {
        // The geometry signal needs the sheets' vector extraction, which can fail on its own (a
        // protected drawing, the extraction service unreachable); the comparator then keeps the
        // raster signal and reports the refusal (U-078), as Revision Compare does for a scanned
        // sheet. Only when no comparison at all can be made is everything flagged.
        let request = RevisionCompareRequest(
            baseline: baseline, revised: revised, renderScale: renderScale, raster: raster
        )
        guard let result = try? await comparator.compare(request) else { return reviewingEverything(target: target) }
        return pair(target: target, result: result, minimumAreaInSquarePoints: minimumAreaInSquarePoints)
    }

    /// The pair a finished comparison gives: its regions as ``CompareBridge/diffs(of:pageLabel:minimumAreaInSquarePoints:)``
    /// lists them.
    public static func pair(
        target: PageID,
        result: RevisionComparisonResult,
        minimumAreaInSquarePoints: Double = 0
    ) -> CarryPair {
        pair(
            target: target,
            revisedToBaseline: result.alignment.transform,
            baselineRegions: result.allRegions
                .map(\.pageBounds)
                .filter { Double($0.width * $0.height) >= minimumAreaInSquarePoints }
        )
    }

    /// The pair from the comparison's two outputs: its alignment (new → old) and its regions (old
    /// sheet's space).
    public static func pair(
        target: PageID,
        revisedToBaseline transform: AlignmentTransform,
        baselineRegions: [CGRect]
    ) -> CarryPair {
        guard transform.isIdentity() else { return reviewingEverything(target: target) }
        return CarryPair(target: target, alignment: .identity, changedRegions: baselineRegions.map(rect))
    }

    /// The pair when no region is known to be unchanged: geometry carried unmoved, every item
    /// flagged for review whatever its bounds.
    public static func reviewingEverything(target: PageID) -> CarryPair {
        CarryPair(target: target, alignment: .identity, reviewsEverything: true)
    }

    static func rect(_ value: CGRect) -> PDFRect {
        PDFRect(x: Double(value.origin.x), y: Double(value.origin.y), width: Double(value.size.width), height: Double(value.size.height))
    }
}
