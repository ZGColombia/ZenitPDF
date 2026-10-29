import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// The dry run, tested as pure arithmetic.
///
/// Every rejection a page operation can suffer happens in the planner, before a writer
/// exists, so these tests are the ones that decide whether a malformed batch can reach
/// the file system at all.
@Suite("Page operation planning")
struct PageOperationPlannerTests {

    let document = DocumentHandle(rawValue: 1)
    let other = DocumentHandle(rawValue: 2)

    func plan(
        _ operations: [PageOperation],
        pages: Int = 4,
        rotations: [Int]? = nil,
        otherPages: Int = 3,
        limits: DocumentLimits = .standard
    ) throws(PageOperationFault) -> PageOperationPlan {
        try PageOperationPlanner.plan(
            operations: operations,
            document: document,
            initialRotations: rotations ?? Array(repeating: 0, count: pages),
            pageCounts: [document: pages, other: otherPages],
            limits: limits
        )
    }

    @Test("An empty batch is a no-op that still reports every page")
    func emptyBatch() throws {
        let result = try plan([])
        #expect(result.resultingPages.count == 4)
        #expect(result.isNoOp)
        #expect(result.changes.isEmpty)
        #expect(result.resultingPages.map(\.source.pageIndex) == [0, 1, 2, 3])
    }

