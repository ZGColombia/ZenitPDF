import Foundation
import Darwin
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// Regression tests and measurements for the exporter findings IM-061, IM-062,
/// IM-063, BH-508, BH-510, BH-511, BH-512, BH-536, BH-537, BH-538.
@Suite("Fix2 E1 exporters", .exclusiveHeap, .serialized)
struct Fix2E1ExporterTests {

    // MARK: - Memory measurement

    /// Bytes the malloc zones hold right now — the Swift heap and libxlsxwriter's C heap alike.
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The highest heap level a sampling thread saw while `body` ran, above where it started,
    /// in MB. The process's own peak counters only ever rise, and building a 100 000-row
    /// projection has already set them higher than either export reaches, so the peak is
    /// sampled here, every millisecond, relative to the start of the body.
    static func peakHeapGrowthMB(_ body: () throws -> Void) rethrows -> Double {
        let sampler = HeapSampler()
        let baseline = heapInUse()
        sampler.start()
        defer { sampler.stop() }
        try body()
        sampler.stop()
        return Double(max(0, sampler.peak - baseline)) / 1_048_576
    }

    final class HeapSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        private var highest = 0
        private let done = DispatchSemaphore(value: 0)

        var peak: Int { lock.withLock { highest } }

        func start() {
            lock.withLock {
                running = true
                highest = Fix2E1ExporterTests.heapInUse()
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while lock.withLock({ running }) {
                    let now = Fix2E1ExporterTests.heapInUse()
                    lock.withLock { highest = max(highest, now) }
                    usleep(1_000)
                }
                done.signal()
            }
        }

