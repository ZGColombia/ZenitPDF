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

/// Three tools that were once half-finished, driven through the shipping
/// `PDFCanvasViewController` — Cutout, Select and Area.
///
/// Every test asserts the four things the acceptance criteria ask for: the
/// markup **type**, its **geometry**, its **ledger consequence** and one `⌘Z`. Save →
/// reopen is the last test in the file.
///
/// Nothing here launches the application. The canvas controller is the shipping one and its
/// handlers are the ones `CanvasPageView` calls from a real mouse.
@MainActor
@Suite(.appTierSerialised)
struct SelectAreaCutoutTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let directory: URL
    }

    /// A loaded drawing calibrated at 100 pt = 1 m, with the shipping canvas over it.
    ///
    /// The scale is round on purpose: every expected quantity below is a number that can be
    /// read off the coordinates, so a wrong answer names itself instead of being "close".
    private func makeHarness(named name: String) async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        // Snap off. Every quantity below is read straight off the click coordinates, and
        // with the 12 pt grid live a 400 pt click lands at 396 and a 4 m² area measures
        // 4.08 m² — a true number about a shape the test did not draw. Snap has its own
        // suites; these are about what the three tools do with the points they are given.
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        await core.refresh()
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        _ = canvas.view
        // The window controller's own routing, minus the window: `.finishGeometry` waits for
        // the asynchronous snap resolve of the last click before committing, exactly as
        // `ProjectWindowController.performShell` does.
        canvas.onShellCommand = { command in
            guard command == .finishGeometry else {
                shell.perform(command)
                return
            }
            Task { @MainActor in
                await core.measurement.settlePlacements()
                core.measurement.commitActiveMeasurement()
            }
        }
        return Harness(
            document: document,
            core: core,
            shell: shell,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    private func records(_ core: AppCoreEnvironment) async -> [MarkupRecord] {
        await core.session.orderedMarkups
    }

    private func markupCount(_ core: AppCoreEnvironment) -> Int {
        core.snapshot.markups.count
    }

    /// Draws a closed polygon with the Area tool, one click per vertex, closing on the first.
    private func drawArea(
        _ vertices: [PDFPointValue],
        _ harness: Harness
    ) async {
        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        for vertex in vertices {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        // Clicking the first vertex again closes and commits.
        harness.canvas.handleClick(at: vertices[0], additive: false)
        await harness.core.measurement.settlePlacements()
    }

    /// Redraws the canvas and waits for the scene the hit test and the cutout's parent list
    /// are read from.
    ///
    /// In the running application `withObservationTracking` does this on every commit; a
    /// controller whose view never appeared has no observation, so the tests ask for it.
    private func settle(_ harness: Harness) async {
        await harness.core.refresh()
        harness.canvas.refresh()
        await harness.canvas.settleScene()
    }

    private func square(x: Double, y: Double, side: Double) -> [PDFPointValue] {
        [
            PDFPointValue(x: x, y: y),
            PDFPointValue(x: x + side, y: y),
            PDFPointValue(x: x + side, y: y + side),
            PDFPointValue(x: x, y: y + side)
        ]
    }

    private func decimal(_ quantity: ZPDFContracts.DecimalQuantity?) -> Decimal? { quantity?.value }

    // MARK: - Cutout

    /// The whole Cutout acceptance, in one pass: draw a polygon inside an
    /// existing area, the area's net value drops, the cutout is a child of that area in the
    /// ledger, and one `⌘Z` puts the parent back.
    @Test("A cutout drawn inside an area becomes its child and drops its net value; ⌘Z restores it")
    func cutoutSubtractsFromItsParentAndBecomesAChildRow() async throws {
        let harness = try await makeHarness(named: "Cutout.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // A 200 × 200 pt area: 2 m × 2 m = 4 m² at 100 pt = 1 m.
        await drawArea(square(x: 400, y: 400, side: 200), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let parentBefore = try #require(await records(harness.core).first)
        #expect(decimal(parentBefore.measurement?[.planArea]) == 4)
        #expect(decimal(parentBefore.measurement?[.netArea]) == 4)

        // A 100 × 100 pt hole inside it: 1 m².
        await settle(harness)
        harness.shell.perform(.cutoutTool)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .measure(.polygonCutout))
        let hole = square(x: 450, y: 450, side: 100)
        for vertex in hole {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        #expect(harness.core.measurement.cutoutParentID == parentBefore.id,
                "the first vertex landed inside the area, so that area is the parent")
        harness.canvas.handleClick(at: hole[0], additive: false)
        #expect(await wait { self.markupCount(harness.core) == 2 })

        let after = await records(harness.core)
        let parent = try #require(after.first { $0.id == parentBefore.id })
        let cutout = try #require(after.first { $0.id != parentBefore.id })

        // Type and parentage.
        #expect(cutout.kind == .polygon)
        #expect(cutout.parentMarkupID == parentBefore.id,
                "a cutout with no parent is an orphan polygon that subtracts nothing — the defect this replaces")
        #expect(parent.cutoutMarkupIDs == [cutout.id])

        // Geometry: the hole became a hole in the parent's ring, which is what Clipper2
        // subtracts. Nothing here does arithmetic on two areas.
        #expect(cutout.geometry?.polygons.first?.outer.points.count == 4)
        #expect(parent.geometry?.polygons.first?.holes.count == 1)

        // The value.
        #expect(decimal(parent.measurement?[.planArea]) == 4, "the outline did not change")
        #expect(decimal(parent.measurement?[.netArea]) == 3, "4 m² less the 1 m² hole")
        #expect(decimal(cutout.measurement?[.cutoutArea]) == 1)

        // The ledger: a child row under the area.
        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 2)
        let rows = (0..<harness.core.ledger.rowCount).compactMap { harness.core.ledger.row(at: $0) }
        let childRow = try #require(rows.first { $0.markupID == cutout.id.rawValue })
        #expect(childRow.parentID == parentBefore.id.rawValue,
                "the cutout must read as a child of the area it came out of")

        // One ⌘Z.
        let undoManager = try #require(harness.document.undoManager)
        #expect(await wait { undoManager.canUndo })
        await harness.core.commands.undo()
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let restored = try #require(await records(harness.core).first)
        #expect(decimal(restored.measurement?[.netArea]) == 4,
                "one undo puts the parent's net value back, not just the hole's row")
        #expect(restored.geometry?.polygons.first?.holes.isEmpty == true)
    }

    /// "Refuse a cutout that overlaps no parent, with a reason."
    @Test("A cutout started outside every area is refused, and the status bar says why")
    func cutoutOutsideEveryAreaIsRefused() async throws {
        let harness = try await makeHarness(named: "CutoutRefusal.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        await drawArea(square(x: 400, y: 400, side: 100), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        await settle(harness)

        harness.shell.perform(.cutoutTool)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 700), additive: false)
        await harness.core.measurement.settlePlacements()

        #expect(harness.core.measurement.placedPoints.isEmpty,
                "the click is refused outright — a cutout that collects vertices it cannot use is the silent failure")
        #expect(harness.core.measurement.cutoutParentID == nil)
        #expect(harness.core.status.snapshot.activeToolNote == CutoutRefusalReason.noAreaUnderPoint.message,
                "the refusal must name what to do instead, not just do nothing")
        #expect(self.markupCount(harness.core) == 1, "and nothing was recorded")

        // X-cutout-ui: a vertex that leaves the parent it started in is placed. The engine
        // subtracts the part of a cutout inside its area, so only a cutout that overlaps nothing
        // is refused — by the engine, at Finish. The vertex used to be refused here.
        harness.canvas.handleClick(at: PDFPointValue(x: 420, y: 420), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 1)
        harness.canvas.handleClick(at: PDFPointValue(x: 560, y: 420), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 2,
                "a vertex outside the parent is part of a cutout the engine accepts")
        #expect(harness.canvas.measurementInputForTesting.cutoutRefusal == nil)
    }

    /// Spec 12.4's whole reason for existing: `netArea = outerArea − union(cutouts)`.
    /// Two overlapping holes share a region, and subtracting each one's own area removes
    /// that region twice.
    @Test("Overlapping cutouts union before they subtract, end to end")
    func overlappingCutoutsUnionBeforeSubtracting() async throws {
        let harness = try await makeHarness(named: "CutoutUnion.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // 400 × 400 pt = 16 m².
        await drawArea(square(x: 100, y: 300, side: 400), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let parentID = try #require(await records(harness.core).first).id

        // Two 100 × 100 pt holes overlapping over 50 × 50 pt.
        // Sum of areas  = 1 + 1      = 2 m²   → a naive net of 14 m².
        // Union of them = 2 − 0.25   = 1.75 m² → the correct net of 14.25 m².
        var expected = 1
        for origin in [PDFPointValue(x: 150, y: 350), PDFPointValue(x: 200, y: 400)] {
            await settle(harness)
            harness.shell.perform(.cutoutTool)
            harness.canvas.refresh()
            let hole = square(x: origin.x, y: origin.y, side: 100)
            for vertex in hole {
                harness.canvas.handleClick(at: vertex, additive: false)
                await harness.core.measurement.settlePlacements()
            }
            #expect(harness.core.measurement.cutoutParentID == parentID)
            harness.canvas.handleClick(at: hole[0], additive: false)
            expected += 1
            #expect(await wait { self.markupCount(harness.core) == expected })
        }

        let parent = try #require(await records(harness.core).first { $0.id == parentID })
        #expect(parent.cutoutMarkupIDs.count == 2)
        #expect(decimal(parent.measurement?[.planArea]) == 16)
        #expect(decimal(parent.measurement?[.netArea]) == Decimal(string: "14.25"),
                "the shared 0.25 m² must be removed once, not twice")
    }

    /// "Draw a polygon **or ellipse** inside an existing area markup." The ellipse cutout is
    /// one press-drag-release and is stored as the two corners of its box — which is not a
    /// ring, so without the ellipse case in `TakeoffSession.merging` it would be recorded,
    /// measured, shown as a child row, and subtract nothing.
    @Test("An ellipse cutout drawn with one drag subtracts its ellipse from the parent")
    func ellipseCutoutSubtractsAnEllipse() async throws {
        let harness = try await makeHarness(named: "EllipseCutout.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // 400 × 400 pt = 16 m².
        await drawArea(square(x: 100, y: 300, side: 400), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let parentID = try #require(await records(harness.core).first).id
        await settle(harness)

        // A 200 × 100 pt ellipse: semi-axes 1 m and 0.5 m, so π/2 ≈ 1.5708 m².
        harness.shell.toolbar.activateMeasurement(.ellipseCutout)
        harness.canvas.refresh()
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 400))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 400, y: 500))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 400, y: 500))
        #expect(await wait { self.markupCount(harness.core) == 2 })

        let parent = try #require(await records(harness.core).first { $0.id == parentID })
        let cutout = try #require(await records(harness.core).first { $0.id != parentID })
        #expect(cutout.parentMarkupID == parentID)
        #expect(cutout.tool == .ellipseCutout)
        let net = try #require(decimal(parent.measurement?[.netArea]))
        #expect(net > Decimal(string: "14.42")! && net < Decimal(string: "14.44")!,
                "16 m² less π/2 ≈ 1.571 m² of ellipse — not less the 2 m² of its bounding box")
        #expect(decimal(cutout.measurement?[.cutoutArea]).map { abs($0 - net.distance(to: 16)) < Decimal(string: "0.01")! } == true,
                "what the child says it removes and what the parent lost must be one number")

        await harness.core.commands.undo()
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let restored = try #require(await records(harness.core).first)
        #expect(decimal(restored.measurement?[.netArea]) == 16)
    }

    // MARK: - Select

    /// The bounding-box hit test, by its defining example.
    @Test("A click in an L-shaped area's notch selects nothing; a click inside the L selects it")
    func hitTestFollowsTheOutlineNotTheBoundingBox() async throws {
        let harness = try await makeHarness(named: "HitTest.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // An L: the notch is the top-right quadrant of its bounding box.
        await drawArea(
            [
                PDFPointValue(x: 400, y: 400),
                PDFPointValue(x: 560, y: 400),
                PDFPointValue(x: 560, y: 480),
                PDFPointValue(x: 480, y: 480),
                PDFPointValue(x: 480, y: 600),
                PDFPointValue(x: 400, y: 600)
            ],
            harness
        )
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let id = try #require(await records(harness.core).first).id.rawValue

        harness.shell.perform(.selectTool)
        await settle(harness)
        #expect(harness.canvas.hitTest(PDFPointValue(x: 430, y: 430)) == id)

        // Inside the bounding box, outside the polygon, and nowhere near an edge.
        #expect(harness.canvas.hitTest(PDFPointValue(x: 530, y: 550)) == nil,
                "a click in the notch used to select the L, because the box contains it")
        harness.canvas.handleClick(at: PDFPointValue(x: 530, y: 550), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs.isEmpty)

        harness.canvas.handleClick(at: PDFPointValue(x: 430, y: 430), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs == [id])
    }

    /// Drag-to-move, and one `⌘Z`. `DocumentCommand.moveMarkup` had no caller in the app
    /// before this.
    @Test("Dragging a selected markup moves it, and one ⌘Z puts it back")
    func draggingASelectedMarkupMovesIt() async throws {
        let harness = try await makeHarness(named: "Move.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 400), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 400), additive: false)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let id = try #require(await records(harness.core).first).id

        harness.shell.perform(.selectTool)
        await settle(harness)
        #expect(harness.canvas.hitTest(PDFPointValue(x: 450, y: 400)) == id.rawValue)
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 400), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs == [id.rawValue])

        // Press on the line, away from either endpoint, so the drag is a move rather than a
        // vertex edit.
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 450, y: 400))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 480, y: 460))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 480, y: 460))

        #expect(await wait {
            (harness.core.snapshot.markups.first?.boundsInPageSpace.minY ?? 0) > 440
        })
        // Through the command bus, which is the one door that registers undo and writes the
        // audit entry — not straight onto the session.
        #expect(harness.core.commands.lastCommandKind == .moveMarkup)
        let moved = try #require(await records(harness.core).first)
        #expect(moved.geometry?.points.map(\.x) == [430, 530])
        #expect(moved.geometry?.points.map(\.y) == [460, 460])
        #expect(decimal(moved.measurement?[.planLength]) == 1,
                "a translation does not change the length")

        await harness.core.commands.undo()
        #expect(await wait {
            (harness.core.snapshot.markups.first?.boundsInPageSpace.minY ?? 0) < 410
        })
        let restored = try #require(await records(harness.core).first)
        #expect(restored.geometry?.points.map(\.y) == [400, 400], "one ⌘Z, one move")
    }

    /// Vertex editing, live recompute and one `⌘Z`. `DocumentCommand.editVertices` had no
    /// caller in the app before this either.
    @Test("Dragging a vertex handle edits the geometry and the engine recomputes the value")
    func draggingAVertexEditsTheGeometry() async throws {
        let harness = try await makeHarness(named: "Vertex.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.measureLength)
        harness.canvas.refresh()
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 400), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 500, y: 400), additive: false)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let id = try #require(await records(harness.core).first).id
        #expect(decimal(try #require(await records(harness.core).first).measurement?[.planLength]) == 1)

        harness.shell.perform(.selectTool)
        await settle(harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 400), additive: false)
        #expect(harness.core.canvas.selectedMarkupIDs == [id.rawValue])
        // The handles are drawn from the *selected* markup's stored vertices, so the scene
        // has to be redrawn once the selection exists before one can be grabbed.
        await settle(harness)

        // The handle is on the vertex itself, and its index is the index
        // `MarkupVertexEditing` — and therefore `.editVertices` — will edit.
        let handle = try #require(harness.canvas.vertexHandle(at: PDFPointValue(x: 500, y: 400)))
        #expect(handle.markupID == id.rawValue)
        #expect(handle.index == 1)

        harness.canvas.handleDragBegan(at: PDFPointValue(x: 500, y: 400))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 600, y: 400))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 600, y: 400))

        #expect(await wait {
            (harness.core.snapshot.markups.first?.boundsInPageSpace.size.width ?? 0) > 150
        })
        #expect(harness.core.commands.lastCommandKind == .editVertices,
                "a vertex edit is a document command, so it is undoable and audited like any other")
        let edited = try #require(await records(harness.core).first)
        #expect(edited.geometry?.points.map(\.x) == [400, 600], "only the dragged vertex moved")
        #expect(decimal(edited.measurement?[.planLength]) == 2,
                "the measurement is recomputed by the engine, not left at its old number")

        await harness.core.commands.undo()
        #expect(await wait {
            (harness.core.snapshot.markups.first?.boundsInPageSpace.size.width ?? 0) < 150
        })
        let restored = try #require(await records(harness.core).first)
        #expect(restored.geometry?.points.map(\.x) == [400, 500])
        #expect(decimal(restored.measurement?[.planLength]) == 1)
    }

    @Test("A marquee selects everything it crosses; ⇧-click adds and removes; Delete clears")
    func marqueeAndShiftClickAndDelete() async throws {
        let harness = try await makeHarness(named: "Marquee.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        var drawn = 0
        for y in [400.0, 500.0, 700.0] {
            harness.shell.perform(.measureLength)
            harness.canvas.refresh()
            harness.canvas.handleClick(at: PDFPointValue(x: 400, y: y), additive: false)
            harness.canvas.handleClick(at: PDFPointValue(x: 500, y: y), additive: false)
            drawn += 1
            #expect(await wait { self.markupCount(harness.core) == drawn })
        }
        let ids = await records(harness.core).map(\.id.rawValue)

        harness.shell.perform(.selectTool)
        await settle(harness)
        #expect(harness.canvas.hitTest(PDFPointValue(x: 450, y: 400)) != nil)

        // A marquee over the first two only.
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 380, y: 380))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 520, y: 520))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 520, y: 520))
        #expect(harness.core.canvas.selectedMarkupIDs == Set(ids.prefix(2)),
                "marquee drag selects many — the gesture that did nothing at all before")

        // `⇧`-click adds the third…
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 700), additive: true)
        #expect(harness.core.canvas.selectedMarkupIDs == Set(ids))
        // …and `⇧`-click on a selected markup removes it.
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 700), additive: true)
        #expect(harness.core.canvas.selectedMarkupIDs == Set(ids.prefix(2)))

        // Delete removes the selection through the command bus.
        harness.canvas.onShellCommand = { [shell = harness.shell] command in shell.perform(command) }
        var deleted = false
        harness.canvas.onShellCommand = { [core = harness.core] command in
            guard command == .deleteSelection else { return }
            deleted = true
            Task { @MainActor in
                for id in core.canvas.selectedMarkupIDs {
                    _ = try? await core.commands.perform(.removeMarkup(MarkupID(id)))
                }
                core.canvas.clearSelection()
            }
        }
        _ = harness.canvas.handle(key: .removeLastVertex)
        #expect(deleted)
        #expect(await wait { self.markupCount(harness.core) == 1 })
    }

    // MARK: - Area, one tool with three gestures

    @Test("Area accepts press-drag-release and commits a four-corner rectangle on release")
    func areaAcceptsPressDragRelease() async throws {
        let harness = try await makeHarness(named: "AreaDrag.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .measure(.area))
        #expect(harness.canvas.armedGesture.usesDragGesture,
                "'hold and drag an area directly' must work from the Area button")
        #expect(harness.canvas.armedGesture.dragAlsoPlacesClicks,
                "and a press that never moves must still be a polygon vertex")

        harness.canvas.handleDragBegan(at: PDFPointValue(x: 400, y: 400))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 600, y: 550))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 600, y: 550))
        #expect(await wait { self.markupCount(harness.core) == 1 })

        let record = try #require(await records(harness.core).first)
        #expect(record.kind == .measurement)
        #expect(record.tool == .area, "the drag must produce an Area, not the separate Rectangle Area kind")
        let ring = try #require(record.geometry?.polygons.first?.outer.points)
        #expect(ring.count == 4)
        #expect(Set(ring.map(\.x)) == [400, 600])
        #expect(Set(ring.map(\.y)) == [400, 550])
        // 200 × 150 pt at 100 pt = 1 m.
        #expect(decimal(record.measurement?[.planArea]) == 3)

        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 1)
        await harness.core.commands.undo()
        #expect(await wait { self.markupCount(harness.core) == 0 })
    }

    @Test("Area accepts the three-click rectangle, and a plain third click still continues the polygon")
    func areaAcceptsTheThreeClickRectangle() async throws {
        let harness = try await makeHarness(named: "AreaThreeClick.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        #expect(harness.canvas.armedGesture.optionDerivesRectangle)

        // Two clicks place the edge; the third, marked with `⌥`, is the depth and finishes.
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 400), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.canvas.handleClick(at: PDFPointValue(x: 600, y: 400), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 2)

        harness.canvas.handleClick(at: PDFPointValue(x: 600, y: 500), additive: false, optionHeld: true)
        #expect(await wait { self.markupCount(harness.core) == 1 })

        let record = try #require(await records(harness.core).first)
        #expect(record.tool == .area)
        let ring = try #require(record.geometry?.polygons.first?.outer.points)
        #expect(ring.count == 4, "P4 = P1 + P3 − P2 is derived, not clicked")
        #expect(ring[3].x == 400 && ring[3].y == 500)
        // 200 × 100 pt = 2 m².
        #expect(decimal(record.measurement?[.planArea]) == 2)

        await harness.core.commands.undo()
        #expect(await wait { self.markupCount(harness.core) == 0 })

        // The same three clicks *without* `⌥` are three polygon vertices and commit nothing,
        // which is what keeps a five-sided area drawable from the same button.
        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        for vertex in [
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 600, y: 400),
            PDFPointValue(x: 600, y: 500)
        ] {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        #expect(harness.core.measurement.placedPoints.count == 3)
        #expect(self.markupCount(harness.core) == 0,
                "a plain third click continues the polygon; it must not silently finish a rectangle")
        harness.canvas.handleClick(at: PDFPointValue(x: 450, y: 500), additive: false)
        await harness.core.measurement.settlePlacements()
        #expect(harness.core.measurement.placedPoints.count == 4)
    }

    @Test("Area still closes a polygon on its first vertex, and one ⌘Z takes it back")
    func areaStillClosesOnTheFirstVertex() async throws {
        let harness = try await makeHarness(named: "AreaPolygon.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        await drawArea(square(x: 400, y: 400, side: 200), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let record = try #require(await records(harness.core).first)
        #expect(record.geometry?.polygons.first?.outer.points.count == 4)
        #expect(decimal(record.measurement?[.planArea]) == 4)

        await harness.core.commands.undo()
        #expect(await wait { self.markupCount(harness.core) == 0 })
    }

    // MARK: - Save → reopen

    @Test("A cutout, a moved markup and a dragged area all survive save → reopen")
    func trackASurvivesAProjectSave() async throws {
        let harness = try await makeHarness(named: "TrackAHydrate.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        await drawArea(square(x: 400, y: 400, side: 200), harness)
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let parentID = try #require(await records(harness.core).first).id

        await settle(harness)
        harness.shell.perform(.cutoutTool)
        harness.canvas.refresh()
        let hole = square(x: 450, y: 450, side: 100)
        for vertex in hole {
            harness.canvas.handleClick(at: vertex, additive: false)
            await harness.core.measurement.settlePlacements()
        }
        harness.canvas.handleClick(at: hole[0], additive: false)
        #expect(await wait { self.markupCount(harness.core) == 2 })

        harness.shell.perform(.measureArea)
        harness.canvas.refresh()
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 650))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 300, y: 800))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 300, y: 800))
        #expect(await wait { self.markupCount(harness.core) == 3 })

        let destination = harness.directory.appendingPathComponent("TrackA.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            harness.document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        harness.document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await wait { reopened.core != nil && !reopened.isLoading })
        let restored = try #require(reopened.core)
        #expect(reopened.loadFailure == nil)

        let after = await records(restored)
        #expect(after.count == 3)
        let parent = try #require(after.first { $0.id == parentID })
        let cutout = try #require(after.first { $0.parentMarkupID == parentID })
        #expect(cutout.kind == .polygon)
        #expect(parent.cutoutMarkupIDs == [cutout.id],
                "the parent/child relation is part of the takeoff, not a session detail")
        #expect(parent.geometry?.polygons.first?.holes.count == 1)
        #expect(decimal(parent.measurement?[.netArea]) == 3,
                "the reopened project must show the net value, not the gross one")
        #expect(after.filter { $0.tool == .area }.count == 2)

        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
