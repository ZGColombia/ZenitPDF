import CoreGraphics
import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// CR-89: the PDF 1.1 flat `/Dests` dictionary is read under the same object budget as every
/// other catalog walk — bounded while it is being read, not after the whole dictionary has been
/// materialised — and a walk the budget cuts short is reported as truncated.
@Suite("Legacy /Dests dictionary")
struct LegacyDestinationsTests {

    /// A one-page PDF whose catalog carries a flat `/Dests` dictionary of `count` `/Fit`
    /// destinations, D0000 … Dnnnn, all pointing at the page.
    private func writeLegacyDestinationsFixture(count: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-legacydests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.pdf")

        let entries = (0..<count).map { String(format: "/D%04d [3 0 R /Fit]", $0) }.joined(separator: " ")
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Dests << \(entries) >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>".utf8)
        ]
        var pdf = Data("%PDF-1.1\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try pdf.write(to: url)
        return url
    }

    private func inspect(_ url: URL, limits: DocumentLimits) throws -> CatalogReport {
        let document = try #require(CGPDFDocument(url as CFURL))
        return CatalogInspector.inspect(document: document, limits: limits)
    }

    @Test("Every entry of a flat /Dests dictionary resolves within the standard limits")
    func legacyDestinationsResolve() throws {
        let url = try writeLegacyDestinationsFixture(count: 40)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try inspect(url, limits: .standard)
        #expect(report.namedDestinations.count == 40)
        #expect(Set(report.namedDestinations.map(\.name)).count == 40)
        #expect(report.namedDestinations.allSatisfy { $0.target.pageIndex == 0 })
        #expect(!report.scanWasTruncated)
    }

    @Test("A /Dests dictionary larger than the object budget is cut short and reported as truncated (CR-89)")
    func oversizedLegacyDestinationsAreBoundedAndReported() throws {
        let entryCount = 400
        let url = try writeLegacyDestinationsFixture(count: entryCount)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let report = try inspect(url, limits: DocumentLimits(maximumHazardScanNodes: 100))

        // Collection stops at the budget's edge instead of reading all 400 entries first.
        #expect(report.namedDestinations.count > 0,
                "the budget was spent before /Dests was reached — recalibrate the test")
        #expect(report.namedDestinations.count <= 100)
        #expect(report.namedDestinations.count < entryCount)
        // The entries left unread are a truncation. The first bounded version of this walk
        // spent exactly its remaining budget on the entries it did read and never tripped the
        // exhausted flag: old output was scanWasTruncated == false with 300 destinations
        // silently dropped.
        #expect(report.scanWasTruncated)
    }
}
