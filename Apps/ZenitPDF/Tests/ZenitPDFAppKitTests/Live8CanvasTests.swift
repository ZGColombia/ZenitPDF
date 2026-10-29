import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement
@testable import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Canvas regressions (l8-canvas): L-36, L-36b, L-37, L-49, L-68, L-71, L-76, L-77, L-101,
/// L-103, L-105. Every test drives the shipping window, canvas and command bus — the window is
/// never ordered on screen, and the one dialogue (Edit Link) is answered by injection. Each test
/// states what the old code produced.
@MainActor
@Suite("Canvas fixes", .appTierSerialised, .serialized)
struct Live8CanvasTests {

    // MARK: - Helpers

    /// A synthetic press or release at a point in a view's own coordinates.
    private static func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    /// One click on the page view at a page point, press and release, with the click count the
    /// system would have given it.
    private static func click(
        _ harness: Fix2Harness, at point: PDFPointValue, clickCount: Int = 1
    ) throws {
        let page = harness.canvas.pageViewForTesting
        let transform = try #require(page.transform)
        let local = transform.viewPoint(from: point)
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local, clickCount: clickCount))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: local, clickCount: clickCount))
    }

    private static func eventually(
        upTo seconds: Double = 5, _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private static func rectangle(
        _ harness: Fix2Harness, from a: (Double, Double), to b: (Double, Double)
    ) async throws -> MarkupRecord {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        let record = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: a.0, y: a.1), PDFPoint(x: b.0, y: a.1), PDFPoint(x: b.0, y: b.1), PDFPoint(x: a.0, y: b.1)],
                isClosed: true
            ))]),
            createdAt: Date(),
            modifiedAt: Date()
        )
        _ = try await harness.core.commands.perform(.addMarkup(record))
        await harness.settle()
        return record
    }

    // MARK: - L-103: the options-bar field takes the keyboard

    /// Old output: the field was a SwiftUI text field 56 pt wide and one text line tall inside a
    /// 24 pt box; the press 3 pt in from the box's leading edge (on the "Slope" label) landed in
    /// SwiftUI's hosting view, which takes no first responder, so the canvas kept the keyboard and
    /// `layout.measurementParameterBox` did not exist.
    @Test("L-103: one press anywhere in the options-bar value box puts the keyboard in the field, and it stays")
    func parameterBoxTakesTheKeyboardOnOnePress() async throws {
        let harness = try await Fix2Harness.make("L103 Focus.pdf")
        defer { harness.tearDown() }
        harness.shell.toolbar.activateMeasurement(.slope)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .slope })
        let window = try #require(harness.controller.window)
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        #expect(layout.isToolOptionsBarVisible, "Slope asks for a value")
        window.contentView?.layoutSubtreeIfNeeded()
        let box = try #require(layout.measurementParameterBox)
        #expect(box.bounds.height >= 24, "the whole drawn box is the control: \(box.bounds)")
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))

        // A press on the label's side of the box, outside the editable text.
        let local = NSPoint(x: 3, y: box.bounds.midY)
        #expect(!box.field.frame.contains(box.convert(local, to: box.field.superview)))
        let windowPoint = box.convert(local, to: nil)
        let frameView = try #require(window.contentView?.superview)
        let hit = try #require(frameView.hitTest(windowPoint))
        #expect(hit === box, "the window's hit test sends the press to the box, not to \(type(of: hit))")
        hit.mouseDown(with: try Self.mouse(.leftMouseDown, at: local, in: box))
        let editor = try #require(window.firstResponder as? NSTextView, "first responder: \(String(describing: window.firstResponder))")
        #expect(editor.delegate === box.field)

        // It keeps it: the canvas refreshing and the strip re-laying out leave the field typing.
        harness.canvas.refresh()
        layout.updateToolOptionsBar()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === editor)
        editor.insertText("20", replacementRange: editor.selectedRange())
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterText == "20" })
        #expect(harness.core.measurement.activeKind == .slope)
        #expect(harness.core.measurement.missingParameterNote == nil)
        // The note leaving the strip re-lays it out; the field keeps typing.
        try? await Task.sleep(nanoseconds: 100_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === editor)
        #expect(layout.measurementParameterBox === box, "the strip kept its field")
    }

    /// Old output: `handleKey("2", …)` armed the Tool Library preset in slot 2 (Interior Wall):
    /// the armed tool became that preset's Wall Area and the slope stayed empty, so the next
    /// clicks recorded a wall area.
    @Test("L-103: a number typed at the canvas while the tool asks for a value goes into the value, never arms a preset")
    func digitsAtTheCanvasGoIntoTheAskedValue() async throws {
        let harness = try await Fix2Harness.make("L103 Digits.pdf")
        defer { harness.tearDown() }
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        try #require(layout.toolSlotRouter.preset(inSlot: 2) != nil, "slot 2 holds a preset to arm")
        harness.shell.toolbar.activateMeasurement(.slope)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .slope })
        let window = try #require(harness.controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))
        let presetBefore = harness.shell.toolLibrary.activePresetID

        // The canvas holds the keyboard, nothing is drawn: the window's key rule is asked.
        let focus = layout.currentToolSlotFocus()
        #expect(focus == .canvas)
        #expect(layout.toolSlotRouter.handleKey(characters: "2", modifiers: [], focus: focus), "the key was spent")
        #expect(harness.shell.toolLibrary.activePresetID == presetBefore, "no preset was armed")
        #expect(harness.core.measurement.activeKind == .slope)
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterText == "2" })

        // The field holds the keyboard now, so the next digit is the field's own.
        let box = try #require(layout.measurementParameterBox)
        #expect(box.isEditing)
        #expect(layout.currentToolSlotFocus().isEditingText)
        let zero = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29
        ))
        window.sendEvent(zero)
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterText == "20" })
        #expect(harness.shell.toolLibrary.activePresetID == presetBefore)

        // Without a question, a digit is the slot again.
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { harness.core.measurement.activeKind == .length })
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))
        #expect(!layout.typeIntoParameterField(characters: "2", modifiers: []))
    }

    /// Re-fix (l8-canvasr). Old output: the first fix took a digit whenever the armed tool *had* a
    /// value field (`requiredParameter != nil`), and every one of the first four Tool Library
    /// slots arms such a tool with its saved value in the field. With Exterior Wall armed by `1`,
    /// `handleKey("2", …)` focused the field and typed into it: Exterior Wall stayed armed,
    /// `parameterText` became "2" (a 2 m wall height on the 2.7 m preset), Interior Wall was
    /// never armed — the next clicks recorded wrong wall areas with only the field's number
    /// changing. A filled field is not a question, so the digit is the slot.
    @Test("L-103: over a preset whose value is filled, a number key arms its slot and leaves the armed preset's value alone")
    func digitOverAFilledPresetValueArmsTheSlot() async throws {
        let harness = try await Fix2Harness.make("L103 Slots.pdf")
        defer { harness.tearDown() }
        let layout = try #require(harness.controller.layoutController(for: harness.document))
        let exterior = try #require(layout.toolSlotRouter.preset(inSlot: 1))
        let interior = try #require(layout.toolSlotRouter.preset(inSlot: 2))
        #expect(exterior.measurementKind == .wallArea && interior.measurementKind == .wallArea,
                "slots 1 and 2 are the shipped Exterior and Interior Wall: \(exterior.name), \(interior.name)")
        let exteriorHeight = try #require(exterior.defaultHeight)
        let interiorHeight = try #require(interior.defaultHeight)
        #expect(exteriorHeight != interiorHeight, "the two presets differ only by their height")
        let window = try #require(harness.controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        // `1` at the canvas, nothing armed: Exterior Wall with its 2.7 m in the field.
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))
        #expect(layout.toolSlotRouter.handleKey(characters: "1", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(await AppTestSupport.wait {
            harness.shell.toolLibrary.activePresetID == exterior.id && harness.core.measurement.activeKind == .wallArea
        })
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterValue == Decimal(string: "2.7") })
        #expect(!harness.core.measurement.isMissingRequiredParameter, "the preset filled the height")
        let exteriorText = harness.core.measurement.parameterText
        harness.canvas.refresh()
        window.contentView?.layoutSubtreeIfNeeded()

        // `2` at the canvas over the filled height: the slot, not the field.
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))
        let focus = layout.currentToolSlotFocus()
        #expect(focus == .canvas)
        #expect(!layout.typeIntoParameterField(characters: "2", modifiers: []), "a filled value is not asked for")
        #expect(layout.toolSlotRouter.handleKey(characters: "2", modifiers: [], focus: focus), "the key armed slot 2")
        #expect(await AppTestSupport.wait { harness.shell.toolLibrary.activePresetID == interior.id },
                "Interior Wall armed; active preset: \(String(describing: harness.shell.toolLibrary.activePresetID))")
        #expect(harness.core.measurement.activeKind == .wallArea)
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterValue == Decimal(string: "2.4") },
                "Interior Wall's own height; field reads \(harness.core.measurement.parameterText)")
        #expect(harness.core.measurement.parameterText != "2", "the digit was not typed into the height")
        #expect(layout.measurementParameterBox?.isEditing != true, "the field did not take the keyboard")
        #expect(window.firstResponder === harness.canvas.pageViewForTesting, "the canvas keeps the keyboard")

        // Exterior Wall's saved height was not rewritten: in the library, and when armed again.
        let storedExterior = harness.shell.toolLibrary.presets.first { $0.id == exterior.id }
        #expect(storedExterior?.defaultHeight == exteriorHeight)
        #expect(harness.shell.toolLibrary.presets.first { $0.id == interior.id }?.defaultHeight == interiorHeight)
        #expect(layout.toolSlotRouter.handleKey(characters: "1", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(await AppTestSupport.wait { harness.shell.toolLibrary.activePresetID == exterior.id })
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterValue == Decimal(string: "2.7") })
        #expect(harness.core.measurement.parameterText == exteriorText)

        // The field emptied: the height is asked for again, so a digit goes into it, no slot.
        harness.core.measurement.setParameterText("")
        #expect(harness.core.measurement.isMissingRequiredParameter)
        harness.canvas.refresh()
        layout.updateToolOptionsBar()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(harness.canvas.pageViewForTesting))
        #expect(layout.toolSlotRouter.handleKey(characters: "3", modifiers: [], focus: layout.currentToolSlotFocus()))
        #expect(harness.shell.toolLibrary.activePresetID == exterior.id, "slot 3 (Slab) was not armed")
        #expect(await AppTestSupport.wait { harness.core.measurement.parameterText == "3" })
        #expect(harness.core.measurement.activeKind == .wallArea)
    }

    // MARK: - L-36, L-36b, L-105: no click is dropped

    @Test("L-36: a double-click is two presses on the canvas, close together, inside the interval")
    func doubleClickRule() {
        let previous: (timestamp: TimeInterval, windowLocation: CGPoint) = (10, CGPoint(x: 100, y: 100))
        typealias V = CanvasPageView
        #expect(V.isDoubleClick(clickCount: 2, timestamp: 10.2, windowLocation: CGPoint(x: 102, y: 101), previous: previous, interval: 0.5))
        // Far from the first press: two clicks, whatever the system counted.
        #expect(!V.isDoubleClick(clickCount: 2, timestamp: 10.2, windowLocation: CGPoint(x: 400, y: 100), previous: previous, interval: 0.5))
        // The first press was not on the canvas (the toolbar button that armed the tool).
        #expect(!V.isDoubleClick(clickCount: 2, timestamp: 10.2, windowLocation: CGPoint(x: 100, y: 100), previous: nil, interval: 0.5))
        // The canvas's last press was long ago; the system's pair began elsewhere.
        #expect(!V.isDoubleClick(clickCount: 2, timestamp: 12, windowLocation: CGPoint(x: 100, y: 100), previous: previous, interval: 0.5))
        #expect(!V.isDoubleClick(clickCount: 1, timestamp: 10.2, windowLocation: CGPoint(x: 100, y: 100), previous: previous, interval: 0.5))
    }

    /// Old output: the second press arrived as `clickCount == 2`, went to the double-click path,
    /// which means nothing to a calibration pick, and was dropped: `collected` stayed `nil`.
    @Test("L-36: a pick's second point clicked within the double-click interval of the first is placed")
    func quickSecondPickPointIsPlaced() async throws {
        let harness = try await Fix2Harness.make("L36 Pick.pdf")
        defer { harness.tearDown() }
        var collected: [PDFPointValue]?
        harness.canvas.onCalibrationClick = nil
        harness.canvas.onCalibrationPointsCollected = { collected = $0 }
        harness.canvas.beginCalibration()
        harness.canvas.refresh()
        try Self.click(harness, at: PDFPointValue(x: 100, y: 300))
        try Self.click(harness, at: PDFPointValue(x: 400, y: 300), clickCount: 2)
        await harness.canvas.settleCalibrationPlacements()
        let points = try #require(collected, "the second point was dropped")
        #expect(points.count == 2)
        #expect(abs(points[1].x - 400) < 0.5 && abs(points[1].y - 300) < 0.5)
    }

    /// Old output: the first canvas press after the toolbar button came as `clickCount == 2`, so
    /// it went to the double-click path and Length had no point: `placedPoints` was empty.
    @Test("L-36b: the first click right after arming Length on the toolbar places the first point")
    func firstClickAfterArmingIsPlaced() async throws {
        let harness = try await Fix2Harness.make("L36b Arm.pdf")
        defer { harness.tearDown() }
        // The toolbar button is the first press of the system's pair; no refresh, no wait.
        harness.shell.toolbar.activateMeasurement(.length)
        try Self.click(harness, at: PDFPointValue(x: 120, y: 300), clickCount: 2)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 1)
    }

    /// Old output: the canvas heard the Zoom tool through an observation hop that had not run, so
    /// the press was routed by Select's flags and the zoom did not change.
    @Test("L-36b: a press right after arming a tool on the toolbar is routed by that tool")
    func pressRightAfterArmingUsesTheArmedTool() async throws {
        let harness = try await Fix2Harness.make("L36b Zoom.pdf")
        defer { harness.tearDown() }
        // A settled page at a known zoom, so the step is measured from where it starts.
        harness.core.canvas.setZoom(0.5)
        harness.canvas.refresh()
        await harness.settle()
        let before = harness.core.canvas.viewport.zoom
        try #require(abs(before - 0.5) < 1e-9)
        harness.shell.perform(.zoomTool)
        let modeBefore = harness.canvas.pageViewForTesting.isZoomTool
        try Self.click(harness, at: PDFPointValue(x: 200, y: 300))
        #expect(await AppTestSupport.wait { abs(harness.core.canvas.viewport.zoom - before * 1.6) < 1e-6 },
                "zoom \(before) -> \(harness.core.canvas.viewport.zoom); zoom tool before the press \(modeBefore), now \(harness.canvas.pageViewForTesting.isZoomTool); armed \(harness.canvas.armedMode); toolbar \(harness.shell.toolbar.activeSelection.mode)")
    }

    /// Old output: the first press inside the area after picking Cutout went to the double-click
    /// path, so the cutout had no first point (`placedPoints` empty) — the "0.04 m² shape" start.
    /// Then, over the empty re-armed tool, a double-click reached Finish and the status line said
    /// "Polygon Cutout needs 3 more points before it can be finished."
    @Test("L-105: the first cutout point after arming is placed, and a double-click over an empty tool says nothing")
    func cutoutFirstPointAndEmptyDoubleClick() async throws {
        let harness = try await Fix2Harness.make("L105 Cutout.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .area) { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 500, y: 100), PDFPoint(x: 500, y: 600), PDFPoint(x: 100, y: 600)
            ]))])
        }
        harness.shell.perform(.cutoutTool)
        try Self.click(harness, at: PDFPointValue(x: 200, y: 200), clickCount: 2)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.activeKind == .polygonCutout)
        #expect(harness.core.measurement.placedPoints.count == 1)

        harness.core.measurement.cancelActiveMeasurement()
        harness.canvas.refresh()
        #expect(harness.core.measurement.placedPoints.isEmpty)
        var commands: [ZPDFCommandID] = []
        harness.canvas.onShellCommand = { commands.append($0) }
        let noteBefore = harness.core.status.snapshot.activeToolNote
        harness.canvas.handleDoubleClick(at: PDFPointValue(x: 300, y: 300))
        await harness.core.measurement.settlePlacements()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(commands.isEmpty, "old: [finishGeometry]")
        #expect(harness.core.status.snapshot.activeToolNote == noteBefore)
        #expect(harness.core.measurement.placedPoints.isEmpty)

        // The live sequence: four corners, then a double-click on the first corner closes the
        // cutout. One cutout lands, Reuse re-arms an empty tool, and nothing asks for points.
        harness.canvas.onShellCommand = { [shell = harness.shell] in shell.perform($0) }
        for corner in [PDFPointValue(x: 200, y: 200), PDFPointValue(x: 300, y: 200), PDFPointValue(x: 300, y: 300), PDFPointValue(x: 200, y: 300)] {
            try Self.click(harness, at: corner)
            await harness.core.measurement.settlePlacements()
        }
        #expect(harness.core.measurement.placedPoints.count == 4)
        try Self.click(harness, at: PDFPointValue(x: 200, y: 200))
        try Self.click(harness, at: PDFPointValue(x: 200, y: 200), clickCount: 2)
        await harness.core.measurement.settlePlacements()
        #expect(await Self.eventually {
            await harness.records().contains { $0.tool == .polygonCutout }
        }, "the cutout was committed")
        try? await Task.sleep(nanoseconds: 200_000_000)
        await harness.core.measurement.settlePlacements()
        #expect(await harness.records().filter { $0.tool == .polygonCutout }.count == 1)
        #expect(harness.core.measurement.activeKind == .polygonCutout, "Reuse Tool keeps the cutout armed")
        #expect(harness.core.measurement.placedPoints.isEmpty, "the re-armed cutout holds \(harness.core.measurement.placedPoints)")
        #expect(!(harness.core.status.snapshot.activeToolNote ?? "").contains("more point"),
                "status: \(harness.core.status.snapshot.activeToolNote ?? "")")
    }

    /// Old output: the corner target was the pop-up button's own 10 × 12 pt (the frame and
    /// padding on the menu's label were dropped), so a press beside the 6 pt mark armed the
    /// chip's last-used count.
    @Test("L-105: the Count chip's list target is the full 16 pt corner, not the mark's 10 × 12 pt")
    func countPaletteTargetIsFullSize() async throws {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = NSToolbar(identifier: "l8-count-corner")
        for identifier in [NSToolbarItem.Identifier.zenitCount, .zenitMeasure] {
            let item = try #require(builder.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
            let view = try #require(item.view)
            view.frame = NSRect(x: 0, y: 0, width: 120, height: 52)
            for _ in 0..<4 {
                view.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            let button = try #require(Self.popUpButtons(in: view).first)
            let frame = button.convert(button.bounds, to: view)
            #expect(frame.width >= 16 && frame.height >= 16, "\(identifier.rawValue): target \(frame.size)")
            #expect(button.image?.accessibilityDescription?.hasPrefix("Open the list of") == true)
        }
    }

    private static func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        if let button = view as? NSPopUpButton { found.append(button) }
        for sub in view.subviews { found += popUpButtons(in: sub) }
        return found
    }

    // MARK: - L-37: Calibrate ▸ Separate X / Y

    /// Old output: all four missing inputs were listed at once (the third and fourth under the
    /// footer), and the X value was labelled "Scale" beside "Y scale".
    @Test("L-37: the sheet lists the next missing input only, and labels the X result \"X scale\"")
    func separateXYSheetWording() {
        let issues: [CalibrationIssue] = [.missingPrimaryPoints, .missingSecondaryPoints, .missingPrimaryLength, .missingSecondaryLength]
        #expect(CalibrationSheet.displayedIssues(issues) == [.missingPrimaryPoints])
        // A real problem is never folded away.
        #expect(CalibrationSheet.displayedIssues([.identicalPrimaryPoints, .missingSecondaryPoints, .missingSecondaryLength, .extremeScale])
                == [.identicalPrimaryPoints, .missingSecondaryPoints, .extremeScale])
        let separate = CalibrationPreview(sx: 0.01, sy: 0.02, isUniform: false, ratioString: "1:49.5", secondaryRatioString: "1:50.6")
        #expect(CalibrationSheet.primaryReadoutLabel(separate) == "X scale")
        let uniform = CalibrationPreview(sx: 0.01, sy: 0.01, isUniform: true, ratioString: "1:50", secondaryRatioString: nil)
        #expect(CalibrationSheet.primaryReadoutLabel(uniform) == "Scale")
    }

    // MARK: - L-49: text readable at the zoom it was typed at

    /// Old output: the committed text kept the tool's 11 pt in page points — 1.1 pt on screen at
    /// 10 %, a speck. Hand-derived: 11 pt ÷ 0.1 = 110 pt on the page, 11 pt on screen.
    @Test("L-49: a text box typed at 10 % is stored at the tool's size divided by the zoom")
    func textTypedZoomedOutIsReadable() async throws {
        let harness = try await Fix2Harness.make("L49 Text.pdf")
        defer { harness.tearDown() }
        harness.core.canvas.setZoom(0.1)
        harness.canvas.refresh()
        let zoom = try #require(harness.canvas.pageViewForTesting.transform?.zoom)
        #expect(abs(Double(zoom) - 0.1) < 1e-9)
        harness.shell.perform(.textTool)
        harness.canvas.refresh()
        let toolSize = harness.shell.toolbar.activeSelection.style.fontSize
        try #require(toolSize > 0)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 400), additive: false)
        let entry = try #require(harness.canvas.activeTextEntry)
        #expect(abs(entry.textScale - 10) < 1e-9)
        harness.canvas.typeIntoTextEntry("Check the slab edge")
        harness.canvas.commitTextEntry()
        #expect(await Self.eventually { await harness.records().contains { $0.kind == .text } })
        let record = try #require(await harness.records().first { $0.kind == .text })
        #expect(abs(record.style.fontSize - toolSize / 0.1) < 1e-9, "stored \(record.style.fontSize)")
        #expect(record.style.fontSize * 0.1 >= toolSize - 1e-9, "on screen at the zoom it was typed at")
        // The tool is back on its own size, so a box at 100 % is not scaled.
        #expect(harness.core.markup.style.fontSize == toolSize || harness.core.markup.activeKind == nil)

        harness.core.canvas.setZoom(1)
        harness.canvas.refresh()
        harness.shell.perform(.textTool)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 200), additive: false)
        #expect(harness.canvas.activeTextEntry?.textScale == 1)
        harness.canvas.typeIntoTextEntry("Full size")
        harness.canvas.commitTextEntry()
        #expect(await Self.eventually { await harness.records().filter { $0.kind == .text }.count == 2 })
        let second = try #require(await harness.records().last { $0.kind == .text })
        #expect(second.style.fontSize == toolSize)
    }

    // MARK: - L-68: a count's own pill selects the count

    /// Old output: the pill hangs on a leader away from the marks, and the hit test knew only the
    /// marks, so the click selected nothing.
    @Test("L-68: a click on a count's pill selects the count")
    func countPillSelectsTheCount() async throws {
        let harness = try await Fix2Harness.make("L68 Count.pdf")
        defer { harness.tearDown() }
        let marks = [(200.0, 400.0), (260.0, 400.0), (320.0, 400.0)].map {
            CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: $0.0, y: $0.1))
        }
        let count = try await harness.addMarkup(tool: .count) { page in
            MeasurementGeometry(pageID: page, countPoints: marks)
        }
        let page = harness.canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { page.shapes.contains { $0.id == count.id.rawValue } })
        let rep = try #require(page.bitmapImageRepForCachingDisplay(in: page.bounds))
        page.cacheDisplay(in: page.bounds, to: rep)
        let pill = try #require(page.captionFrames[count.id.rawValue], "the count's pill was drawn")
        let transform = try #require(page.transform)
        let centre = transform.pagePoint(from: CGPoint(x: pill.midX, y: pill.midY))
        // The pill is clear of every mark's own hit area.
        let markReach = harness.core.canvas.viewport.pageDistance(forViewPoints: 12)
        #expect(marks.allSatisfy { hypot($0.position.x - centre.x, $0.position.y - centre.y) > markReach })
        harness.core.canvas.clearSelection()
        harness.canvas.handleClick(at: centre, additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs == [count.id.rawValue])
    }

    // MARK: - L-71: Cancel Tool and Cycle Snap Candidate say what they did

    /// Old output: with Reuse Tool on (the default) and nothing drawn, Cancel Tool left Length
    /// armed and said nothing; Cycle Snap Candidate with no other candidate changed nothing and
    /// said nothing.
    @Test("L-71: Cancel Tool with nothing drawn puts the tool down; Escape mid-shape keeps it under Reuse; one candidate is said")
    func cancelToolAndCycleSnapSpeak() async throws {
        let harness = try await Fix2Harness.make("L71 Cancel.pdf")
        defer { harness.tearDown() }
        harness.canvas.onShellCommand = { [shell = harness.shell] in shell.perform($0) }
        #expect(harness.core.toolLibrary.reuseToolEnabled)
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.refresh()

        // Cycle Snap Candidate with snapping off: nothing to step to, and it says so.
        #expect(harness.canvas.cycleSnapCandidate(forward: true))
        #expect(harness.core.status.snapshot.activeToolNote == PDFCanvasViewController.noOtherSnapCandidateNote)

        // Mid-shape, Escape cancels the shape and Reuse keeps the tool.
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 300), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 1)
        _ = harness.canvas.handle(key: .escape)
        #expect(harness.core.measurement.placedPoints.isEmpty)
        #expect(harness.shell.toolbar.activeSelection.mode == .measure(.length), "Reuse keeps the tool after cancelling a shape")

        // Nothing drawn: Cancel Tool (the menu) puts the tool down.
        harness.shell.perform(.cancelTool)
        #expect(harness.shell.toolbar.activeTool == .select)
        harness.canvas.refresh()
        #expect(harness.core.measurement.activeKind == nil)

        // The same for Escape over an armed, empty markup tool.
        harness.shell.perform(.shapesTool)
        harness.canvas.refresh()
        #expect(harness.core.markup.activeKind != nil)
        _ = harness.canvas.handle(key: .escape)
        #expect(harness.shell.toolbar.activeTool == .select)
    }

    // MARK: - L-76: a copy lands where it can be seen

    /// Old output: Duplicate and Paste moved the copy 10 page points — 1 point on screen at 10 %,
    /// so it sat on top of the original. Hand-derived: 10 ÷ 0.1 = 100 page points, so the corner
    /// (300, 300) lands at (400, 200).
    @Test("L-76: Duplicate and Paste move the copy ten screen points at the zoom in view")
    func pasteAndDuplicateOffsetIsVisible() async throws {
        let harness = try await Fix2Harness.make("L76 Paste.pdf")
        defer { harness.tearDown() }
        harness.controller.markupPasteboard = ScratchMarkupPasteboard()
        harness.core.canvas.setZoom(0.1)
        harness.canvas.refresh()
        #expect(PDFCanvasViewController.pasteOffset(zoom: 0.1) == 100)
        #expect(PDFCanvasViewController.pasteOffset(zoom: 1) == 10)
        #expect(PDFCanvasViewController.pasteOffset(zoom: 4) == 10, "zoomed in, never less than ten page points")
        let original = try await Self.rectangle(harness, from: (300, 300), to: (400, 400))
        harness.core.canvas.select(markupIDs: [original.id.rawValue], additive: false)

        let duplicated = try #require(await harness.canvas.duplicateSelectedMarkups())
        let copyID = try #require(duplicated.pastedIDs.first)
        let copy = try #require(await harness.core.session.markup(MarkupID(copyID)))
        #expect(copy.geometry?.polygons.first?.outer.points.first == PDFPoint(x: 400, y: 200))

        harness.core.canvas.select(markupIDs: [original.id.rawValue], additive: false)
        _ = try #require(await harness.canvas.copySelectedMarkups())
        let pasted = try #require(await harness.canvas.pasteMarkups(placement: nil))
        let pasteID = try #require(pasted.pastedIDs.first)
        let paste = try #require(await harness.core.session.markup(MarkupID(pasteID)))
        #expect(paste.geometry?.polygons.first?.outer.points.first == PDFPoint(x: 400, y: 200))
    }

    // MARK: - L-77: Hide Selection on a locked markup

    /// Old output: the engine refused the whole hide for the locked markup, nothing was hidden —
    /// not even the unlocked one beside it — and the status line said nothing.
    @Test("L-77: Hide Selection hides the unlocked markups and says why the locked one stayed")
    func hideSelectionOnALockedMarkup() async throws {
        let harness = try await Fix2Harness.make("L77 Hide.pdf")
        defer { harness.tearDown() }
        let locked = try await Self.rectangle(harness, from: (100, 100), to: (200, 200))
        let free = try await Self.rectangle(harness, from: (300, 300), to: (400, 400))
        await ZenitPDFProjectDocument.performLockHide(ids: [locked.id.rawValue], lock: true, hide: nil, core: harness.core)
        await harness.settle()
        #expect(harness.core.snapshot.markups.first { $0.id == locked.id.rawValue }?.locked == true)

        harness.core.canvas.select(markupIDs: [locked.id.rawValue, free.id.rawValue], additive: false)
        harness.controller.applyLockOrHide(for: harness.document, hide: true)
        #expect(await Self.eventually { await harness.core.session.markup(free.id)?.hidden == true })
        #expect(await Self.eventually { harness.core.status.snapshot.activeToolNote?.contains("locked markup") == true })
        #expect(await harness.core.session.markup(locked.id)?.hidden == false)
        #expect(harness.core.status.snapshot.activeToolNote
                == "1 locked markup was not hidden. Unlock it first (Edit ▸ Unlock Selection).",
                "note: \(harness.core.status.snapshot.activeToolNote ?? "nil")")
        #expect(harness.core.canvas.selectedMarkupIDs == [locked.id.rawValue],
                "the locked one, still on screen, stays selected: \(harness.core.canvas.selectedMarkupIDs) locked \(locked.id.rawValue) free \(free.id.rawValue)")
    }

    // MARK: - L-101: a link box asks where it leads and can be selected

    /// Old output: the drawn link box asked nothing (no Edit Link request), had no destination,
    /// and a click inside its frame selected nothing, so Edit Link answered "Select one link".
    @Test("L-101: a link box drawn on the canvas asks where it leads, and a click inside it selects it")
    func hyperlinkAsksForItsTargetAndIsSelectable() async throws {
        ZenitModalPresenter.reset()
        defer {
            ZenitModalPresenter.reset()
            MarkupRound2Actions.typeLinkForTesting = nil
        }
        MarkupRound2Actions.typeLinkForTesting = "https://example.com/details"
        ZenitModalPresenter.handler = { request in
            request.identifier == MarkupRound2Actions.editLinkIdentifier ? .button(0) : .dismissed
        }
        let harness = try await Fix2Harness.make("L101 Link.pdf")
        defer { harness.tearDown() }
        harness.shell.toolbar.activateShape(.hyperlink)
        harness.canvas.refresh()
        #expect(harness.core.markup.activeKind == .hyperlink)
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 150, y: 450))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 250, y: 400))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 350, y: 350))
        #expect(await Self.eventually { await harness.records().contains { $0.kind == .hyperlink } })
        let link = try #require(await harness.records().first { $0.kind == .hyperlink })
        #expect(await Self.eventually { ZenitModalPresenter.didRequest(MarkupRound2Actions.editLinkIdentifier) })
        #expect(await Self.eventually { await harness.core.session.markup(link.id)?.link?.url == "https://example.com/details" })

        // Select, then a click inside the frame (nowhere near its edge) selects it again.
        harness.shell.toolbar.selectTool(.select)
        harness.canvas.refresh()
        await harness.settle()
        harness.core.canvas.clearSelection()
        harness.canvas.handleClick(at: PDFPointValue(x: 250, y: 400), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs == [link.id.rawValue])
    }
}
