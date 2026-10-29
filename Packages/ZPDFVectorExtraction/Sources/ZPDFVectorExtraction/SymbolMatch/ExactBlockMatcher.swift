import CoreGraphics
import Foundation

/// Exact block counting (NL-AUTO-12): when the boxed symbol is one drawing of a Form XObject,
/// every drawing of that form is an instance — exactly, with residual 0 and the drawing's own
/// transform. No clustering, no alignment, no threshold.
///
/// The short-circuit applies only when it is certain: the exemplar's usable primitives are
/// exactly the usable primitives of one innermost form invocation. Anything else — a producer
/// that flattened its blocks, a box that caught half a block or two — returns `nil`, and the
/// geometric matcher runs as before.
public enum ExactBlockMatcher {

    /// The block the exemplar is: the innermost form drawing whose usable primitives are
    /// exactly the exemplar's. `nil` when it is not one block.
    ///
    /// The boxed drawing names the form and carries the transform the exemplar is measured in,
    /// but it is **not** the measure of a whole drawing (U-076): a person may box a copy that a
    /// clip or the viewport edge cut short. The reference is the largest drawing of the same form
    /// on the exemplar's page — its primitive count and its usable count — so a clipped exemplar
    /// never makes the whole copies look partial.
    public static func block(of exemplar: SymbolExemplar, in extraction: VectorPageExtraction) -> ExactBlock? {
        guard let invocations = extraction.formInvocations, !invocations.isEmpty else { return nil }
        let primitives = extraction.primitives
        let exemplarIDs = Set(exemplar.primitiveIDs)
        guard !exemplarIDs.isEmpty else { return nil }
        func usableIDs(_ invocation: VectorFormInvocation) -> Set<UInt64> {
            Set(primitives[invocation.primitiveRange].filter(SymbolFeatureExtraction.isUsable).map(\.id))
        }
        let source = invocations
            .filter { invocation in
                invocation.primitiveRange.contains(where: { exemplarIDs.contains(primitives[$0].id) })
            }
            .sorted { $0.primitiveCount < $1.primitiveCount }
            .first { usableIDs($0) == exemplarIDs }
        guard let source else { return nil }
        var wholeCount = source.primitiveCount
        var wholeUsable = exemplarIDs.count
        for sibling in invocations where sibling.formIdentity == source.formIdentity {
            let usable = usableIDs(sibling).count
            if (sibling.primitiveCount, usable) > (wholeCount, wholeUsable) {
                wholeCount = sibling.primitiveCount
                wholeUsable = usable
            }
        }
        return ExactBlock(invocation: source, primitiveCount: wholeCount, usableCount: wholeUsable, exemplar: exemplar)
    }

