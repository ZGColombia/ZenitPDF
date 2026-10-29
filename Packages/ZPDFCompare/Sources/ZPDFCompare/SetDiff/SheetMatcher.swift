import CoreGraphics
import Foundation

/// Matches the sheets of two whole drawing sets against each other, by label, before any
/// page is rendered.
///
/// A set comparison reports what changed between two whole drawing sets. Everything
/// downstream of that — the raster pass, the geometry pass, the quantity bookkeeping —
/// already exists and already works *per page*. What did not exist is the answer to the
/// question those passes have to be asked: **which page of the new set is this page of
/// the old set?** Index is the wrong answer, because a set with an inserted sheet
/// renumbers everything after it, and comparing `A-104` against `A-103` reports every
/// difference between two unrelated drawings as a change.
///
/// So the matcher works on labels, in three descending strengths of evidence, and it
/// records which one it used for every pair it emits:
///
/// 1. **Exact label.** The labels are identical and neither repeats in its own set.
/// 2. **Normalised label.** They agree after trimming, case folding, whitespace
///    collapsing, and at most one trailing revision suffix — `A-101-B` is revision B of
///    `A-101`. The exact rule is ``SheetLabel/stem(_:)`` and it is deliberately narrow.
/// 3. **Position fallback.** No label evidence survives. Among the sheets nothing else
///    could match, same paper size and same position pair up — and the pair is tagged as
///    the guess it is.
///
/// Anything still unmatched is an addition or a removal.
///
/// ### What it will not do
///
/// It will not pair two sheets whose label is duplicated inside its own set by anything
/// other than position, and when a set contains such a duplicate the whole matching
/// carries ``SheetMatching/isAmbiguous``. A set with two sheets called `A-101` gives the
/// matcher no way to tell which is which; pairing them in array order and staying quiet
/// about it is precisely the silent guess a set comparison must never make.
///
/// The type is a plain `Sendable` value with no state, no I/O and no clock. A matching is
/// a pure function of two arrays of ``SetSheet``, which is what makes every rule above
/// testable by hand.
public struct SheetMatcher: Sendable, Hashable {

    /// How far two page boxes may differ, in PDF points, and still count as the same
    /// paper size for ``MatchBasis/positionFallback``.
    ///
    /// One point is 1/72 inch, about 0.35 mm. Wide enough to absorb the rounding in a
    /// `/MediaBox` written as `841.89 1190.55`, far narrower than the ~250 pt step
    /// between two ISO paper sizes. The comparison is on width and height separately, so
    /// a sheet that was re-plotted rotated is *not* the same size — it is left unmatched
    /// rather than paired on a coincidence.
    public var sizeTolerance: Double

    public init(sizeTolerance: Double = 1) {
        self.sizeTolerance = sizeTolerance
    }

    public static let standard = SheetMatcher()

