import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The drawing semantics in the assembled app, as a person uses them by hand, driven through
/// the shipping `PDFCanvasViewController` input handlers against a real document, a real
/// engine session and the real Quantity Ledger.
///
/// Each behaviour here was specified after hands-on measuring, so each test drives the exact
/// gesture sequence: clicks through `handleClick`, presses through the drag handlers, the
/// two-finger tap through `handleSecondaryClick`, Shift through `handleModifiers`.
@MainActor
@Suite(.appTierSerialised)
struct DrawingSemanticsTests {

    // MARK: - Harness

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-semantics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-201.pdf")
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

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// One loaded, calibrated document with its canvas, wired the way the window wires it:
    /// `finishGeometry` settles the in-flight placements and then commits.
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

    private func makeHarness() async throws -> Harness {
        let url = try fixtureURL()
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.startLoadingIfNeeded()
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)

        // 300 PDF points across is 30 metres: a 1:100 sheet at 72 dpi.
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
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else { return }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        return Harness(
            document: document,
            core: core,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    // MARK: - Close on the first vertex

    @Test("Clicking the first vertex closes the area and the row lands in the ledger")
    func clickOnFirstVertexClosesTheArea() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .area)
        // A 10 m × 5 m right triangle, clear of the drawn rectangle's vector geometry.
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 3)

        // The pointer travels back over the first vertex: the close affordance must be
        // offered there before the click.
        harness.canvas.handlePointerMove(PDFPointValue(x: 131, y: 129))
        #expect(harness.canvas.firstVertexCloseTarget() != nil,
                "the ring affordance must appear within tolerance of the first vertex")

        // The click on the first vertex commits — no Return, no double-click.
        harness.canvas.handleClick(at: PDFPointValue(x: 131, y: 129), additive: false)
        #expect(await wait { core.ledger.rowCount == 1 },
                "closing on the first vertex must land the row in the ledger immediately")
        #expect(core.measurement.placedPoints.isEmpty)
    }

    @Test("The close probe composes snap: a snapped click on the vertex closes even when the raw cursor misses")
    func closeProbeUsesTheSnappedPoint() async throws {
        // The wiring break: the snap engine (wider tolerance) put the click
        // ON the first vertex while the old raw-cursor check missed, so the click stacked
        // a duplicate vertex instead of closing.
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        await core.measurement.settlePlacements()

        // A probe exactly on the first vertex — what the snap engine hands back — closes.
        #expect(harness.canvas.firstVertexCloseTarget(probe: PDFPointValue(x: 130, y: 130)) != nil)
        // A probe far away does not.
        #expect(harness.canvas.firstVertexCloseTarget(probe: PDFPointValue(x: 190, y: 160)) == nil)
    }

    // MARK: - Three-point rectangle

    @Test("Three clicks finish the rectangle with the derived fourth corner in the ledger")
    func threeClicksFinishTheRectangle() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .rectangleArea)
        // Edge 100 pt (10 m), depth 50 pt (5 m): 50 m², committed on the third click.
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 2)
        #expect(core.ledger.rowCount == 0, "two corners are an edge, not a rectangle")

        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        #expect(await wait { core.ledger.rowCount == 1 },
                "the third click must auto-finish — no confirm step")
        let csv = LedgerCSVExport.render(presenter: core.ledger)
        #expect(csv.contains("50"), "P4 = P1 + P3 − P2 closes 10 m × 5 m = 50 m²:\n\(csv)")
    }

    @Test("The rectangle's one-gesture drag still finishes on release")
    func rectangleDragStillFinishes() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .rectangleArea)
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 130, y: 130))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 200, y: 160))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 230, y: 180))
        #expect(await wait { core.ledger.rowCount == 1 },
                "press, drag, release: one gesture, one row")
    }

    // MARK: - Two-finger tap / secondary click

    @Test("A secondary click closes a polygon with three vertices and commits")
    func secondaryClickClosesThePolygon() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        await core.measurement.settlePlacements()

        #expect(harness.canvas.handleSecondaryClick(),
                "the tap must be consumed — never a context menu mid-measurement")
        #expect(await wait { core.ledger.rowCount == 1 })
    }

    @Test("A secondary click with too few vertices does nothing and never cancels")
    func secondaryClickBelowMinimumIsInert() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        await core.measurement.settlePlacements()

        #expect(harness.canvas.handleSecondaryClick(),
                "still consumed: no context menu over an in-progress measurement")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(core.ledger.rowCount == 0, "two vertices are not a polygon")
        #expect(core.measurement.placedPoints.count == 2, "the tap must never cancel work")

        // With no measurement tool armed the secondary click is not consumed: selection
        // and the context menu keep working.
        core.measurement.deactivate()
        #expect(!harness.canvas.handleSecondaryClick())
    }

    @Test("A secondary click finishes a polylength as placed")
    func secondaryClickFinishesPolylength() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .polylength)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        await core.measurement.settlePlacements()

        #expect(harness.canvas.handleSecondaryClick())
        #expect(await wait { core.ledger.rowCount == 1 })
    }

    // MARK: - Shift = straight line

    @Test("A Shift-constrained click places an exactly horizontal point and commits the length")
    func shiftClickIsExactlyHorizontal() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .length)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        await core.measurement.settlePlacements()

        harness.canvas.handleModifiers(shiftHeld: true)
        // 6° off horizontal: the constraint holds the committed point to y == 130 exactly.
        harness.canvas.handleClick(at: PDFPointValue(x: 250, y: 143), additive: false)
        let placed = core.measurement.placedPoints
        #expect(placed.count == 2)
        #expect(placed.last?.y == 130, "the committed point is the constrained point, exactly")
        #expect(await wait { core.ledger.rowCount == 1 })
        harness.canvas.handleModifiers(shiftHeld: false)
    }

    @Test("Shift constrains the rubber band live and releasing it mid-draw frees it")
    func shiftConstrainsTheLiveCursor() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .length)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        await core.measurement.settlePlacements()

        harness.canvas.handlePointerMove(PDFPointValue(x: 250, y: 143))
        #expect(core.measurement.liveCursorPoint == PDFPointValue(x: 250, y: 143),
                "free movement first")

        harness.canvas.handleModifiers(shiftHeld: true)
        #expect(core.measurement.liveCursorPoint?.y == 130,
                "Shift applies to the rubber band immediately, not at the next move")

        harness.canvas.handleModifiers(shiftHeld: false)
        #expect(core.measurement.liveCursorPoint == PDFPointValue(x: 250, y: 143),
                "releasing Shift mid-draw returns to free movement")
    }

    @Test("Shift on the rectangle's depth point yields a true rectangle")
    func shiftDepthPointMakesATrueRectangle() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core

        core.measurement.activate(kind: .rectangleArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        await core.measurement.settlePlacements()

        harness.canvas.handleModifiers(shiftHeld: true)
        // A skewed depth click: Shift holds it perpendicular to the placed edge.
        harness.canvas.handleClick(at: PDFPointValue(x: 242, y: 180), additive: false)
        #expect(await wait { core.ledger.rowCount == 1 })
        let csv = LedgerCSVExport.render(presenter: core.ledger)
        #expect(csv.contains("50"), "10 m × 5 m true rectangle = 50 m²:\n\(csv)")
        harness.canvas.handleModifiers(shiftHeld: false)
    }

    @Test("Shift holds the second calibration point straight")
    func shiftConstrainsCalibrationPicking() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        var collected: [PDFPointValue] = []
        harness.canvas.onCalibrationPointsCollected = { points in collected = points }
        harness.canvas.beginCalibration()
        // Calibration placement is asynchronous since 2026-08-26: the click resolves a snap
        // before it lands, exactly as a measurement click does. Settling is the same wait
        // `AppMeasurementToolPresenter.settlePlacements()` exists for, and skipping it would make
        // this assertion a race rather than a test.
        harness.canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        await harness.canvas.settleCalibrationPlacements()
        harness.canvas.handleModifiers(shiftHeld: true)
        harness.canvas.handleClick(at: PDFPointValue(x: 250, y: 137), additive: false)
        await harness.canvas.settleCalibrationPlacements()
        harness.canvas.handleModifiers(shiftHeld: false)

        #expect(collected.count == 2)
        #expect(collected.last?.y == 130, "calibration picking is a segment context too")
    }
}