    /// Every drawing of `block` on a page — the exemplar's page or any other — as instances with
    /// residual 0 and the drawing's own transform.
    ///
    /// A drawing of the same form that is not whole is **rejected, never dropped** (T-066): a
    /// clip that cut some of its primitives away (the extractor leaves out geometry wholly
    /// outside the clip, so the drawing produced fewer primitives), or a member the layer filter
    /// hides. It is reported as ``SymbolRejectionReason/partialBlock(visible:total:)`` with the
    /// members that are still visible, their bounds and the exemplar's centroid carried through
    /// the drawing's transform, so the review lists it as a row a person can accept — not as an
    /// anonymous shape that "did not resemble the symbol". A drawing with nothing visible is
    /// not on the sheet and is not reported.
    ///
    /// - Parameter isExemplarPage: whether `extraction` is the page the exemplar was boxed on;
    ///   only there can a drawing be the boxed one (primitive identifiers restart per page).
    public static func instances(
        of block: ExactBlock,
        in extraction: VectorPageExtraction,
        visible: [VectorPrimitive],
        isExemplarPage: Bool = true
    ) -> SymbolMatchReport {
        let primitives = extraction.primitives
        let visibleIDs = Set(visible.map(\.id))
        let drawings = (extraction.formInvocations ?? []).filter { invocation in
            invocation.formIdentity == block.invocation.formIdentity
        }
        let inverse = block.invocation.transform.inverted()
        let membersOfDrawing = drawings.map { invocation in
            primitives[invocation.primitiveRange].filter(SymbolFeatureExtraction.isUsable)
        }
        // A whole drawing has the reference's counts. Should this page hold a drawing larger than
        // any on the exemplar's page (every copy there was clipped), that one is the measure, so a
        // partial drawing never shows more strokes than its total (U-076).
        var wholeCount = block.primitiveCount
        var wholeUsable = block.usableCount
        for (invocation, members) in zip(drawings, membersOfDrawing)
        where (invocation.primitiveCount, members.count) > (wholeCount, wholeUsable) {
            wholeCount = invocation.primitiveCount
            wholeUsable = members.count
        }
        var confirmed: [SymbolInstance] = []
        var rejected: [SymbolRejection] = []
        for (invocation, members) in zip(drawings, membersOfDrawing) {
            // Exemplar page space → form space → this drawing's page space.
            let map = inverse.concatenating(invocation.transform)
            let transform = SymbolTransform(
                a: Double(map.a), b: Double(map.b), c: Double(map.c),
                d: Double(map.d), tx: Double(map.tx), ty: Double(map.ty)
            )
            let isWhole = invocation.primitiveCount == wholeCount
                && members.count == wholeUsable
                && members.allSatisfy({ visibleIDs.contains($0.id) })
            guard isWhole else {
                let shown = members.filter { visibleIDs.contains($0.id) }
                guard var bounds = shown.first?.bounds else { continue }
                for member in shown.dropFirst() { bounds = bounds.union(member.bounds) }
                rejected.append(SymbolRejection(
                    primitiveIDs: shown.map(\.id).sorted(),
                    position: transform.apply(block.exemplar.centroid),
                    bounds: bounds,
                    reason: .partialBlock(visible: shown.count, total: max(wholeUsable, members.count))
                ))
                continue
            }
            var bounds = members[0].bounds
            for member in members.dropFirst() { bounds = bounds.union(member.bounds) }
            let determinant = transform.determinant
            let ids = members.map(\.id).sorted()
            confirmed.append(SymbolInstance(
                primitiveIDs: ids,
                position: transform.apply(block.exemplar.centroid),
                bounds: bounds,
                transform: transform,
                isMirrored: determinant < 0,
                scaleFactor: Swift.abs(determinant).squareRoot(),
                residual: 0,
                isExemplar: isExemplarPage && ids == block.exemplar.primitiveIDs
            ))
        }
        confirmed.sort { ($0.primitiveIDs.first ?? 0) < ($1.primitiveIDs.first ?? 0) }
        rejected.sort { ($0.primitiveIDs.first ?? 0) < ($1.primitiveIDs.first ?? 0) }
        return SymbolMatchReport(
            confirmed: confirmed,
            rejected: rejected,
            searchedRegion: extraction.geometryBounds ?? block.exemplar.region,
            candidateCount: drawings.count,
            wasTruncated: false,
            residualThreshold: SymbolMatchOptions.standard.residualThreshold
        )
    }

    /// The instances of the exemplar's block on its own page, or `nil` when the exemplar is
    /// not one block.
    public static func matches(
        exemplar: SymbolExemplar,
        extraction: VectorPageExtraction,
        visible: [VectorPrimitive]
    ) -> SymbolMatchReport? {
        guard let block = block(of: exemplar, in: extraction) else { return nil }
        return instances(of: block, in: extraction, visible: visible)
    }
}

/// One CAD block, as the exemplar identified it: the form drawing it came from and the size of
/// a whole drawing of it.
public struct ExactBlock: Sendable, Hashable {
    /// The boxed drawing: its form identity names the block, and its transform maps the
    /// exemplar's page space into form space. It may be a clipped copy.
    public let invocation: VectorFormInvocation
    /// Primitives in a whole drawing: the largest drawing of the form on the exemplar's page.
    public let primitiveCount: Int
    /// Usable primitives in that whole drawing — the `total` of a partial one.
    public let usableCount: Int
    public let exemplar: SymbolExemplar
}
