import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Iteration 5, ui-presentation-measure, on the canvas: `⌘` suspends snapping (V-070), `⇧Tab`
/// steps the snap candidates back (V-071), and the close ring stays off while an arc's through
/// point is due (V-074).
///
/// The fixture is CalibrationSnapTests' stroked rectangle with corners at exactly (72, 72),
/// (372, 72), (372, 272) and (72, 272), so "did it snap" is an exact comparison. Nothing here puts
/// a window on screen: the canvas is built headless and driven through its handlers.
@MainActor
@Suite(.appTierSerialised)
struct Iter5UIPresentationMeasureAppTests {

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

    private func fixtureURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-it5-uipm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Plan A-501.pdf")
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
        // Nothing to snap to until the index exists; without it these tests would say nothing.
        #expect(
            await AppTestSupport.wait(upTo: 40) { core.status.snapshot.geometryIndexStatus.allowsVectorSnap },
            "the vector snap index never became available"
        )
        // 300 pt across is 30 m, so a measurement tool has a scale to work in.
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
        return Harness(document: document, core: core, canvas: canvas, directory: url.deletingLastPathComponent())
    }

    private static let corner = PDFPointValue(x: 72, y: 72)
    private static let nearCorner = PDFPointValue(x: 75, y: 74)

    // MARK: - V-070 ⌘ suspends snapping

    /// Old output: with `⌘` held the glyph stayed on (72, 72) and the click stored (72, 72): the
    /// page view reported only Shift and `⌥`, and every resolve passed no keys.
    @Test("⌘ held: the hover glyph clears at once, and a click 3 pt off a corner stores the raw point")
    func commandSuspendsSnapForHoverAndClick() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        core.measurement.activate(kind: .length)

        canvas.handlePointerMove(Self.nearCorner)
        #expect(await AppTestSupport.wait { core.canvas.snapFeedback?.pagePoint == Self.corner },
                "precondition: the glyph lands on the corner with no key held")

        canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: true)
        #expect(canvas.isCommandHeld)
        #expect(await AppTestSupport.wait(upTo: 3) { core.canvas.snapFeedback == nil },
                "⌘ down clears the glyph without a mouse move")

        canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: false)
        #expect(await AppTestSupport.wait { core.canvas.snapFeedback?.pagePoint == Self.corner },
                "⌘ up brings the glyph back")

        canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: true)
        #expect(await AppTestSupport.wait(upTo: 3) { core.canvas.snapFeedback == nil })
        canvas.handleClick(at: Self.nearCorner, additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints == [Self.nearCorner], "the ⌘-click is placed raw")

        // ⌘ released: the next click snaps as before.
        canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: false)
        canvas.handleClick(at: PDFPointValue(x: 369, y: 75), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.last == PDFPointValue(x: 372, y: 72))
    }

    /// Old output: collected == [(72, 72), (372, 72)] — the calibration pick resolved with no keys.
    @Test("⌘ held: a calibration pick keeps the raw point; released, the next pick snaps")
    func commandSuspendsSnapForCalibration() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        var collected: [PDFPointValue] = []
        harness.canvas.onCalibrationPointsCollected = { collected = $0 }
        harness.canvas.beginCalibration()

        harness.canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: true)
        harness.canvas.handleClick(at: Self.nearCorner, additive: false)
        await harness.canvas.settleCalibrationPlacements()
        harness.canvas.handleModifiers(shiftHeld: false, optionHeld: false, commandHeld: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 369, y: 75), additive: false)
        await harness.canvas.settleCalibrationPlacements()

        #expect(collected == [Self.nearCorner, PDFPointValue(x: 372, y: 72)], "\(collected)")
    }

    /// The page view hands `⌘` over with Shift and `⌥`; it used to drop it.
    @Test("flagsChanged carries ⌘ to the canvas")
    func flagsChangedCarriesCommand() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let page = harness.canvas.pageViewForTesting
        let down = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        ))
        page.flagsChanged(with: down)
        #expect(harness.canvas.isCommandHeld)
        let up = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        ))
        page.flagsChanged(with: up)
        #expect(!harness.canvas.isCommandHeld)
    }

    // MARK: - V-071 ⇧Tab steps back

    private static func tab(shift: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0,
            context: nil, characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ))
    }

    /// The snap engine's `Tab` position, read on the session. The probe feeds `keysChanged(.none)`,
    /// which leaves the position alone.
    private static func cycleAdvance(_ core: AppCoreEnvironment, reaching expected: Int) async -> Int {
        var last = Int.min
        for _ in 0..<150 {
            last = await core.session.applySnapModifier(.keysChanged(.none)).cycleAdvance
            if last == expected { return last }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return last
    }

    /// Old output: cycleAdvance == +1 after ⇧Tab — the key and the window's command carried no
    /// direction, so both keys stepped forward.
    @Test("⇧Tab steps the snap candidates back, Tab forward")
    func shiftTabStepsBack() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core
        core.measurement.activate(kind: .length)
        let page = harness.canvas.pageViewForTesting

        page.keyDown(with: try Self.tab(shift: true))
        #expect(await Self.cycleAdvance(core, reaching: -1) == -1)
        page.keyDown(with: try Self.tab(shift: false))
        page.keyDown(with: try Self.tab(shift: false))
        #expect(await Self.cycleAdvance(core, reaching: 1) == 1)
    }

    // MARK: - V-074 no close ring while the arc's through point is due

    /// Old output: the ring was offered on (130, 130) with the arc armed, while the click there
    /// would place the arc's through point and not close.
    @Test("An armed arc shows no close ring near the first vertex; once its through point lands, it does")
    func armedArcShowsNoCloseRing() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        core.measurement.activate(kind: .area)
        canvas.handleClick(at: PDFPointValue(x: 130, y: 130), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 230, y: 130), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 230, y: 180), additive: false)
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 3)

        canvas.handlePointerMove(PDFPointValue(x: 131, y: 129))
        #expect(canvas.firstVertexCloseTarget() != nil, "precondition: the ring is offered with no arc armed")

        #expect(canvas.handle(key: .area))
        #expect(core.measurement.isArcNextSegment)
        canvas.handlePointerMove(PDFPointValue(x: 131, y: 129))
        #expect(canvas.firstVertexCloseTarget() == nil)
        #expect(canvas.liveStateForTesting().drawing.firstVertexCloseTarget == nil)

        canvas.handleClick(at: PDFPointValue(x: 180, y: 100), additive: false)
        #expect(await AppTestSupport.wait { core.measurement.arcThroughPoint != nil })
        #expect(core.measurement.placedPoints.count == 3, "the through point is not a vertex")
        canvas.handlePointerMove(PDFPointValue(x: 131, y: 129))
        #expect(canvas.firstVertexCloseTarget() != nil, "the arc's end may close the shape")
    }
}
