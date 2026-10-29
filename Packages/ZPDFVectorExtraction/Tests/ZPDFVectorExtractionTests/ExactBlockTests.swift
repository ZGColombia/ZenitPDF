import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// NL-AUTO-12: a door Form XObject drawn fourteen times is counted exactly.
struct ExactBlockTests {

    /// A PDF whose page draws the form `/D` at each `cm`, and optionally the same door inline.
    static func writePDF(placements: [String], useForm: Bool) throws -> URL {
        let door = "1 w 0 0 m 20 0 l S 0 0 m 0 12 l S 20 0 m 20 6 l S"
        let page: String
        if useForm {
            page = placements.map { "q \($0) cm /D Do Q" }.joined(separator: "\n")
        } else {
            page = placements.map { "q \($0) cm \(door) Q" }.joined(separator: "\n")
        }
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Contents 4 0 R /Resources << /XObject << /D 5 0 R >> >> >>",
            "<< /Length \(page.utf8.count) >>\nstream\n\(page)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [-5 -5 40 40] /Length \(door.utf8.count) >>\nstream\n\(door)\nendstream"
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exact-block-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    /// Fourteen placements: ten translations, two turned 90°, two mirrored.
    static let placements: [String] = (0..<10).map { "1 0 0 1 \(60 + $0 * 60) 100" }
        + ["0 1 -1 0 200 300", "0 1 -1 0 300 300", "-1 0 0 1 500 300", "-1 0 0 1 600 300"]

    @Test("A door Form XObject drawn 14 times: one box returns 14, residual 0, marked exact")
    func fourteenDoors() async throws {
        let url = try Self.writePDF(placements: Self.placements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        #expect(extraction.formInvocations?.count == 14)
        // The first door spans 60…80 × 100…112.
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 55, minY: 95, maxX: 85, maxY: 117)
        )
        let report = try #require(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives))
        #expect(report.confirmed.count == 14)
        #expect(report.confirmed.allSatisfy { $0.residual == 0 })
        #expect(report.confirmed.filter(\.isExemplar).count == 1)
        #expect(report.confirmed.filter(\.isMirrored).count == 2)
        // The exemplar's centroid, carried to the second placement: 60 pt to the right.
        let second = try #require(report.confirmed.first { abs($0.position.y - exemplar.centroid.y) < 1e-9 && abs($0.position.x - (exemplar.centroid.x + 60)) < 1e-9 })
        #expect(second.scaleFactor == 1)
    }

    @Test("The same doors drawn without a form fall back to geometric matching")
    func noFormFallsBack() async throws {
        let url = try Self.writePDF(placements: Self.placements, useForm: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        #expect(extraction.formInvocations?.isEmpty == true)
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 55, minY: 95, maxX: 85, maxY: 117)
        )
        #expect(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives) == nil)
        #expect(try SymbolMatcher().matches(exemplar: exemplar, in: extraction.primitives).confirmed.count == 14)
    }

    @Test("A box that catches only part of a block is not an exact match")
    func partialBlock() async throws {
        let url = try Self.writePDF(placements: Self.placements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        // 55…70 catches the jamb and not the far stop.
        let partial = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 55, minY: 95, maxX: 70, maxY: 117), minimumPrimitiveCount: 1
        )
        #expect(ExactBlockMatcher.matches(exemplar: partial, extraction: extraction, visible: extraction.primitives) == nil)
    }

    @Test("The invocation table round-trips through codec format 4")
    func codecRoundTrip() async throws {
        let url = try Self.writePDF(placements: Self.placements, useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let bytes = VectorExtractionCodec.encode(extraction)
        #expect(Array(bytes[4..<8]) == [4, 0, 0, 0])
        let decoded = try VectorExtractionCodec.decode(bytes)
        #expect(decoded == extraction)
        #expect(decoded.formInvocations?.count == 14)
    }
}
