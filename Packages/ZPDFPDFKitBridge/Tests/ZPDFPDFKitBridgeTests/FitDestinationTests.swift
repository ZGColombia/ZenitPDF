import CoreGraphics
import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// CR-85: named-destination coordinates are read according to the destination's fit type.
///
/// A destination array is `[page /FitType ...params]`. Reading params[0]/params[1] as (left, top)
/// is correct only for `/XYZ`. A `/FitR left bottom right top` read that way navigates to
/// (left, bottom) — the wrong corner. The point of a `/FitR` is its top-left, `(left, top)`.
@Suite("Fit destinations")
struct FitDestinationTests {

    /// A one-page PDF whose `/Names /Dests` names one destination with the given fit array text,
    /// e.g. `"/FitR 100 200 300 400"`.
    private func writeDestinationFixture(name: String, fit: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-fitdest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fit.pdf")

        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(\(name)) [3 0 R \(fit)]] >> >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>".utf8)
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
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

    @Test("A /FitR destination resolves to its top-left corner, not (left, bottom)")
    func fitRUsesTopLeftCorner() async throws {
        // /FitR left bottom right top = 100 200 300 400. Old output: point = (100, 200), read
        // from slots 2/3 as if the array were /XYZ; the correct scroll point is (left, top).
        let url = try writeDestinationFixture(name: "SHEET", fit: "/FitR 100 200 300 400")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)
        let sheet = try #require(destinations.first { $0.name == "SHEET" })
        #expect(sheet.target.pageIndex == 0)
        let point = try #require(sheet.target.point)
        #expect(abs(point.x - 100) < 0.5, "x was \(point.x), expected the left edge 100")
        #expect(abs(point.y - 400) < 0.5, "y was \(point.y), expected the top edge 400, not the bottom 200")
    }

    @Test("An /XYZ destination still reads (left, top) and its zoom")
    func xyzUnchanged() async throws {
        let url = try writeDestinationFixture(name: "ZOOMED", fit: "/XYZ 120 480 2")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)
        let dest = try #require(destinations.first { $0.name == "ZOOMED" })
        let point = try #require(dest.target.point)
        #expect(abs(point.x - 120) < 0.5)
        #expect(abs(point.y - 480) < 0.5)
        #expect(dest.target.zoom == 2)
    }

    @Test("A /FitH destination carries only its vertical coordinate")
    func fitHVerticalOnly() async throws {
        let url = try writeDestinationFixture(name: "TOP", fit: "/FitH 500")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: url)
        let destinations = try await provider.namedDestinations(of: opened.handle)
        let dest = try #require(destinations.first { $0.name == "TOP" })
        let point = try #require(dest.target.point)
        #expect(abs(point.y - 500) < 0.5)
    }
}
