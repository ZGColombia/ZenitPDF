import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Iteration-7 app-canvas fixes (iteration-7 findings, items triaged "fix"):
/// X-001, X-003, X-004, X-005 and X-009. Every test drives the shipping canvas or window
/// controller directly; no window is ordered front and no modal is raised.
///
/// The harness calibrates 100 pt = 1 m with snap off, so quantities read straight off the
/// coordinates.
@MainActor
@Suite(.appTierSerialised)
struct Iter7AppCanvasTests {

    // MARK: - Shared helpers

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

    private static func record(
        _ harness: Fix2Harness, id: UUID = UUID(), tool: MeasurementTool, label: String = "",
        geometry: (PageID) -> MeasurementGeometry
    ) throws -> MarkupRecord {
        let drawing = try #require(harness.document.drawing)
        let page = drawing.pages[0]
        return MarkupRecord(
            id: MarkupID(id), documentID: drawing.documentID, pageID: page.id, kind: .measurement,
            tool: tool, label: label, geometry: geometry(page.id), createdAt: Date(), modifiedAt: Date()
        )
    }

    private static func ring(_ points: [(Double, Double)], page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: points.map { PDFPoint(x: $0.0, y: $0.1) }))])
    }

    /// A 3 m × 3 m area (100, 100)–(400, 400) with a 1 m × 1 m polygon cutout (200, 200)–(300, 300):
    /// gross 9 m², net 8 m², cutout 1 m².
    private static func areaWithCutout(
        _ harness: Fix2Harness, parentID: UUID = UUID(), cutoutID: UUID = UUID()
    ) async throws -> (parent: MarkupID, cutout: MarkupID) {
        let parent = try record(harness, id: parentID, tool: .area, label: "Room 1") { page in
            ring([(100, 100), (400, 100), (400, 400), (100, 400)], page: page)
        }
        let cutout = try record(harness, id: cutoutID, tool: .polygonCutout) { page in
            ring([(200, 200), (300, 200), (300, 300), (200, 300)], page: page)
        }
        _ = try await harness.core.commands.perform(.addMarkup(parent))
        _ = try await harness.core.commands.perform(.addCutout(parent: parent.id, cutout: cutout))
        await harness.settle()
        return (parent.id, cutout.id)
    }

    private static func stored(_ harness: Fix2Harness, _ id: MarkupID) async -> MarkupRecord? {
        await harness.records().first { $0.id == id }
    }

    private static func outer(_ record: MarkupRecord?) -> [PDFPoint] {
        record?.geometry?.polygons.first?.outer.points ?? []
    }

    private static func value(_ record: MarkupRecord?, _ field: ZPDFContracts.MeasurementField) -> Decimal? {
        record?.measurement?[field]?.value
    }

    private static func shifted(_ points: [(Double, Double)], dx: Double) -> [PDFPoint] {
        points.map { PDFPoint(x: $0.0 + dx, y: $0.1) }
    }

    private static func near(_ a: PDFPoint, _ b: PDFPoint, within tolerance: Double = 1e-6) -> Bool {
        Swift.abs(a.x - b.x) <= tolerance && Swift.abs(a.y - b.y) <= tolerance
    }

    /// Whether `points` is `ring` moved `dx` along x. The nudge's page step goes through the
    /// display transform, so it lands within a few ulps of 10 pt, not on it.
    private static func ring(_ points: [PDFPoint], isShifted ring: [(Double, Double)], by dx: Double) -> Bool {
        let expected = shifted(ring, dx: dx)
        return points.count == expected.count && zip(points, expected).allSatisfy { near($0, $1) }
    }

    private static let parentRing: [(Double, Double)] = [(100, 100), (400, 100), (400, 400), (100, 400)]
    private static let holeRing: [(Double, Double)] = [(200, 200), (300, 200), (300, 300), (200, 300)]

    // MARK: - X-001 a parent carries its cutout once

    /// A marquee catches the area and its cutout (each is its own shape). Shift-→ moves the
    /// selection 10 pt, a drag on the area another 20 pt. Hand-derived: both rings move by the
    /// same 10 pt and then 30 pt in all, net stays 9 − 1 = 8 m², cutout 1 m², and one ⌘Z takes
    /// one gesture back. Old output (one `.moveMarkup` per selected id): the parent carried the
    /// cutout and the cutout's own command moved it again — the hole at x 220…320 after the
    /// nudge (twice the offset), and 260…360 after the drag, outside the ghost.
    @Test("X-001: moving or nudging an area with its own cutout moves the hole once")
    func parentAndCutoutMoveOnce() async throws {
        let harness = try await Fix2Harness.make("Iter7 Move Cutout.pdf")
        defer { harness.tearDown() }
        let ids = try await Self.areaWithCutout(harness)
        let canvas = harness.canvas
        harness.shell.perform(.selectTool)
        canvas.refresh()
        await canvas.settleScene()

        // The marquee from empty paper around both. From the top right: the area's pill hangs
        // off its lower-left corner (its centroid is in the hole), and a press on a pill takes
        // its markup since L-68, so (50, 50) is no longer empty paper.
        canvas.beginSelectDrag(at: PDFPointValue(x: 450, y: 450))
        canvas.updateSelectDrag(to: PDFPointValue(x: 50, y: 50))
        canvas.endSelectDrag(at: PDFPointValue(x: 50, y: 50))
        #expect(harness.core.canvas.selectedMarkupIDs == [ids.parent.rawValue, ids.cutout.rawValue],
                "the marquee caught \(harness.core.canvas.selectedMarkupIDs.count) markups")

        #expect(canvas.handle(key: .nudge(dx: 1, dy: 0, large: true, isRepeat: false)))
        let moved10 = await Self.eventually { await Self.ring(Self.outer(Self.stored(harness, ids.parent)), isShifted: Self.parentRing, by: 10) }
        let parentAt10 = Self.outer(await Self.stored(harness, ids.parent))
        #expect(moved10, "parent at \(parentAt10)")
        try? await Task.sleep(for: .milliseconds(200))
        var parent = await Self.stored(harness, ids.parent)
        var cutout = await Self.stored(harness, ids.cutout)
        #expect(Self.ring(Self.outer(cutout), isShifted: Self.holeRing, by: 10), "hole at \(Self.outer(cutout))")
        #expect(Self.value(parent, .netArea) == 8)
        #expect(Self.value(parent, .planArea) == 9)
        #expect(Self.value(cutout, .cutoutArea) == 1)
        #expect(harness.document.undoManager?.undoActionName == "Move Markup")

        // A drag that starts on the area moves the same selection.
        await harness.settle()
        canvas.beginSelectDrag(at: PDFPointValue(x: 150, y: 150))
        canvas.updateSelectDrag(to: PDFPointValue(x: 170, y: 150))
        canvas.endSelectDrag(at: PDFPointValue(x: 170, y: 150))
        let moved30 = await Self.eventually { await Self.ring(Self.outer(Self.stored(harness, ids.parent)), isShifted: Self.parentRing, by: 30) }
        let parentAt30 = Self.outer(await Self.stored(harness, ids.parent))
        #expect(moved30, "parent at \(parentAt30)")
        try? await Task.sleep(for: .milliseconds(200))
        parent = await Self.stored(harness, ids.parent)
        cutout = await Self.stored(harness, ids.cutout)
        #expect(Self.ring(Self.outer(cutout), isShifted: Self.holeRing, by: 30), "hole at \(Self.outer(cutout))")
        #expect(Self.value(parent, .netArea) == 8)
        #expect(!harness.core.status.warnings.contains { $0.title == "That edit was not made." })

        // One ⌘Z is the drag, both rings together.
        harness.controller.undo(nil)
        #expect(await Self.eventually { await Self.ring(Self.outer(Self.stored(harness, ids.parent)), isShifted: Self.parentRing, by: 10) })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(Self.ring(Self.outer(await Self.stored(harness, ids.cutout)), isShifted: Self.holeRing, by: 10))
    }

    @Test("X-001/X-003: the shared rule drops only a cutout whose parent is in the same set")
    func carriedCutoutRule() {
        let parent = UUID(), cutout = UUID(), other = UUID(), orphanParent = UUID(), lone = UUID()
        let parents = [cutout: parent, lone: orphanParent]
        #expect(CarriedCutouts.roots(of: [cutout, other, parent, lone]) { parents[$0] } == [other, parent, lone])
        #expect(CarriedCutouts.roots(of: [cutout]) { parents[$0] } == [cutout], "a cutout alone is what was asked for")
    }

    // MARK: - X-003 Delete of an area and its own cutout

    /// Both UUID orders. Old output when the parent's UUID sorts first: `.removeMarkup(parent)`
    /// took the cutout with it, `.removeMarkup(cutout)` threw `unknownMarkup`, the batch rolled
    /// back — nothing deleted, the selection restored, "That edit was not made." in the tray.
    @Test("X-003: Delete removes an area and its own cutout in either UUID order; one ⌘Z brings both back")
    func deleteParentAndCutout() async throws {
        let low = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000A2")!
        func removed(_ commands: [DocumentCommand]) -> [MarkupID] {
            commands.compactMap { if case .removeMarkup(let id) = $0 { id } else { nil } }
        }
        #expect(removed(ProjectWindowController.deleteCommands(for: [low, high], parents: [high: low])) == [MarkupID(low)])
        #expect(removed(ProjectWindowController.deleteCommands(for: [low, high], parents: [low: high])) == [MarkupID(high)])

        for (order, parentID, cutoutID) in [("parent first", low, high), ("cutout first", high, low)] {
            let harness = try await Fix2Harness.make("Iter7 Delete Cutout \(order).pdf")
            defer { harness.tearDown() }
            let ids = try await Self.areaWithCutout(harness, parentID: parentID, cutoutID: cutoutID)
            harness.core.canvas.select(markupIDs: [ids.parent.rawValue, ids.cutout.rawValue], additive: false)
            let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
            item.representedObject = ZPDFCommandID.deleteSelection.rawValue
            harness.controller.performZenitCommand(item)
            #expect(await Self.eventually { await harness.records().isEmpty }, "\(order): nothing was deleted")
            #expect(!harness.core.status.warnings.contains { $0.title == "That edit was not made." }, "\(order): refused")
            #expect(harness.document.undoManager?.undoActionName == "Delete 2 Markups")

            harness.controller.undo(nil)
            #expect(await Self.eventually { await harness.records().count == 2 }, "\(order): ⌘Z restored too little")
            let parent = await Self.stored(harness, ids.parent)
            #expect(parent?.cutoutMarkupIDs == [ids.cutout])
            #expect(Self.value(parent, .netArea) == 8)
        }
    }

    // MARK: - X-004 a typed length ends with its shape

    /// Polylength from (100, 300). Old output: after the double-click finish the "4" stayed —
    /// `ownsToolKey` true with no shape, the next shape's pill "4 m ⏎"; after the click on
    /// (150, 500) the Return read the stale "4" (no direction: refused, entry restored) instead
    /// of finishing the two-point shape; after the toolbar switch the "4" stayed.
    @Test("X-004: a typed length is dropped when its shape ends by double-click, a click places a point, or the tool changes")
    func typedEntryEndsWithItsShape() async throws {
        let harness = try await Fix2Harness.make("Iter7 Typed Stale.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        harness.shell.toolbar.activateMeasurement(.polylength)
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })

        // Finished by double-click with an entry half typed.
        canvas.handleClick(at: PDFPointValue(x: 100, y: 300), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 200, y: 300), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.handle(key: .typed("4")))
        #expect(canvas.typedEntry == "4")
        canvas.handleDoubleClick(at: PDFPointValue(x: 200, y: 300))
        #expect(await Self.eventually { await harness.records().contains { $0.tool == .polylength } })
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })
        canvas.refresh()
        #expect(canvas.typedEntry.isEmpty, "the entry outlived its shape")
        #expect(!canvas.ownsToolKey(characters: "c", modifiers: []), "a tool key is still held with no shape")

        // The next shape's pill does not echo the old entry, and a click supersedes a new one.
        canvas.handleClick(at: PDFPointValue(x: 100, y: 500), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.liveStateForTesting().drawing.caption?.contains("\u{23CE}") != true)
        #expect(canvas.handle(key: .typed("4")))
        canvas.handleClick(at: PDFPointValue(x: 150, y: 500), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.typedEntry.isEmpty, "the click left the entry for the next Return")
        #expect(canvas.handle(key: .finish))
        let second = await Self.eventually { await harness.records().filter { $0.tool == .polylength }.count == 2 }
        let shapes = await harness.records().filter { $0.tool == .polylength }.map { $0.geometry?.points ?? [] }
        #expect(second, "Return did not finish the shape: placed \(core.measurement.placedPoints), stored \(shapes)")
        let finished = try #require(shapes.last)
        #expect(finished.count == 2 && Self.near(finished[0], PDFPoint(x: 100, y: 500)) && Self.near(finished[1], PDFPoint(x: 150, y: 500)),
                "\(finished)")

        // A toolbar switch mid-entry.
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })
        canvas.handleClick(at: PDFPointValue(x: 100, y: 600), additive: false)
        await core.measurement.settlePlacements()
        #expect(canvas.handle(key: .typed("4")))
        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .length })
        #expect(canvas.typedEntry.isEmpty, "the entry outlived a tool switch")
    }

    // MARK: - X-005 the vertex-drag pill is the committed pill's grammar

    /// "Room 1", 3 m × 3 m. Dragging the corner (400, 400) to (500, 400) gives a trapezoid of
    /// (3 + 4) / 2 × 3 = 10.5 m², perimeter 3 + √10 + 4 + 3 ≈ 13.16 m. The live pill must read
    /// the area, exactly as the committed pill reads it after the release. Old output, measured
    /// with the fix disabled in the same build: the first field the engine wrote, the perimeter —
    /// live pill "Room 1: 13,16 m" (test locale) against the committed "Room 1: 10,50 m²".
    @Test("X-005: dragging an area's corner shows the area in the committed pill's words")
    func vertexDragPillShowsTheHeadline() async throws {
        let harness = try await Fix2Harness.make("Iter7 Vertex Pill.pdf")
        defer { harness.tearDown() }
        let area = try Self.record(harness, tool: .area, label: "Room 1") { page in
            Self.ring(Self.parentRing, page: page)
        }
        _ = try await harness.core.commands.perform(.addMarkup(area))
        await harness.settle()
        let canvas = harness.canvas
        harness.shell.perform(.selectTool)
        harness.core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        func pill() -> String? { canvas.pageViewForTesting.shapes.first { $0.id == area.id.rawValue }?.caption }
        let before = try #require(pill())
        #expect(before.hasPrefix("Room 1: 9") && before.hasSuffix("m²"), "committed pill \(before)")

        canvas.beginSelectDrag(at: PDFPointValue(x: 400, y: 400))
        canvas.updateSelectDrag(to: PDFPointValue(x: 500, y: 400))
        #expect(await AppTestSupport.wait { pill() != before }, "no live pill")
        let live = try #require(pill())
        #expect(live.hasPrefix("Room 1: 10") && live.hasSuffix("m²"), "live pill \(live)")
        #expect(!live.hasPrefix("Room 1: 13"), "the live pill showed the perimeter: \(live)")

        canvas.endSelectDrag(at: PDFPointValue(x: 500, y: 400))
        #expect(await Self.eventually {
            await Self.outer(Self.stored(harness, area.id)).contains(PDFPoint(x: 500, y: 400))
        })
        await harness.settle()
        #expect(await AppTestSupport.wait { pill() == live }, "committed \(String(describing: pill())) after live \(live)")

        // The badge and the caption choice come along: ×3 on the summary reaches the live pill.
        let summary = try #require(harness.core.canvas.visibleMarkups.first { $0.id == area.id.rawValue })
        var repeated = summary
        repeated.repeatCount = 3
        let perimeterFirst = summary.measurementFields.filter { $0.field == .perimeter }
            + summary.measurementFields.filter { $0.field != .perimeter }
        #expect(perimeterFirst.first?.field == .perimeter)
        let badged = try #require(PDFCanvasViewController.liveCaption(previewFields: perimeterFirst, committed: repeated, choice: nil))
        #expect(badged == "\(live) ×3", "\(badged)")
    }

    // MARK: - X-009 the by-name layer hide is gone

    /// The deleted path: `NavigatorLayerListModel.onSetMarkupLayerVisible` → the canvas's
    /// `setHiddenMarkupLayers`. Its rows show only while `markupLayers.isInstalled` is false,
    /// and every window installs the project's layers (ADR-0032), whose eye is `onSetVisible`.
    @Test("X-009: a window installs the project's markup layers, so the by-name Navigator rows never show")
    func projectLayersReplaceTheByNameRows() async throws {
        let harness = try await Fix2Harness.make("Iter7 Layers Installed.pdf")
        defer { harness.tearDown() }
        #expect(await AppTestSupport.wait { harness.shell.markupLayers.isInstalled })
        #expect(harness.shell.markupLayers.onSetVisible != nil, "the ADR-0032 eye is not wired")
    }
}
