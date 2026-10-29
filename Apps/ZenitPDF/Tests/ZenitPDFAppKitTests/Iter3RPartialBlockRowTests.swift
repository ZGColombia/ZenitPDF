import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIWorkflows
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Loop iteration 3, render-extract-search re-fix (T-066): a clipped drawing of the boxed CAD
/// block reaches the Symbol Schedule review as a row — the exact report through
/// `SymbolCountReviewBuilder.pageResult`, the window's `reviewRow` and the review model, the
/// chain the exact path in `ProjectWindowController+SymbolSchedule` runs.
@MainActor
@Suite("Clipped exact block as a review row (iter3 re-fix T-066)", .appTierSerialised)
struct Iter3RPartialBlockRowTests {

    /// Four drawings of a door Form XObject; the first under a clip `x ≤ 70` that drops its stop.
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-block-row-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test("T-066: the review lists the clipped door as a near miss the person can tick, and no shape as unlike the symbol")
    func clippedDoorIsAReviewRow() async throws {
        let url = try Self.fourDoorsFirstClipped()
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 155, minY: 95, maxX: 185, maxY: 117)
        )
        let block = try #require(ExactBlockMatcher.block(of: exemplar, in: extraction))
        let report = ExactBlockMatcher.instances(
            of: block, in: extraction, visible: extraction.primitives, isExemplarPage: true
        )
        let result = SymbolCountReviewBuilder().pageResult(
            pageID: PageID(UUID()), pageIndex: 0, exemplar: exemplar, report: report, existing: []
        )
        let rows = result.candidates.map { ProjectWindowController.reviewRow($0, pageLabel: "A-101", exactBlock: true) }
        let model = SymbolCountReviewModel(designation: "D-1", pageTotal: 1, onAccept: { _ in }, onCancel: {})
        model.append(
            page: SymbolCountReviewPage(
                pageIndex: 0, pageLabel: "A-101", otherShapeCount: result.otherShapeCount, isTruncated: false
            ),
            rows: rows
        )

        // Old output: 3 rows, the summary "3 confirmed, 0 near miss(es) shown; 1 other shapes did
        // not resemble the symbol." — the clipped door had no row and could not be accepted.
        #expect(model.confirmedCount == 3 && model.nearMissCount == 1 && model.otherShapeCount == 0, "\(model.summaryText)")
        let row = try #require(model.rows.first { $0.status == .nearMiss })
        #expect(abs(row.position.x - (exemplar.centroid.x - 100)) < 1e-9 && abs(row.position.y - exemplar.centroid.y) < 1e-9)
        #expect(row.statusText == "Near miss")
        #expect(row.detail == "exact block · partly hidden — 2 of 3 strokes visible", "\(row.detail)")
        #expect(!model.selectedRowIDs.contains(row.id), "left for the person to decide")
        // The whole drawings keep the exact detail alone.
        #expect(model.rows.filter { $0.status == .confirmed }.allSatisfy { $0.detail == "exact block" })
    }
}
