import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The scale proposal, end to end: a drawing whose title block says `SKALA 1:100` opens, the
/// warning tray offers it, Apply calibrates through the ordinary bus, and dismissal is honoured.
///
/// The one rule is the whole design: the proposal never applies itself —
/// CORE_LOOP.md's first silent-wrongness entry is a scale nobody chose.
@MainActor
@Suite(.appTierSerialised)
struct ScaleProposalWiringTests {

    /// A one-page A1-landscape PDF whose only text says SKALA 1:100.
    private func writeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-scaleprop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-501.pdf")
        // A1 landscape: 2384 × 1684 pt. Text via the standard 14 fonts, no embedding needed.
        let content = Data("""
        BT /F1 12 Tf 2000 60 Td (SKALA 1:100) Tj ET
        2 w 0 0 0 RG 100 100 m 500 100 l S
        """.utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".utf8)
        ]
        var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        stream.append(content)
        stream.append(Data("\nendstream".utf8))
        objects.append(stream)
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))
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

    @Test("An uncalibrated drawing with SKALA 1:100 in its title block gets the offer, and Apply calibrates")
    func theProposalIsOfferedAndAppliesThroughTheBus() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)

        // The offer arrives through the tray, named and actioned.
        #expect(await AppTestSupport.wait(upTo: 20) {
            core.document.warnings.contains { $0.actionTitle?.contains("1:100") == true }
        }, "no scale proposal arrived for a title block that plainly says SKALA 1:100")
        let warning = try #require(
            core.document.warnings.first { $0.actionTitle?.contains("1:100") == true }
        )
        #expect(document.holdsScaleProposal(warningID: warning.id))

        // Nothing applied itself: the page is still uncalibrated until Apply.
        let pageID = try #require(await core.session.firstPageID)
        let before = await core.session.scale(onPage: pageID)
        #expect(before == nil, "the proposal calibrated the page without the Apply press")

        // Apply, the way the tray's button applies.
        document.applyScaleProposal(warningID: warning.id)
        var applied: ScaleTransform?
        for _ in 0..<200 {
            applied = await core.session.scale(onPage: pageID)
            if applied != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let scale = try #require(applied, "Apply produced no scale")

        // The right scale: 100 pt at 1:100 maps to 0.0254*100*100/72 m = 3.5277…
        let mapped = scale.matrix.map(PDFPoint(x: 100, y: 0))
        let origin = scale.matrix.map(PDFPoint(x: 0, y: 0))
        let metres = mapped.distance(to: origin)
        #expect(abs(metres - 2.54 * 100 / 72) < 0.001, "100 pt maps to \(metres) m")
        // ADR-0019: a ratio is a preset, with no calibration evidence. Old output:
        // `.calibrationTwoPoint` with evidence points (0,0) and (100,0) nobody picked.
        #expect(scale.source == .preset)
        #expect(await core.session.evidence(for: scale.id) == nil)

        // The warning is gone once applied.
        #expect(await AppTestSupport.wait(upTo: 10) {
            !core.document.warnings.contains { $0.id == warning.id }
        })
    }

    @Test("Apply never overwrites a calibration the estimator made by hand")
    func applyRefusesOverAHandCalibration() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)

        // Let the offer arrive first — the racy order the first draft of this test lost to.
        #expect(await AppTestSupport.wait(upTo: 20) {
            core.document.warnings.contains { $0.actionTitle?.contains("1:100") == true }
        })
        let warning = try #require(
            core.document.warnings.first { $0.actionTitle?.contains("1:100") == true }
        )

        // The estimator calibrates by hand while the banner sits there: 100 pt = 5 m.
        let pageID = try #require(await core.session.firstPageID)
        _ = try await core.commands.calibrate(
            page: pageID,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 5,
            knownLengthUnit: .metre
        )

        // Then presses Apply anyway. The hand calibration must survive.
        document.applyScaleProposal(warningID: warning.id)
        try? await Task.sleep(for: .seconds(1))

        let scale = try #require(await core.session.scale(onPage: pageID))
        let mapped = scale.matrix.map(PDFPoint(x: 100, y: 0))
        let origin = scale.matrix.map(PDFPoint(x: 0, y: 0))
        let metres = mapped.distance(to: origin)
        #expect(abs(metres - 5) < 0.001, """
        Apply overwrote a hand calibration: 100 pt now maps to \(metres) m, not the 5 m the \
        estimator set. The proposal may only fill an empty page.
        """)
        // …and the stale banner came down.
        #expect(await AppTestSupport.wait(upTo: 10) {
            !core.document.warnings.contains { $0.id == warning.id }
        })
    }
}
