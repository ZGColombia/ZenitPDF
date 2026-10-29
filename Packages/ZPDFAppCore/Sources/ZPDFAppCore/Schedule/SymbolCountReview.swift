import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFVectorExtraction

/// The review step between a symbol search and the count it lands (NL-AUTO-02).
///
/// A symbol search used to commit straight away and then warn that "N candidates were skipped
/// and M symbols could not be classified", with N in the hundreds on every real sheet: every
/// stray line, hatch stroke and letter the matcher looked at and turned down was counted as a
/// skip. A warning that fires on every sheet teaches people to ignore the one that matters.
/// This type sorts one page's report into what a person can actually act on:
///
/// - **confirmed** instances, which the review ticks;
/// - **near misses** — shapes that almost matched, by the rule in
///   ``SymbolCountReviewBuilder/isNearMiss(_:exemplar:)`` — which the review lists unticked and
///   the canvas highlights, because those are the doors a list could silently miss;
/// - **already counted** places, where a count point of this designation — or of another one —
///   already sits, which the review lists unticked so a second run never double counts;
/// - and a single number for everything else: shapes on the page that did not resemble the
///   symbol. That number is stated in the summary and never raised as a warning.
///
/// Nothing here computes geometry of its own. Positions, residuals and scales are the report's;
/// the near-miss and duplicate rules are comparisons of those numbers against fixed ratios
/// written down below.
public struct SymbolCountCandidate: Sendable, Hashable, Identifiable {

    public enum Status: Sendable, Hashable {
        /// The matcher confirmed it.
        case confirmed
        /// The matcher turned it down, but only just.
        case nearMiss(SymbolRejectionReason)
        /// The matcher confirmed it, and a count point already sits there — under `subject`,
        /// which is this run's designation for a rerun, or another type's for a contested place.
        case alreadyCounted(subject: String)
    }

    /// Stable within one review: page index × 100 000 + position in the page's list, plus the
    /// caller's offset when one review holds several symbols.
    public let id: Int
    public let pageID: PageID
    public let pageIndex: Int
    /// Where the count point would go.
    public let position: PDFPoint
    /// The candidate's primitives' bounds, for the thumbnail and the canvas highlight.
    public let bounds: VectorBounds
    public let status: Status
    /// Residual over the run's threshold: `0…1` for a confirmed instance, above 1 for a near
    /// miss on residual, `nil` for a near miss on scale (it was never aligned).
    public let residualRatio: Double?
    public let isMirrored: Bool
    /// Instance size over exemplar size, when measured.
    public let scaleFactor: Double?
    /// The instance the person boxed.
    public let isExemplar: Bool

    /// Whether the review ticks it before the person touches anything.
    public var isSelectedByDefault: Bool {
        if case .confirmed = status { return true }
        return false
    }
}

/// One page's sorted report.
public struct SymbolCountPageResult: Sendable, Hashable {
    public let pageID: PageID
    public let pageIndex: Int
    /// Confirmed, near-miss and already-counted candidates, in the report's stable order.
    public let candidates: [SymbolCountCandidate]
    /// Shapes the matcher looked at that did not resemble the symbol. A count, never a warning.
    public let otherShapeCount: Int
    /// `true` when a cap stopped the search on this page: the page may hold more.
    public let wasTruncated: Bool

    public var confirmedCount: Int { candidates.filter { $0.status == .confirmed }.count }
    public var nearMissCount: Int {
        candidates.filter { if case .nearMiss = $0.status { return true } else { return false } }.count
    }
    public var alreadyCountedCount: Int {
        candidates.filter { if case .alreadyCounted = $0.status { return true } else { return false } }.count
    }
}

/// A count point already on a page, as the duplicate check sees it.
public struct ExistingCountPoint: Sendable, Hashable {
    public let subject: String
    public let position: PDFPoint

    public init(subject: String, position: PDFPoint) {
        self.subject = subject
        self.position = position
    }
}