        func stop() {
            let wasRunning = lock.withLock { () -> Bool in
                let value = running
                running = false
                return value
            }
            if wasRunning { done.wait() }
        }
    }

    // MARK: - IM-061

    @Test("IM-061: the streamed CSV is byte-identical to the Data export, in every option set")
    func streamedCSVIsByteIdentical() throws {
        let cases: [(LedgerReport, ExportNumberLocale, CSVExportOptions)] = [
            (try ExportFixture.goldenReport(), .invariant, CSVExportOptions()),
            (try ExportFixture.goldenReport(grouped: true), .enUS, CSVExportOptions(delimiter: ";", byteOrderMark: true)),
            (try ExportFixture.goldenReport(grouped: true), .svSE, .excelSwedish),
            (try ExportFixture.syntheticReport(rowCount: 20_000), .invariant, CSVExportOptions())
        ]
        for (report, locale, options) in cases {
            let projection = try ExportFixture.projection(report, locale: locale)
            let url = temporaryURL("csv")
            defer { try? FileManager.default.removeItem(at: url) }
            try CSVExporter().export(projection, options: options, to: url)
            let streamed = try Data(contentsOf: url)
            let inMemory = try CSVExporter().export(projection, options: options)
            #expect(streamed == inMemory)
            #expect(streamed.count > 100)
        }
    }

    @Test("IM-061: the streamed CSV replaces an existing file whole and leaves no partial file")
    func streamedCSVReplacesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdfexport-e1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.csv")
        try Data("previous export".utf8).write(to: url)

        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        try CSVExporter().export(projection, to: url)
        #expect(try Data(contentsOf: url) == (try CSVExporter().export(projection)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ledger.csv"])

        // A refused export (the delimiter is the decimal separator) leaves the old file alone.
        let swedish = try ExportFixture.projection(try ExportFixture.goldenReport(), locale: .svSE)
        #expect(throws: ExportError.self) {
            try CSVExporter().export(swedish, options: CSVExportOptions(delimiter: ","), to: url)
        }
        #expect(try Data(contentsOf: url) == (try CSVExporter().export(projection)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ledger.csv"])
    }

    @Test("IM-061: the file sink holds at most one flush threshold plus a record")
    func fileSinkIsBounded() throws {
        let projection = try ExportFixture.projection(try ExportFixture.syntheticReport(rowCount: 20_000))
        let url = temporaryURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var sink = FileSink(handle: handle, threshold: CSVExporter.streamFlushThreshold)
        try CSVExporter().write(projection, options: CSVExportOptions(), into: &sink)
        try sink.flush()
        try handle.close()
        let size = try Data(contentsOf: url).count
        #expect(size > 4 * CSVExporter.streamFlushThreshold)
        // The buffer never held the file: one threshold and the record that crossed it.
        #expect(sink.peakBufferedBytes < CSVExporter.streamFlushThreshold + 4_096)
    }

    @Test("IM-061: 100 000 rows, peak memory of the streamed and the in-memory CSV")
    func streamedCSVMeasurement() throws {
        let projection = try ExportFixture.projection(try ExportFixture.syntheticReport(rowCount: 100_000))
        let url = temporaryURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        var streamedSeconds = 0.0
        let streamed = try Self.peakHeapGrowthMB {
            let start = DispatchTime.now().uptimeNanoseconds
            try CSVExporter().export(projection, to: url)
            streamedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        var bytes = 0
        let inMemory = try Self.peakHeapGrowthMB {
            // The old entry point's shape: the whole file as a String, then a second copy as
            // Data — reproduced here so the measurement has its "before".
            var output = ""
            var sink = DataSink()
            try CSVExporter().write(projection, options: CSVExportOptions(), into: &sink)
            output = String(decoding: sink.data, as: UTF8.self)
            let data = Data(output.utf8)
            bytes = data.count
        }
        let size = try Data(contentsOf: url).count
        #expect(size == bytes)
        print("IM-061 CSV 100 000 rows (\(size) bytes): streamed to file peak growth "
              + String(format: "%.1f", streamed) + " MB in " + String(format: "%.2f", streamedSeconds)
              + " s; String + Data in memory peak growth " + String(format: "%.1f", inMemory) + " MB")
        // The streamed writer never holds the file; the String + Data shape holds it twice.
        #expect(streamed < Double(size) / 1_048_576)
        #expect(inMemory > Double(size) / 1_048_576)
    }

    // MARK: - IM-062

    @Test("IM-062: a large export switches to constant-memory mode by itself, same cells")
    func automaticConstantMemory() throws {
        let options = XLSXExportOptions()
        #expect(!options.usesConstantMemory(forRowCount: 5_000))
        #expect(options.usesConstantMemory(forRowCount: 5_001))
        #expect(XLSXExportOptions(constantMemory: true).usesConstantMemory(forRowCount: 10))
        #expect(!XLSXExportOptions(constantMemoryRowThreshold: nil).usesConstantMemory(forRowCount: 1_000_000))

        let projection = try ExportFixture.projection(try ExportFixture.syntheticReport(rowCount: 6_000))
        let automatic = temporaryURL("xlsx")
        let inMemory = temporaryURL("xlsx")
        defer {
            try? FileManager.default.removeItem(at: automatic)
            try? FileManager.default.removeItem(at: inMemory)
        }
        try XLSXExporter().export(projection, to: automatic)
        try XLSXExporter().export(
            projection, to: inMemory, options: XLSXExportOptions(constantMemoryRowThreshold: nil)
        )
        let streamed = try XLSXInspector(url: automatic)
        let held = try XLSXInspector(url: inMemory)
        // Old: the default export held every row in memory and wrote shared strings.
        #expect(streamed.cells.contains { $0.type == "inlineStr" })
        #expect(!held.cells.contains { $0.type == "inlineStr" })
        // The same grid: every cell's value and number format agree.
        #expect(streamed.cells.count == held.cells.count)
        let heldByReference = Dictionary(held.cells.map { ($0.reference, $0) }, uniquingKeysWith: { a, _ in a })
        for cell in streamed.cells {
            let other = try #require(heldByReference[cell.reference])
            #expect(other.value == cell.value, "\(cell.reference)")
            #expect(held.numberFormat(of: other) == streamed.numberFormat(of: cell), "\(cell.reference)")
        }
    }

    @Test("IM-062: 100 000 rows, peak memory with and without constant-memory mode")
    func constantMemoryMeasurement() throws {
        let projection = try ExportFixture.projection(try ExportFixture.syntheticReport(rowCount: 100_000))
        let streamedURL = temporaryURL("xlsx")
        let heldURL = temporaryURL("xlsx")
        defer {
            try? FileManager.default.removeItem(at: streamedURL)
            try? FileManager.default.removeItem(at: heldURL)
        }
        let streamed = try Self.peakHeapGrowthMB {
            try XLSXExporter().export(projection, to: streamedURL)
        }
        let held = try Self.peakHeapGrowthMB {
            try XLSXExporter().export(
                projection, to: heldURL, options: XLSXExportOptions(constantMemoryRowThreshold: nil)
            )
        }
        print("IM-062 XLSX 100 000 rows: default (automatic constant-memory) peak growth "
              + String(format: "%.1f", streamed) + " MB; in-memory mode peak growth "
              + String(format: "%.1f", held) + " MB")
        #expect(streamed <= 300)
        #expect(held > streamed)
    }

    // MARK: - IM-063

    @Test("IM-063: outline levels for data rows, subtotals and totals")
    func outlineLevels() {
        #expect(XLSXExporter.outlineLevel(groupDepth: nil, isSubtotal: false) == 0)
        #expect(XLSXExporter.outlineLevel(groupDepth: 0, isSubtotal: false) == 1)
        #expect(XLSXExporter.outlineLevel(groupDepth: 0, isSubtotal: true) == 0)
        #expect(XLSXExporter.outlineLevel(groupDepth: 1, isSubtotal: false) == 2)
        #expect(XLSXExporter.outlineLevel(groupDepth: 1, isSubtotal: true) == 1)
        #expect(XLSXExporter.outlineLevel(groupDepth: 9, isSubtotal: false) == 7)
    }

    // MARK: - BH-508

    @Test("BH-508: a header that starts like a formula is guarded like any other text")
    func headerIsFormulaGuarded() throws {
        #expect(CSVExporter.escape(
            "=HYPERLINK(\"http://x\",\"Total\")", delimiter: ",", quoting: .minimal,
            guardFormulas: .apostrophe
        ).hasPrefix("\"'="))
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport())
        let text = String(decoding: try CSVExporter().export(projection), as: UTF8.self)
        let header = try #require(text.split(separator: "\r\n").first)
        #expect(header.hasPrefix("Record,subject,"))
        // A custom column titled with a leading minus: old header wrote `-1+1` unguarded.
        let columns = try ExportFixture.columnSet()
        var definitions = columns.columns
        let index = try #require(definitions.firstIndex { $0.key == "golden" })
        definitions[index].title = "-1+1"
        // No rows are needed: the header is what is under test.
        let store = try LedgerStore(markups: [], columns: LedgerColumnSet(columns: definitions))
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(ExportFixture.epoch))
            .makeReport(store.makeView(LedgerViewSpec()), title: "Guarded")
        let guarded = String(decoding: try CSVExporter().export(try ExportFixture.projection(report)), as: UTF8.self)
        let guardedHeader = try #require(guarded.split(separator: "\r\n").first)
        #expect(guardedHeader.contains(",'-1+1,"))
    }

    // MARK: - BH-510, BH-511, BH-512

    @Test("BH-510: an integer one past Int.max is refused, not converted")
    func integerBoundIsExact() throws {
        #expect(throws: ExportError.self) {
            _ = try JSONReader.value(from: Data("{\"index\": 9223372036854775808}".utf8))
        }
        let largest = try JSONReader.value(from: Data("{\"index\": 4611686018427387904}".utf8))
        #expect(largest["index"]?.integerValue == 4_611_686_018_427_387_904)
        let negative = try JSONReader.value(from: Data("{\"index\": -9223372036854775808}".utf8))
        #expect(negative["index"]?.integerValue == Int.min)
    }

    @Test("BH-511: the ISO-8601 check refuses a long string by its length first")
    func iso8601ChecksLengthFirst() {
        #expect(ZenitInterchangeImport.isISO8601("2026-09-01T22:30:00Z"))
        #expect(!ZenitInterchangeImport.isISO8601("2026-09-01T22:30:00ZZ"))
        // Old: Array(text) materialised every Character before the count guard; a string of a
        // million characters is refused here without that allocation.
        let long = String(repeating: "2", count: 1_000_000)
        #expect(!ZenitInterchangeImport.isISO8601(long))
        // Twenty Characters but not twenty ASCII bytes.
        #expect(!ZenitInterchangeImport.isISO8601("２０２６-09-01T22:30:00Z"))
    }

    @Test("BH-512: a non-string provenance or a non-integer decimalPlaces is refused")
    func mistypedOptionalFieldsAreRefused() throws {
        let ledger = ZenitJSONExporter().document(
            from: try ProvenanceExportTests.mixedProjection()
        )
        let text = String(decoding: ZenitJSONExporter().encode(ledger), as: UTF8.self)
        #expect(text.contains("\"provenance\": \"derived\""))
        // Old: `"provenance": 2` read as nil — the measured claim — and passed the validator.
        let numeric = text.replacingOccurrences(of: "\"provenance\": \"derived\"", with: "\"provenance\": 2")
        #expect(throws: ExportError.self) {
            _ = try ZenitInterchangeImport.read(Data(numeric.utf8), fileName: "e1.zpdfjson")
        }
        let boolean = text.replacingOccurrences(of: "\"provenance\": \"read\"", with: "\"provenance\": true")
        #expect(throws: ExportError.self) {
            _ = try ZenitInterchangeImport.read(Data(boolean.utf8), fileName: "e1.zpdfjson")
        }
        // Old: `"decimalPlaces": "2"` read as "no declared precision".
        #expect(text.contains("\"decimalPlaces\": 2"))
        let stringPlaces = text.replacingOccurrences(of: "\"decimalPlaces\": 2", with: "\"decimalPlaces\": \"2\"")
        #expect(throws: ExportError.self) {
            _ = try ZenitInterchangeImport.read(Data(stringPlaces.utf8), fileName: "e1.zpdfjson")
        }
        // The file as written still reads.
        _ = try ZenitInterchangeImport.read(Data(text.utf8), fileName: "e1.zpdfjson")
    }

    // MARK: - BH-536

    @Test("BH-536: a text cell over 32 767 characters is cut, and the workbook is written")
    func overlongTextCellIsCut() throws {
        let long = String(repeating: "Specification text. ", count: 2_000)
        #expect(long.count > XLSXExporter.maximumCellCharacters)
        let cut = XLSXExporter.cellText(long)
        #expect(cut.unicodeScalars.count == XLSXExporter.maximumCellCharacters)
        #expect(cut.hasSuffix("\u{2026}"))
        #expect(XLSXExporter.cellText("short") == "short")

        var context = ExportDocumentContext(projectName: "Long notes")
        context.notes = long
        let projection = try ExportFixture.projection(try ExportFixture.goldenReport(), document: context)
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        // Old: ExportError.xlsx(LXW_ERROR_MAX_STRING_LENGTH_EXCEEDED) — the whole export failed.
        try XLSXExporter().export(projection, to: url)
        let metadata = try XLSXInspector(url: url, sheet: 2)
        #expect(metadata.cells.contains { $0.value.hasSuffix("\u{2026}") && $0.value.count > 30_000 })
    }

    // MARK: - BH-537, BH-538

    @Test("BH-537/538: more than 255 runs nest the SUM, and an over-long formula falls back to the number")
    func sumFormulaRespectsExcelLimits() {
        // 300 runs: every other row, so no two rows are contiguous.
        let rows = (0..<300).map { $0 * 2 + 1 }
        let formula = try? #require(XLSXExporter.sumFormula(column: 7, rows: rows))
        let text = formula ?? ""
        // Old: SUM( with 300 comma-separated arguments — past Excel's 255.
        #expect(text.hasPrefix("SUM(SUM(H2,"))
        #expect(Self.largestArgumentCount(text) <= XLSXExporter.maximumFunctionArguments)
        #expect(text.components(separatedBy: "H").count - 1 == 300)
        // 5 000 runs cannot fit in 8 192 characters however they are nested.
        let many = (0..<5_000).map { $0 * 2 + 1 }
        #expect(XLSXExporter.sumFormula(column: 7, rows: many) == nil)
        // The ordinary case is untouched.
        #expect(XLSXExporter.sumFormula(column: 2, rows: [1, 2, 5, 6]) == "SUM(C2:C3,C6:C7)")
    }

    /// The most arguments any one call in `formula` takes.
    static func largestArgumentCount(_ formula: String) -> Int {
        var stack: [Int] = []
        var largest = 0
        for character in formula {
            switch character {
            case "(": stack.append(1)
            case ",": if !stack.isEmpty { stack[stack.count - 1] += 1 }
            case ")": largest = max(largest, stack.popLast() ?? 0)
            default: break
            }
        }
        return largest
    }
}
