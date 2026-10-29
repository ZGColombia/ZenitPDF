import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// IM-019: every measurement mouse and key event on the shipping canvas goes through its
/// `MeasurementInputController`, and each tool's gesture sequence commits what it always did.
///
/// Driven headless through the canvas's own handlers against a real document and engine
/// session. The fixture sheet is calibrated so 300 PDF points are 30 metres; every expected
/// quantity below is derived from that by hand. The only drawn vectors are the rectangle
/// 72…372 × 72…272, and every point used here keeps well clear of it, so no snap moves a
/// click and the committed geometry is the clicked geometry.
@MainActor
@Suite(.appTierSerialised)
struct CanvasInputRoutingTests {

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        /// Every shell command the canvas raised, in order.
        var commands: [ZPDFCommandID] = []

        init(document: ZenitPDFProjectDocument, core: AppCoreEnvironment, canvas: PDFCanvasViewController) {
            self.document = document
            self.core = core
            self.canvas = canvas
        }

        func tearDown(_ url: URL) {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func makeHarness(_ url: URL) async throws -> Harness {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
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
        let harness = Harness(document: document, core: core, canvas: canvas)
        // Wired the way the window wires Finish: settle the in-flight snaps, then commit.
        canvas.onShellCommand = { [weak harness] command in
            harness?.commands.append(command)
            guard command == .finishGeometry else { return }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        return harness
    }

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private func committed(_ tool: MeasurementTool, in core: AppCoreEnvironment) async -> [MarkupRecord] {
        await core.session.orderedMarkups.filter { $0.tool == tool }
    }

    private func waitForMarkup(
        _ tool: MeasurementTool,
        in core: AppCoreEnvironment,
        where predicate: @escaping (MarkupRecord) -> Bool = { _ in true }
    ) async -> MarkupRecord? {
        for _ in 0..<200 {
            if let record = await committed(tool, in: core).first(where: predicate) { return record }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    // MARK: - Routing is real

    @Test("Clicks reach the input machine, which holds what the presenter holds")
    func clicksReachTheMachine() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Routing.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .polylength)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        harness.canvas.handleClick(at: p(230, 400), additive: false)
        let machine = harness.canvas.measurementInputForTesting
        #expect(machine.state.kind == .polylength)
        #expect(machine.state.vertices == [p(130, 400), p(230, 400)], "the machine took both clicks")
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints == [p(130, 400), p(230, 400)])
        #expect(harness.commands.isEmpty, "two polylength vertices commit nothing")

        // A tool change made elsewhere is adopted on the next event, not remembered stale.
        core.measurement.activate(kind: .length)
        harness.canvas.handleClick(at: p(130, 450), additive: false)
        #expect(machine.state.kind == .length)
        #expect(machine.state.vertices == [p(130, 450)])
    }

    // MARK: - Fixed count

    @Test("Length: the second click commits a 10 m length through the shell's Finish")
    func lengthCommitsOnSecondClick() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingLength.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .length)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        harness.canvas.handleClick(at: p(230, 400), additive: false)
        #expect(await AppTestSupport.wait { harness.commands == [.finishGeometry] })
        let record = try #require(await waitForMarkup(.length, in: core))
        // 100 pt at 300 pt = 30 m is 10 m, between exactly the two clicks.
        #expect(record.geometry?.points == [PDFPoint(x: 130, y: 400), PDFPoint(x: 230, y: 400)])
        #expect(harness.canvas.routedCommitCountForTesting == 1)
    }

    // MARK: - Count

    @Test("Count: three marks, ⌥-click removes the middle one, Escape ends the group with two")
    func countAddRemoveAndEnd() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCount.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .count)
        for x in [130.0, 180, 230] { harness.canvas.handleClick(at: p(x, 400), additive: false) }
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 3)
        #expect(harness.canvas.measurementInputForTesting.state.vertices.count == 3)

        // ⌥-click one point off the middle mark: inside the 8-screen-point target.
        harness.canvas.handleClick(at: p(181, 401), additive: false, optionHeld: true)
        #expect(core.measurement.placedPoints == [p(130, 400), p(230, 400)])

        // ⌥-click on empty page removes nothing and places nothing.
        harness.canvas.handleClick(at: p(300, 500), additive: false, optionHeld: true)
        #expect(core.measurement.placedPoints == [p(130, 400), p(230, 400)])

        #expect(harness.canvas.handle(key: .escape))
        #expect(harness.commands == [.finishGeometry], "Escape finishes a count group, never cancels it")
        let record = try #require(await waitForMarkup(.count, in: core))
        #expect(record.geometry?.countPoints.map(\.position) == [PDFPoint(x: 130, y: 400), PDFPoint(x: 230, y: 400)])
    }

    @Test("Count: Shift does not pull a mark onto a 45° ray (BH-256, now shipping)")
    func countIgnoresShift() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCountShift.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .count)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        await core.measurement.settlePlacements()
        harness.canvas.handleModifiers(shiftHeld: true)
        // 26° from the first mark: the old canvas would have moved it onto the 45° or 0° ray.
        harness.canvas.handleClick(at: p(230, 449), additive: true)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints == [p(130, 400), p(230, 449)])
    }

    // MARK: - Cutout

    @Test("Polygon cutout: the first click names its parent, Return commits it as that area's hole")
    func cutoutCommitsIntoItsParent() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCutout.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core
        let canvas = harness.canvas

        // The parent: a 10 m × 10 m area well below the drawn rectangle, closed on its first vertex.
        core.measurement.activate(kind: .area)
        for vertex in [p(130, 400), p(230, 400), p(230, 500), p(130, 500)] {
            canvas.handleClick(at: vertex, additive: false)
        }
        await core.measurement.settlePlacements()
        canvas.handleClick(at: p(130, 400), additive: false)
        let area = try #require(await waitForMarkup(.area, in: core))
        canvas.refresh()
        await canvas.settleScene()
        #expect(await AppTestSupport.wait(upTo: 10) { canvas.cutoutCandidateCountForTesting > 0 })

        core.measurement.activate(kind: .polygonCutout)
        // A first click outside every area is refused and places nothing.
        canvas.handleClick(at: p(400, 700), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.isEmpty)
        #expect(canvas.measurementInputForTesting.cutoutRefusal != nil)

        canvas.handleClick(at: p(150, 420), additive: false)
        #expect(core.measurement.cutoutParentID == area.id, "the first vertex resolves the parent")
        #expect(core.status.snapshot.activeToolNote?.hasPrefix("Cutting out of") == true)
        canvas.handleClick(at: p(200, 420), additive: false)
        canvas.handleClick(at: p(175, 470), additive: false)
        await core.measurement.settlePlacements()

        harness.commands = []
        #expect(canvas.handle(key: .finish))
        #expect(harness.commands == [.finishGeometry], "Return reaches the shell exactly once")
        let hole = try #require(await waitForMarkup(.polygonCutout, in: core) { $0.parentMarkupID != nil })
        #expect(hole.parentMarkupID == area.id)
    }

    // MARK: - Calibration

    @Test("Calibration: two clicks collect the two reference points and end the flow")
    func calibrationCollectsTwoPoints() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCalibration.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let canvas = harness.canvas

        var collected: [[PDFPointValue]] = []
        canvas.onCalibrationPointsCollected = { collected.append($0) }
        canvas.beginCalibration()
        #expect(canvas.calibrationInputForTesting.state.phase == .armed)
        canvas.handleClick(at: p(130, 600), additive: false)
        canvas.handleClick(at: p(330, 600), additive: false)
        await canvas.settleCalibrationPlacements()
        #expect(collected == [[p(130, 600), p(330, 600)]])
        #expect(!canvas.isCalibrating)
        #expect(canvas.calibrationInputForTesting.state.phase == .idle)
    }

    @Test("Calibration: Escape after one point ends the flow with nothing collected")
    func calibrationEscape() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCalibrationEscape.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let canvas = harness.canvas

        var collected = 0
        var ends: [Bool] = []
        canvas.onCalibrationPointsCollected = { _ in collected += 1 }
        canvas.onCalibrationEnd = { ends.append($0) }
        canvas.beginCalibration()
        canvas.handleClick(at: p(130, 600), additive: false)
        await canvas.settleCalibrationPlacements()
        #expect(canvas.handle(key: .escape))
        #expect(!canvas.isCalibrating)
        #expect(ends == [false], "ended once, abandoned")
        #expect(collected == 0)
    }

    // MARK: - Escape / cancel

    @Test("Escape over an area in progress goes to the shell's Cancel, never to Finish")
    func escapeCancelsAnArea() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingEscape.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        harness.canvas.handleClick(at: p(230, 400), additive: false)
        await core.measurement.settlePlacements()
        #expect(harness.canvas.handle(key: .escape))
        #expect(harness.commands == [.cancelTool])

        // An armed tool with nothing drawn backs out through the same door.
        harness.commands = []
        core.measurement.cancelActiveMeasurement()
        #expect(harness.canvas.handle(key: .escape))
        #expect(harness.commands == [.cancelTool])
    }

    @Test("Return the machine refuses still reaches the shell once, which speaks the refusal")
    func refusedReturnStillReachesTheShell() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingRefusedReturn.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        await core.measurement.settlePlacements()
        #expect(harness.canvas.handle(key: .finish))
        #expect(harness.commands == [.finishGeometry])
        #expect(harness.canvas.routedCommitCountForTesting == 0, "one vertex is not an area")
        await core.measurement.settlePlacements()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await committed(.area, in: core).isEmpty)
    }

    @Test("Backspace removes the last vertex through the shell; with nothing drawn it falls through")
    func backspaceRoutes() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingBackspace.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .polylength)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        await core.measurement.settlePlacements()
        #expect(harness.canvas.handle(key: .removeLastVertex))
        #expect(harness.commands == [.removeLastVertex])

        // With no vertex and no selection the key is not the canvas's.
        core.measurement.cancelActiveMeasurement()
        harness.commands = []
        #expect(!harness.canvas.handle(key: .removeLastVertex))
        #expect(harness.commands.isEmpty)
    }

    // MARK: - Double-click

    @Test("Double-click finishes a polylength with exactly its placed vertices")
    func doubleClickFinishesPolylength() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingDoubleClick.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .polylength)
        // The double-click's first click is an ordinary click; the view sends the second as
        // the double-click.
        for vertex in [p(130, 400), p(230, 400), p(230, 500)] {
            harness.canvas.handleClick(at: vertex, additive: false)
        }
        harness.canvas.handleDoubleClick(at: p(230, 500))
        #expect(await AppTestSupport.wait { harness.commands == [.finishGeometry] })
        let record = try #require(await waitForMarkup(.polylength, in: core))
        // 10 m + 10 m, through the three clicked vertices.
        #expect(record.geometry?.points == [
            PDFPoint(x: 130, y: 400), PDFPoint(x: 230, y: 400), PDFPoint(x: 230, y: 500)
        ])
    }

    @Test("Double-click during a count group neither closes the group nor loses a mark (CR-177)")
    func doubleClickIgnoredByCount() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingCountDouble.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .count)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        harness.canvas.handleClick(at: p(134, 400), additive: false)
        harness.canvas.handleDoubleClick(at: p(134, 400))
        await core.measurement.settlePlacements()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.commands.isEmpty, "the old canvas finished the group here")
        #expect(core.measurement.placedPoints.count == 2)
        #expect(await committed(.count, in: core).isEmpty)
    }

    // MARK: - Drag and ⌥-click rectangles

    @Test("Area press-drag-release commits the 10 m × 5 m rectangle between the corners")
    func areaDragCommitsRectangle() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingAreaDrag.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleDragBegan(at: p(130, 400))
        harness.canvas.handleDragMoved(to: p(200, 430))
        harness.canvas.handleDragEnded(at: p(230, 450))
        let record = try #require(await waitForMarkup(.area, in: core))
        let ring = record.geometry?.polygons.first?.outer.points ?? []
        #expect(Set(ring.map { "\($0.x),\($0.y)" }) == ["130.0,400.0", "230.0,400.0", "230.0,450.0", "130.0,450.0"])
    }

    @Test("⌥-click with an edge placed completes the Area as a three-point rectangle")
    func optionClickRectangle() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "RoutingOptionRectangle.pdf")
        let harness = try await makeHarness(url)
        defer { harness.tearDown(url) }
        let core = harness.core

        core.measurement.activate(kind: .area)
        harness.canvas.handleClick(at: p(130, 400), additive: false)
        harness.canvas.handleClick(at: p(230, 400), additive: false)
        await core.measurement.settlePlacements()
        harness.canvas.handleClick(at: p(230, 450), additive: false, optionHeld: true)
        #expect(harness.commands == [.finishGeometry], "the ⌥-click finishes at once")
        let record = try #require(await waitForMarkup(.area, in: core))
        // P4 = P1 + P3 − P2 = (130, 450).
        #expect(record.geometry?.polygons.first?.outer.points == [
            PDFPoint(x: 130, y: 400), PDFPoint(x: 230, y: 400), PDFPoint(x: 230, y: 450), PDFPoint(x: 130, y: 450)
        ])
    }
}

