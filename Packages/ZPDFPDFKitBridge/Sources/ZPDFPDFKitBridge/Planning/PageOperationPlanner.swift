import Foundation

/// Turns a batch of ``PageOperation`` into a ``PageOperationPlan``.
///
/// Pure arithmetic on page lists: no PDFKit, no file system, no clock. Every rejection
/// happens here, before anything is opened for writing, which is why the dry run and the
/// real thing cannot disagree — the real thing consumes this planner's output.
public enum PageOperationPlanner {

    /// Plans `operations` against a document whose pages carry `initialRotations`.
    ///
    /// - Parameters:
    ///   - operations: applied in order; indices always refer to the state after the
    ///     previous operation.
    ///   - document: the handle whose pages the plan starts from.
    ///   - initialRotations: the current `/Rotate` of each page, in page order.
    ///   - pageCounts: page counts of every open document, needed to validate operations
    ///     that pull pages from elsewhere.
    ///   - externalRotations: the current `/Rotate` of each page of every *other* open document,
    ///     in page order. A page pulled in by `.insert` or `.merge` keeps its own rotation; a
    ///     document not listed here contributes pages at rotation `0` (CR-75). The primary
    ///     document's rotations come from `initialRotations`.
    ///   - limits: the ceilings that make a hostile batch fail rather than allocate.
    public static func plan(
        operations: [PageOperation],
        document: DocumentHandle,
        initialRotations: [Int],
        pageCounts: [DocumentHandle: Int],
        externalRotations: [DocumentHandle: [Int]] = [:],
        limits: DocumentLimits = .standard
    ) throws(PageOperationFault) -> PageOperationPlan {
        guard operations.count <= limits.maximumPageOperations else {
            throw .tooManyOperations(count: operations.count, limit: limits.maximumPageOperations)
        }

        let initialCount = initialRotations.count

        // The `/Rotate` a page arrives with. The primary document's pages come from
        // `initialRotations`; a foreign page keeps its own rotation so a landscape sheet merged
        // in does not come out portrait (CR-75).
        func rotation(of reference: PageReference) -> Int {
            if reference.document == document, reference.pageIndex < initialRotations.count {
                return PageRotationMath.normalised(initialRotations[reference.pageIndex])
            }
            if let rotations = externalRotations[reference.document],
               reference.pageIndex < rotations.count {
                return PageRotationMath.normalised(rotations[reference.pageIndex])
            }
            return 0
        }

        var pages: [PlannedPage] = (0..<initialCount).map {
            PlannedPage(
                source: PageReference(document: document, pageIndex: $0),
                rotation: PageRotationMath.normalised(initialRotations[$0])
            )
        }

        for operation in operations {
            switch operation {
            case let .rotate(indices, change):
                // Deduplicated, like delete and duplicate: a selection that lists a page twice
                // applied a relative change twice, planning [0, 0] +90 as 180 (BH-579).
                var seen: Set<Int> = []
                let validated = try validate(indices, against: pages.count)
                    .filter { seen.insert($0).inserted }
                for index in validated {
                    guard let rotation = change.applied(to: pages[index].rotation) else {
                        throw .rotationNotMultipleOfNinety(degrees: change.requestedDegrees)
                    }
                    pages[index] = PlannedPage(source: pages[index].source, rotation: rotation)
                }

            case let .delete(indices):
                let validated = Set(try validate(indices, against: pages.count))
                pages = pages.enumerated().filter { !validated.contains($0.offset) }.map(\.element)

            case let .reorder(order):
                guard order.count == pages.count else {
                    throw .notAPermutation(expectedCount: pages.count, receivedCount: order.count)
                }
                let validated = try validate(order, against: pages.count)
                guard Set(validated).count == pages.count else {
                    throw .notAPermutation(expectedCount: pages.count, receivedCount: Set(validated).count)
                }
                pages = validated.map { pages[$0] }

            case let .insert(references, atIndex):
                guard atIndex >= 0, atIndex <= pages.count else {
                    throw .insertIndexOutOfRange(index: atIndex, count: pages.count)
                }
                let planned = try plannedPages(
                    for: references, pageCounts: pageCounts, rotation: rotation
                )
                try checkResultingCount(pages.count + planned.count, limits: limits)
                pages.insert(contentsOf: planned, at: atIndex)

            case let .extract(indices):
                let validated = try validate(indices, against: pages.count)
                guard Set(validated).count == validated.count else {
                    throw .duplicatePageIndex(firstDuplicate(in: validated) ?? 0)
                }
                pages = validated.map { pages[$0] }

            case let .merge(other, otherPageCount):
                guard let known = pageCounts[other] else { throw .unknownDocument(other) }
                let count = min(otherPageCount, known)
                guard count > 0 else { throw .pageIndexOutOfRange(index: 0, count: known) }
                try checkResultingCount(pages.count + count, limits: limits)
                pages.append(contentsOf: (0..<count).map {
                    let reference = PageReference(document: other, pageIndex: $0)
                    return PlannedPage(source: reference, rotation: rotation(of: reference))
                })

            case let .duplicate(indices):
                let validated = try validate(indices, against: pages.count)
                try checkResultingCount(pages.count + validated.count, limits: limits)
                // Insert from the back so earlier insertions do not shift later indices.
                for index in Set(validated).sorted(by: >) {
                    pages.insert(pages[index], at: index + 1)
                }
            }
        }

        guard !pages.isEmpty else { throw .resultWouldBeEmpty }
        try checkResultingCount(pages.count, limits: limits)

        let changes = diff(
            initialRotations: initialRotations,
            document: document,
            resulting: pages
        )
        var external: [DocumentHandle] = []
        for page in pages where page.source.document != document {
            if !external.contains(page.source.document) { external.append(page.source.document) }
        }

        return PageOperationPlan(
            document: document,
            initialPageCount: initialCount,
            resultingPages: pages,
            changes: changes,
            externalDocuments: external
        )
    }

