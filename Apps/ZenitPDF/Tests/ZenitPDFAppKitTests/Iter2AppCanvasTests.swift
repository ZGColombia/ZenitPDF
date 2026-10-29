import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Iteration-2 app-canvas fixes (iteration-2 findings), against the shipping window
/// and canvas. No window is ordered front and every modal goes through `ZenitModalPresenter`.
@MainActor
@Suite(.appTierSerialised)
struct Iter2AppCanvasTests {

    private static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Helpers

    private static func keyEvent(
        _ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    /// The virtual key code and modifiers AppKit reports for each character a typed length uses.
    private static let typedKeys: [Character: (UInt16, NSEvent.ModifierFlags)] = [
        "0": (29, []), "1": (18, []), "2": (19, []), "4": (21, []), "6": (22, []),
        " ": (49, []), "/": (44, []), "<": (43, [.shift]), "'": (39, []), "\"": (39, [.shift])
    ]

    /// Types `text` and Return through the canvas's own `keyDown`, as AppKit delivers each key
    /// to the focused canvas, then releases Space if it was pressed.
    private static func type(_ text: String, into pageView: CanvasPageView) throws {
        for character in text {
            let (code, modifiers) = try #require(typedKeys[character], "no key code for \(character)")
            pageView.keyDown(with: try keyEvent(code, String(character), modifiers))
            if character == " " { pageView.keyUp(with: try keyEvent(49, " ", type: .keyUp)) }
        }
    }

    private static func near(_ point: PDFPointValue?, _ x: Double, _ y: Double) -> Bool {
        guard let point else { return false }
        return Swift.abs(point.x - x) < 1e-6 && Swift.abs(point.y - y) < 1e-6
    }

    /// The shipping window over a one-page A1 portrait sheet (1684 × 2384 pt), calibrated
    /// 100 pt = 1 m with snapping off, so a typed metre is exactly 100 page points.
    private static func a1Harness(_ name: String) async throws -> Fix2Harness {
        let fixture = try NLMeasureR2Harness.writeFixture(named: name)
        return try await Fix2Harness.make(name, fixture: fixture)
    }

    // MARK: - S-001 a space inside a typed length

    /// 100 pt = 1 m, snap off. "4 1/2<0" from (100, 300) is 4.5 m → 450 pt → (550, 300).
    /// "12'6 1/2\"<0" is 150.5 in = 3.8227 m → 382.27 pt → (932.27, 300).
    ///
    /// Old output: Space always started the temporary pan and never reached the entry, so the
    /// parser saw "41/2" = 20.5 m and placed (2150, 300); the imperial entry became 12' 30.5"
    /// = 174.5 in = 4.4323 m, 443.23 pt from the vertex before instead of 382.27.
    @Test("S-001: Space inside a typed length is part of it: 4 1/2 is 4.5 m and 12'6 1/2\" is 150.5 in")
    func spaceReachesATypedLength() async throws {
        let harness = try await Self.a1Harness("Iter2 Typed Space.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        harness.shell.perform(.measurePolylength)
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })

        // With nothing typed, Space is still the temporary pan.
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        pageView.keyDown(with: try Self.keyEvent(49, " "))
        #expect(canvas.typedEntry.isEmpty, "a Space with no entry is not typed")
        #expect(pageView.restingCursor() == .openHand, "and it still holds the pan")
        pageView.keyUp(with: try Self.keyEvent(49, " ", type: .keyUp))

        try Self.type("4", into: pageView)
        pageView.keyDown(with: try Self.keyEvent(49, " "))
        #expect(canvas.typedEntry == "4 ", "the Space went to the entry")
        #expect(pageView.restingCursor() != .openHand, "and it held no pan")
        pageView.keyUp(with: try Self.keyEvent(49, " ", type: .keyUp))
        try Self.type("1/2<0", into: pageView)
        #expect(canvas.typedEntry == "4 1/2<0")
        pageView.keyDown(with: try Self.keyEvent(36, "\r"))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        let second = core.measurement.placedPoints.last
        #expect(Self.near(second, 550, 300), "\(String(describing: second))")

        try Self.type("12'6 1/2\"<0", into: pageView)
        #expect(canvas.typedEntry == "12'6 1/2\"<0")
        pageView.keyDown(with: try Self.keyEvent(36, "\r"))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 3 })
        let third = core.measurement.placedPoints.last
        #expect(Self.near(third, 932.27, 300), "\(String(describing: third))")
        _ = canvas.handle(key: .escape)
    }

    // MARK: - S-002 the keyboard cursor leads

    /// 100 pt = 1 m, snap off. The first vertex is at (100, 300) and the pointer has left the
    /// canvas; ten Shift-arrows move the keyboard cursor to (200, 300).
    ///
    /// Old output: pressing Shift re-derived the rubber band from the mouse's last position,
    /// which was gone (`liveCursorPoint` nil, no "0.0°" in the pill); a typed "2" + Return was
    /// refused with "Move the pointer the way the segment should go…" and placed nothing.
    @Test("S-002: Shift and a typed length follow the keyboard cursor, not the absent mouse")
    func keyboardCursorLeadsShiftAndTypedLengths() async throws {
        let harness = try await Self.a1Harness("Iter2 Keyboard Lead.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        let machine = canvas.measurementInputForTesting
        harness.shell.perform(.measurePolylength)
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        canvas.handlePointerMove(nil)   // the pointer leaves the canvas

        for _ in 0..<10 { pageView.keyDown(with: try Self.keyEvent(124, "\u{F703}", [.shift])) }
        #expect(machine.state.isKeyboardCursorActive)
        #expect(Self.near(machine.cursor, 200, 300), "\(machine.cursor)")

        canvas.handleModifiers(shiftHeld: true)
        #expect(Self.near(core.measurement.liveCursorPoint, 200, 300),
                "Shift moved the rubber band off the keyboard cursor: \(String(describing: core.measurement.liveCursorPoint))")
        let caption = canvas.liveStateForTesting().drawing.caption ?? ""
        #expect(caption.contains("0.0°"), "the pill's Shift angle follows the keyboard cursor: \(caption)")
        canvas.handleModifiers(shiftHeld: false)
        #expect(Self.near(core.measurement.liveCursorPoint, 200, 300))

        try Self.type("2", into: pageView)
        pageView.keyDown(with: try Self.keyEvent(36, "\r"))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 },
                "the typed length was refused: \(core.status.snapshot.activeToolNote ?? "nil")")
        let second = core.measurement.placedPoints.last
        #expect(Self.near(second, 300, 300), "the segment goes toward the keyboard cursor: \(String(describing: second))")
        _ = canvas.handle(key: .escape)
    }

    // MARK: - S-003 smart magnify's fit is the presenter's

    /// A1 portrait (1684 × 2384 pt) turned 90° in the view stands 2384 × 1684. In a 1600 × 1000
    /// content area Fit Page is min(1600/2384, 1000/1684) = 1000/1684 = 0.593824. Cropped in the
    /// view to 1192 × 842 and still turned, it stands 842 × 1192: min(1600/842, 1000/1192) =
    /// 1000/1192 = 0.838926.
    ///
    /// Old output: smart magnify fitted the unturned, uncropped crop box into the whole view,
    /// min(1600/1684, 1000/2384) = 0.41946 in both cases — 41 % and 100 % away from the zoom Fit
    /// Page set, outside the 3 % "at fit" band — so a double-tap at fit asked for Fit Page again.
    @Test("S-003: a double-tap at fit zooms in on a sheet turned or cropped in the view")
    func smartMagnifyFitsTheTurnedAndCroppedSheet() async throws {
        let harness = try await Self.a1Harness("Iter2 Smart Magnify.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        let first = try #require(await core.session.firstPageID)

        let rotate = try #require(harness.shell.onRotatePages, "the window wires Rotate")
        rotate([first.rawValue], 90)
        #expect(await AppTestSupport.wait { core.document.pages.first?.viewRotation == 90 })
        let content = CGSize(width: 1600, height: 1000)
        #expect(await AppTestSupport.wait {
            core.canvas.viewSize = content
            return core.canvas.fitZoom.map { Swift.abs($0 - 1000.0 / 1684.0) < 1e-12 } ?? false
        }, "\(String(describing: core.canvas.fitZoom))")
        // Synchronously from here: a layout pass would put the real content size back.
        canvas.view.setFrameSize(content)
        core.canvas.viewSize = content
        core.canvas.zoomToFit()
        let turnedFit = try #require(canvas.fittedZoomForSmartMagnify())
        #expect(Swift.abs(turnedFit - 0.593824228) < 1e-9, "\(turnedFit)")
        #expect(CanvasSmartZoom.step(currentZoom: core.canvas.viewport.zoom, fitZoom: turnedFit, target: 2) == .zoomIn(to: 2))

        await harness.document.cropPage(first, to: PDFRectValue(x: 0, y: 0, width: 1192, height: 842))
        #expect(await AppTestSupport.wait {
            core.canvas.viewSize = content
            return core.canvas.fitZoom.map { Swift.abs($0 - 1000.0 / 1192.0) < 1e-12 } ?? false
        }, "\(String(describing: core.canvas.fitZoom))")
        canvas.view.setFrameSize(content)
        core.canvas.viewSize = content
        core.canvas.zoomToFit()
        let croppedFit = try #require(canvas.fittedZoomForSmartMagnify())
        #expect(Swift.abs(croppedFit - 0.838926174) < 1e-9, "\(croppedFit)")
        #expect(CanvasSmartZoom.step(currentZoom: core.canvas.viewport.zoom, fitZoom: croppedFit, target: 2) == .zoomIn(to: 2))
    }

    // MARK: - S-004 the history chords are reserved

    /// Old output: `reservedChords` held neither chord, so `assign(⌘[)` returned `true`, the
    /// override was saved, and the command never fired in a project window — the canvas takes
    /// ⌘[ and ⌘] for sheet history before the menu bar sees them.
    @Test("S-004: Customize Keyboard Shortcuts refuses ⌘[ and ⌘], naming Go Back and Go Forward")
    func shortcutSettingsRefuseTheHistoryChords() throws {
        let reserved = ZenitShortcutSettings.reservedChords
        #expect(reserved[ZPDFKeyBinding.character("[", [.command]).chord] != nil)
        #expect(reserved[ZPDFKeyBinding.character("]", [.command]).chord] != nil)
        let model = ZenitShortcutSettings.makeModel()
        defer {
            model.restoreAll()
            ZPDFCommandTable.effective = .standard
        }
        #expect(!model.assign(.character("[", [.command]), to: .toggleCoverageMap))
        #expect(model.refusal?.contains("Go Back") == true, "\(model.refusal ?? "nil")")
        #expect(!model.assign(.character("]", [.command]), to: .toggleCoverageMap))
        #expect(model.refusal?.contains("Go Forward") == true, "\(model.refusal ?? "nil")")
        #expect(ZPDFCommandTable.effective.command(.toggleCoverageMap)?.binding?.chord
                != ZPDFKeyBinding.character("[", [.command]).chord, "nothing was saved")
    }

    // MARK: - S-005 hover rejects far shapes by their ink

    private static func shape(
        strokes: [CanvasStroke], counts: [PDFPointValue] = [], textBox: PDFRectValue? = nil,
        lineWidth: Double = 1.5, rotation: Double = 0, centre: PDFPointValue? = nil
    ) -> CanvasMarkupShape {
        var shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            strokes: strokes, counts: counts,
            bounds: textBox ?? PDFRectValue(x: 0, y: 0, width: 1, height: 1), hidden: false, textBox: textBox
        )
        shape.lineWidth = lineWidth
        shape.rotationDegrees = rotation
        shape.rotationCentre = centre
        return shape
    }

    /// A real callout from the scene builder: target (40, 40), text box (200, 200)–(300, 240).
    private static func callout() throws -> CanvasMarkupShape {
        let page = PageID(UUID())
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .callout,
            caption: "Check the lintel",
            geometry: MeasurementGeometry(pageID: page, points: [
                PDFPoint(x: 40, y: 40), PDFPoint(x: 200, y: 200), PDFPoint(x: 300, y: 240)
            ]),
            createdAt: stamp, modifiedAt: stamp
        )
        return try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue).first)
    }

    /// The prefilter never refuses a point the exact rule accepts: every probe on a 1-pt grid
    /// around each shape, at a fine and a coarse zoom. The callout's leader reaches (40, 40),
    /// far outside its bounds (the text box), and it stays clickable there.
    @Test("S-005: the ink-bounds prefilter never refuses a point the exact hit test accepts")
    func inkPrefilterIsConservative() throws {
        let area = Self.shape(strokes: [
            CanvasStroke(points: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 100, y: 40),
                                  PDFPointValue(x: 40, y: 40), PDFPointValue(x: 40, y: 100), PDFPointValue(x: 0, y: 100)],
                         closed: true, filled: true),
            CanvasStroke(points: [PDFPointValue(x: 10, y: 10), PDFPointValue(x: 20, y: 10), PDFPointValue(x: 20, y: 20),
                                  PDFPointValue(x: 10, y: 20)], closed: true, filled: false)
        ])
        let fatLine = Self.shape(strokes: [CanvasStroke(points: [PDFPointValue(x: 0, y: 50), PDFPointValue(x: 100, y: 50)],
                                                        closed: false, filled: false)], lineWidth: 9)
        let count = Self.shape(strokes: [], counts: [PDFPointValue(x: 50, y: 50), PDFPointValue(x: 70, y: 60)])
        let turnedText = Self.shape(strokes: [], textBox: PDFRectValue(x: 20, y: 40, width: 60, height: 20),
                                    rotation: 30, centre: PDFPointValue(x: 50, y: 50))
        let callout = try Self.callout()
        #expect(!callout.bounds.contains(PDFPointValue(x: 41, y: 41)), "the leader's end is outside the callout's bounds")

        for (name, shape) in [("area", area), ("fat line", fatLine), ("count", count), ("turned text", turnedText), ("callout", callout)] {
            let ink = CanvasHitTesting.inkBounds(of: shape)
            #expect(ink != nil, "\(name) has ink")
            for (tolerance, zoom) in [(1.5, 4.0), (24.0, 0.25)] {
                var hits = 0
                var refused: [String] = []
                var y = -60.0
                while y <= 360 {
                    var x = -60.0
                    while x <= 360 {
                        let point = PDFPointValue(x: x, y: y)
                        if CanvasHitTesting.shape(shape, contains: point, tolerance: tolerance, zoom: zoom) {
                            hits += 1
                            if !CanvasHitTesting.mayContain(shape, inkBounds: ink, point: point, tolerance: tolerance, zoom: zoom) {
                                refused.append("\(x),\(y)")
                            }
                        }
                        x += 1
                    }
                    y += 1
                }
                #expect(hits > 0, "\(name) is hit somewhere")
                #expect(refused.isEmpty, "\(name) (tolerance \(tolerance), zoom \(zoom)): the prefilter refused \(refused.prefix(5))")
            }
        }
        #expect(CanvasHitTesting.shape(callout, contains: PDFPointValue(x: 41, y: 41), tolerance: 1.5, zoom: 4))
        #expect(CanvasHitTesting.mayContain(callout, inkBounds: CanvasHitTesting.inkBounds(of: callout),
                                            point: PDFPointValue(x: 41, y: 41), tolerance: 1.5, zoom: 4))
        // A shape with no ink cannot be hit, and the prefilter says so.
        #expect(!CanvasHitTesting.mayContain(Self.shape(strokes: []), inkBounds: nil, point: .init(x: 0, y: 0), tolerance: 100))
    }

    /// 2 000 filled 20 × 20 pt areas on a 40-pt grid. Old output: every hover ran the exact test
    /// on all 2 000 (`exactHitTestsInLastPass` would have been 2 000 on empty paper); now none on
    /// empty paper and one over an area.
    @Test("S-005: a hover over empty paper exact-tests no shape; over an area, only that one")
    func hoverExactTestsOnlyNearbyShapes() async throws {
        let harness = try await Self.a1Harness("Iter2 Hover.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let pageView = canvas.pageViewForTesting
        harness.core.canvas.setZoom(1)   // 6 view points = 6 page points of tolerance
        var shapes: [CanvasMarkupShape] = []
        for row in 0..<40 {
            for column in 0..<50 {
                let x = Double(column) * 40, y = Double(row) * 40
                shapes.append(Self.shape(strokes: [CanvasStroke(points: [
                    PDFPointValue(x: x, y: y), PDFPointValue(x: x + 20, y: y),
                    PDFPointValue(x: x + 20, y: y + 20), PDFPointValue(x: x, y: y + 20)
                ], closed: true, filled: true)]))
            }
        }
        pageView.shapes = shapes
        #expect(canvas.hitTest(PDFPointValue(x: 30, y: 30)) == nil, "the gap between areas is empty paper")
        #expect(canvas.exactHitTestsInLastPass == 0)
        let inside = shapes[1 * 50 + 2]   // row 1, column 2: (80, 40)–(100, 60)
        #expect(canvas.hitTest(PDFPointValue(x: 90, y: 50)) == inside.id)
        #expect(canvas.exactHitTestsInLastPass == 1)

        // A measurement, printed: 500 hovers over empty paper, exact-all against prefiltered.
        let probes = (0..<500).map { PDFPointValue(x: 30 + Double($0 % 50) * 40, y: 30 + Double($0 / 50) * 40) }
        let tolerance = harness.core.canvas.viewport.pageDistance(forViewPoints: 6)
        let clock = ContinuousClock()
        let exactAll = clock.measure {
            for probe in probes {
                _ = shapes.contains { CanvasHitTesting.shape($0, contains: probe, tolerance: tolerance) }
            }
        }
        let prefiltered = clock.measure {
            for probe in probes { _ = canvas.hitTest(probe) }
        }
        print("S-005 measurement: 500 hovers × 2000 areas — exact test on every shape \(exactAll), with the ink prefilter \(prefiltered)")
        // U-005 (iteration 4): the print is a check. Measured 1.488 s against 0.137 s (debug,
        // 2026-09-27), a factor of 10.8; the prefilter must at least halve the exact-all cost,
        // a ratio both sides of which one machine's load moves together.
        #expect(prefiltered * 2 < exactAll, "the ink prefilter no longer pays: \(prefiltered) against \(exactAll)")
    }

    // MARK: - S-006 segment labels are formatted only on a cache miss

    /// Old output: `build` formatted every segment label before the cache lookup, so the second
    /// pass over an unchanged record called the formatter twice more (4 calls, not 2).
    @Test("S-006: an unchanged record's segment labels are not reformatted on a cache hit")
    func segmentLabelsFormatOnlyOnAMiss() async throws {
        let page = PageID(UUID())
        var style = MarkupStyle()
        style.measurementCaption = MeasurementCaption(showsSegmentLengths: true)
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .polylength,
            style: style,
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 200)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        final class Counter { var calls = 0 }
        let counter = Counter()
        func labelling(_ token: AnyHashable?, prefix: String) -> CanvasSegmentLabelling {
            CanvasSegmentLabelling(metresPerPoint: (0.01, 0.01), formatToken: token) { metres in
                counter.calls += 1
                return "\(prefix)\(metres)"
            }
        }
        let cache = CanvasShapeCache()
        let metres = labelling("m|2", prefix: "")
        // 100 pt and 200 pt at 0.01 m/pt: 1 m and 2 m.
        func values(_ shapes: [CanvasMarkupShape], prefix: String) -> Bool {
            let texts = shapes.first?.segmentLabels.map(\.text) ?? []
            let numbers = texts.compactMap { $0.hasPrefix(prefix) ? Double($0.dropFirst(prefix.count)) : nil }
            return numbers.count == 2 && Swift.abs(numbers[0] - 1) < 1e-9 && Swift.abs(numbers[1] - 2) < 1e-9
        }
        let first = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue, cache: cache, segmentLabelling: metres)
        #expect(values(first, prefix: ""))
        #expect(counter.calls == 2)
        let second = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue, cache: cache, segmentLabelling: metres)
        #expect(counter.calls == 2, "a hit formatted \(counter.calls - 2) labels")
        #expect(values(second, prefix: ""))
        #expect(cache.compileCount == 1)

        // Another unit is another token: the record recompiles with the new texts.
        let millimetres = labelling("mm|0", prefix: "mm ")
        let third = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue, cache: cache, segmentLabelling: millimetres)
        #expect(values(third, prefix: "mm "))
        #expect(cache.compileCount == 2)

        // A formatter with no identity still labels correctly, keyed on its texts.
        let anonymous = labelling(nil, prefix: "x ")
        let fourth = CanvasSceneBuilder.build(records: [record], summaries: [], pageID: page.rawValue, cache: cache, segmentLabelling: anonymous)
        #expect(values(fourth, prefix: "x "))

        // The shipping labelling names its formatter.
        let harness = try await Self.a1Harness("Iter2 Segment Token.pdf")
        defer { harness.tearDown() }
        let pageID = try #require(await harness.core.session.firstPageID)
        #expect(CanvasSegmentLabelling.make(snapshot: harness.core.snapshot, page: pageID.rawValue).formatToken != nil)
    }

    // MARK: - S-007 Curve an Edge judges the edge click at its own zoom

    /// 100 pt = 1 m, snap off. The 1000 × 500 pt bay's right side is x = 1100. Curving it
    /// through (1350, 350) makes the semicircle: area 50 + 3.125π m².
    ///
    /// Old output: the tolerance was converted when the pick was armed. Armed at 25 % (32 pt)
    /// and clicked at 400 %, a click 10 pt (40 screen points) off the edge curved it; armed at
    /// 400 % (2 pt) and clicked at 25 %, a click 20 pt (5 screen points) off it was refused.
    @Test("S-007: zooming between Curve an Edge and the edge click judges the click at the click's zoom")
    func curveEdgeJudgesTheClickAtItsZoom() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter2 Arc Zoom.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        let bay = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Bay", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 1100, y: 100), PDFPoint(x: 1100, y: 600), PDFPoint(x: 100, y: 600)
            ]))]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        try await core.commands.perform(.addMarkup(bay))
        await core.refresh()
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        func area() async -> Double {
            NSDecimalNumber(decimal: await core.session.markup(bay.id)?.measurement?[.netArea]?.value ?? 0).doubleValue
        }

        // Armed at 25 %, clicked at 400 %: 10 pt off is 40 screen points — refused.
        core.canvas.select(markupIDs: [bay.id.rawValue], additive: false)
        core.canvas.setZoom(0.25)
        harness.controller.beginCurveEdge(for: harness.document)
        #expect(CurveEdgePick.isArmed(harness.document))
        core.canvas.setZoom(4)
        canvas.handleClick(at: PDFPointValue(x: 1110, y: 350), additive: false)
        #expect(Swift.abs((CurveEdgePick.armedTolerance(harness.document) ?? 0) - 8.0 / core.canvas.viewport.zoom) < 1e-9)
        canvas.handleClick(at: PDFPointValue(x: 1350, y: 350), additive: false)
        await canvas.settleCalibrationPlacements()
        #expect(await AppTestSupport.wait {
            core.status.snapshot.activeToolNote?.contains("No edge of the selected polylength or area there") == true
        }, "\(core.status.snapshot.activeToolNote ?? "nil")")
        let untouched = await area()
        #expect(Swift.abs(untouched - 50) <= 50 * 1e-12, "a click 40 screen points off the edge curved it: \(untouched)")

        // Armed at 400 %, clicked at 25 %: 20 pt off is 5 screen points — curved.
        core.canvas.select(markupIDs: [bay.id.rawValue], additive: false)
        core.canvas.setZoom(4)
        harness.controller.beginCurveEdge(for: harness.document)
        core.canvas.setZoom(0.25)
        canvas.handleClick(at: PDFPointValue(x: 1120, y: 350), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 1350, y: 350), additive: false)
        await canvas.settleCalibrationPlacements()
        let expected = 50 + 3.125 * Double.pi
        var curved = 0.0
        for _ in 0..<150 {
            curved = await area()
            if curved > 51 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Swift.abs(curved - expected) <= expected * 1e-12,
                "a click 5 screen points off the edge was refused: \(curved), \(core.status.snapshot.activeToolNote ?? "nil")")
    }

    // MARK: - L-04 the window's accessibility tree

    /// Every element an accessibility client can reach from `element`, depth first, with its
    /// role and label — the in-process view of the tree VoiceOver and automation walk.
    private static func accessibilityTree(from element: Any) -> [(role: String, label: String)] {
        var seen: [(role: String, label: String)] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ element: Any, depth: Int) {
            guard depth < 80, let object = element as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted,
                  let ax = object as? NSAccessibilityProtocol else { return }
            let role = ax.accessibilityRole()?.rawValue ?? ""
            let label = ax.accessibilityLabel() ?? ax.accessibilityTitle() ?? ""
            seen.append((role, label))
            for child in ax.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return seen
    }

    /// L-04 (LT3-09's symptom): the live automation client found no element at all in the
    /// window. In process, with the shipping window built headless, the window reaches its whole
    /// AppKit tier, every region labelled: the top band as a toolbar, the Navigator, Inspector,
    /// canvas bar and status strip, the tool chips by name, and the canvas as
    /// "Drawing, page 1". The SwiftUI content inside each hosting view is built only for a
    /// connected assistive client — a bare SwiftUI button in a plain window reports no children
    /// headless either — so this suite asserts the tier a client must pass through. The
    /// cross-process view was observed on the installed build (iteration-2 re-check): the
    /// window, reached from outside the process, has 144 elements with the SwiftUI content in
    /// them, and the live "0 elements" was the system's AXWindows list leaving out a window on
    /// another Space, as it does for every application's off-Space windows.
    @Test("L-04: the project window exposes its top band, panels and canvas to accessibility clients")
    func windowExposesAccessibilityElements() async throws {
        let harness = try await Self.a1Harness("Iter2 Accessibility.pdf")
        defer { harness.tearDown() }
        let window = try #require(harness.controller.window)
        // No panel forcing: Fix2Harness opens every window at the first-launch layout
        // (`forgetStoredWindowLayouts`), whatever an earlier suite stored.
        window.contentView?.layoutSubtreeIfNeeded()
        let tree = Self.accessibilityTree(from: window)
        func has(_ role: NSAccessibility.Role, _ label: String) -> Bool {
            tree.contains { $0.role == role.rawValue && $0.label == label }
        }
        #expect(tree.first?.role == NSAccessibility.Role.window.rawValue && tree.first?.label.hasPrefix("Iter2 Accessibility") == true,
                "the window itself, named for its document: \(String(describing: tree.first))")
        #expect(has(.toolbar, "Toolbar"), "the top band")
        for region in ["Open documents", "Navigator", "Inspector", "Canvas controls", "Canvas status"] {
            #expect(has(.group, region), "the \(region) region is reachable and labelled")
        }
        for tool in ["Select", "Length", "Area"] {
            #expect(has(.group, tool), "the \(tool) chip is reachable and labelled")
        }
        #expect(has(.layoutArea, "Drawing, page 1"), "the canvas is reachable and labelled")
        #expect(tree.count >= 40, "\(tree.count) elements")
    }
}
