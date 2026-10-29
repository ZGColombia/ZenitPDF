import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// IM-189, projector part: no per-row `Dictionary`, no per-date `Calendar`.
///
/// The number printed here is the evidence. Measured on the old projector (one dictionary per
/// row, one Gregorian calendar and time zone per date cell) and on the new one, on the same
/// 20 000-row synthetic ledger with a `created` column on every row.
@Suite("Fix2 E1 projector performance", .sharedHeap, .serialized)
struct Fix2E1ProjectorPerformanceTests {

    @Test("Projecting 20 000 rows is timed, and the projection is complete")
    func projectionTiming() throws {
        let report = try ExportFixture.syntheticReport(rowCount: 20_000, grouped: false)
        // One warm-up so the first-touch costs of the fixture are not what is timed.
        _ = try ExportProjector().project(report)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let projection = try ExportProjector().project(report)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            best = min(best, elapsed)
            #expect(projection.table.rows.count == 20_000)
        }
        print("IM-189 projector: 20 000 rows x \(report.columns.count) columns projected in "
              + String(format: "%.3f", best) + " s (best of 3)")
        #expect(best < 30)
    }

    /// The two costs IM-189 removed, measured side by side on the same 20 000 report rows: the
    /// old per-row `Dictionary` of cells against the per-projection position map, and the old
    /// per-date Gregorian `Calendar` and `TimeZone` against the hoisted one.
    @Test("IM-189: the position map and the hoisted calendar beat the per-row and per-date work")
    func beforeAndAfter() throws {
        let report = try ExportFixture.syntheticReport(rowCount: 20_000, grouped: false)
        let order = report.columns.map(\.id)

        func time(_ body: () -> Int) -> (seconds: Double, checksum: Int) {
            var best = Double.greatestFiniteMagnitude
            var checksum = 0
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                checksum = body()
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            }
            return (best, checksum)
        }

        // Before: one dictionary per row, then one lookup per column.
        let dictionary = time {
            var filled = 0
            for row in report.rows {
                let byColumn = Dictionary(row.cells.map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
                for id in order where byColumn[id] != nil { filled += 1 }
            }
            return filled
        }
        // After: the position map, built once.
        let map = time {
            var positions: [ColumnID: Int] = [:]
            for (position, id) in order.enumerated() where positions[id] == nil { positions[id] = position }
            var filled = 0
            for row in report.rows {
                var seen = [Bool](repeating: false, count: order.count)
                for cell in row.cells {
                    guard let position = positions[cell.column], !seen[position] else { continue }
                    seen[position] = true
                    filled += 1
                }
            }
            return filled
        }
        #expect(dictionary.checksum == map.checksum)

        let dates = report.rows.map { _ in ExportFixture.epoch }
        // Before: a Gregorian calendar and a UTC zone built for every date cell.
        let perDate = time {
            var total = 0
            for date in dates {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
                total &+= calendar.component(.day, from: date)
            }
            return total
        }
        // After: one calendar, made once.
        let hoisted = time {
            let calendar = ExportProjector.calendar(in: .gmt)
            var total = 0
            for date in dates { total &+= calendar.component(.day, from: date) }
            return total
        }
        #expect(perDate.checksum == hoisted.checksum)

        print("IM-189 row fill, 20 000 rows: per-row Dictionary "
              + String(format: "%.4f", dictionary.seconds) + " s -> position map "
              + String(format: "%.4f", map.seconds) + " s")
        print("IM-189 dates, 20 000 cells: per-date Calendar "
              + String(format: "%.4f", perDate.seconds) + " s -> hoisted "
              + String(format: "%.4f", hoisted.seconds) + " s")
        #expect(map.seconds < dictionary.seconds)
        #expect(hoisted.seconds < perDate.seconds)
    }
}