    /// Matches `old` against `new`.
    ///
    /// - Parameters:
    ///   - old: the sheets of the earlier set, in document order.
    ///   - new: the sheets of the later set, in document order.
    /// - Returns: a ``SheetMatching`` whose three lists partition the two sets.
    /// - Throws: ``SheetMatchingFault/duplicateSheetIndex(side:index:)`` when a set
    ///   repeats a ``SetSheet/index``. Dropping the duplicate would drop a sheet, and a
    ///   dropped sheet is one whose changes are never reported.
    public func match(old: [SetSheet], new: [SetSheet]) throws -> SheetMatching {
        try assertUniqueIndices(old, side: .old)
        try assertUniqueIndices(new, side: .new)

        let oldCanonical = old.map { SheetLabel.canonical($0.label) }
        let newCanonical = new.map { SheetLabel.canonical($0.label) }
        let oldCanonicalCounts = Self.counts(oldCanonical)
        let newCanonicalCounts = Self.counts(newCanonical)

        // A label that repeats inside its own set is evidence of nothing. Sheets carrying
        // one are excluded from every label-based rule below and can only ever be paired
        // by position — and the matching says so.
        let duplicated = Set(oldCanonicalCounts.filter { $0.value > 1 }.keys)
            .union(newCanonicalCounts.filter { $0.value > 1 }.keys)

        // A synthesised ordinal label ("5" for the fifth page of a set without /PageLabels)
        // or an empty one is not evidence either: pairing old "5" with new "5" is index
        // matching presented as a certain exact-label match (BH-124). Such sheets go to the
        // positional fallback, which is tagged as a guess.
        func oldIsDistinct(_ position: Int) -> Bool {
            old[position].labelIsEvidence && oldCanonicalCounts[oldCanonical[position]] == 1
        }
        func newIsDistinct(_ position: Int) -> Bool {
            new[position].labelIsEvidence && newCanonicalCounts[newCanonical[position]] == 1
        }

        var matchedOld = [Bool](repeating: false, count: old.count)
        var matchedNew = [Bool](repeating: false, count: new.count)
        var pairs: [SheetPair] = []
        pairs.reserveCapacity(Swift.min(old.count, new.count))

        // MARK: 1 — exact label, unique on both sides
        //
        // Identical strings. A sheet whose canonical label repeats in its own set is
        // excluded, which also means the candidate list here can never hold two entries:
        // two distinct sheets sharing a raw label would share a canonical label too.
        var newByRawLabel: [String: Int] = [:]
        for position in new.indices where newIsDistinct(position) {
            newByRawLabel[new[position].label] = position
        }
        for position in old.indices where oldIsDistinct(position) {
            guard let candidate = newByRawLabel[old[position].label], !matchedNew[candidate] else {
                continue
            }
            pairs.append(
                SheetPair(old: old[position].index, new: new[candidate].index, basis: .exactLabel)
            )
            matchedOld[position] = true
            matchedNew[candidate] = true
        }

        // MARK: 2a — normalised label
        //
        // Same drawing, different typing: trailing space, different case, a doubled space
        // inside. `SheetLabel.canonical` is the whole rule.
        var newByCanonical: [String: Int] = [:]
        for position in new.indices where newIsDistinct(position) && !matchedNew[position] {
            newByCanonical[newCanonical[position]] = position
        }
        for position in old.indices where oldIsDistinct(position) && !matchedOld[position] {
            guard let candidate = newByCanonical[oldCanonical[position]], !matchedNew[candidate]
            else { continue }
            pairs.append(
                SheetPair(
                    old: old[position].index, new: new[candidate].index, basis: .normalisedLabel
                )
            )
            matchedOld[position] = true
            matchedNew[candidate] = true
        }

        // MARK: 2b — normalised label with a revision suffix removed
        //
        // `A-101` against `A-101-B`. Only over what is still unmatched, so an old set that
        // really does contain `A-101-B` has already claimed it in step 1 and this rule
        // never sees it.
        //
        // The stem is required to be unique among the *remaining* candidates on both
        // sides. If the new set offers both `A-101-B` and `A-101-C` against a single old
        // `A-101`, there is no way to tell which supersedes it, so neither is picked here;
        // they fall through to the positional fallback, which is tagged as a guess. Picking
        // the first is the silent wrong answer this feature exists to avoid.
        let remainingOld = old.indices.filter { !matchedOld[$0] && oldIsDistinct($0) }
        let remainingNew = new.indices.filter { !matchedNew[$0] && newIsDistinct($0) }
        let oldStems = remainingOld.map { SheetLabel.stem(old[$0].label) }
        let newStems = remainingNew.map { SheetLabel.stem(new[$0].label) }
        let oldStemCounts = Self.counts(oldStems)
        let newStemCounts = Self.counts(newStems)
        var newByStem: [String: Int] = [:]
        for (offset, position) in remainingNew.enumerated() where newStemCounts[newStems[offset]] == 1 {
            newByStem[newStems[offset]] = position
        }
        for (offset, position) in remainingOld.enumerated() {
            let stem = oldStems[offset]
            guard oldStemCounts[stem] == 1, let candidate = newByStem[stem], !matchedNew[candidate]
            else { continue }
            pairs.append(
                SheetPair(
                    old: old[position].index, new: new[candidate].index, basis: .normalisedLabel
                )
            )
            matchedOld[position] = true
            matchedNew[candidate] = true
        }

        // MARK: 3 — position fallback
        //
        // Position here means position *among what is left*, not index in the original
        // set: the k-th unmatched old sheet against the k-th unmatched new sheet. That is
        // what survives an inserted sheet earlier in the set, and it is what pairs the two
        // `A-101`s of an ambiguous set in the order they were drawn.
        //
        // Paper size is a hard requirement. A detail at A3 and a plan at A1 are not the
        // same drawing however neatly their positions line up, and a fallback that ignored
        // size would pair them and report every difference between them as a change.
        let residualOld = old.indices.filter { !matchedOld[$0] }
        let residualNew = new.indices.filter { !matchedNew[$0] }
        // A size mismatch skips the sheet that does not agree instead of keeping one shared
        // offset: with a single offset an unmatched inserted A3 detail shifted every later A1
        // pairing by one (BH-125). The alignment is the order-preserving pairing with the
        // most size-agreeing pairs; among equals the k-th with the k-th wins.
        for (oldPosition, newPosition) in positionalAlignment(
            residualOld.map { old[$0].sizeInPoints },
            residualNew.map { new[$0].sizeInPoints }
        ).map({ (residualOld[$0.0], residualNew[$0.1]) }) {
            pairs.append(
                SheetPair(
                    old: old[oldPosition].index,
                    new: new[newPosition].index,
                    basis: .positionFallback
                )
            )
            matchedOld[oldPosition] = true
            matchedNew[newPosition] = true
        }

        return SheetMatching(
            pairs: pairs,
            addedInNew: new.indices.filter { !matchedNew[$0] }.map { new[$0].index },
            removedFromOld: old.indices.filter { !matchedOld[$0] }.map { old[$0].index },
            isAmbiguous: !duplicated.isEmpty,
            ambiguousLabels: Array(duplicated),
            oldSheetIndices: old.map(\.index),
            newSheetIndices: new.map(\.index)
        )
    }

