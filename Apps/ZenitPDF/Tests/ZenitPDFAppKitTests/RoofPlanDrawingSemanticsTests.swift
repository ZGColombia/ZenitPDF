import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFTestingSupport
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The drawing-semantics acceptance on a heavy A1 roof plan — the Synthetic Roof Plan of
/// `ZPDFTestingSupport` (`synthetic-roof-plan.pdf`, DEMO ROOF, A-00-0-001, one A1 vector sheet,
/// 16 341 primitives).
///
/// The document is opened through `ZenitPDFProjectDocument` — the app's own load pipeline,
/// snap index included — and every gesture goes through the shipping
/// `PDFCanvasViewController` handlers. This is the assembled app minus pixels: it checks the
/// assembled behaviour without driving a screen, and it is the regression these semantics
/// deserve either way.
///
/// Calibration is the sheet's own 100 mm control ruler: 36000/127 = 283.4646 pt of paper is
/// 5 000 mm of building (SKALA 1:50), so 1 pt = 1.27/72 = 0.017638… m. All picked vertices sit
/// in the sheet's free measuring band between the roof plan and the title column
/// (`SyntheticRoofPlan.freeBand`, x 1720…2045, y 520…1200), which no drawn primitive comes
/// within 40 pt of except the title column's divider at x = 2050.
@MainActor
@Suite(.appTierSerialised)
struct RoofPlanDrawingSemanticsTests {

    /// The synthetic roof plan in the shared fixture cache, read in place: the document reads a
    /// PDF, it never writes it.
    private static func fixtureURL() throws -> URL {
        try ZPDFFixtures.shared(.syntheticRoofPlan).url
    }

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("Drawing semantics on the A1 roof plan: Shift-straight length, close on first vertex, three-point rectangle, two-finger tap")
    func drawingSemanticsOnTheRoofPlan() async throws {
        let url = try Self.fixtureURL()
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "the roof plan is missing at \(url.path)"
        )

        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil && document.shell != nil })
        defer { document.close() }
        let core = try #require(document.core)

        // Calibrate across the control ruler's outer tick feet, (1050, 42) and
        // (1050 + 36000/127, 42): 283.4646 pt = 5 m.
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 1050, y: 42),
            second: PDFPoint(x: 1333.464566929134, y: 42),
            knownLength: Decimal(5),
            knownLengthUnit: .metre
        )
        await core.refresh()

        let toolbar = try #require(document.shell?.toolbar)
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: toolbar
        )
        _ = canvas.view
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else { return }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }

        // ── a Shift-constrained horizontal length along the free band. ──────────────
        core.measurement.activate(kind: .length)
        canvas.handleClick(at: PDFPointValue(x: 1745, y: 890), additive: false)
        await core.measurement.settlePlacements()
        canvas.handleModifiers(shiftHeld: true)
        // The cursor is 7 pt off horizontal; the readout and the committed point are not.
        canvas.handlePointerMove(PDFPointValue(x: 2028.465, y: 897))
        #expect(core.measurement.liveCursorPoint?.y == 890,
                "the rubber band follows the constrained point while Shift is held")
        canvas.handleClick(at: PDFPointValue(x: 2028.465, y: 897), additive: false)
        let placedLength = core.measurement.placedPoints
        #expect(placedLength.count == 2)
        #expect(placedLength.last?.y == 890, "angle readout 0.0° means dy == 0, exactly")
        canvas.handleModifiers(shiftHeld: false)
        #expect(await wait { core.ledger.rowCount == 1 },
                "the Shift-straight length lands in the ledger")

        // ── an area closed by clicking its first point. ─────────────────────────────
        core.measurement.activate(kind: .area)
        canvas.handleClick(at: PDFPointValue(x: 1745, y: 600), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 2028.465, y: 600), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 2028.465, y: 770.079), additive: false)
        await core.measurement.settlePlacements()
        canvas.handlePointerMove(PDFPointValue(x: 1746, y: 601))
        #expect(canvas.firstVertexCloseTarget() != nil,
                "the ring affordance must be offered on the first vertex")
        canvas.handleClick(at: PDFPointValue(x: 1746, y: 601), additive: false)
        #expect(await wait { core.ledger.rowCount == 2 },
                "clicking the first vertex closes and commits — no Return, no double-click")

        // ── a three-point rectangle over the free band, third click commits. ────────
        core.measurement.activate(kind: .rectangleArea)
        canvas.handleClick(at: PDFPointValue(x: 1745, y: 1100), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 2028.465, y: 1100), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.ledger.rowCount == 2, "two corners are an edge, not a rectangle")
        canvas.handleClick(at: PDFPointValue(x: 2028.465, y: 1128.3465), additive: false)
        #expect(await wait { core.ledger.rowCount == 3 },
                "the third click auto-finishes with the derived fourth corner")

        // ── a two-finger tap (secondary click) finishes a polygon. ──────────────────
        core.measurement.activate(kind: .area)
        canvas.handleClick(at: PDFPointValue(x: 1745, y: 655), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 1858.693, y: 655), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.handleSecondaryClick(),
                "consumed while measuring — a context menu never appears mid-measurement")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(core.ledger.rowCount == 3, "two vertices: the tap does nothing, cancels nothing")
        #expect(core.measurement.placedPoints.count == 2)
        canvas.handleClick(at: PDFPointValue(x: 1858.693, y: 683.3465), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.handleSecondaryClick())
        #expect(await wait { core.ledger.rowCount == 4 },
                "with three vertices the tap closes the polygon and commits")
    }
}