/// Design round d7 decisions (2026-09-23): the canvas
/// assigns its live overlay as one value, and the new default ink and dashed Length apply to
/// new measurements only — a stored markup keeps its colour and line style.
@MainActor
@Suite(.appTierSerialised)
struct CanvasLiveStateAndInkTests {

    private func p(_ x: Double, _ y: Double) -> PDFPointValue { PDFPointValue(x: x, y: y) }

    private func makeCanvas(_ url: URL) async throws -> (ZenitPDFProjectDocument, AppCoreEnvironment, PDFCanvasViewController) {
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let toolbar = try #require(document.shell?.toolbar)
        let canvas = PDFCanvasViewController(core: core, rasterSource: nil, toolbar: toolbar)
        _ = canvas.view
        return (document, core, canvas)
    }

    @Test("A refresh hands the view the whole live state it built, in one value")
    func refreshAssignsTheBuiltLiveState() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "LiveState.pdf")
        let (document, core, canvas) = try await makeCanvas(url)
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        // A scale first: since LT3-05 (nl-measure) an area on a sheet with no scale refuses its
        // first vertex up front.
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72), second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30), knownLengthUnit: .metre
        )
        await core.refresh()
        core.measurement.activate(kind: .area)
        canvas.handleClick(at: p(130, 400), additive: false)
        canvas.handleClick(at: p(230, 400), additive: false)
        await core.measurement.settlePlacements()
        canvas.handlePointerMove(p(230, 480))
        canvas.refresh()
        let live = canvas.pageViewLiveStateForTesting
        #expect(live == canvas.liveStateForTesting())
        #expect(live.drawing.points == [p(130, 400), p(230, 400)])
        #expect(live.drawing.closesOutline, "an area's outline is drawn closed")
        #expect(!live.drawing.isPointPlacement)
        #expect(live.drawing.cursorPoint == core.measurement.liveCursorPoint)
    }

    @Test("The calibration cursor the pointer set survives a refresh")
    func calibrationCursorSurvivesRefresh() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "LiveStateCalibration.pdf")
        let (document, _, canvas) = try await makeCanvas(url)
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        canvas.beginCalibration()
        canvas.handlePointerMove(p(150, 600))
        #expect(canvas.pageViewLiveStateForTesting.calibration.cursor == p(150, 600))
        canvas.refresh()
        #expect(canvas.pageViewLiveStateForTesting.calibration.cursor == p(150, 600))
        canvas.endCalibration()
    }

    @Test("A stored markup keeps its old cyan and solid line; a new Length commits blue and dashed")
    func storedStyleIsKeptNewLengthIsDashed() async throws {
        let cyan = RGBAColor(red: 0x50 / 255.0, green: 0xD6 / 255.0, blue: 0xDE / 255.0, alpha: 1)
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .length,
            subject: "Length",
            author: "test",
            style: MarkupStyle(color: cyan, lineStyle: .solid),
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]),
            createdAt: stamp,
            modifiedAt: stamp
        )
        let shape = try #require(CanvasSceneBuilder.build(records: [stored], summaries: [], pageID: pageID.rawValue).first)
        #expect(abs(shape.color.red - cyan.red) < 0.001 && abs(shape.color.blue - cyan.blue) < 0.001)
        #expect(shape.lineStyle == .solid, "nothing restyles a stored markup")

        let url = try AppTestSupport.writeFixturePDF(named: "LiveStateInk.pdf")
        let (document, core, canvas) = try await makeCanvas(url)
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        // Calibrated, so the Length can commit (an uncalibrated sheet refuses it).
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()
        var committed: MarkupRecord?
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else { return }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        core.measurement.activate(kind: .length)
        canvas.handleClick(at: p(130, 400), additive: false)
        canvas.handleClick(at: p(230, 400), additive: false)
        for _ in 0..<200 {
            if let record = await core.session.orderedMarkups.first(where: { $0.tool == .length }) {
                committed = record
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let record = try #require(committed)
        #expect(record.style.color == AppMeasurementToolPresenter.measurementInk)
        #expect(record.style.lineStyle == .dashed)
    }
}