public struct SymbolCountReviewBuilder: Sendable {

    /// A residual rejection is a near miss up to this multiple of the threshold.
    public static let nearMissResidualFactor = 2.0
    /// A scale rejection is a near miss within this factor outside the band.
    public static let nearMissScaleFactor = 1.5
    /// A near miss holds between these shares of the exemplar's primitive count.
    public static let nearMissPrimitiveShare: ClosedRange<Double> = 0.5...1.5
    /// A confirmed position within this multiple of the exemplar's RMS radius of an existing
    /// count point is that point.
    public static let duplicateRadiusFactor = 0.5

    public init() {}

    /// The fixed near-miss rule. No engine change: a comparison of the rejection's own numbers.
    ///
    /// A clipped or partly hidden drawing of the boxed CAD block
    /// (`SymbolRejectionReason.partialBlock`) is always a near miss, whatever share of it shows:
    /// it is the symbol itself, placed again, so it is a row the person can accept — never one
    /// of the shapes that "did not resemble the symbol" (T-066). A geometric cluster crossing the
    /// searched region's edge (`partialOverlap`) stays what it was: it may be anything.
    public static func isNearMiss(_ rejection: SymbolRejection, exemplar: SymbolExemplar) -> Bool {
        if case .partialBlock = rejection.reason { return !rejection.primitiveIDs.isEmpty }
        let exemplarCount = Double(exemplar.primitiveIDs.count)
        let share = Double(rejection.primitiveIDs.count) / Swift.max(1, exemplarCount)
        guard nearMissPrimitiveShare.contains(share) else { return false }
        switch rejection.reason {
        case .residualTooHigh(let residual, let threshold):
            guard threshold.isFinite, threshold > 0, residual.isFinite else { return false }
            return residual <= threshold * nearMissResidualFactor
        case .scaleOutsideBand(let scale, let band):
            guard scale.isFinite, scale > 0 else { return false }
            return scale >= band.lowerBound / nearMissScaleFactor && scale <= band.upperBound * nearMissScaleFactor
        case .partialOverlap, .tooFewPrimitives, .partialBlock:
            return false
        }
    }

    /// Sorts one page's report.
    ///
    /// - Parameters:
    ///   - existing: the count points already on this page, every subject. A confirmed
    ///     instance within ``duplicateRadiusFactor`` × the exemplar's RMS radius of one is
    ///     reported as already counted, never minted twice.
    public func pageResult(
        pageID: PageID,
        pageIndex: Int,
        exemplar: SymbolExemplar,
        report: SymbolMatchReport,
        existing: [ExistingCountPoint],
        idOffset: Int = 0
    ) -> SymbolCountPageResult {
        let threshold = report.residualThreshold > 0 ? report.residualThreshold : 1
        let radius = exemplar.rmsRadius * Self.duplicateRadiusFactor
        var candidates: [SymbolCountCandidate] = []
        var index = 0
        func nextID() -> Int {
            defer { index += 1 }
            return idOffset + pageIndex * 100_000 + index
        }

        for instance in report.confirmed {
            let position = PDFPoint(x: instance.position.x, y: instance.position.y)
            let duplicate = existing
                .filter { $0.position.distance(to: position) <= radius }
                .min { $0.position.distance(to: position) < $1.position.distance(to: position) }
            candidates.append(SymbolCountCandidate(
                id: nextID(),
                pageID: pageID,
                pageIndex: pageIndex,
                position: position,
                bounds: instance.bounds,
                status: duplicate.map { .alreadyCounted(subject: $0.subject) } ?? .confirmed,
                residualRatio: instance.residual / threshold,
                isMirrored: instance.isMirrored,
                scaleFactor: instance.scaleFactor,
                isExemplar: instance.isExemplar
            ))
        }

        var others = 0
        for rejection in report.rejected {
            guard Self.isNearMiss(rejection, exemplar: exemplar) else {
                others += 1
                continue
            }
            let ratio: Double?
            let scale: Double?
            switch rejection.reason {
            case .residualTooHigh(let residual, _):
                ratio = residual / threshold
                scale = nil
            case .scaleOutsideBand(let measured, _):
                ratio = nil
                scale = measured
            default:
                ratio = nil
                scale = nil
            }
            candidates.append(SymbolCountCandidate(
                id: nextID(),
                pageID: pageID,
                pageIndex: pageIndex,
                position: PDFPoint(x: rejection.position.x, y: rejection.position.y),
                bounds: rejection.bounds,
                status: .nearMiss(rejection.reason),
                residualRatio: ratio,
                isMirrored: false,
                scaleFactor: scale,
                isExemplar: false
            ))
        }

        return SymbolCountPageResult(
            pageID: pageID,
            pageIndex: pageIndex,
            candidates: candidates,
            otherShapeCount: others,
            wasTruncated: report.wasTruncated
        )
    }

