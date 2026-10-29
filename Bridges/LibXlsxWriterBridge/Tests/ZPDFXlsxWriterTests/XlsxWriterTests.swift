import Foundation
import Testing
@testable import ZPDFXlsxWriter

/// Unzips one member of a zip archive with the system `unzip`, so the tests read what Excel
/// would read rather than what the writer believes it wrote.
enum Unzipper {
    static func entry(_ name: String, of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path(percentEncoded: false), name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func list(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

func temporaryFile(_ ext: String = "xlsx") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zpdf-xlsx-\(UUID().uuidString).\(ext)")
}

@Suite("libxlsxwriter bridge")
struct XlsxWriterTests {

    @Test("The vendored library reports the pinned upstream version")
    func libraryVersion() {
        #expect(!XlsxWriter.libraryVersion.isEmpty)
    }

    /// The bridge is built with `USE_STANDARD_TMPFILE`, so this is load-bearing rather than
    /// incidental: if the platform `tmpfile()` stops working, XLSX export stops working.
    @Test("The C standard tmpfile() this build depends on is usable")
    func standardTmpfileIsUsable() {
        #expect(XlsxWriter.temporaryFileSupportIsAvailable())
    }

    @Test("A workbook writes the expected XLSX parts")
    func writesParts() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url, properties: XlsxDocumentProperties(title: "Zenit", author: "Zenit PDF")) { workbook in
            let sheet = try workbook.addWorksheet(name: "Ledger")
            try sheet.writeString(row: 0, column: 0, "Subject")
            try sheet.writeNumber(row: 1, column: 0, 1.5)
        }
        let members = try Unzipper.list(url)
        #expect(members.contains("xl/workbook.xml"))
        #expect(members.contains("xl/worksheets/sheet1.xml"))
        #expect(members.contains("docProps/core.xml"))
        #expect(try Unzipper.entry("docProps/core.xml", of: url).contains("Zenit PDF"))
    }

    @Test("Numbers are stored as numeric cells, not as strings")
    func numbersAreNumeric() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            let format = try workbook.format(XlsxFormatSpec(numberFormat: "0.000"))
            try sheet.writeNumber(row: 0, column: 0, 12.5, format: format)
        }
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        // A string cell would carry t="s" or t="inlineStr"; a numeric cell carries neither.
        #expect(xml.contains("<v>12.5</v>"))
        #expect(!xml.contains("t=\"s\""))
        let styles = try Unzipper.entry("xl/styles.xml", of: url)
        #expect(styles.contains("0.000"))
    }

    @Test("Freeze panes, auto-filter and column widths land in the sheet XML")
    func sheetFurniture() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            try sheet.setColumnWidth(first: 0, last: 2, width: 18)
            try sheet.freezePanes(row: 1, column: 0)
            for column in 0..<3 { try sheet.writeString(row: 0, column: column, "H\(column)") }
            try sheet.writeNumber(row: 1, column: 0, 1)
            try sheet.autofilter(firstRow: 0, firstColumn: 0, lastRow: 1, lastColumn: 2)
        }
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        #expect(xml.contains("<pane ySplit=\"1\""))
        #expect(xml.contains("<autoFilter ref=\"A1:C2\"/>"))
        #expect(xml.contains("width=\"18"))
    }

    @Test("Constant-memory mode writes 20 000 rows through the standard tmpfile()")
    func constantMemory() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url, options: XlsxWorkbookOptions(constantMemory: true)) { workbook in
            let sheet = try workbook.addWorksheet(name: "Big")
            for row in 0..<20_000 {
                try sheet.writeNumber(row: row, column: 0, Double(row))
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = try #require(attributes[.size] as? Int)
        #expect(size > 10_000)
        let xml = try Unzipper.entry("xl/worksheets/sheet1.xml", of: url)
        #expect(xml.contains("<v>19999</v>"))
    }

    @Test("A throwing body leaves no file behind")
    func abandonsOnFailure() throws {
        struct Boom: Error {}
        let url = temporaryFile()
        #expect(throws: Boom.self) {
            try XlsxWriter.write(to: url) { workbook in
                _ = try workbook.addWorksheet(name: "S")
                throw Boom()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("Out-of-range cells are a typed error, not a crash")
    func outOfRange() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: XlsxError.self) {
            try XlsxWriter.write(to: url) { workbook in
                let sheet = try workbook.addWorksheet(name: "S")
                try sheet.writeNumber(row: XlsxLimits.maximumRows, column: 0, 1)
            }
        }
    }

    /// CR-132. `XlsxWorkbookOptions.temporaryDirectory` was a public option the build cannot
    /// honour: `USE_STANDARD_TMPFILE` makes the C library call `tmpfile()` and ignore `tmpdir`
    /// entirely (vendored `utility.c`, `lxw_tmpfile`). An option that does nothing is removed
    /// rather than kept as a promise; the writer must still round-trip in both memory modes.
    // Fails on the old code:
    //   XlsxWriterTests.swift:160:9: Expectation failed: !((labels → ["constantMemory",
    //     "temporaryDirectory", "useZip64"]).contains("temporaryDirectory") → true)
    //   XlsxWriterTests.swift:162:9: Expectation failed: (labels → ["constantMemory",
    //     "temporaryDirectory", "useZip64"]) == ["constantMemory", "useZip64"]
    @Test("No inert temporaryDirectory option is offered, and both memory modes still write")
    func noInertTemporaryDirectoryOption() throws {
        let labels = Mirror(reflecting: XlsxWorkbookOptions()).children.compactMap(\.label)
        #expect(!labels.contains("temporaryDirectory"),
                "an option the C library ignores must not be offered; options: \(labels)")
        #expect(labels == ["constantMemory", "useZip64"])

        for constantMemory in [false, true] {
            let url = temporaryFile()
            defer { try? FileManager.default.removeItem(at: url) }
            try XlsxWriter.write(to: url, options: XlsxWorkbookOptions(constantMemory: constantMemory)) { workbook in
                let sheet = try workbook.addWorksheet(name: "S")
                try sheet.writeNumber(row: 0, column: 0, 42)
            }
            #expect(try Unzipper.entry("xl/worksheets/sheet1.xml", of: url).contains("<v>42</v>"),
                    "constantMemory: \(constantMemory)")
        }
    }

    @Test("Equal format specs allocate one format")
    func formatCaching() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try XlsxWriter.write(to: url) { workbook in
            let sheet = try workbook.addWorksheet(name: "S")
            let a = try workbook.format(XlsxFormatSpec(bold: true))
            let b = try workbook.format(XlsxFormatSpec(bold: true))
            #expect(a.pointer == b.pointer)
            try sheet.writeString(row: 0, column: 0, "x", format: a)
        }
    }
}