    /// ``match(old:new:)`` at the default tolerance.
    public static func match(old: [SetSheet], new: [SetSheet]) throws -> SheetMatching {
        try standard.match(old: old, new: new)
    }

    // MARK: - Internals

    /// The order-preserving pairing of two size lists with the most size-agreeing pairs
    /// (a longest common subsequence under ``sizesAgree(_:_:)``). Ties prefer pairing the
    /// current heads, so equal lists pair k-th with k-th exactly as before.
    ///
    /// Quadratic in the residual counts; above ~16 M cells it degrades to a greedy walk
    /// that still skips a disagreeing sheet rather than locking the offset.
    func positionalAlignment(_ old: [CGSize], _ new: [CGSize]) -> [(Int, Int)] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return [] }
        var result: [(Int, Int)] = []
        if n * m > 16_000_000 {
            var j = 0
            for i in 0..<n where j < m {
                if let k = (j..<m).first(where: { sizesAgree(old[i], new[$0]) }) {
                    result.append((i, k))
                    j = k + 1
                }
            }
            return result
        }
        // suffix[i][j] = best pairing count of old[i...] with new[j...].
        let width = m + 1
        var suffix = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                let skip = Swift.max(suffix[(i + 1) * width + j], suffix[i * width + j + 1])
                let take = sizesAgree(old[i], new[j]) ? suffix[(i + 1) * width + j + 1] + 1 : 0
                suffix[i * width + j] = Swift.max(skip, take)
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if sizesAgree(old[i], new[j]), suffix[i * width + j] == suffix[(i + 1) * width + j + 1] + 1 {
                result.append((i, j))
                i += 1; j += 1
            } else if suffix[(i + 1) * width + j] >= suffix[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// Same paper, within ``sizeTolerance``. Not orientation-insensitive: a rotated
    /// re-plot is a different size here, deliberately.
    private func sizesAgree(_ first: CGSize, _ second: CGSize) -> Bool {
        guard first.width.isFinite, first.height.isFinite,
              second.width.isFinite, second.height.isFinite
        else { return false }
        return abs(first.width - second.width) <= sizeTolerance
            && abs(first.height - second.height) <= sizeTolerance
    }

    private func assertUniqueIndices(_ sheets: [SetSheet], side: SetSide) throws {
        var seen = Set<Int>()
        seen.reserveCapacity(sheets.count)
        for sheet in sheets where !seen.insert(sheet.index).inserted {
            throw SheetMatchingFault.duplicateSheetIndex(side: side, index: sheet.index)
        }
    }

    private static func counts(_ keys: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(keys.count)
        for key in keys { result[key, default: 0] += 1 }
        return result
    }
}