    // MARK: - Validation

    private static func validate(
        _ indices: [Int],
        against count: Int
    ) throws(PageOperationFault) -> [Int] {
        for index in indices where index < 0 || index >= count {
            throw .pageIndexOutOfRange(index: index, count: count)
        }
        return indices
    }

    private static func plannedPages(
        for references: [PageReference],
        pageCounts: [DocumentHandle: Int],
        rotation: (PageReference) -> Int
    ) throws(PageOperationFault) -> [PlannedPage] {
        var planned: [PlannedPage] = []
        planned.reserveCapacity(references.count)
        for reference in references {
            guard let count = pageCounts[reference.document] else {
                throw .unknownDocument(reference.document)
            }
            guard reference.pageIndex >= 0, reference.pageIndex < count else {
                throw .pageIndexOutOfRange(index: reference.pageIndex, count: count)
            }
            planned.append(PlannedPage(source: reference, rotation: rotation(reference)))
        }
        return planned
    }

    private static func checkResultingCount(
        _ count: Int,
        limits: DocumentLimits
    ) throws(PageOperationFault) {
        guard count <= limits.maximumPageCount else {
            throw .resultExceedsPageLimit(count: count, limit: limits.maximumPageCount)
        }
    }

    private static func firstDuplicate(in indices: [Int]) -> Int? {
        var seen = Set<Int>()
        for index in indices {
            if !seen.insert(index).inserted { return index }
        }
        return nil
    }

    // MARK: - Diffing

    /// Describes the difference between the starting page list and the planned one.
    ///
    /// A source page appearing more than once in the result is reported as one retained
    /// page plus `n - 1` duplicates, so `duplicate` and `insert` read differently in a
    /// confirmation sheet even though both grow the document.
    ///
    /// A move is a change of **relative order**, not of absolute index: the retained pages
    /// on the longest increasing run of source indices kept their order and are not moved;
    /// only the rest are. Deleting a cover sheet from a 300-page set therefore reads
    /// "1 deleted", not "1 deleted, 299 moved" — which is what the old absolute-index rule
    /// reported (documents bug 6).
    private static func diff(
        initialRotations: [Int],
        document: DocumentHandle,
        resulting: [PlannedPage]
    ) -> [PageOperationChange] {
        var changes: [PageOperationChange] = []
        var firstOccurrence: [PageReference: Int] = [:]

        // Own pages retained, in result order, to find the ones whose relative order held.
        var retained: [(source: Int, resultIndex: Int)] = []
        for (resultIndex, page) in resulting.enumerated() {
            let reference = page.source
            guard reference.document == document,
                  reference.pageIndex < initialRotations.count,
                  firstOccurrence[reference] == nil else { continue }
            firstOccurrence[reference] = resultIndex
            retained.append((reference.pageIndex, resultIndex))
        }
        let stayed = longestIncreasingRun(retained.map(\.source))
        firstOccurrence.removeAll(keepingCapacity: true)

        for (resultIndex, page) in resulting.enumerated() {
            let reference = page.source
            let isOwnPage = reference.document == document
                && reference.pageIndex < initialRotations.count

            if firstOccurrence[reference] != nil {
                changes.append(.duplicated(source: reference, atResultIndex: resultIndex))
                continue
            }
            firstOccurrence[reference] = resultIndex

            if isOwnPage {
                if !stayed.contains(reference.pageIndex) {
                    changes.append(
                        .moved(source: reference, fromIndex: reference.pageIndex, toIndex: resultIndex)
                    )
                }
                let before = PageRotationMath.normalised(initialRotations[reference.pageIndex])
                if before != page.rotation {
                    changes.append(.rotated(source: reference, from: before, to: page.rotation))
                }
            } else {
                changes.append(.inserted(source: reference, atResultIndex: resultIndex))
            }
        }

        for index in 0..<initialRotations.count {
            let reference = PageReference(document: document, pageIndex: index)
            if firstOccurrence[reference] == nil {
                changes.append(.deleted(source: reference))
            }
        }
        return changes
    }

    /// The values on one longest strictly increasing subsequence of `values` (patience
    /// sorting, O(n log n), so a 100 000-page plan stays cheap). Deterministic: among equal
    /// lengths it keeps the run the classic algorithm reconstructs.
    static func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = []          // indices into `values`
        var previous = [Int](repeating: -1, count: values.count)
        for (i, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var run: Set<Int> = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.insert(values[cursor])
            cursor = previous[cursor]
        }
        return run
    }
}

private extension RotationChange {
    var requestedDegrees: Int {
        switch self {
        case let .relative(degrees): return degrees
        case let .absolute(degrees): return degrees
        }
    }
}