    @Test("Reorder is a permutation, and the diff names the moves")
    func reorder() throws {
        let result = try plan([.reorder(order: [3, 1, 0, 2])])
        #expect(result.resultingPages.map(\.source.pageIndex) == [3, 1, 0, 2])
        // Two moves make [3, 1, 0, 2] from [0, 1, 2, 3] (3 to the front, 1 before 0); the old
        // absolute-index rule reported 3. Page 2 keeps its order relative to the rest.
        #expect(result.summary.moved == 2)
        #expect(result.summary.deleted == 0)
        #expect(!result.changes.contains { change in
            if case let .moved(source, _, _) = change { return source.pageIndex == 2 }
            return false
        })
    }

    @Test("A reorder that is not a permutation is rejected")
    func badReorder() {
        #expect(throws: PageOperationFault.notAPermutation(expectedCount: 4, receivedCount: 3)) {
            try plan([.reorder(order: [0, 1, 2])])
        }
        #expect(throws: PageOperationFault.notAPermutation(expectedCount: 4, receivedCount: 3)) {
            try plan([.reorder(order: [0, 1, 1, 2])])
        }
    }

    @Test("Rotation is relative or absolute and always normalised")
    func rotation() throws {
        let relative = try plan(
            [.rotate(pageIndices: [0, 2], change: .relative(degrees: -90))],
            rotations: [0, 0, 270, 90]
        )
        #expect(relative.resultingPages.map(\.rotation) == [270, 0, 180, 90])
        #expect(relative.summary.rotated == 2)

        let absolute = try plan(
            [.rotate(pageIndices: [1], change: .absolute(degrees: 450))],
            rotations: [0, 0, 0, 0]
        )
        #expect(absolute.resultingPages[1].rotation == 90)
    }

    @Test("A rotation that is not a multiple of ninety is rejected")
    func badRotation() {
        #expect(throws: PageOperationFault.rotationNotMultipleOfNinety(degrees: 45)) {
            try plan([.rotate(pageIndices: [0], change: .relative(degrees: 45))])
        }
    }

    @Test("Delete removes pages and reports each one")
    func delete() throws {
        let result = try plan([.delete(pageIndices: [1, 2])])
        #expect(result.resultingPages.map(\.source.pageIndex) == [0, 3])
        #expect(result.summary.deleted == 2)
        // Page 3 slid up to index 1 but kept its order: not a move. The old code said 1.
        #expect(result.summary.moved == 0)
    }

    /// Documents bug 6: deleting the cover of a 300-page set read "1 deleted,
    /// 299 moved" under the old absolute-index rule.
    @Test("Deleting a cover sheet reports one deletion and no moves")
    func deleteCoverOfLargeSet() throws {
        let result = try PageOperationPlanner.plan(
            operations: [.delete(pageIndices: [0])],
            document: document,
            initialRotations: Array(repeating: 0, count: 300),
            pageCounts: [document: 300]
        )
        #expect(result.summary.deleted == 1)
        #expect(result.summary.moved == 0)
        #expect(result.resultingPages.count == 299)
    }

    @Test("Moving one sheet to the end of a set is one move, whatever it shifts")
    func singleMoveIsOneMove() throws {
        let result = try PageOperationPlanner.plan(
            operations: [.reorder(order: Array(1..<10) + [0])],
            document: document,
            initialRotations: Array(repeating: 0, count: 10),
            pageCounts: [document: 10]
        )
        #expect(result.summary.moved == 1)
        #expect(result.changes == [.moved(source: .init(document: document, pageIndex: 0), fromIndex: 0, toIndex: 9)])
        #expect(PageOperationPlanner.longestIncreasingRun([]) == [])
        #expect(PageOperationPlanner.longestIncreasingRun([5, 1, 2, 9, 3]) == [1, 2, 3])
    }

    @Test("Deleting every page is refused: a PDF with no pages is not a PDF")
    func deleteEverything() {
        #expect(throws: PageOperationFault.resultWouldBeEmpty) {
            try plan([.delete(pageIndices: [0, 1, 2, 3])])
        }
    }

    @Test("Insert pulls pages from another open document")
    func insert() throws {
        let result = try plan([
            .insert(
                pages: [
                    PageReference(document: other, pageIndex: 2),
                    PageReference(document: other, pageIndex: 0)
                ],
                atIndex: 1
            )
        ])
        #expect(result.resultingPages.count == 6)
        #expect(result.resultingPages[1].source == PageReference(document: other, pageIndex: 2))
        #expect(result.summary.inserted == 2)
        #expect(result.externalDocuments == [other])
    }

    @Test("Insert from a document that is not open is rejected")
    func insertUnknownDocument() {
        let stranger = DocumentHandle(rawValue: 99)
        #expect(throws: PageOperationFault.unknownDocument(stranger)) {
            try plan([.insert(pages: [PageReference(document: stranger, pageIndex: 0)], atIndex: 0)])
        }
    }

    @Test("Insert past the end is rejected, insert at the end is not")
    func insertBounds() throws {
        #expect(throws: PageOperationFault.insertIndexOutOfRange(index: 5, count: 4)) {
            try plan([.insert(pages: [PageReference(document: other, pageIndex: 0)], atIndex: 5)])
        }
        let appended = try plan([.insert(pages: [PageReference(document: other, pageIndex: 0)], atIndex: 4)])
        #expect(appended.resultingPages.count == 5)
    }

    @Test("Extract keeps only the named pages, in the order named")
    func extract() throws {
        let result = try plan([.extract(pageIndices: [3, 0])])
        #expect(result.resultingPages.map(\.source.pageIndex) == [3, 0])
        #expect(result.summary.deleted == 2)
    }

    @Test("Extract with a repeated index is rejected; duplicate is the operation for that")
    func extractDuplicate() {
        #expect(throws: PageOperationFault.duplicatePageIndex(1)) {
            try plan([.extract(pageIndices: [1, 1])])
        }
    }

    @Test("Merge appends every page of another document")
    func merge() throws {
        let result = try plan([.merge(document: other, pageCount: 3)])
        #expect(result.resultingPages.count == 7)
        #expect(result.resultingPages.suffix(3).map(\.source.document) == [other, other, other])
        #expect(result.summary.inserted == 3)
    }

    @Test("Duplicate puts each copy directly after its original")
    func duplicate() throws {
        let result = try plan([.duplicate(pageIndices: [0, 2])])
        #expect(result.resultingPages.map(\.source.pageIndex) == [0, 0, 1, 2, 2, 3])
        #expect(result.summary.duplicated == 2)
    }

    @Test("Operations compose in order, and indices always mean the current state")
    func composition() throws {
        let result = try plan([
            .delete(pageIndices: [0]),
            .reorder(order: [2, 0, 1]),
            .rotate(pageIndices: [0], change: .relative(degrees: 90))
        ])
        #expect(result.resultingPages.map(\.source.pageIndex) == [3, 1, 2])
        #expect(result.resultingPages[0].rotation == 90)
        #expect(result.summary.deleted == 1)
        #expect(result.summary.rotated == 1)
    }

    @Test("An out-of-range index is rejected wherever it appears")
    func outOfRange() {
        #expect(throws: PageOperationFault.pageIndexOutOfRange(index: 9, count: 4)) {
            try plan([.delete(pageIndices: [9])])
        }
        #expect(throws: PageOperationFault.pageIndexOutOfRange(index: -1, count: 4)) {
            try plan([.rotate(pageIndices: [-1], change: .relative(degrees: 90))])
        }
    }

    @Test("The batch size and the resulting page count are both bounded")
    func limits() {
        var limits = DocumentLimits.standard
        limits.maximumPageOperations = 2
        #expect(throws: PageOperationFault.tooManyOperations(count: 3, limit: 2)) {
            try plan([.delete(pageIndices: [0]), .delete(pageIndices: [0]), .delete(pageIndices: [0])], limits: limits)
        }

        var pageLimit = DocumentLimits.standard
        pageLimit.maximumPageCount = 5
        #expect(throws: PageOperationFault.resultExceedsPageLimit(count: 7, limit: 5)) {
            try plan([.merge(document: other, pageCount: 3)], limits: pageLimit)
        }
    }
}
