import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFVectorExtraction

/// T-066: a clipped drawing of the boxed CAD
/// block reaches the Symbol Schedule review as a near-miss row at its own position, which the
/// person can tick — not as one of the "other shapes [that] did not resemble the symbol".
struct Iter3RPartialBlockReviewTests {

    /// A door Form XObject `/D` (sill 20, jamb 12, stop 6) drawn at (60, 100), (160, 100),
    /// (260, 100) and (360, 100). The first drawing sits inside a clip `x ≤ 70`, which leaves its
    /// stop (80,100)–(80,106) wholly outside, so the extractor drops it: that drawing produces 2
    /// primitives, the others 3.
    static func fourDoorsFirstClipped() throws -> URL {
        let door = "1 w 0 0 m 20 0 l S 0 0 m 0 12 l S 20 0 m 20 6 l S"
        let placements = ["0 0 70 842 re W n 1 0 0 1 60 100", "1 0 0 1 160 100", "1 0 0 1 260 100", "1 0 0 1 360 100"]
        let page = placements.map { "q \($0) cm /D Do Q" }.joined(separator: "\n")
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Contents 4 0 R /Resources << /XObject << /D 5 0 R >> >> >>",
            "<< /Length \(page.utf8.count) >>\nstream\n\(page)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [-5 -5 40 40] /Length \(door.utf8.count) >>\nstream\n\(door)\nendstream",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-block-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test("T-066: the clipped door of an exact block is a near-miss row at its own position, and no other shape")
    func clippedBlockDrawingIsAReviewRow() async throws {
        let url = try Self.fourDoorsFirstClipped()
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let invocations = try #require(extraction.formInvocations)
        // Precondition: the clip really removed the first drawing's stop.
        #expect(invocations.map(\.primitiveCount) == [2, 3, 3, 3])
        // The exemplar is the second, whole drawing: 160…180 × 100…112.
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 155, minY: 95, maxX: 185, maxY: 117)
        )
        let report = try #require(ExactBlockMatcher.matches(
            exemplar: exemplar, extraction: extraction, visible: extraction.primitives
        ))

        let result = SymbolCountReviewBuilder().pageResult(
            pageID: PageID(UUID()), pageIndex: 0, exemplar: exemplar, report: report, existing: []
        )
        // Old output (the drawing rejected as `.partialOverlap`, which is never a near miss):
        // confirmed 3, near misses 0, otherShapeCount 1 — no row, no position, nothing to tick,
        // and the summary called a clipped copy of the block a shape that "did not resemble the
        // symbol".
        #expect(result.confirmedCount == 3, "\(result.candidates.map(\.status))")
        #expect(result.nearMissCount == 1, "\(result.candidates.map(\.status))")
        #expect(result.otherShapeCount == 0)
        #expect(result.candidates.count == 4)

        let row = try #require(result.candidates.first { if case .nearMiss = $0.status { true } else { false } })
        #expect(row.status == .nearMiss(.partialBlock(visible: 2, total: 3)))
        #expect(!row.isSelectedByDefault && !row.isExemplar)
        // At the clipped door: the exemplar's centroid carried 100 pt to the left.
        #expect(abs(row.position.x - (exemplar.centroid.x - 100)) < 1e-9, "\(row.position)")
        #expect(abs(row.position.y - exemplar.centroid.y) < 1e-9, "\(row.position)")
        // Bounds of the two strokes that survived the clip: sill 60…80 at y 100, jamb to y 112.
        #expect(row.bounds.contains(VectorBounds(minX: 60, minY: 100, maxX: 80, maxY: 112)), "\(row.bounds)")
        #expect(row.bounds.minX > 58 && row.bounds.maxX < 82, "\(row.bounds)")

        // Ticking it lands a fourth count point, at the clipped door.
        let accepted = SymbolCountReviewBuilder.acceptedPositions(
            from: [result], selected: Set(result.candidates.map(\.id)), exemplar: exemplar
        )
        #expect(accepted.first?.positions.count == 4)
        #expect(accepted.first?.positions.contains(row.position) == true)
        // Left unticked (the default), the three whole doors land.
        let byDefault = SymbolCountReviewBuilder.acceptedPositions(
            from: [result], selected: Set(result.candidates.filter(\.isSelectedByDefault).map(\.id)), exemplar: exemplar
        )
        #expect(byDefault.first?.positions.count == 3)
    }

    @Test("T-066: only a drawing of the block is lifted; a geometric cluster cut by the search edge stays an other shape")
    func partialOverlapStaysAnOtherShape() throws {
        let primitives = SymbolCountReviewTests.sheet()
        let exemplar = try SymbolCountReviewTests.exemplar(primitives)
        let bounds = VectorBounds(minX: 0, minY: 0, maxX: 20, maxY: 12)
        // Two of the exemplar's three primitives either way; only the reason differs.
        let cluster = SymbolRejection(primitiveIDs: [1, 2], position: .zero, bounds: bounds, reason: .partialOverlap)
        let block = SymbolRejection(
            primitiveIDs: [1, 2], position: .zero, bounds: bounds, reason: .partialBlock(visible: 2, total: 3)
        )
        #expect(!SymbolCountReviewBuilder.isNearMiss(cluster, exemplar: exemplar))
        #expect(SymbolCountReviewBuilder.isNearMiss(block, exemplar: exemplar))
        // However little of the block shows, it is still the block.
        let sliver = SymbolRejection(
            primitiveIDs: [1], position: .zero, bounds: bounds, reason: .partialBlock(visible: 1, total: 12)
        )
        #expect(SymbolCountReviewBuilder.isNearMiss(sliver, exemplar: exemplar))
    }
}
