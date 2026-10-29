import Foundation
import GRDB
import Testing
import ZPDFPersistence

/// The 100 000-row envelope from QUALITY_BAR 4.7, at the persistence layer.
///
/// These print their measurements. A number without its raw output is not evidence, and
/// a threshold that is only in a comment is not a threshold — the assertions here are
/// deliberately loose ceilings that catch an order-of-magnitude regression, while the
/// printed p50/p95/p99/max is the number a human reads.
struct PerformanceTests {

    static let markupCount = 100_000
    static let pageCount = 50
    static let zoneCount = 20

    private func printSpread(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            TestSupport.percentile(sorted, fraction)
        }
        print(String(
            format: "  %@: n=%d  p50=%.3f ms  p95=%.3f ms  p99=%.3f ms  max=%.3f ms",
            label, sorted.count, percentile(0.5), percentile(0.95), percentile(0.99),
            sorted.last ?? 0
        ))
    }

    @Test("100 000 markups insert in one transaction, and page and zone queries stay fast")
    func hundredThousandMarkups() async throws {
        let workspace = try TestSupport.makeWorkspace("Perf")
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let package = try await TestSupport.createPackage(workspace)
        let documentId = try await TestSupport.documentIdentifier(of: package)
        _ = try await TestSupport.projectIdentifier(of: package)

        let pageIds = (0..<Self.pageCount).map { "page-\($0)" }
        let zoneIds = (0..<Self.zoneCount).map { "zone-\($0)" }
        let geometry = try TestSupport.sampleGeometry(pointCount: 16)
        let zonePolygon = try GeometryBlob(kind: .polygon, points: [
            GeometryPoint(x: 0, y: 0), GeometryPoint(x: 100, y: 0),
            GeometryPoint(x: 100, y: 100), GeometryPoint(x: 0, y: 100)
        ]).encode()

        try await package.write { db in
            for (index, pageId) in pageIds.enumerated() {
                try PageRecord(
                    id: pageId, documentId: documentId, pageIndex: index,
                    mediaX: 0, mediaY: 0, mediaWidth: 1684, mediaHeight: 2384,
                    cropX: 0, cropY: 0, cropWidth: 1684, cropHeight: 2384,
                    rotation: 0
                ).insert(db)
            }
            for (index, zoneId) in zoneIds.enumerated() {
                try ProjectZoneRecord(
                    id: zoneId, pageId: pageIds[index % pageIds.count],
                    name: "Zone \(index)", polygonBlob: zonePolygon,
                    sortOrder: index, colorRgba: PackedRGBA(packedValue: 0x3366_99FF)
                ).insert(db)
            }
        }

        // ── The insert, in one transaction ──────────────────────────────────────────
        let total = Self.markupCount
        let statuses = ["draft", "reviewed", nil, nil, nil, nil, nil, nil]
        let insertStart = DispatchTime.now()
        try await package.write { db in
            for index in 0..<total {
                try MarkupRecord(
                    id: "m-\(index)",
                    documentId: documentId,
                    pageId: pageIds[index % pageIds.count],
                    type: index % 3 == 0 ? "count" : "polyline",
                    subject: "Item \(index)",
                    label: "L\(index)",
                    geometryBlob: geometry,
                    styleBlob: Data([UInt8(index % 251)]),
                    zoneId: zoneIds[index % zoneIds.count],
                    status: statuses[index % statuses.count],
                    createdAt: TestSupport.seedTimestamp,
                    modifiedAt: TestSupport.seedTimestamp
                ).insert(db)
                try MeasurementValueRecord(
                    markupId: "m-\(index)",
                    planLengthSi: DecimalString(text: "\(index).3333333333333333333333333333"),
                    formulaVersion: 1
                ).insert(db)
            }
        }
        let insertSeconds = Double(DispatchTime.now().uptimeNanoseconds - insertStart.uptimeNanoseconds) / 1e9

        print("")
        print("ZPDFPersistence — 100 000-markup envelope")
        print(String(format: "  insert: %d markups + %d measurement rows in one transaction: %.3f s (%.0f rows/s)",
                     total, total, insertSeconds, Double(total * 2) / insertSeconds))

        let saveStart = DispatchTime.now()
        let receipt = try await package.save()
        let saveSeconds = Double(DispatchTime.now().uptimeNanoseconds - saveStart.uptimeNanoseconds) / 1e9
        print(String(format: "  save pipeline (validate → swap): %.3f s, database %.1f MB",
                     saveSeconds, Double(receipt.databaseByteCount) / 1_048_576))

        // ── Query by page ───────────────────────────────────────────────────────────
        var byPage: [Double] = []
        for iteration in 0..<200 {
            let pageId = pageIds[iteration % pageIds.count]
            let start = DispatchTime.now()
            let count = try await package.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM markup WHERE page_id = ?", arguments: [pageId]
                ) ?? -1
            }
            byPage.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            #expect(count == total / Self.pageCount)
        }
        printSpread("query by page  ", byPage)

        // ── Query by zone ───────────────────────────────────────────────────────────
        var byZone: [Double] = []
        for iteration in 0..<200 {
            let zoneId = zoneIds[iteration % zoneIds.count]
            let start = DispatchTime.now()
            let count = try await package.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM markup WHERE zone_id = ?", arguments: [zoneId]
                ) ?? -1
            }
            byZone.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            #expect(count == total / Self.zoneCount)
        }
        printSpread("query by zone  ", byZone)

        // ── Fetching whole rows, which is what the canvas actually does ─────────────
        var pageRows: [Double] = []
        for iteration in 0..<50 {
            let pageId = pageIds[iteration % pageIds.count]
            let start = DispatchTime.now()
            let rows = try await package.read { db in
                try MarkupRecord.fetchAll(
                    db, sql: "SELECT * FROM markup WHERE page_id = ?", arguments: [pageId]
                )
            }
            pageRows.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            #expect(rows.count == total / Self.pageCount)
        }
        printSpread("fetch page rows", pageRows)
        print("")

        // Ceilings, not targets: an order-of-magnitude regression fails the test, and
        // the printed spread above is what a human compares against the baseline.
        #expect(TestSupport.percentile(byPage, 0.95) < 100,
                "query-by-page p95 regressed past 100 ms")
        #expect(TestSupport.percentile(byZone, 0.95) < 100,
                "query-by-zone p95 regressed past 100 ms")
        #expect(insertSeconds < 180, "the 100 000-markup insert took \(insertSeconds) s")

        // Correctness after the benchmark, per QUALITY_BAR 4.7 rule 2.
        #expect(try ProjectPackage.verifyIntegrity(at: workspace.packageURL).isFullyConsistent)
        let sampled = try await package.read { db in
            try MeasurementValueRecord.fetchOne(db, key: ["markup_id": "m-99999"])
        }
        #expect(sampled?.planLengthSi?.canonicalText == "99999.3333333333333333333333333333")
        try await package.close()
    }
}
