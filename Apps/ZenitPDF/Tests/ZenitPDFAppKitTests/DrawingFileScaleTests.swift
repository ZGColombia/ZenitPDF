import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
@testable import ZenitPDFAppKit

/// NL-PLAT-06 in the app: a CAD-exported PDF's own `/Measure` scale is offered once, in one click,
/// never applied silently, and never over a scale a person made.
@MainActor
@Suite("Scale from the drawing file — NL-PLAT-06", .appTierSerialised)
struct DrawingFileScaleTests {

    /// A one-page A3 PDF with a stroked line and a whole-page 1:100 viewport.
    private static func writeCADPDF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-vp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("CAD export.pdf")
        let content = "1 w 0 0 0 RG 72 72 m 572 72 l S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1191 842] /Contents 4 0 R /VP [<< /Type /Viewport /BBox [0 0 1191 842] "
                + "/Measure << /Type /Measure /Subtype /RL /R (1:100) /X [<< /Type /NumberFormat /U (m) /C 0.0352777777778 >>] >> >>] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(body.utf8).write(to: url)
        return url
    }

    @Test("A 1:100 viewport is offered as 'The drawing file says 1:100.', and Apply installs it with its provenance")
    func offeredAndApplied() async throws {
        // Old behaviour: /VP was never read; scale came only from calibration or title-block text.
        let harness = try await Fix2Harness.make("unused.pdf", calibrate: false, fixture: try Self.writeCADPDF())
        defer { harness.tearDown() }
        #expect(await AppTestSupport.wait { harness.core.document.warnings.contains { $0.title == "The drawing file says 1:100." } })
        let offer = try #require(harness.core.document.warnings.first { $0.title == "The drawing file says 1:100." })
        #expect(offer.actionTitle == "Apply 1:100")
        let page = try #require(await harness.core.session.firstPageID)
        #expect(await harness.core.session.scale(onPage: page) == nil, "offered, never applied silently")

        #expect(harness.document.handleDrawingFileScaleAction(offer.id))
        #expect(await AppTestSupport.wait { harness.core.document.warnings.allSatisfy { $0.id != offer.id } })
        let scale = try #require(await harness.core.session.scale(onPage: page))
        #expect(scale.label == "1:100 from the drawing file")
        // 500 pt at 1:100 is 500 × 0.0254 / 72 × 100 = 17.638… m.
        let record = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 72, y: 72), PDFPoint(x: 572, y: 72)])
        }
        let metres = try #require(await harness.core.session.markup(record.id)?.measurement?.values[.planLength]?.value)
        #expect(abs(NSDecimalNumber(decimal: metres).doubleValue - 500 * 0.0254 / 72 * 100) < 1e-9)
    }
}
