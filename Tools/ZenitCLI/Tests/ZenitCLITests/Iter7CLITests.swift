import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
@testable import ZenitCLICore

/// Iteration 7: `zenit` reads `/UserUnit` through the application's own reader (X-051).
@Suite("zenit CLI — iteration 7", .serialized)
struct Iter7CLITests {

    /// A four-page drawing: `/UserUnit 2`, `/UserUnit 1e9` (past the cap), `/UserUnit -3`
    /// (refused by the contract) and no entry at all.
    private static func writeUserUnitPDF(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("Units.pdf")
        let content = Data("1 w 0 0 0 RG\n72 72 m 372 72 l S\n".utf8)
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        let page = { (unit: String) in
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] \(unit) /Contents 7 0 R >>".utf8)
        }
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>".utf8),
            page("/UserUnit 2"), page("/UserUnit 1000000000"), page("/UserUnit -3"), page(""),
            stream,
        ]
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    /// Hand-derived: 2 stays 2; 10^9 is capped at 75 000; −3 is refused and reads 1; a page with no
    /// entry is absent from the reader's answer and reads 1 on the page. The CLI's pages carry
    /// exactly what the shared reader — the application's loader's reader — answers.
    @Test("X-051: the CLI's pages carry the user units the application's reader answers")
    func cliPagesReadThroughTheSharedReader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-cli-x051-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = try Self.writeUserUnitPDF(in: directory)

        let shared = PageUserUnits.read(at: pdf)
        #expect(shared == [0: 2, 1: 75_000, 2: 1])
        let pages = try ProjectReader.pages(of: pdf, documentID: DocumentID(UUID()))
        #expect(pages.map(\.userUnit) == [2, 75_000, 1, 1])
        #expect(pages.map(\.userUnit) == pages.indices.map { shared[$0] ?? 1 })
    }

    /// An unreadable file declares nothing, so every page reads 1.0 on both paths.
    @Test("X-051: a file that is not a drawing declares no user unit")
    func unreadableFileDeclaresNothing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-cli-x051-\(UUID().uuidString).pdf")
        try Data("not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PageUserUnits.read(at: url).isEmpty)
    }
}
