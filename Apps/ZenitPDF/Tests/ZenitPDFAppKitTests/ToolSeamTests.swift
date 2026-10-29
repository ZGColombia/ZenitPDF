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

/// The regression that stops a whole class of tool bug coming back.
///
/// The defect was not "Shapes is unfinished". It was that the toolbar's notion of the armed
/// tool never reached the canvas, so a chip could light up over a canvas that was still in
/// Select — and nothing in the build said so. These tests assert the seam itself: every
/// `ZenitToolIdentifier` case, armed through the shipping toolbar model, reaches the
/// shipping canvas controller and produces a behaviour there.
@MainActor
@Suite(.appTierSerialised)
struct ToolSeamTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private func makeCanvas() async throws -> (
        document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment,
        shell: ProjectShellEnvironment,
        toolbar: ZenitToolbarModel,
        canvas: PDFCanvasViewController,
        directory: URL
    ) {
        let url = try AppTestSupport.writeFixturePDF(named: "Seam.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        _ = canvas.view
        return (document, core, shell, shell.toolbar, canvas, url.deletingLastPathComponent())
    }

    // MARK: - The exhaustiveness gate

    @Test("Every ZenitToolIdentifier case reaches the canvas with a behaviour of its own")
    func everyToolIdentifierIsHandledByTheCanvas() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // Twelve cases, and the two the enum was missing are in the list: `length` and
        // `area` are first-class toolbar items and were absent,
        // which is the second half of the root cause.
        #expect(ZenitToolIdentifier.allCases.contains(.length))
        #expect(ZenitToolIdentifier.allCases.contains(.area))

        // The Measure palette must be pointing at something that is not Length or Area,
        // or its chip and theirs arm the same mode and the round-trip below is ambiguous —
        // which is itself the property being pinned.
        harness.toolbar.activateMeasurement(.polylength)

        var seenModes: Set<ZenitToolMode> = []
        for tool in ZenitToolIdentifier.allCases {
            let expected = tool.mode(
                lastUsedMeasurement: harness.toolbar.lastUsedMeasurementKind,
                lastUsedShape: harness.toolbar.lastUsedShapeKind
            )
            harness.toolbar.selectTool(tool)
            harness.canvas.refresh()

            #expect(
                harness.canvas.armedMode == expected,
                "\(tool.rawValue): the toolbar armed \(expected) and the canvas is in \(harness.canvas.armedMode)"
            )
            #expect(
                harness.toolbar.activeTool == tool,
                "\(tool.rawValue): the chip that lights up must be the tool that was armed"
            )
            #expect(
                ZenitToolIdentifier(mode: expected) == tool,
                "\(tool.rawValue): mode → identifier must round-trip, or two chips claim one tool"
            )
            #expect(
                !harness.canvas.armedToolName.isEmpty,
                "\(tool.rawValue): the status bar has nothing to name"
            )
            // A behaviour, not a fall-through: the tool either collects geometry on the
            // canvas, or it is one of the three that own the pointer outright.
            let gesture = expected.gesture
            let ownsPointer = expected == .select || expected == .pan || expected == .zoom
            #expect(
                gesture.collectsPoints || ownsPointer,
                "\(tool.rawValue) is armed but collects nothing — an armed tool must collect"
            )
            seenModes.insert(expected)
        }
        #expect(seenModes.count == ZenitToolIdentifier.allCases.count,
                "two identifiers arm the same mode; one of them is a chip that cannot be reached")
    }

    @Test("Every drawable markup kind has a gesture; every undrawable one says so")
    func everyMarkupKindIsEitherDrawableOrHonest() {
        for kind in ZPDFUIPresentation.MarkupKind.allCases {
            let mode = ZenitToolMode.markup(kind)
            if ZenitToolMode.isDrawable(kind) {
                #expect(mode.gesture.collectsPoints, "\(kind.rawValue) is offered but collects nothing")
                #expect(mode.gesture.minimumPointCount >= 1)
                #expect(mode.limitationNote == nil, "\(kind.rawValue) is drawable and must not claim otherwise")
            } else {
                #expect(!mode.gesture.collectsPoints)
                #expect(
                    mode.limitationNote != nil,
                    "\(kind.rawValue) cannot be drawn, so arming it must say so rather than doing something else"
                )
            }
        }
        // The Shapes palette is these seven shapes, in this order.
        #expect(ZenitToolMode.shapePalette == [
            .rectangle, .ellipse, .line, .arrow, .polyline, .polygon, .cloud
        ])
    }

    @Test("Every measurement kind still answers the gesture question it always did")
    func measurementGesturesAreUnchangedByTheNewVocabulary() {
        for kind in MeasurementKind.allCases {
            let gesture = ZenitToolMode.measure(kind).gesture
            #expect(gesture.collectsPoints)
            #expect(gesture.minimumPointCount == kind.minimumPointCount)
            #expect(gesture.completingPointCount == kind.completingPointCount)
            #expect(gesture.closesOnFirstVertex == kind.closesOnFirstVertex)
            #expect(gesture.derivesFourthCorner == kind.derivesFourthCorner)
            // Area is the deliberate exception, and the only one: the Area tool offers three
            // ways to draw one ring from one button, so its *gesture* is
            // wider than the kind's semantics. Everything else must still
            // be drawn exactly the way `MeasurementToolSemantics` says.
            if kind == .area {
                #expect(gesture.usesDragGesture)
                #expect(gesture.dragAlsoPlacesClicks)
                #expect(gesture.optionDerivesRectangle)
            } else {
                #expect(gesture.usesDragGesture == kind.usesDragGesture)
                #expect(!gesture.optionDerivesRectangle)
            }
        }
        // Count places points, never a path. This flag is what stops the live overlay
        // stroking a polygon through the dots.
        #expect(ZenitToolMode.measure(.count).gesture.isPointPlacement)
        #expect(!ZenitToolMode.measure(.area).gesture.isPointPlacement)
    }

    // MARK: - Arming is visible and true

    @Test("Arming names the tool in the status bar, and says when the tool is incomplete")
    func armingIsVisibleInTheStatusBar() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.textTool)
        #expect(harness.core.status.snapshot.activeToolName == ZPDFUIPresentation.MarkupKind.text.displayName)
        #expect(harness.core.status.snapshot.activeToolNote == nil)

        harness.shell.perform(.measureLength)
        #expect(harness.core.status.snapshot.activeToolName == MeasurementKind.length.displayName)

        // The honest "not implemented" of the last shared tool rule.
        harness.toolbar.activateMeasurement(.volume)
        #expect(harness.core.status.snapshot.activeToolName == MeasurementKind.volume.displayName)
        #expect(harness.core.status.snapshot.activeToolNote != nil,
                "Volume cannot be given its depth yet, and the status bar must say so")
        #expect(harness.core.status.snapshot.toolIndicatorText.contains(MeasurementKind.volume.displayName))

        // Cutout subtracts now, so its note is no longer an apology — it
        // is the precondition, which is the one thing about the tool a user cannot guess.
        harness.shell.perform(.cutoutTool)
        #expect(harness.canvas.armedMode == .measure(.polygonCutout))
        let cutoutNote = try #require(harness.core.status.snapshot.activeToolNote)
        #expect(cutoutNote.contains("inside an existing area"),
                "Cutout must say what it needs; it must not claim to be unimplemented now that it works")

        // A scroll or a page change must not rename the armed tool.
        harness.toolbar.activateMeasurement(.volume)
        await harness.core.refresh()
        #expect(harness.core.status.snapshot.activeToolName == MeasurementKind.volume.displayName)
    }

    @Test("Count arms Count: the previous polygon never continues into it")
    func countCannotInheritTheLastArmedKind() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // A scale first, so the commit is judged on the count and not on a missing calibration
        // — and since LT3-05 (nl-measure) an area on a sheet with no scale refuses its first
        // vertex up front, so the half-drawn area below needs one too.
        _ = try await harness.core.commands.calibrate(
            page: try #require(await harness.core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await harness.core.refresh()

        // Two vertices of an area, then Count. The count must start empty and place
        // points, not continue the polygon.
        harness.shell.perform(.measureArea)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 2)

        harness.shell.perform(.measureCount)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .measure(.count))
        #expect(harness.canvas.armedGesture.isPointPlacement,
                "count points are points; stroking a path through them draws a polygon nobody measured")
        #expect(harness.core.measurement.placedPoints.isEmpty,
                "the half-drawn area must not become the first two count points")

        // And a count preset that was saved without a measurement kind cannot leave the
        // previous tool armed: the Count button arms Count, always.
        harness.shell.perform(.measureArea)
        harness.shell.toolbar.activateCountPreset(id: UUID())
        #expect(harness.shell.toolbar.activeSelection.mode == .measure(.count))
        #expect(harness.shell.toolbar.activeTool == .count)
    }

    /// A typical count sequence, driven through the shipping canvas controller:
    /// five clicks, one ledger row valued five, `⌥`-click removes one, Escape ends the
    /// group rather than throwing it away.
    @Test("Count: five clicks are one row valued 5, ⌥-click un-places one, Escape ends the group")
    func countPlacesPointsAndEndsOnEscape() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harness.canvas.onShellCommand = { [shell = harness.shell, core = harness.core] command in
            guard command == .finishGeometry else { return shell.perform(command) }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }

        // A scale, so the commit is judged on the count and not on a missing calibration.
        _ = try await harness.core.commands.calibrate(
            page: try #require(await harness.core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await harness.core.refresh()

        harness.shell.perform(.measureCount)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .measure(.count))

        let marks = [
            PDFPointValue(x: 120, y: 120),
            PDFPointValue(x: 180, y: 120),
            PDFPointValue(x: 240, y: 120),
            PDFPointValue(x: 300, y: 120),
            PDFPointValue(x: 360, y: 120)
        ]
        for mark in marks {
            harness.canvas.handleClick(at: mark, additive: false)
        }
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 5,
                "one click places one point, and nothing about the fifth click commits anything")
        #expect(harness.core.ledger.rowCount == 0,
                "a count group is open until the estimator says it is finished")

        // `⌥` on a placed mark un-places it — it must not add a sixth.
        harness.canvas.handleClick(at: PDFPointValue(x: 241, y: 121), additive: false, optionHeld: true)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 4,
                "⌥ on an existing point removes it")
        let survivingX: [Double] = harness.core.measurement.placedPoints.map(\.x)
        #expect(survivingX == [120, 180, 300, 360],
                "the removed point is the one under the cursor, not the last one placed")

        // `⌥` on empty space removes nothing and places nothing: the click is spent.
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 500), additive: false, optionHeld: true)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 4)

        // Escape *ends* the group. Every other tool discards on Escape; a count does not,
        // because the marks are the work.
        _ = harness.canvas.handle(key: .escape)
        #expect(await wait { harness.core.ledger.rowCount == 1 },
                "Escape must commit the count group, not throw four marks away")
        let row = try #require(harness.core.ledger.row(at: 0))
        #expect(row.measurementKind == .count)
        #expect(row.values[.count] == .quantity(.count(4)),
                "one row per group, valued by the number of points that survived")
        #expect(harness.core.measurement.placedPoints.isEmpty)
    }

    /// A count is a number of things, not a number of metres. It was blocked by the
    /// `.missingScale` warning like every other measurement, so counting on a sheet that
    /// had not been calibrated yet placed the marks, took the Escape, and silently threw
    /// the group away — the "armed but produces nothing" failure on
    /// the one tool that never needed a scale.
    @Test("Count needs no scale: an uncalibrated sheet still records the group")
    func countCommitsWithoutACalibration() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harness.canvas.onShellCommand = { [shell = harness.shell, core = harness.core] command in
            guard command == .finishGeometry else { return shell.perform(command) }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }

        harness.shell.perform(.measureCount)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 120), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 180, y: 120), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(!harness.core.measurement.hasBlockingWarning,
                "a missing scale must not block a count — there is no length in it to get wrong")

        _ = harness.canvas.handle(key: .escape)
        #expect(await wait { harness.core.ledger.rowCount == 1 })
        let row = try #require(harness.core.ledger.row(at: 0))
        #expect(row.measurementKind == .count)
        #expect(harness.core.measurement.placedPoints.isEmpty)
        // The marks are kept; the *number* still waits for a scale, which is the engine's
        // standing rule for an unscaled drawing (spec 10.2) and is stated in the row rather
        // than guessed at. Calibrating afterwards restamps it.
    }

    @Test("Pan arms a state the canvas reads, and Escape leaves a markup tool")
    func panAndEscapeReachTheCanvas() async throws {
        let harness = try await makeCanvas()
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.panTool)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .pan,
                "Pan used to arm a state nobody read, so it behaved exactly like Select")

        harness.shell.perform(.shapesTool)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .markup(.rectangle))
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        #expect(harness.core.markup.placedPoints.count == 1)

        harness.canvas.onShellCommand = { [shell = harness.shell] command in shell.perform(command) }
        _ = harness.canvas.handle(key: .escape)
        #expect(harness.core.markup.placedPoints.isEmpty, "Escape cancels the markup in progress")
        // Reuse Tool is on by default since 2026-08-26, and the shared tool rule is
        // that Escape returns to Select *unless* it is on. Escape still cancels the shape in
        // progress — that is the assertion above, and it is the one that matters.
        #expect(harness.toolbar.activeTool == .shapes, "Reuse Tool is on, so the tool stays armed")

        harness.core.toolLibrary.setReuseToolEnabled(false)
        harness.shell.perform(.shapesTool)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        _ = harness.canvas.handle(key: .escape)
        #expect(harness.toolbar.activeTool == .select, "with Reuse Tool off, Escape returns to Select")
    }
}
