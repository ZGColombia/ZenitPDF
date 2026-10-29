import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Calibration clicks snap, like every other placed point.
///
/// Calibration once did not snap at all, and it was
/// not a near miss — the calibration branch of `handleClick` took the raw click and appended it.
/// Every other placement in the product goes through `TakeoffSession.resolveSnap`; this was the
/// one that did not.
///
/// It matters more here than anywhere else. Calibration is the step every later number is derived
/// from, and it is measured between two points picked off a dimension line — exactly the endpoints
/// vector snap exists to find. A calibration a few points off scales the whole sheet by that
/// error, silently, so both calibration picks snap to the dimension line's endpoints.
///
/// The fixture is a stroked rectangle whose corners are at exactly (72, 72), (372, 72),
/// (372, 272) and (72, 272), so "did it snap" is an exact comparison rather than a tolerance.
@MainActor
@Suite(.appTierSerialised)
struct CalibrationSnapTests {

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        let directory: URL

        func tearDown() {
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A one-page PDF holding a stroked rectangle with corners on round numbers.
    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-calsnap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-301.pdf")
        let content = Data("2 w 0 0 0 RG\n72 72 m 372 72 l 372 272 l 72 272 l h S\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>".utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)

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

    private func makeHarness() async throws -> Harness {
        let url = try fixtureURL()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)

        // The snap index is built asynchronously after the document opens. Without it there is
        // nothing to snap *to*, and this test would pass or fail on timing rather than on the
        // behaviour under test.
        #expect(
            await AppTestSupport.wait(upTo: 40) {
                core.status.snapshot.geometryIndexStatus.allowsVectorSnap
            },
            "the vector snap index never became available; this test cannot say anything"
        )

        let toolbar = try #require(document.shell?.toolbar)
        let canvas = PDFCanvasViewController(core: core, rasterSource: nil, toolbar: toolbar)
        _ = canvas.view
        return Harness(
            document: document,
            core: core,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    @Test("A calibration click near a corner lands on the corner")
    func calibrationClickSnaps() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        var collected: [PDFPointValue] = []
        harness.canvas.onCalibrationPointsCollected = { collected = $0 }
        harness.canvas.beginCalibration()
        #expect(harness.canvas.isCalibrating)

        // Three points shy of the rectangle's lower-left and lower-right corners — inside snap
        // range, and nowhere near them by the standards of a scale that multiplies the error.
        harness.canvas.handleClick(at: PDFPointValue(x: 75, y: 74), additive: false)
        await harness.canvas.settleCalibrationPlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 369, y: 75), additive: false)
        await harness.canvas.settleCalibrationPlacements()

        #expect(collected.count == 2, "calibration did not collect two points")
        #expect(
            collected.first?.x == 72 && collected.first?.y == 72,
            "the first reference point did not snap: got \(String(describing: collected.first))"
        )
        #expect(
            collected.last?.x == 372 && collected.last?.y == 72,
            "the second reference point did not snap: got \(String(describing: collected.last))"
        )
    }

    @Test("A calibration click with nothing in range keeps the raw point")
    func aClickInEmptySpaceIsNotMoved() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        var collected: [PDFPointValue] = []
        harness.canvas.onCalibrationPointsCollected = { collected = $0 }
        harness.canvas.beginCalibration()

        // The far side of the sheet, where the fixture draws nothing at all. Snapping must not
        // invent a target: the raw point is the honest answer, and it is what the estimator saw
        // under the cursor.
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 700), additive: false)
        await harness.canvas.settleCalibrationPlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 520, y: 700), additive: false)
        await harness.canvas.settleCalibrationPlacements()

        #expect(collected.count == 2)
        #expect(collected.first?.x == 500 && collected.first?.y == 700)
        #expect(collected.last?.x == 520 && collected.last?.y == 700)
    }
}
