import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Iteration-5 app-canvas fixes: the findings
/// L-10, L-12, L-13 and L-15 reproduced headless, and the reviewed V-001 to V-015. Every test
/// drives the shipping canvas or its page view directly; no window is ordered front and no modal
/// is raised.
@MainActor
@Suite(.appTierSerialised)
struct Iter5AppCanvasTests {

    // MARK: - Shared helpers

    /// The default fixture's rectangle corner (`AppTestSupport.writeFixturePDF`).
    private static let corner = PDFPointValue(x: 372, y: 272)

    private static func eventually(
        _ seconds: Double = 15, _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private static func settleRaster(_ canvas: PDFCanvasViewController) async {
        for _ in 0..<5 {
            await canvas.settleRasterForTesting()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Default snapping on, the page calibrated 100 pt = 1 m, and the vector snap index ready.
    private static func snappingHarness(_ name: String) async throws -> Fix2Harness {
        let harness = try await Fix2Harness.make(name)
        try await harness.core.session.setSnapSettings(.default)
        await harness.core.refresh()
        #expect(
            await AppTestSupport.wait(upTo: 40) { harness.core.status.snapshot.geometryIndexStatus.allowsVectorSnap },
            "the vector snap index never became available"
        )
        return harness
    }

    private static func length(_ a: PDFPointValue, _ b: PDFPointValue) -> (PageID) -> MeasurementGeometry {
        { MeasurementGeometry(pageID: $0, points: [PDFPoint(x: a.x, y: a.y), PDFPoint(x: b.x, y: b.y)]) }
    }

    private static func planLengthMetres(_ record: MarkupRecord?) -> Double? {
        guard let value = record?.measurement?[.planLength]?.value else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    /// A standalone page view over a page box, drawn at 1×.
    private static func pageView(page: CGSize, zoom: CGFloat = 1) -> CanvasPageView {
        let view = CanvasPageView()
        view.backingScaleOverride = 1
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: page.width, height: page.height),
            rotation: 0, zoom: zoom, origin: .zero
        )
        view.frame = CGRect(x: 0, y: 0, width: page.width * zoom, height: page.height * zoom)
        return view
    }

    private static func render(_ view: CanvasPageView, rect: CGRect? = nil) -> NSBitmapImageRep {
        let area = rect ?? view.bounds
        let device = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = view.bounds.size
        view.cacheDisplay(in: area, to: rep)
        return rep
    }

    private static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        var value = [Int](repeating: 0, count: 4)
        rep.getPixel(&value, atX: x, y: y)
        return value
    }

    private static func measuredLength(
        id: UUID = UUID(), _ a: PDFPointValue, _ b: PDFPointValue, caption: String? = "1.00 m"
    ) -> CanvasMarkupShape {
        var shape = CanvasMarkupShape(
            id: id, pageID: UUID(), color: ColorRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
            strokes: [CanvasStroke(points: [a, b], closed: false, filled: false)], counts: [],
            bounds: ZenitMarkupGeometry.boundingRect(a, b), hidden: false
        )
        shape.caption = caption
        shape.lineWidth = 4
        return shape
    }

