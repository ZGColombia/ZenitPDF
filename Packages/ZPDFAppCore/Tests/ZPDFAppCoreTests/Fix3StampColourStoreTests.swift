import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Fix round 3, stamps (BH-167 follow-up, ADR-0011 §2.4): the
/// ink an imported seal was drawn in reaches the descriptor a preset adopts, so the stamp starts
/// in that colour. The PDF is compiled by the real importer, not stubbed.
@Suite("Fix round 3 — the artwork store hands the seal's ink to the preset")
struct Fix3StampColourStoreTests {

    /// A one-page PDF with a correct cross-reference table, in the temporary directory.
    private static func pdf(_ content: String, label: String) throws -> URL {
        let stream = "<< /Length \(Data(content.utf8).count) >>\nstream\n\(content)\nendstream"
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 4 0 R >>",
            stream
        ]
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-fix3-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).pdf")
        try out.write(to: url, options: .atomic)
        return url
    }

    private static func descriptor(_ content: String, label: String) async throws -> StampArtworkDescriptor {
        let url = try pdf(content, label: label)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let artwork = try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        return ProjectArtworkStore.descriptor(of: artwork)
    }

    @Test("A red seal's descriptor carries red; its stored geometry stays colourless")
    func redSealDescriptor() async throws {
        let url = try Self.pdf("1 0 0 rg 10 10 80 80 re f 1 1 1 rg 40 40 20 20 re f", label: "red")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let artwork = try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        let descriptor = ProjectArtworkStore.descriptor(of: artwork)
        #expect(descriptor.sourceInk == ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1))
        // What the store writes: the ink region colourless (so the stamp colour paints it), the
        // knockout white. Stored rows are unchanged in shape by the ruling.
        #expect(artwork.geometry.regions.map(\.color) == [nil, RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)])
    }

    @Test("A two-ink seal's descriptor names no ink")
    func twoInkDescriptor() async throws {
        let descriptor = try await Self.descriptor(
            "1 0 0 rg 10 10 40 40 re f 0 0 1 rg 50 50 40 40 re f",
            label: "two-ink"
        )
        #expect(descriptor.sourceInk == nil)
    }
}
