import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Quality-loop iteration 3, area "ui-presentation-measure", in the assembled app: the Rectangle
/// Area's Return after two clicked corners, driven through the shipping `PDFCanvasViewController`
/// input handlers against a real document, session and Quantity Ledger; and the Scale Regions
/// panel's refusal sentence. No window is put on screen.
@MainActor
@Suite("Iteration 3 ui-presentation-measure (app)", .appTierSerialised)
struct Iter3UIPresentationMeasureAppTests {

    // MARK: - Harness

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-it3-uipm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-201.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8),
            Data("<< /Length \(content.count) >>\nstream\n".utf8) + content + Data("\nendstream".utf8)
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
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
        return url
    }

    private func wait(upTo seconds: Double = 60, for condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        let directory: URL
        /// How many times the canvas asked the shell to finish.
        let finishes: () -> Int

        func tearDown() {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// One loaded document calibrated to 10 pt per metre (300 pt = 30 m), with its canvas wired
    /// the way the window wires it: `finishGeometry` settles in-flight placements, then commits
    /// through the presenter, whose `canCommit` is the last gate.
    private func makeHarness() async throws -> Harness {
        let url = try fixtureURL()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()
        let toolbar = try #require(document.shell?.toolbar)
        let canvas = PDFCanvasViewController(core: core, rasterSource: nil, toolbar: toolbar)
        _ = canvas.view
        final class Counter { var value = 0 }
        let counter = Counter()
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else { return }
            counter.value += 1
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        return Harness(
            document: document, core: core, canvas: canvas,
            directory: url.deletingLastPathComponent(), finishes: { counter.value }
        )
    }

    // MARK: - T-055

    /// Two corners along a slanted edge, (130, 130) and (230, 180), then Return.
    ///
    /// Old output: the machine's `canFinish` was true at two points (click mode is set only by a
    /// press-release sent as a drag, which the canvas never sends for a click), Return reached
    /// the shell's Finish, the presenter's `canCommit` (two points ≥ minimum 2) let it through,
    /// and the edge's axis-aligned bounding box — 100 × 50 pt = 10 m × 5 m = 50 m² — landed in the
    /// Quantity Ledger.
    @Test("T-055: Return after two clicked Rectangle Area corners commits nothing; the third corner finishes it")
    func returnAfterTwoCornersCommitsNothing() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .rectangleArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 2)
        #expect(!core.measurement.canCommit, "old output: true")
        #expect(core.measurement.commitRefusalReason == "Rectangle Area needs 1 more point before it can be finished.")

        #expect(harness.canvas.handle(key: .finish))
        #expect(await wait(upTo: 5) { harness.finishes() >= 1 }, "Return still reaches the shell, which states the refusal")
        await core.measurement.settlePlacements()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(core.ledger.rowCount == 0, "old output: one row, the edge's 50 m² bounding box")
        #expect(core.measurement.placedPoints.count == 2, "the two corners are kept for the third")

        // The depth point (200, 240): P4 = P1 + P3 − P2 = (100, 190). By hand, the parallelogram's
        // area is |(100, 50) × (−30, 60)| = 100·60 + 50·30 = 7500 pt² = 75 m² at 10 pt per metre.
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 240), additive: false)
        #expect(await wait { core.ledger.rowCount == 1 }, "the third click auto-finishes")
        let csv = LedgerCSVExport.render(presenter: core.ledger)
        #expect(csv.contains("75"), "P1 P2 P3 P4 = 75 m², not the edge's 50 m² box:\n\(csv)")
    }

    // MARK: - T-056

    /// Old output: "scale 5A50…-… belongs to another page and cannot be used on page 5A50…-…".
    @Test("T-056: a scale from another sheet is refused in words, without ids")
    func crossSheetRefusalIsPlainWords() {
        let scale = UUID(uuidString: "5A504446-0000-4000-8000-000000000001") ?? UUID()
        let page = UUID(uuidString: "5A504446-0000-4000-8000-000000000002") ?? UUID()
        let sentence = ZenitPDFProjectDocument.scaleRegionRefusal(
            DocumentCommandError.scaleBelongsToAnotherPage(scale: ScaleID(scale), page: PageID(page))
        )
        #expect(sentence == "That scale was calibrated on another sheet. Pick one of this sheet's scales, or calibrate the region on the drawing.")
        #expect(!sentence.contains(scale.uuidString) && !sentence.contains(page.uuidString))
        // Every other refusal is the core's plain sentence, never `description` (L-102 re-fix:
        // old output "measurement failed: x").
        #expect(ZenitPDFProjectDocument.scaleRegionRefusal(DocumentCommandError.measurementFailed("x")) == "X.")
        #expect(ZenitPDFProjectDocument.scaleRegionRefusal(ScaleApplicationError.overlappingRegions(ScaleRegionID(scale), ScaleRegionID(page)))
            == "Two Scale Regions on this sheet overlap. Change one so they no longer overlap.")
    }
}