    private static func flagsEvent(_ flags: NSEvent.ModifierFlags, in view: NSView) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
        )!
    }

    // MARK: - L-10 switching tools commits the text being typed

    /// Old output: the chip's switch reached `applyArmedSelection`, which called
    /// `cancelTextEntry()` — "Testtext 123" was thrown away and the markup count stayed 0.
    @Test("L-10: choosing another tool while typing commits the text box and keeps the chosen tool")
    func toolSwitchCommitsTheText() async throws {
        let harness = try await Fix2Harness.make("Iter5 Text Switch.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        harness.shell.perform(.textTool)
        canvas.refresh()
        #expect(canvas.armedMode == .markup(.text))
        canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        #expect(canvas.activeTextEntry != nil)
        canvas.typeIntoTextEntry("Testtext 123")

        // The toolbar chip, exactly as a click on it arms Select.
        harness.shell.toolbar.selectTool(.select)
        canvas.refresh()
        #expect(canvas.activeTextEntry == nil, "the switch must end the box")
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 1 }, "the typed words were thrown away")
        let record = try #require(await harness.records().first)
        #expect(record.kind == .text)
        #expect(record.caption == "Testtext 123")
        #expect(canvas.armedMode == .select)

        // A switch to another drawing tool keeps that tool: the commit's return to Select must
        // not override the person's choice.
        harness.shell.perform(.textTool)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 120, y: 300), additive: false)
        canvas.typeIntoTextEntry("Second")
        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 2 })
        #expect(canvas.armedMode == .measure(.length), "the commit put Select back over the chosen Length")

        // Empty text still discards the box.
        harness.shell.perform(.textTool)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 300, y: 300), additive: false)
        harness.shell.toolbar.selectTool(.select)
        canvas.refresh()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.core.snapshot.markups.count == 2, "an empty box must leave no markup")
    }

    // MARK: - L-12 / V-001 the ring is drawn only where the snap is taken

    /// Old output: `displayedSnapPoint()` returned the snap in every mode, so the Text tool
    /// showed a ring at (72, 72) and it stayed there after Select was armed (the "small green
    /// circle").
    @Test("L-12 / V-001: the snap ring shows for a measurement tool, never for a markup tool or Select")
    func ringOnlyWhereTheSnapIsTaken() async throws {
        let harness = try await Self.snappingHarness("Iter5 Ring.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let nearCorner = PDFPointValue(x: 75, y: 74)
        let snappedCorner = PDFPointValue(x: 72, y: 72)

        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        canvas.handlePointerMove(nearCorner)
        #expect(await AppTestSupport.wait { harness.core.canvas.snapFeedback?.pagePoint == snappedCorner })
        canvas.refreshFromObservation()
        #expect(canvas.snapGlyphForTesting == snappedCorner, "a measurement tool takes the snap and shows it")

        harness.shell.perform(.textTool)
        canvas.refresh()
        canvas.handlePointerMove(PDFPointValue(x: 74, y: 75))
        #expect(await AppTestSupport.wait { harness.core.canvas.snapFeedback?.pagePoint == snappedCorner })
        canvas.refreshFromObservation()
        #expect(canvas.snapGlyphForTesting == nil, "the Text tool places the raw point and must not promise a snap")

        // The text box opens there, is typed into, and Select is armed from the toolbar.
        canvas.handleClick(at: nearCorner, additive: false)
        canvas.typeIntoTextEntry("Beside the corner")
        harness.shell.toolbar.selectTool(.select)
        canvas.refresh()
        #expect(harness.core.canvas.snapFeedback != nil, "precondition: the resolve still answered")
        #expect(canvas.snapGlyphForTesting == nil, "a ring stayed at the text box's position")

        harness.shell.toolbar.activateShape(.rectangle)
        canvas.refresh()
        canvas.handlePointerMove(nearCorner)
        try? await Task.sleep(for: .milliseconds(150))
        canvas.refreshFromObservation()
        #expect(canvas.snapGlyphForTesting == nil, "a Rectangle markup never takes the snap")
    }

    /// A Length (300, 300)–(360, 260) whose end is dragged to (370, 270), 2.8 pt from the fixture
    /// corner (372, 272). At 100 pt = 1 m the stored length is √(72² + 28²) / 100 = √5968 / 100
    /// = 0.772 528 316 … m.
    ///
    /// Old output: the preview and the commit took the raw release point (370, 270), so the
    /// stored length was √(70² + 30²) / 100 = √5800 / 100 = 0.761 577 310 … m while the ring
    /// showed the corner.
    @Test("V-001: a vertex dragged near a vector corner previews, shows and stores the corner")
    func vertexDragSnapsToTheCorner() async throws {
        let harness = try await Self.snappingHarness("Iter5 Vertex Snap.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let record = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 300, y: 300), PDFPointValue(x: 360, y: 260))
        )
        let id = record.id.rawValue
        harness.shell.perform(.selectTool)
        harness.core.canvas.select(markupIDs: [id], additive: false)
        await harness.settle()
        #expect(canvas.vertexHandle(at: PDFPointValue(x: 360, y: 260))?.index == 1)

        canvas.handleDragBegan(at: PDFPointValue(x: 360, y: 260))
        canvas.handleDragMoved(to: PDFPointValue(x: 370, y: 270))
        // The engine's winner here is the dragged vertex's own old position (a markup vertex
        // outranks a drawing's corner); the drag takes the corner, the best other candidate.
        #expect(await AppTestSupport.wait { canvas.vertexDragSnap?.point == Self.corner },
                "drag snap: \(String(describing: canvas.vertexDragSnap)), presenter: \(String(describing: harness.core.canvas.snapFeedback))")
        #expect(canvas.snapGlyphForTesting == Self.corner, "a vertex drag takes the snap, so it shows the ring")
        let previewed = canvas.pageViewForTesting.shapes.first { $0.id == id }
        #expect(previewed?.vertices.last == Self.corner, "the preview is not where the ring is")

        canvas.handleDragEnded(at: PDFPointValue(x: 370, y: 270))
        #expect(await Self.eventually {
            await harness.core.session.markup(record.id)?.geometry?.points.last == PDFPoint(x: 372, y: 272)
        }, "the stored vertex is not the corner the ring showed")
        let metres = try #require(Self.planLengthMetres(await harness.core.session.markup(record.id)))
        let expected = 5968.0.squareRoot() / 100
        #expect(Swift.abs(metres - expected) <= expected * 1e-12, "recomputed \(metres), expected \(expected)")
    }

    /// The markup's own old vertex is a snap target in the index; a small nudge inside the snap
    /// radius must still move the vertex rather than pin it where it was.
    @Test("V-001: a dragged vertex never snaps back onto its own old position")
    func vertexDragIgnoresItsOwnOldPosition() async throws {
        let harness = try await Self.snappingHarness("Iter5 Vertex Self.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let record = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 300, y: 400), PDFPointValue(x: 450, y: 400))
        )
        harness.shell.perform(.selectTool)
        harness.core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        await harness.settle()
        canvas.handleDragBegan(at: PDFPointValue(x: 300, y: 400))
        canvas.handleDragMoved(to: PDFPointValue(x: 302, y: 401))
        try? await Task.sleep(for: .milliseconds(150))
        canvas.refreshFromObservation()
        #expect(canvas.snapGlyphForTesting != PDFPointValue(x: 300, y: 400), "the ring promised the old corner")
        canvas.handleDragEnded(at: PDFPointValue(x: 302, y: 401))
        #expect(await Self.eventually {
            await harness.core.session.markup(record.id)?.geometry?.points.first != PDFPoint(x: 300, y: 400)
        }, "the vertex snapped back onto its own old position and nothing was edited")
        let moved = try #require(await harness.core.session.markup(record.id)?.geometry?.points.first)
        #expect(((moved.x - 302) * (moved.x - 302) + (moved.y - 401) * (moved.y - 401)).squareRoot() <= 3)
    }

    @Test("V-001: a dragged vertex's snap anchor is its neighbour")
    func vertexDragAnchor() {
        let vertices = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 10, y: 0), PDFPointValue(x: 10, y: 10)]
        #expect(PDFCanvasViewController.neighbouringVertex(of: 0, in: vertices) == vertices[1])
        #expect(PDFCanvasViewController.neighbouringVertex(of: 2, in: vertices) == vertices[1])
        #expect(PDFCanvasViewController.neighbouringVertex(of: 0, in: [vertices[0]]) == nil)
        #expect(PDFCanvasViewController.vertexDragSnapPoint(in: nil, excluding: vertices[0]) == nil)
    }

    // MARK: - L-13 a selected markup's hover label goes

    /// Old output: `selection` invalidated the page only; the overlay kept the hover label drawn
    /// above the markup's own pill (`liveChangeCount` unchanged), two identical labels stacked.
    @Test("L-13: selecting the hovered markup repaints the overlay without its hover label")
    func selectingTheHoveredMarkupDropsItsLabel() {
        let view = Self.pageView(page: CGSize(width: 400, height: 300))
        let id = UUID()
        view.shapes = [Self.measuredLength(id: id, PDFPointValue(x: 50, y: 150), PDFPointValue(x: 250, y: 150))]
        view.hoverTarget = .markup(id)
        #expect(view.hoverOutlineMarkupID == id)
        let before = view.liveChangeCount
        view.selection = [id]
        #expect(view.hoverOutlineMarkupID == nil)
        #expect(view.liveChangeCount == before + 1, "the overlay kept the stale hover label")
        // A selection change that does not touch the hovered markup leaves the overlay alone.
        let other = UUID()
        view.selection = [id, other]
        #expect(view.liveChangeCount == before + 1)
    }

    // MARK: - L-15 count marks are visible at fit zoom

    /// Old output: an 8 pt mark at 20 % was drawn 1.6 view points across (a speck, three or four
    /// pixels), with no outline.
    @Test("L-15: a count mark has a minimum on-screen size and a contrasting keyline")
    func countMarksReadAtFitZoom() throws {
        #expect(CanvasCountSymbolPainter.drawnSizeInView(for: nil, zoom: 0.2) == CanvasCountSymbolPainter.minimumOnScreenSize)
        #expect(CanvasCountSymbolPainter.drawnSizeInView(for: nil, zoom: 2) == 16)

        let side = 40
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // A dark hatch-like ground, where a dark ink disappears.
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let ink = NSColor(srgbRed: 0.10, green: 0.42, blue: 1.0, alpha: 1)
        CanvasCountSymbolPainter.draw(
            symbol: nil, artwork: nil, at: CGPoint(x: 20, y: 20), zoom: 0.2, backingScale: 1, color: ink, in: context
        )
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: side * side * 4)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = (y * side + x) * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }
        var inked = 0, light = 0
        for y in 0..<side {
            for x in 0..<side {
                let value = rgb(x, y)
                if value.2 > 150 && value.0 < 120 { inked += 1 }
                // The ground is dark, so every light pixel is the keyline.
                if value.0 > 180 && value.1 > 180 && value.2 > 180 { light += 1 }
            }
        }
        // A 12-point box draws an 8-point dot (π·4² ≈ 50 px) inside a 2-point keyline ring
        // (π·(6² − 4²) ≈ 63 px).
        #expect(inked >= 35, "the mark covers \(inked) blue pixels at 20 %")
        #expect(light >= 25, "no light keyline round a dark mark: \(light) light pixels")
        #expect(CanvasCountSymbolPainter.keylineColor(for: ink).whiteComponentOrLuminance > 0.9)
        #expect(CanvasCountSymbolPainter.keylineColor(for: .yellow).whiteComponentOrLuminance < 0.2)
    }

    /// Old output: the hit radius was size ÷ 2 ÷ zoom — 1 pt for an 8 pt mark at 400 %, which the
    /// painter draws 4 pt across on the sheet — so a click on the drawn mark 3 pt from its centre
    /// missed.
    @Test("L-15: the drawn mark is the hit target at every zoom")
    func countHitTargetIsTheDrawnMark() {
        let mark = PDFPointValue(x: 100, y: 100)
        let shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [], counts: [mark], bounds: PDFRectValue(x: 99, y: 99, width: 2, height: 2), hidden: false
        )
        #expect(CanvasHitTesting.shape(shape, contains: PDFPointValue(x: 103, y: 100), tolerance: 0.75, zoom: 4))
        #expect(!CanvasHitTesting.shape(shape, contains: PDFPointValue(x: 105, y: 100), tolerance: 0.75, zoom: 4))
        // At 20 % the 10-point minimum is 50 pt on the sheet: its radius, 25 pt, is the target.
        #expect(CanvasHitTesting.shape(shape, contains: PDFPointValue(x: 124, y: 100), tolerance: 1, zoom: 0.2))
    }

    // MARK: - V-002 held keys follow the pointer events

    /// Old output: ⇧ stayed held after the canvas resigned first responder, after a pointer move
    /// without ⇧ and after another window took the keyboard, so the second point of a Length was
    /// forced onto the rose: (x, 500) instead of (200, 530).
    @Test("V-002: a stale ⇧ is corrected by the next pointer event, by resigning and by losing key")
    func heldKeysAreReconciled() async throws {
        let harness = try await Fix2Harness.make("Iter5 Modifiers.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let page = canvas.pageViewForTesting
        page.flagsChanged(with: Self.flagsEvent(.shift, in: page))
        #expect(canvas.isShiftHeld)
        _ = page.resignFirstResponder()
        #expect(!canvas.isShiftHeld, "resigning first responder kept ⇧")

        page.flagsChanged(with: Self.flagsEvent(.shift, in: page))
        page.mouseMoved(with: harness.mouseEvent(.mouseMoved, atLocal: CGPoint(x: 200, y: 200)))
        #expect(!canvas.isShiftHeld, "a move without ⇧ kept it")

        page.flagsChanged(with: Self.flagsEvent(.shift, in: page))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: page.window)
        #expect(!canvas.isShiftHeld, "another window taking the keyboard kept ⇧")

        // The click stores the unconstrained point.
        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 100, y: 500), additive: false)
        page.flagsChanged(with: Self.flagsEvent(.shift, in: page))
        let transform = try #require(page.transform)
        let second = transform.viewPoint(from: PDFPointValue(x: 200, y: 530))
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: second))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: second))
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 1 })
        let points = try #require(await harness.records().first?.geometry?.points)
        #expect(points.count == 2)
        #expect(Swift.abs(points[1].x - 200) < 1e-6 && Swift.abs(points[1].y - 530) < 1e-6, "stored \(points[1])")
    }

    // MARK: - V-003 the ledger filter reaches the drawing

    /// Old output: Hide left B in `pageView.shapes` — drawn, without its pill, and hit by a click
    /// on its line; Dim drew A and B the same.
    @Test("V-003: Hide takes filtered-out markups off the sheet; Dim draws them faintly")
    func ledgerFilterHidesAndDims() async throws {
        let harness = try await Fix2Harness.make("Iter5 Filter.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let ledger = harness.core.ledger
        let a = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 100, y: 500), PDFPointValue(x: 300, y: 500)), subject: "Walls"
        )
        let b = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 100, y: 600), PDFPointValue(x: 300, y: 600)), subject: "Doors"
        )
        harness.shell.perform(.selectTool)
        await harness.settle()
        #expect(canvas.pageViewForTesting.shapes.count == 2)

        // The filter panel's control, through the ledger, as the Quantity Ledger drives it.
        ledger.setCanvasFilterBehavior(.hideNonMatching)
        ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Walls"))
        ]))
        #expect(await AppTestSupport.wait { harness.core.canvas.visibleMarkups.map(\.id) == [a.id.rawValue] })
        await harness.settle()
        #expect(canvas.pageViewForTesting.shapes.map(\.id) == [a.id.rawValue], "Hide left the filtered-out markup drawn")
        #expect(canvas.hitTest(PDFPointValue(x: 200, y: 600)) == nil, "a hidden markup was still hit")
        #expect(canvas.hitTest(PDFPointValue(x: 200, y: 500)) == a.id.rawValue)

        ledger.setCanvasFilterBehavior(.dimNonMatching)
        #expect(await AppTestSupport.wait { harness.core.canvas.dimmedMarkupIDs == [b.id.rawValue] })
        await harness.settle()
        let shapes = canvas.pageViewForTesting.shapes
        #expect(shapes.count == 2)
        #expect(shapes.first { $0.id == b.id.rawValue }?.isDimmed == true, "Dim drew the filtered-out markup normally")
        #expect(shapes.first { $0.id == a.id.rawValue }?.isDimmed == false)
        #expect(canvas.hitTest(PDFPointValue(x: 200, y: 600)) == b.id.rawValue, "a dimmed markup is still there")

        ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(await AppTestSupport.wait { harness.core.canvas.dimmedMarkupIDs.isEmpty })
        await harness.settle()
        #expect(canvas.pageViewForTesting.shapes.allSatisfy { !$0.isDimmed })
    }

    @Test("V-003: a dimmed markup is drawn at a quarter of its ink")
    func dimmedMarkupIsFaint() {
        let view = Self.pageView(page: CGSize(width: 300, height: 200))
        let a = Self.measuredLength(PDFPointValue(x: 20, y: 150), PDFPointValue(x: 280, y: 150), caption: nil)
        var b = Self.measuredLength(PDFPointValue(x: 20, y: 50), PDFPointValue(x: 280, y: 50), caption: nil)
        b.isDimmed = true
        view.shapes = [a, b]
        let rep = Self.render(view)
        // Page y 150 is view y 50; page y 50 is view y 150; view y 100 is bare ground.
        let ground = Self.pixel(rep, 150, 100)
        let normal = Self.pixel(rep, 150, 50)
        let faint = Self.pixel(rep, 150, 150)
        // The ink's strength is how far it pulls the green channel from the ground's: the
        // markup is red, so full ink pulls green almost to 0 and a quarter of it a quarter as far.
        let full = Double(Swift.abs(ground[1] - normal[1])), dim = Double(Swift.abs(ground[1] - faint[1]))
        #expect(full > 100, "the plain markup is not drawn: ground \(ground), ink \(normal)")
        #expect(dim / full > 0.1 && dim / full < 0.45, "the dimmed ink is \(dim / full) of full: \(faint) over \(ground)")
    }

    // MARK: - V-003 re-check: what Hide takes off the sheet is no snap target

    /// "Walls" (100, 500)–(300, 500) and "Doors" (100, 600)–(300, 600) under default snapping with
    /// the grid off (36 pt grid points would otherwise compete), so only the two markups and the
    /// fixture's rectangle — far away, y ≤ 272 — are targets.
    private static func filterSnapHarness(_ name: String) async throws -> (Fix2Harness, MarkupRecord, MarkupRecord) {
        let harness = try await Self.snappingHarness(name)
        var settings = SnapSettings.default
        settings.enabledKinds.remove(.grid)
        try await harness.core.session.setSnapSettings(settings)
        await harness.core.refresh()
        let walls = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 100, y: 500), PDFPointValue(x: 300, y: 500)), subject: "Walls"
        )
        let doors = try await harness.addMarkup(
            tool: .length, geometry: Self.length(PDFPointValue(x: 100, y: 600), PDFPointValue(x: 300, y: 600)), subject: "Doors"
        )
        return (harness, walls, doors)
    }

    /// The Quantity Ledger's filter panel: subject equals "Walls", with the canvas behaviour.
    private static func filterToWalls(_ harness: Fix2Harness, _ behavior: LedgerCanvasFilterBehavior) {
        harness.core.ledger.setCanvasFilterBehavior(behavior)
        harness.core.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Walls"))
        ]))
    }

    /// Old output (traced from the code): `buildSnapIndex` and `refreshSnapMarkups` index every
    /// markup not hidden by its own flag or its layer, and no resolve read the ledger filter, so
    /// under Hide the pointer at (303, 602) still landed on Doors' end (300, 600) — a
    /// markupVertex, priority 0 — and the Length's second click stored (300, 600), a point the
    /// sheet no longer showed.
    @Test("V-003: a markup Hide takes off the sheet is no snap target; Dim and a cleared filter restore it")
    func filterHiddenMarkupIsNoSnapTarget() async throws {
        let (harness, walls, doors) = try await Self.filterSnapHarness("Iter5 Filter Snap.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let presenter = harness.core.canvas
        let doorsEnd = PDFPointValue(x: 300, y: 600)
        let wallsEnd = PDFPointValue(x: 300, y: 500)
        let nearDoorsEnd = PDFPointValue(x: 303, y: 602)
        let firstClick = PDFPointValue(x: 200, y: 700)
        func drawnLength() async -> MarkupRecord? {
            await harness.records().first { $0.id != walls.id && $0.id != doors.id }
        }
        /// A Length clicked as a hand does it: the pointer moves to each point, then clicks there
        /// (a click takes the ring the canvas shows for the pointer's own position).
        func clickLength(ending end: PDFPointValue) async {
            canvas.handlePointerMove(firstClick)
            _ = await AppTestSupport.wait { presenter.snapFeedback == nil && presenter.viewport.cursorPagePoint == firstClick }
            canvas.handleClick(at: firstClick, additive: false)
            canvas.handlePointerMove(end)
            try? await Task.sleep(for: .milliseconds(150))
            canvas.handleClick(at: end, additive: false)
        }

        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        canvas.handlePointerMove(nearDoorsEnd)
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == doorsEnd },
                "precondition: unfiltered, Doors' end catches the pointer")

        Self.filterToWalls(harness, .hideNonMatching)
        #expect(await AppTestSupport.wait { presenter.visibleMarkups.map(\.id) == [walls.id.rawValue] })
        await harness.settle()
        #expect(presenter.filterHiddenMarkupIDs == [doors.id.rawValue])
        #expect(canvas.pageViewForTesting.shapes.map(\.id) == [walls.id.rawValue], "precondition: Hide took Doors off the sheet")
        // The resting pointer is re-resolved when the filter changes, so the ring leaves at once.
        #expect(await AppTestSupport.wait { presenter.snapFeedback == nil },
                "the ring stayed on a markup Hide took away: \(String(describing: presenter.snapFeedback))")

        // A drawn markup still catches; the move back to Doors' end lands on nothing.
        canvas.handlePointerMove(PDFPointValue(x: 303, y: 502))
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == wallsEnd }, "a drawn markup stopped catching")
        canvas.handlePointerMove(nearDoorsEnd)
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint != wallsEnd })
        #expect(presenter.snapFeedback == nil, "Doors' end caught the pointer under Hide: \(String(describing: presenter.snapFeedback))")
        canvas.refreshFromObservation()
        #expect(canvas.snapGlyphForTesting == nil, "the ring promised a point the sheet does not show")

        // The Length's second click, on the measurement presenter's own resolve, stores the raw point.
        await clickLength(ending: nearDoorsEnd)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 3 })
        let raw = try #require(await drawnLength())
        let rawEnd = try #require(raw.geometry?.points.last)
        #expect(rawEnd.distance(to: PDFPoint(x: 303, y: 602)) <= 1e-9,
                "stored \(String(describing: raw.geometry?.points)); Doors' end is (300, 600)")
        _ = try await harness.core.commands.perform(.removeMarkup(raw.id))
        await harness.settle()

        // Dim draws Doors, so it is a target again.
        harness.core.ledger.setCanvasFilterBehavior(.dimNonMatching)
        #expect(await AppTestSupport.wait { presenter.dimmedMarkupIDs == [doors.id.rawValue] })
        #expect(presenter.filterHiddenMarkupIDs.isEmpty)
        canvas.handlePointerMove(PDFPointValue(x: 302, y: 601))
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == doorsEnd }, "Dim draws Doors, yet its end did not catch")

        // Hide again, then clear the filter: the end catches and the click stores it.
        harness.core.ledger.setCanvasFilterBehavior(.hideNonMatching)
        #expect(await AppTestSupport.wait { presenter.filterHiddenMarkupIDs == [doors.id.rawValue] })
        canvas.handlePointerMove(nearDoorsEnd)
        #expect(await AppTestSupport.wait { presenter.snapFeedback == nil }, "Hide again left Doors a target")
        harness.core.ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(await AppTestSupport.wait { presenter.filterHiddenMarkupIDs.isEmpty })
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == doorsEnd },
                "clearing the filter did not restore the target under the resting pointer")
        await clickLength(ending: nearDoorsEnd)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 3 })
        let snapped = try #require(await drawnLength())
        let snappedEnd = try #require(snapped.geometry?.points.last)
        #expect(snappedEnd.distance(to: PDFPoint(x: 300, y: 600)) <= 1e-9, "stored \(String(describing: snapped.geometry?.points))")
    }

    /// Old output (traced from the code): the vertex-drag resolver passed no exclusion, so under
    /// Hide Walls' end dragged to (302, 597) took Doors' end (300, 600) — ring, preview and the
    /// stored vertex.
    @Test("V-003 / V-001: a Select vertex drag does not snap to a markup Hide took off the sheet")
    func vertexDragIgnoresFilterHiddenMarkup() async throws {
        let (harness, walls, doors) = try await Self.filterSnapHarness("Iter5 Filter Vertex.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let doorsEnd = PDFPointValue(x: 300, y: 600)
        Self.filterToWalls(harness, .hideNonMatching)
        #expect(await AppTestSupport.wait { harness.core.canvas.filterHiddenMarkupIDs == [doors.id.rawValue] })
        harness.shell.perform(.selectTool)
        harness.core.canvas.select(markupIDs: [walls.id.rawValue], additive: false)
        await harness.settle()
        #expect(canvas.vertexHandle(at: PDFPointValue(x: 300, y: 500))?.index == 1)

        canvas.handleDragBegan(at: PDFPointValue(x: 300, y: 500))
        canvas.handleDragMoved(to: PDFPointValue(x: 302, y: 597))
        try? await Task.sleep(for: .milliseconds(250))
        #expect(canvas.vertexDragSnap == nil, "the drag snapped to \(String(describing: canvas.vertexDragSnap))")
        #expect(canvas.pageViewForTesting.shapes.first { $0.id == walls.id.rawValue }?.vertices.last == PDFPointValue(x: 302, y: 597))
        canvas.handleDragEnded(at: PDFPointValue(x: 302, y: 597))
        let storedRaw = await Self.eventually {
            await harness.core.session.markup(walls.id)?.geometry?.points.last == PDFPoint(x: 302, y: 597)
        }
        let stored = await harness.core.session.markup(walls.id)?.geometry?.points
        #expect(storedRaw, "stored \(String(describing: stored)); Doors' end is (300, 600)")

        // With the filter cleared the same neighbourhood lands on Doors' end.
        harness.core.ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(await AppTestSupport.wait { harness.core.canvas.filterHiddenMarkupIDs.isEmpty })
        harness.core.canvas.select(markupIDs: [walls.id.rawValue], additive: false)
        await harness.settle()
        canvas.handleDragBegan(at: PDFPointValue(x: 302, y: 597))
        canvas.handleDragMoved(to: PDFPointValue(x: 302, y: 598))
        #expect(await AppTestSupport.wait { canvas.vertexDragSnap?.point == doorsEnd },
                "cleared, the drag did not snap: \(String(describing: canvas.vertexDragSnap))")
        canvas.handleDragEnded(at: PDFPointValue(x: 302, y: 598))
        #expect(await Self.eventually {
            await harness.core.session.markup(walls.id)?.geometry?.points.last == PDFPoint(x: 300, y: 600)
        })
    }

    /// The exclusion belongs to one resolve, never to the session: one session serves every window
    /// of a document (NL-UX-20), each window with its own ledger filter. An excluded cutout's hole,
    /// which its visible parent still draws, stays a target exactly as a hidden cutout's does
    /// (V-085), and a changed index is never answered from a stale cut.
    ///
    /// One 1 000 × 1 000 pt page (grid off), an area (100, 100)–(500, 400) with an Ellipse Cutout
    /// over (200, 200)–(400, 300), Length A (600, 600)–(800, 600) and Length B (600, 800)–(800, 800).
    @Test("V-003: the snap exclusion is per resolve, keeps an excluded cutout's hole, and follows index changes")
    func snapExclusionIsPerResolve() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        var settings = SnapSettings.default
        settings.enabledKinds.remove(.grid)
        let session = try TakeoffSession(documentID: documentID, pages: [page], snapSettings: settings)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 10, y: 10), second: PDFPoint(x: 110, y: 10),
                                        knownLength: 10, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_790_500_000)
        func record(_ tool: MeasurementTool, _ geometry: MeasurementGeometry) -> MarkupRecord {
            MarkupRecord(id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .measurement, tool: tool,
                         geometry: geometry, createdAt: stamp, modifiedAt: stamp)
        }
        let parent = record(.area, MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 400), PDFPoint(x: 100, y: 400)
        ]))]))
        let cutout = record(.ellipseCutout, MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 400, y: 300)]))
        let a = record(.length, MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 600, y: 600), PDFPoint(x: 800, y: 600)]))
        let b = record(.length, MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 600, y: 800), PDFPoint(x: 800, y: 800)]))
        _ = try await session.apply(.addMarkup(parent))
        _ = try await session.apply(.addCutout(parent: parent.id, cutout: cutout))
        _ = try await session.apply(.addMarkup(a))
        _ = try await session.apply(.addMarkup(b))
        _ = try await session.buildSnapIndex(page: page, extraction: nil)
        let layout = PageViewLayout(zoom: 1, backingScale: 2)
        func winner(_ point: PDFPoint, excluding: Set<MarkupID> = []) async throws -> SnapCandidate? {
            await session.resetSnapState()
            return try await session.resolveSnap(pageID: page.id, pagePoint: point, layout: layout, excludingMarkupIDs: excluding).winner
        }

        // Alternating exclusions on one session: each resolve answers for its own.
        let nearAEnd = PDFPoint(x: 803, y: 602)
        #expect(try await winner(nearAEnd)?.position == PDFPoint(x: 800, y: 600))
        #expect(try await winner(nearAEnd, excluding: [a.id]) == nil, "an excluded markup was a target")
        #expect(try await winner(nearAEnd)?.position == PDFPoint(x: 800, y: 600), "an exclusion outlived its resolve")
        #expect(try await winner(nearAEnd, excluding: [b.id])?.position == PDFPoint(x: 800, y: 600), "excluding B took A away")

        // An excluded parent loses its corners; its cutout's own ellipse is untouched.
        let nearCorner = PDFPoint(x: 102, y: 101)
        #expect(try await winner(nearCorner)?.position == PDFPoint(x: 100, y: 100))
        #expect(try await winner(nearCorner, excluding: [parent.id]) == nil, "an excluded parent kept its corner")
        let t = Double.pi / 3
        let onCurve = PDFPoint(x: 300 + 100 * cos(t), y: 250 + 50 * sin(t))
        let nx = cos(t) / 100, ny = sin(t) / 50, norm = (nx * nx + ny * ny).squareRoot()
        let nearCurve = PDFPoint(x: onCurve.x + 2 * nx / norm, y: onCurve.y + 2 * ny / norm)
        let viaCutout = try #require(try await winner(nearCurve, excluding: [parent.id]))
        #expect(viaCutout.kind == .markupEdge && viaCutout.position.distance(to: onCurve) <= 1e-9)

        // An excluded cutout: the visible parent still draws its hole, so the curve stays a target.
        let viaParent = try #require(try await winner(nearCurve, excluding: [cutout.id]), "an excluded cutout took its drawn hole away")
        #expect(viaParent.kind == .markupEdge && viaParent.position.distance(to: onCurve) <= 1e-9, "landed \(viaParent)")

        // A moved markup is found at its new place by a resolve with the same exclusion as before.
        #expect(try await winner(PDFPoint(x: 803, y: 802), excluding: [a.id])?.position == PDFPoint(x: 800, y: 800))
        _ = try await session.apply(.moveMarkup(id: b.id, dx: 0, dy: 50))
        #expect(try await winner(PDFPoint(x: 803, y: 852), excluding: [a.id])?.position == PDFPoint(x: 800, y: 850),
                "a stale cut answered after the index changed")
        #expect(try await winner(PDFPoint(x: 803, y: 802), excluding: [a.id]) == nil)
    }

    // MARK: - V-004 a move never recomputes

    /// Old output: two move frames started two live previews (`livePreviewStartCountForTesting`
    /// 2), each recomputing the markup on the session actor.
    @Test("V-004: a Select move starts no live quantity preview; a vertex drag does")
    func moveStartsNoPreview() async throws {
        let harness = try await Fix2Harness.make("Iter5 Move Preview.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let record = try await harness.addMarkup(tool: .length, geometry: Self.length(PDFPointValue(x: 100, y: 500), PDFPointValue(x: 300, y: 500)))
        harness.shell.perform(.selectTool)
        harness.core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        await harness.settle()
        let before = canvas.livePreviewStartCountForTesting
        canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 500))
        canvas.handleDragMoved(to: PDFPointValue(x: 210, y: 510))
        canvas.handleDragMoved(to: PDFPointValue(x: 220, y: 520))
        #expect(canvas.livePreviewStartCountForTesting == before, "a move recomputed a value it cannot change")
        canvas.handleDragEnded(at: PDFPointValue(x: 220, y: 520))
        #expect(await Self.eventually { await harness.core.session.markup(record.id)?.geometry?.points.first == PDFPoint(x: 120, y: 520) })
        await harness.settle()
        harness.core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        await harness.settle()
        canvas.handleDragBegan(at: PDFPointValue(x: 320, y: 520))
        canvas.handleDragMoved(to: PDFPointValue(x: 400, y: 520))
        #expect(canvas.livePreviewStartCountForTesting == before + 1, "a vertex drag changes the quantity and previews it")
        canvas.handleDragEnded(at: PDFPointValue(x: 400, y: 520))
    }

    // MARK: - V-005 a freehand sample repaints the overlay only

    /// Old output: `handleDragMoved` set `pageView.needsDisplay = true` on every Pen sample.
    @Test("V-005: a Pen sample leaves the page view's committed ink alone")
    func penSampleRepaintsTheOverlayOnly() async throws {
        let harness = try await Fix2Harness.make("Iter5 Pen.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        harness.shell.toolbar.activateShape(.freehand)
        canvas.refresh()
        #expect(canvas.armedMode == .markup(.freehand))
        canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        let page = canvas.pageViewForTesting
        page.needsDisplay = false
        canvas.handleDragMoved(to: PDFPointValue(x: 150, y: 120))
        #expect(harness.core.markup.placedPoints.count >= 2, "precondition: the sample was taken")
        #expect(!page.needsDisplay, "a freehand sample repainted the whole page view")
        canvas.handleDragEnded(at: PDFPointValue(x: 180, y: 130))
    }

    // MARK: - V-006 / V-007 / V-008 the magnifier

    private static func withLoupe<T>(
        _ canvas: PDFCanvasViewController, _ body: () async throws -> T
    ) async throws -> T {
        // The loupe suite `NLMeasureLoupeTests` already uses: one plist per prefix, ever.
        let name = ScratchDefaults.suiteName(for: "zenit.r2measure.loupe")
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        canvas.loupeDefaults = defaults
        CanvasLoupe.setEnabled(true, defaults)
        defer {
            canvas.loupeDefaults = .standard
            ScratchDefaults.discard(defaults, suiteName: name)
        }
        return try await body()
    }

    /// Old output: the lens stayed at the press point through the whole drag
    /// (`shownPagePoint` (400, 1200)), and stayed up after calibration ended.
    @Test("V-006: the lens follows a press-drag, and leaves when its tool ends")
    func lensFollowsDragsAndLeaves() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter5 Loupe Drag.pdf", content: "12 w 0 0 0 RG 200 1200 m 1400 1200 l S")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        try await harness.core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        await harness.core.refresh()
        canvas.refresh()
        await Self.settleRaster(canvas)
        try await Self.withLoupe(canvas) {
            harness.shell.toolbar.activateMeasurement(.area)
            canvas.refresh()
            let press = PDFPointValue(x: 400, y: 1200), drag = PDFPointValue(x: 900, y: 1100)
            canvas.handlePointerMove(press)
            let host = try #require(canvas.loupeHost as? LoupeHostingView)
            #expect(host.shownPagePoint == press)
            canvas.handleDragBegan(at: press)
            canvas.handleDragMoved(to: drag)
            #expect((canvas.loupeHost as? LoupeHostingView)?.shownPagePoint == drag, "the lens froze at the press")
            canvas.handleDragEnded(at: drag)

            harness.shell.toolbar.selectTool(.select)
            canvas.beginCalibration()
            canvas.handlePointerMove(press)
            #expect(canvas.loupeHost != nil)
            canvas.endCalibration()
            #expect(canvas.loupeHost == nil, "the lens outlived calibration")
        }
    }

    /// Old output: a scroll under a still pointer left the lens on the crop and coordinate of
    /// before (`shownPagePoint` unchanged).
    @Test("V-006: a scroll under a still pointer re-aims the lens at the point now under it")
    func lensFollowsAScroll() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter5 Loupe Scroll.pdf", content: "12 w 0 0 0 RG 200 1200 m 1400 1200 l S")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        await Self.settleRaster(canvas)
        harness.core.canvas.setZoom(harness.core.canvas.viewport.zoom * 4)
        canvas.refresh()
        await Self.settleRaster(canvas)
        try await Self.withLoupe(canvas) {
            harness.shell.toolbar.activateMeasurement(.length)
            canvas.refresh()
            let page = canvas.pageViewForTesting
            let transform = try #require(page.transform)
            // A point in the middle of what is on screen.
            let visible = page.visibleRect
            let start = transform.pagePoint(from: CGPoint(x: visible.midX, y: visible.midY))
            canvas.handlePointerMove(start)
            let host = try #require(canvas.loupeHost as? LoupeHostingView)
            let windowPoint = try #require(host.pointerWindowPoint)
            page.onPanBy?(CGSize(width: 60, height: 0))
            #expect(await AppTestSupport.wait(upTo: 5) {
                (canvas.loupeHost as? LoupeHostingView)?.shownPagePoint != start
            }, "the lens kept the point of before the scroll")
            let now = try #require(page.transform)
            let expected = now.pagePoint(from: page.convert(windowPoint, from: nil))
            let shown = try #require((canvas.loupeHost as? LoupeHostingView)?.shownPagePoint)
            #expect(Swift.abs(shown.x - expected.x) < 1e-6 && Swift.abs(shown.y - expected.y) < 1e-6)
        }
    }

    /// Old output: the lens was drawn before the sample's resolve started and never again, so it
    /// named no snap (`shownSnapChip.kind == nil`) while the ring sat on the corner.
    @Test("V-007: the lens names the snap that landed for the sample it shows")
    func lensChipFollowsTheLanding() async throws {
        let harness = try await Self.snappingHarness("Iter5 Loupe Chip.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.refresh()
        await Self.settleRaster(canvas)
        try await Self.withLoupe(canvas) {
            harness.shell.toolbar.activateMeasurement(.length)
            canvas.refresh()
            canvas.handlePointerMove(PDFPointValue(x: 75, y: 74))
            let host = try #require(canvas.loupeHost as? LoupeHostingView)
            #expect(await AppTestSupport.wait { harness.core.canvas.snapFeedback?.pagePoint == PDFPointValue(x: 72, y: 72) })
            canvas.refreshFromObservation()
            #expect(host.shownSnapChip == LoupeSnapChip(harness.core.canvas.snapFeedback))
            #expect(host.shownSnapChip.kind != nil, "the lens names no snap while the ring shows one")
            // Another landing with the same chip costs nothing.
            let refreshes = canvas.loupeChipRefreshCountForTesting
            canvas.refreshFromObservation()
            #expect(canvas.loupeChipRefreshCountForTesting == refreshes)
        }
    }

    /// Old output: `loupeCrop` read only the underlay, page raster and tiles, so with only the
    /// resident base (a sheet just shown) or only level tiles it returned `nil` and the lens
    /// disappeared.
    @Test("V-008: the lens crops the resident base and the level tiles too")
    func lensCropsTheBaseAndLevelTiles() throws {
        let view = Self.pageView(page: CGSize(width: 100, height: 100))
        let context = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let dark = PageRaster(image: try #require(context.makeImage()), coverage: .wholePage, scale: 1)

        view.baseRaster = dark
        let fromBase = try #require(view.loupeCrop(around: CGPoint(x: 50, y: 50), magnification: 4, diameter: 132),
                                    "the base raster alone gave no crop")
        #expect(NLMeasureLoupeTests.centreBrightness(fromBase.image) < 0.1)

        view.baseRaster = nil
        view.levelTileRasters = [dark]
        let fromLevel = try #require(view.loupeCrop(around: CGPoint(x: 50, y: 50), magnification: 4, diameter: 132),
                                     "the level tiles alone gave no crop")
        #expect(NLMeasureLoupeTests.centreBrightness(fromLevel.image) < 0.1)
    }

    // MARK: - V-009 ⇧⌥ union is decided at the click

    /// Three 3 m × 3 m rooms side by side (0–300, 300–600, 600–900 pt, 300 pt tall).
    private static let rooms = "1 w 0 0 0 RG 0 0 m 900 0 l S 900 0 m 900 300 l S 900 300 m 0 300 l S 0 300 m 0 0 l S"
        + " 300 0 m 300 300 l S 600 0 m 600 300 l S"

    private static func netArea(_ record: MarkupRecord?) -> Double {
        NSDecimalNumber(decimal: record?.measurement?[.netArea]?.value ?? 0).doubleValue
    }

    /// Room A traced (9 m²) and selected. A ⇧⌥-click on B whose ⇧ is released, and whose
    /// selection is cleared, before the trace lands still adds B: 9 + 9 = 18 m², one markup. A
    /// ⌥-click on C followed by pressing ⇧ traces C on its own: two markups, A stays 18 m².
    ///
    /// Old output: the first traced B as a second area (two markups, A 9 m²); the second added C
    /// to A (one markup, 27 m²).
    @Test("V-009: ⇧⌥ adds to the area selected at the click, whatever ⇧ does before the trace lands")
    func unionIsDecidedAtTheClick() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter5 Union.pdf", content: Self.rooms)
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        await core.refresh()
        harness.shell.toolbar.activateMeasurement(.area)
        canvas.handleClick(at: PDFPointValue(x: 150, y: 150), additive: false, optionHeld: true)
        await canvas.settleAutoTrace()
        let area = try #require(await NLMeasureFenceTraceTests.markup(core, count: 1).first)
        #expect(Swift.abs(Self.netArea(area) - 9) < 1e-9)

        core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.handleClick(at: PDFPointValue(x: 450, y: 150), additive: true, optionHeld: true)
        // ⇧ up and the selection gone before the trace lands.
        canvas.isShiftHeld = false
        core.canvas.select(markupIDs: [], additive: false)
        await canvas.settleAutoTrace()
        #expect(await Self.eventually { Self.netArea(await core.session.markup(area.id)) > 17 }, "B was not added to A")
        #expect(Swift.abs(Self.netArea(await core.session.markup(area.id)) - 18) < 1e-9)
        #expect(await core.session.orderedMarkups.count == 1)

        core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.handleClick(at: PDFPointValue(x: 750, y: 150), additive: false, optionHeld: true)
        canvas.isShiftHeld = true
        await canvas.settleAutoTrace()
        canvas.isShiftHeld = false
        let both = await NLMeasureFenceTraceTests.markup(core, count: 2)
        #expect(both.count == 2, "a ⌥-click followed by ⇧ rewrote the selected area")
        #expect(Swift.abs(Self.netArea(await core.session.markup(area.id)) - 18) < 1e-9)
        let room = try #require(both.first { $0.id != area.id })
        #expect(Swift.abs(Self.netArea(room) - 9) < 1e-9)
    }

    // MARK: - V-010 the cursor rects are rebuilt only on a real change

    @Test("V-010: re-assigning the same selection-tool flag does not rebuild the cursor rects")
    func selectionToolFlagIsGuarded() {
        let view = Self.pageView(page: CGSize(width: 100, height: 100))
        let start = view.cursorRectInvalidationCount
        view.isSelectionTool = true
        view.isSelectionTool = true
        #expect(view.cursorRectInvalidationCount == start, "an unchanged flag rebuilt the cursor rects")
        view.isSelectionTool = false
        view.isSelectionTool = false
        #expect(view.cursorRectInvalidationCount == start + 1)
    }

    // MARK: - V-011 / V-012 a dragged-away caption

    /// A length (100, 100)–(200, 100) at 200 % whose caption was dragged 60 pt up the sheet: the
    /// pill sits 120 view points above the automatic place, beyond the 80-point pad.
    ///
    /// Old output: the padded bounds (y 520…680) missed the moved pill at y 480, so a redraw of
    /// the pill's area alone culled the markup and the pill was neither drawn nor grabbable
    /// (`captionFrames` empty).
    @Test("V-011: a dragged-away caption stays inside its markup's culling bounds")
    func movedCaptionIsNotCulled() {
        let transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 2, origin: .zero
        )
        let id = UUID()
        var shape = Self.measuredLength(id: id, PDFPointValue(x: 100, y: 100), PDFPointValue(x: 200, y: 100))
        shape.captionOffset = PDFPointValue(x: 0, y: 60)
        let padded = CanvasPageView.paddedViewBounds(of: shape, transform: transform)
        let automatic = transform.viewPoint(from: PDFPointValue(x: 150, y: 100))
        #expect(padded.contains(CGPoint(x: automatic.x, y: automatic.y - 120)), "padded \(padded)")

        let view = Self.pageView(page: CGSize(width: 600, height: 400), zoom: 2)
        view.shapes = [shape]
        // Redraw only a band around the moved pill, away from the markup's own ink.
        _ = Self.render(view, rect: CGRect(x: 0, y: 440, width: 1200, height: 60))
        #expect(view.captionFrames[id] != nil, "the moved pill was culled with its markup")
    }

    /// Old output: every drag frame called `invalidatePage()` (`pageInvalidationCount` +1 per
    /// frame, the whole sheet's ink re-stroked), unchanged frames included.
    @Test("V-012: a caption drag frame repaints the pill's area, and an unchanged frame nothing")
    func captionDragRepaintsThePillOnly() throws {
        let view = Self.pageView(page: CGSize(width: 600, height: 400))
        let id = UUID()
        view.shapes = [Self.measuredLength(id: id, PDFPointValue(x: 100, y: 200), PDFPointValue(x: 300, y: 200))]
        _ = Self.render(view)
        let frame = try #require(view.captionFrames[id])
        let invalidations = view.pageInvalidationCount
        view.captionDragPreview = (id, CGSize(width: 30, height: -20))
        let dirty = try #require(view.lastCaptionDragDirtyRect)
        #expect(view.pageInvalidationCount == invalidations, "a drag frame invalidated the whole page")
        #expect(dirty.contains(frame))
        #expect(dirty.contains(frame.offsetBy(dx: 30, dy: -20)))
        #expect(dirty.width * dirty.height < view.bounds.width * view.bounds.height * 0.1)
        view.captionDragPreview = (id, CGSize(width: 30, height: -20))
        #expect(view.lastCaptionDragDirtyRect == dirty)
        #expect(view.pageInvalidationCount == invalidations)
    }

    // MARK: - V-013 a modifier costs a live-lane update

    /// Old output: `handleModifiers` ran `refresh()`: one layout (`layoutCountForTesting` +1) and
    /// one scene fetch (`sceneFetchCountForTesting` +1) per ⇧ press.
    @Test("V-013: pressing ⇧ while drawing updates the live lane, with no layout and no scene fetch")
    func modifierIsALiveLaneUpdate() async throws {
        let harness = try await Fix2Harness.make("Iter5 Modifier Cost.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 100, y: 500), additive: false)
        canvas.handlePointerMove(PDFPointValue(x: 200, y: 530))
        await harness.settle()
        let layouts = canvas.layoutCountForTesting
        let fetches = canvas.sceneFetchCountForTesting
        canvas.handleModifiers(shiftHeld: true)
        #expect(canvas.layoutCountForTesting == layouts, "a ⇧ press re-laid the page")
        #expect(canvas.sceneFetchCountForTesting == fetches, "a ⇧ press refetched the scene")
        #expect(canvas.pageViewLiveStateForTesting.drawing.caption?.contains("0.0°") == true,
                "the live lane did not take the constraint")
        canvas.handleModifiers(shiftHeld: false)
    }

    // MARK: - V-014 no context menu mid-pick

    /// Old output: `handleSecondaryClick` returned `false` during calibration and snippet capture,
    /// so the tap reselected and opened the markup or canvas menu.
    @Test("V-014: a secondary click during Calibrate or a snippet region is swallowed")
    func secondaryClickIsSwallowedMidPick() async throws {
        let harness = try await Fix2Harness.make("Iter5 Secondary.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        canvas.beginCalibration()
        #expect(canvas.handleSecondaryClick())
        canvas.endCalibration()
        canvas.beginSnippetRegion()
        #expect(canvas.handleSecondaryClick())
        canvas.endSnippetRegion()
        #expect(!canvas.handleSecondaryClick(), "Select still gets its menu")
    }

    // MARK: - V-015 committed labels do not follow the scroll

    /// A count mark at page (300, 700): its caption hangs 14 pt up and right of it, at view
    /// y ≈ 68–86. With the scroll view's top at y 80 the visible-area rule flipped the pill below
    /// the leader (y 92); at y 0 it did not.
    ///
    /// Old output: the pill's frame (and its drag hit area) moved with the scroll position of the
    /// redraw.
    @Test("V-015: a committed count caption keeps its side whatever the scroll")
    func committedCaptionIgnoresTheScroll() throws {
        let view = Self.pageView(page: CGSize(width: 600, height: 800))
        let id = UUID()
        var shape = CanvasMarkupShape(
            id: id, pageID: UUID(), color: ColorRGBA(red: 0.1, green: 0.4, blue: 1, alpha: 1),
            strokes: [], counts: [PDFPointValue(x: 300, y: 700)],
            bounds: PDFRectValue(x: 299, y: 699, width: 2, height: 2), hidden: false
        )
        shape.caption = "Count 1"
        view.shapes = [shape]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = view
        scroll.contentView.scroll(to: .zero)
        _ = Self.render(view)
        let atTop = try #require(view.captionFrames[id])
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 80))
        #expect(view.visibleRect.minY == 80, "precondition: the page view sees the scroll")
        _ = Self.render(view)
        let scrolled = try #require(view.captionFrames[id])
        #expect(scrolled == atTop, "the committed pill moved from \(atTop) to \(scrolled) with the scroll")
    }
}

private extension NSColor {
    /// The colour's relative luminance, for the keyline assertions.
    var whiteComponentOrLuminance: CGFloat {
        let rgb = usingColorSpace(.sRGB) ?? self
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
