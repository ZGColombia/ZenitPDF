import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// W-080: a composite form's block identity covers the sub-forms it draws.
///
/// Two composite forms `/A` and `/B` have byte-identical content, `/Fm0 Do /Fm1 Do`, and each
/// resolves those names in its own `/Resources`: `/A` draws a door (a sill and a jamb, then a
/// stop), `/B` draws a window. Before the fix both composites carried the digest of those same
/// bytes, so boxing one door counted the windows as doors too.
struct Iter6NestedBlockIdentityTests {

    /// The door: a sill (0,0)–(20,0) and a jamb (0,0)–(0,12) in `/Fm0`, the stop (20,0)–(20,6)
    /// in `/Fm1` — the door block of ``ExactBlockTests`` split over two sub-forms.
    static let doorLeaf = "1 w 0 0 m 20 0 l S 0 0 m 0 12 l S"
    static let doorStop = "1 w 20 0 m 20 6 l S"
    /// The window: two sashes in `/Fm0`, one mullion in `/Fm1` — as many strokes as the door.
    static let windowSashes = "1 w 0 0 m 30 0 l S 0 4 m 30 4 l S"
    static let windowMullion = "1 w 15 0 m 15 4 l S"
    /// A window with a second mullion: four strokes, one more than the door.
    static let windowMullions = "1 w 15 0 m 15 4 l S 30 0 m 30 4 l S"

    /// A page that draws `/A` at each of `doors` and `/B` at each of `windows`.
    static func writePDF(doors: [String], windows: [String], windowSecond: String = windowMullion) throws -> URL {
        let composite = "/Fm0 Do /Fm1 Do"
        let page = (doors.map { "q \($0) cm /A Do Q" } + windows.map { "q \($0) cm /B Do Q" })
            .joined(separator: "\n")
        func form(_ content: String, resources: String = "") -> String {
            "<< /Type /XObject /Subtype /Form /BBox [-5 -5 40 40] \(resources)/Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        }
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842 595] /Contents 4 0 R /Resources << /XObject << /A 5 0 R /B 6 0 R >> >> >>",
            "<< /Length \(page.utf8.count) >>\nstream\n\(page)\nendstream",
            form(composite, resources: "/Resources << /XObject << /Fm0 7 0 R /Fm1 8 0 R >> >> "),
            form(composite, resources: "/Resources << /XObject << /Fm0 9 0 R /Fm1 10 0 R >> >> "),
            form(doorLeaf),
            form(doorStop),
            form(windowSashes),
            form(windowSecond),
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nested-block-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    static let doors = ["1 0 0 1 60 100", "1 0 0 1 160 100", "1 0 0 1 260 100"]
    static let windows = ["1 0 0 1 60 300", "1 0 0 1 160 300"]

    /// The first door spans 60…80 × 100…112.
    static let firstDoor = VectorBounds(minX: 55, minY: 95, maxX: 85, maxY: 117)

    /// The composite drawings (depth 1) of the extraction, in scan order.
    static func composites(_ extraction: VectorPageExtraction) throws -> [VectorFormInvocation] {
        try #require(extraction.formInvocations).filter { $0.depth == 1 }
    }

    @Test("W-080: byte-identical composites over different sub-forms are different blocks — boxing a door returns the 3 doors, not the 2 windows")
    func equalSizedAssembliesAreApart() async throws {
        let url = try Self.writePDF(doors: Self.doors, windows: Self.windows)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let composites = try Self.composites(extraction)
        #expect(composites.count == 5)
        #expect(composites.allSatisfy { $0.primitiveCount == 3 })
        // Old output: one identity for all five composite drawings.
        #expect(Set(composites.prefix(3).map(\.formIdentity)).count == 1)
        #expect(Set(composites.suffix(2).map(\.formIdentity)).count == 1)
        #expect(composites[0].formIdentity != composites[3].formIdentity)

        let exemplar = try SymbolExemplar(primitives: extraction.primitives, region: Self.firstDoor)
        let report = try #require(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives))
        // Old output: 5 confirmed, residual 0 — the two windows counted as doors.
        #expect(report.confirmed.count == 3)
        #expect(report.rejected.isEmpty)
        #expect(report.candidateCount == 3)
        #expect(report.confirmed.allSatisfy { $0.bounds.maxY < 113 })
    }

    @Test("W-080: a larger foreign assembly with the same bytes no longer marks every real door partial")
    func largerForeignAssemblyIsNotTheMeasure() async throws {
        let url = try Self.writePDF(doors: Self.doors, windows: Self.windows, windowSecond: Self.windowMullions)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let composites = try Self.composites(extraction)
        #expect(composites.map(\.primitiveCount) == [3, 3, 3, 4, 4])

        let exemplar = try SymbolExemplar(primitives: extraction.primitives, region: Self.firstDoor)
        let report = try #require(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives))
        // Old output: confirmed 2 (both windows) and rejected 3 — every door
        // .partialBlock(visible: 3, total: 4).
        #expect(report.confirmed.count == 3)
        #expect(report.rejected.isEmpty)
        #expect(report.confirmed.filter(\.isExemplar).count == 1)
    }

    @Test("W-080: a clip that empties one sub-form keeps the composite's identity, so the copy is still reported partial")
    func clippedSubFormKeepsTheIdentity() async throws {
        // The first door sits inside a clip x ≤ 70: its stop (80,100)–(80,106) is wholly outside,
        // so `/Fm1` produces no primitive in that drawing.
        let doors = ["0 0 70 842 re W n 1 0 0 1 60 100", "1 0 0 1 160 100", "1 0 0 1 260 100"]
        let url = try Self.writePDF(doors: doors, windows: Self.windows)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let composites = try Self.composites(extraction)
        #expect(composites.map(\.primitiveCount) == [2, 3, 3, 3, 3])
        #expect(composites[0].formIdentity == composites[1].formIdentity)

        // Box the second, whole door: 160…180 × 100…112.
        let exemplar = try SymbolExemplar(
            primitives: extraction.primitives, region: VectorBounds(minX: 155, minY: 95, maxX: 185, maxY: 117)
        )
        let report = try #require(ExactBlockMatcher.matches(exemplar: exemplar, extraction: extraction, visible: extraction.primitives))
        #expect(report.confirmed.count == 2)
        #expect(report.rejected.map(\.reason) == [.partialBlock(visible: 2, total: 3)])
    }

    @Test("W-080: a leaf form keeps its bare content digest, so a single-level block's identity is unchanged")
    func leafIdentityIsTheContentDigest() async throws {
        let url = try ExactBlockTests.writePDF(placements: ["1 0 0 1 60 100"], useForm: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let invocation = try #require(extraction.formInvocations?.first)
        var hash = FNVHash()
        hash.combine([UInt8]("1 w 0 0 m 20 0 l S 0 0 m 0 12 l S 20 0 m 20 6 l S".utf8))
        #expect(invocation.formIdentity == hash.value)
    }
}
