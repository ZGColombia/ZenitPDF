import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Feature 16 — traceable bid export.
///
/// Every exported row carries the sheet it was drawn on, the scale it was **measured under**, the
/// date, and who measured it. The tests that matter are the last two: a re-measured row shows the
/// later date, and a row whose scale cannot be recovered says `unknown` rather than borrowing the
/// scale that happens to be in force now.
@Suite("Traceable export", .sharedHeap)
struct TraceableExportTests {

    // MARK: - Fixture

    /// One trace per golden row. Row 3 is deliberately left without one, to exercise the row that
    /// has no provenance at all.
    static func traces() throws -> [String: ExportRowTrace] {
        var traces: [String: ExportRowTrace] = [:]
        for index in 0..<ExportFixture.goldenValues.count where index != 3 {
            let id = MarkupID(ExportFixture.uuid(index)).rawValue.uuidString
            traces[id] = ExportRowTrace(
                sheetLabel: "A-1\(index)",
                // Row 4 is the recalibrated markup: its scale at measure time is not recoverable.
                scaleAtMeasureTime: index == 4 ? nil : "1:\(50 + index)",
                scaleRegionLabel: index == 2 ? "Basement" : nil,
                createdAt: ExportFixture.epoch.addingTimeInterval(Double(index) * 3600),
                measuredAt: ExportFixture.epoch.addingTimeInterval(Double(index) * 3600),
                author: index % 2 == 0 ? "Ada" : "Grace"
            )
        }
        return traces
    }

    static func tracedProjection(
        traces: [String: ExportRowTrace]? = nil
    ) throws -> ExportProjection {
        try ExportProjector().project(
            try ExportFixture.goldenReport(),
            options: ExportProjectionOptions(rowTraces: try traces ?? Self.traces())
        )
    }

    private func records(_ data: Data) -> [[String]] {
        CSVReader.records(String(decoding: data, as: UTF8.self), delimiter: ",")
    }

    // MARK: - The columns

    @Test("The trace columns are appended after every existing column")
    func columnsComeLast() throws {
        let plain = try ExportProjector().project(try ExportFixture.goldenReport())
        let traced = try Self.tracedProjection()

        let plainHeader = records(try CSVExporter().export(plain))[0]
        let tracedHeader = records(try CSVExporter().export(traced))[0]

        // Every old column, at its old index, followed by the six new ones.
        #expect(Array(tracedHeader.prefix(plainHeader.count)) == plainHeader)
        #expect(Array(tracedHeader.dropFirst(plainHeader.count)) == ExportRowTrace.columnTitles)
    }

    @Test("A projection with no traces exports the bytes it always did")
    func untracedIsUnchanged() throws {
        let plain = try ExportProjector().project(try ExportFixture.goldenReport())
        #expect(!plain.table.carriesRowTraces)

        let csv = try CSVExporter().export(plain)
        #expect(!records(csv)[0].contains { $0.hasPrefix("Trace: ") })

        // And the JSON has no "trace" key anywhere, so the round trip is byte-identical.
        let json = String(decoding: ZenitJSONExporter().export(plain), as: UTF8.self)
        #expect(!json.contains("\"trace\""))
        let reexported = ZenitJSONExporter()
            .encode(try ZenitJSONImporter().document(from: Data(json.utf8)))
        #expect(String(decoding: reexported, as: UTF8.self) == json)
    }

    // MARK: - A row's trace matches the record