    /// The count positions a person accepted, grouped by page in page order — one count markup
    /// per page, so the ledger keeps its per-page grouping. Positions within the duplicate radius
    /// of one another on a page (the same symbol accepted twice through two overlapping boxes)
    /// are minted once.
    public static func acceptedPositions(
        from results: [SymbolCountPageResult],
        selected: Set<Int>,
        exemplar: SymbolExemplar
    ) -> [(pageID: PageID, positions: [PDFPoint])] {
        let radius = exemplar.rmsRadius * duplicateRadiusFactor
        var grouped: [(pageID: PageID, positions: [PDFPoint])] = []
        for result in results.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            var positions: [PDFPoint] = []
            for candidate in result.candidates where selected.contains(candidate.id) {
                guard !positions.contains(where: { $0.distance(to: candidate.position) <= radius }) else { continue }
                positions.append(candidate.position)
            }
            if !positions.isEmpty { grouped.append((result.pageID, positions)) }
        }
        return grouped
    }
}

// MARK: - Several types in one run (NL-AUTO-06)

extension SymbolCountReviewBuilder {

    /// One type's run on one page, as the contested check needs it.
    public struct TypeRun: Sendable {
        public let designation: String
        public let report: SymbolMatchReport
        public let result: SymbolCountPageResult

        public init(designation: String, report: SymbolMatchReport, result: SymbolCountPageResult) {
            self.designation = designation
            self.report = report
            self.result = result
        }
    }

    /// Places two or more types both confirmed, as groups of candidate identities: minting a
    /// contested place under two designations is a double count, so the review makes the person
    /// pick one. Candidates of one type that overlap each other are not contested — that is one
    /// type seeing one place. Groups are ordered by their smallest candidate identity.
    public static func contestedGroups(_ runs: [TypeRun]) -> [[Int]] {
        struct Claim { let candidateID: Int; let type: Int; let primitives: [UInt64] }
        var claims: [Claim] = []
        for (typeIndex, run) in runs.enumerated() {
            // `pageResult` lists the report's confirmed instances first, in the report's order.
            for (index, instance) in run.report.confirmed.enumerated() where index < run.result.candidates.count {
                claims.append(Claim(candidateID: run.result.candidates[index].id, type: typeIndex, primitives: instance.primitiveIDs))
            }
        }
        var parent = Array(claims.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var owner: [UInt64: Int] = [:]
        for (index, claim) in claims.enumerated() {
            for primitive in claim.primitives {
                if let first = owner[primitive] {
                    let a = find(first), b = find(index)
                    if a != b { parent[b] = a }
                } else {
                    owner[primitive] = index
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in claims.indices { groups[find(index), default: []].append(index) }
        return groups.values
            .filter { Set($0.map { claims[$0].type }).count > 1 }
            .map { $0.map { claims[$0].candidateID }.sorted() }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }
}
