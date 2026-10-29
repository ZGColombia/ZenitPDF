import Foundation
import Darwin
import Testing
import ZPDFQuantityLedger
@testable import ZPDFExport

/// `make benchmark-export` in miniature (QUALITY_BAR 4.7).
///
/// The thresholds asserted here are deliberately loose — they are "this did not blow up on the
/// machine that ran it", not the reference-machine budgets, which belong in
/// `Docs/Execution/quality-thresholds.json` and to CI. What the suite is really for is the
/// printed numbers: an export that quietly goes from two seconds to two minutes, or from
/// 40 MB to 4 GB, shows up here before a user finds it.
@Suite("Export benchmark", .sharedHeap, .serialized)
struct ExportBenchmarkTests {

    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    struct Measurement {
        let seconds: Double
        let residentDeltaMB: Double
        let outputBytes: Int
    }

    static func measure(_ body: () throws -> Int) rethrows -> Measurement {
        let beforeBytes = residentBytes()
        let start = DispatchTime.now().uptimeNanoseconds
        let produced = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let delta = Double(max(0, residentBytes() - beforeBytes)) / 1_048_576
        return Measurement(seconds: elapsed, residentDeltaMB: delta, outputBytes: produced)
    }

    @Test("10 000 rows through all four exporters, timed and measured")
    func fourFormats() throws {
        let report = try ExportFixture.syntheticReport(rowCount: 10_000)
        let projection = try ExportFixture.projection(report)
        #expect(projection.table.metadata.rowCount == 10_000)

        let xlsxURL = temporaryURL("xlsx")
        let xlsxStreamURL = temporaryURL("xlsx")
        let pdfURL = temporaryURL("pdf")
        defer {
            for url in [xlsxURL, xlsxStreamURL, pdfURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let csv = try Self.measure { try CSVExporter().export(projection).count }
        let json = Self.measure { ZenitJSONExporter().export(projection).count }
        let xlsx = try Self.measure {
            try XLSXExporter().export(projection, to: xlsxURL)
            return try Self.size(of: xlsxURL)
        }
        let xlsxStream = try Self.measure {
            try XLSXExporter().export(
                projection, to: xlsxStreamURL, options: XLSXExportOptions(constantMemory: true)
            )
            return try Self.size(of: xlsxStreamURL)
        }
        let pdf = try Self.measure {
            _ = try PDFReportRenderer().render(projection, to: pdfURL)
            return try Self.size(of: pdfURL)
        }

        let rows: [(String, Measurement)] = [
            ("CSV", csv),
            ("JSON (.zpdfjson)", json),
            ("XLSX", xlsx),
            ("XLSX constant-memory", xlsxStream),
            ("PDF report", pdf)
        ]
        var lines: [String] = ["benchmark-export, 10 000 rows, 10 columns, one grouping level:"]
        for (name, measurement) in rows {
            let label: String = name.padding(toLength: 22, withPad: " ", startingAt: 0)
            let seconds: String = String(format: "%.3f", measurement.seconds)
            let resident: String = String(format: "%.1f", measurement.residentDeltaMB)
            lines.append(
                "  " + label + seconds + " s   RSS delta " + resident
                    + " MB   output " + String(measurement.outputBytes) + " bytes"
            )
        }
        print(lines.joined(separator: "\n"))

        // Loose ceilings: a regression of an order of magnitude fails, ordinary variance does not.
        #expect(csv.seconds < 20)
        #expect(json.seconds < 30)
        #expect(xlsx.seconds < 60)
        #expect(pdf.seconds < 120)
        for (name, measurement) in rows {
            #expect(measurement.outputBytes > 1000, "\(name) produced nothing")
            #expect(measurement.residentDeltaMB < 900, "\(name) resident set grew too far")
        }
    }

    static func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes[.size] as? Int ?? 0
    }
}