    @Test("A row's trace columns carry that row's sheet, scale, region, dates and author")
    func rowTraceMatchesTheRecord() throws {
        let traces = try Self.traces()
        let projection = try Self.tracedProjection(traces: traces)
        let rows = records(try CSVExporter().export(projection))
        let header = rows[0]

        let sheet = try #require(header.firstIndex(of: "Trace: Sheet"))
        let scale = try #require(header.firstIndex(of: "Trace: Scale"))
        let region = try #require(header.firstIndex(of: "Trace: Scale region"))
        let created = try #require(header.firstIndex(of: "Trace: Created"))
        let measured = try #require(header.firstIndex(of: "Trace: Measured"))
        let author = try #require(header.firstIndex(of: "Trace: Author"))
        // r2-platform, ADR-0031: the capture column follows the author.
        let captured = try #require(header.firstIndex(of: "Trace: Captured"))
        let kind = try #require(header.firstIndex(of: "Record"))

        let dataRows = rows.dropFirst().filter { $0[kind] == "Row" }
        #expect(dataRows.count == ExportFixture.goldenValues.count)

        // Row 2: the one measured inside a Scale Region.
        let second = dataRows[2]
        let expected = try #require(traces[MarkupID(ExportFixture.uuid(2)).rawValue.uuidString])
        #expect(second[sheet] == "A-12")
        #expect(second[scale] == "1:52")
        #expect(second[region] == "Basement")
        #expect(second[created] == expected.createdText)
        #expect(second[measured] == expected.measuredText)
        #expect(second[author] == "Ada")

        // A subtotal or grand total was not measured by anyone, on any sheet, at any scale.
        let totals = rows.dropFirst().filter { $0[kind] != "Row" }
        #expect(!totals.isEmpty)
        for total in totals {
            #expect([total[sheet], total[scale], total[region],
                     total[created], total[measured], total[author], total[captured]] == ExportRowTrace.totalFieldTexts)
        }
    }

    @Test("The JSON carries the same trace on the same row and round-trips it")
    func jsonTrace() throws {
        let projection = try Self.tracedProjection()
        let data = ZenitJSONExporter().export(projection)
        let document = try ZenitJSONImporter().document(from: data)

        let traced = try #require(document.rows.first { $0.trace?.sheet == "A-12" })
        let trace = try #require(traced.trace)
        #expect(trace.scale == "1:52")
        #expect(trace.scaleRegion == "Basement")
        #expect(trace.author == "Ada")

        // Export, import, re-export: byte-identical, trace and all.
        #expect(ZenitJSONExporter().encode(document) == data)
    }

    // MARK: - A re-measured row shows the later date

    @Test("A re-measured row shows the later date, and its created date does not move")
    func reMeasuredRowShowsTheLaterDate() throws {
        let markup = MarkupID(ExportFixture.uuid(0)).rawValue.uuidString
        let created = ExportFixture.epoch
        let reMeasured = created.addingTimeInterval(86_400 * 7)

        var before = try Self.traces()
        before[markup] = ExportRowTrace(
            sheetLabel: "A-10",
            scaleAtMeasureTime: "1:50",
            createdAt: created,
            measuredAt: created,
            author: "Ada"
        )
        var after = before
        after[markup] = ExportRowTrace(
            sheetLabel: "A-10",
            scaleAtMeasureTime: "1:50",
            createdAt: created,
            // The markup was measured again a week later.
            measuredAt: reMeasured,
            author: "Ada"
        )

        func dates(_ traces: [String: ExportRowTrace]) throws -> (created: String, measured: String) {
            let rows = records(
                try CSVExporter().export(try Self.tracedProjection(traces: traces))
            )
            let header = rows[0]
            let createdColumn = try #require(header.firstIndex(of: "Trace: Created"))
            let measuredColumn = try #require(header.firstIndex(of: "Trace: Measured"))
            let kind = try #require(header.firstIndex(of: "Record"))
            let first = try #require(rows.dropFirst().first { $0[kind] == "Row" })
            return (first[createdColumn], first[measuredColumn])
        }

        let earlier = try dates(before)
        let later = try dates(after)

        #expect(earlier.measured == ExportProjector.iso8601(created))
        #expect(later.measured == ExportProjector.iso8601(reMeasured))
        #expect(later.measured > earlier.measured)
        // The creation date is not the measurement date, and re-measuring must not rewrite it.
        #expect(later.created == earlier.created)
        #expect(later.created == ExportProjector.iso8601(created))
    }

    // MARK: - The "unknown" path

    @Test("A scale that cannot be recovered exports as \"unknown\", never as the current scale")
    func unknownScale() throws {
        let projection = try Self.tracedProjection()
        let rows = records(try CSVExporter().export(projection))
        let header = rows[0]
        let scale = try #require(header.firstIndex(of: "Trace: Scale"))
        let kind = try #require(header.firstIndex(of: "Record"))
        let dataRows = rows.dropFirst().filter { $0[kind] == "Row" }

        // Row 4 was measured before a recalibration and its transform is gone.
        #expect(dataRows[4][scale] == "unknown")
        // Row 3 has no trace at all — the same answer, for the same reason.
        #expect(dataRows[3][scale] == "unknown")

        // The current document scale is "1:100 (calibrated, two-point)" in the fixture context.
        // Neither unknown row may have borrowed it, nor any other row's scale.
        let others = Set(dataRows.indices.filter { $0 != 3 && $0 != 4 }.map { dataRows[$0][scale] })
        #expect(!others.contains("unknown"))
        #expect(!dataRows[4][scale].contains("1:"))
        #expect(!dataRows[3][scale].contains("1:"))

        // A row with no trace still says "unknown" in every format.
        let json = String(decoding: ZenitJSONExporter().export(projection), as: UTF8.self)
        #expect(json.contains("\"scale\": \"unknown\""))
        #expect(ExportRowTrace.unknown.scaleText == "unknown")
    }
}
