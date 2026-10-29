import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Review fixes to the arc-segment canvas wiring (ADR-0030 §5.7, r2-arcs-fix), through the shipping
/// window controller and canvas. 100 pt = 1 m. No window is ordered front.
@MainActor
@Suite(.appTierSerialised)
struct ArcReviewFixAppTests {

    /// A 10 × 5 m bay (100,100)–(1100,100)–(1100,600)–(100,600) whose right side is the outward
    /// semicircle, bulge 1: centre (1100, 350), r = 250 pt, apex (1350, 350).
    private func addGoldenBay(_ harness: NLMeasureR2Harness.Harness) async throws -> MarkupID {
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let bay = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Bay", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 1100, y: 100), PDFPoint(x: 1100, y: 600), PDFPoint(x: 100, y: 600)],
                isClosed: true,
                bulges: [0, 1, 0, 0]
            ))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(bay))
        await core.refresh()
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        harness.shell.perform(.selectTool)
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [bay.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        return bay.id
    }

    /// Polls an actor-side condition, as `AppTestSupport.wait` polls a main-actor one.
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func pointCount(_ harness: NLMeasureR2Harness.Harness, _ id: MarkupID) async -> Int {
        await harness.core.session.markup(id)?.geometry?.polygons.first?.outer.points.count ?? 0
    }

    // MARK: ⌥-click on an arc (findings 16 and 17)

    /// The chord of the semicircle, x = 1100 between y = 100 and 600, has nothing drawn on it: its
    /// midpoint (1100, 350) is 250 pt from the arc. An ⌥-click there is not an edge click; on the
    /// apex (1350, 350) it is, and inserts a vertex on the curve.
    ///
    /// Old output: the click on the chord was taken (the chords between vertices were asked too),
    /// and then nothing happened and nothing was said.
    @Test("⌥-click on an arc's empty chord is not taken; on the curve it inserts a vertex")
    func optionClickOnTheChord() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Chord.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let bay = try await addGoldenBay(harness)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        #expect(!canvas.insertVertexOnSelectedEdge(at: PDFPointValue(x: 1100, y: 350)))
        #expect(canvas.insertVertexOnSelectedEdge(at: PDFPointValue(x: 1350, y: 350)))
        #expect(await eventually { await pointCount(harness, bay) == 5 })
    }

    /// A polylength (100,100) → (1100,100) ⌒ (1100,600), its second edge the semicircle bulging to
    /// +x. An ⌥-click 2 pt beyond the chain's end, (1100, 602), is nearest the arc at its end,
    /// where there is nothing to cut: refused, and the status note says why.
    ///
    /// Old output: the click was taken and nothing happened, with no note.
    @Test("⌥-click on an arc's end says why nothing was inserted")
    func optionClickOnAnArcEnd() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc End.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let chain = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .polylength, subject: "Kerb", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 1100, y: 100), PDFPoint(x: 1100, y: 600)
            ], pointBulges: [0, 1, 0]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(chain))
        await core.refresh()
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        harness.shell.perform(.selectTool)
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [chain.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        #expect(canvas.insertVertexOnSelectedEdge(at: PDFPointValue(x: 1100, y: 602)))
        #expect(await AppTestSupport.wait { core.status.snapshot.activeToolNote?.contains("end of the curve") == true },
                "\(String(describing: core.status.snapshot.activeToolNote))")
        #expect(await core.session.markup(chain.id)?.geometry?.points.count == 3)
    }

    // MARK: Delete on a vertex that ends an arc (finding 9)

    /// After a vertex is inserted at the apex, the arc is two quarter arcs; the vertex (1100, 100)
    /// joins the straight bottom edge to the first of them. Removing it is refused, with the reason.
    ///
    /// Old output: "This vertex cannot be removed: the shape would no longer be a measurement of its
    /// kind." — not the reason.
    @Test("Delete on a vertex that ends an arc names the curve as the reason")
    func deleteVertexAtAnArcEnd() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Vertex.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let bay = try await addGoldenBay(harness)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        #expect(canvas.insertVertexOnSelectedEdge(at: PDFPointValue(x: 1350, y: 350)))
        #expect(await eventually { await pointCount(harness, bay) == 5 })
        await harness.core.refresh()
        canvas.refresh()
        await canvas.settleScene()
        canvas.focusedVertex = (bay.rawValue, 1)
        #expect(canvas.removeFocusedVertex())
        #expect(await AppTestSupport.wait { harness.core.status.snapshot.activeToolNote?.contains("straight edge to a curve") == true },
                "\(String(describing: harness.core.status.snapshot.activeToolNote))")
        #expect(await pointCount(harness, bay) == 5)
    }

    // MARK: A during a two-point pick (finding 20)

    /// Calibrate is a two-point pick: its clicks go to the pick until it ends. A must not arm Area
    /// under it. Old output: the toolbar switched to Area while clicks still went to the pick.
    @Test("A during a two-point pick does not arm Area")
    func areaKeyDuringAPick() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Pick.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        harness.controller.beginCalibration(for: harness.document)
        #expect(canvas.isCalibrating)
        let before = harness.shell.toolbar.activeSelection
        #expect(canvas.handle(key: .area))
        #expect(harness.shell.toolbar.activeSelection == before)
        #expect(canvas.isCalibrating)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.core.measurement.activeKind != .area)
        #expect(canvas.ownsToolKey(characters: "a", modifiers: []), "the window's router leaves A to the canvas during the pick")
        canvas.endCalibration()
        #expect(!canvas.ownsToolKey(characters: "a", modifiers: []))
    }

    // MARK: A during a boundary capture (findings 10 and 18)

    /// A Scale Region boundary is drawn with the Area kind but straight edges. A mid-boundary does
    /// not arm an arc in the input machine, says why, and the next click is a vertex.
    ///
    /// Old output: the machine armed the arc (the presenter refused it), no note was shown, and a
    /// click landing while a placement was still resolving became a through point that was dropped.
    @Test("A during a Scale Region boundary does not arm an arc; the next click is a vertex")
    func areaKeyDuringABoundaryCapture() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Boundary.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        _ = canvas.view
        core.measurement.beginBoundaryCapture(.scaleRegion)
        canvas.refresh()
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 100))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        #expect(canvas.handle(key: .area))
        #expect(!canvas.measurementInputForTesting.state.isArcNextSegment)
        #expect(core.status.snapshot.activeToolNote?.contains("straight segments only") == true,
                "\(String(describing: core.status.snapshot.activeToolNote))")
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 600, y: 100))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        core.measurement.cancelActiveMeasurement()
    }

    // MARK: The live arc pill (finding 15)

    /// The pill's "Arc …" is observed: with no manual refresh it shows the arc's 2.5π m ≈ 7.85 m.
    /// (A guard: the old code showed it too whenever the main preview happened to land after the
    /// arc's own preview; the canvas now observes the arc field itself.)
    @Test("The live arc pill updates without a manual refresh")
    func arcPillIsObserved() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Pill.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        harness.shell.toolbar.activateMeasurement(.polylength)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 100))
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1100, y: 100))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        #expect(canvas.handle(key: .area))
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 1350, y: 350))
        #expect(await AppTestSupport.wait { core.measurement.arcThroughPoint != nil })
        core.measurement.updateLiveCursor(PDFPointValue(x: 1100, y: 600))
        await core.measurement.settlePreviewsForTesting()
        // In the session's locale, as the ledger and every committed pill (L-104): "Arc 7,85 m" on
        // a Swedish Mac, "Arc 7.85 m" in English.
        let expected = "Arc 7\(Locale.current.decimalSeparator ?? ".")85"
        #expect(await AppTestSupport.wait { canvas.liveStateForTesting().drawing.caption?.contains(expected) == true },
                "\(String(describing: canvas.liveStateForTesting().drawing.caption))")
    }

    // MARK: The context menu (finding 13)

    /// Right-click on the selected arc area offers Split Area and Curve an Edge; on its bottom edge
    /// also Insert Vertex Here, on its corner Remove Vertex; two areas offer Merge Areas.
    /// Old output: none of these rows existed.
    @Test("The context menu offers split, merge, curve and vertex edits where they apply")
    func contextMenuRows() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Menu.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let bay = try await addGoldenBay(harness)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        func titles(at point: PDFPointValue) -> [String] {
            canvas.markupContextMenu(at: point)?.items.map(\.title) ?? []
        }
        let onEdge = titles(at: PDFPointValue(x: 600, y: 100))
        #expect(onEdge.contains("Split Area"), "\(onEdge)")
        #expect(onEdge.contains("Curve an Edge"))
        #expect(onEdge.contains("Insert Vertex Here"))
        #expect(!onEdge.contains("Remove Vertex"))
        let onCorner = titles(at: PDFPointValue(x: 100, y: 100))
        #expect(onCorner.contains("Remove Vertex"), "\(onCorner)")
        #expect(!onCorner.contains("Merge Areas"))

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let other = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Bay", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 600), PDFPoint(x: 1100, y: 600), PDFPoint(x: 1100, y: 900), PDFPoint(x: 100, y: 900)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await harness.core.commands.perform(.addMarkup(other))
        await harness.core.refresh()
        harness.core.canvas.select(markupIDs: [bay.rawValue, other.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        let both = titles(at: PDFPointValue(x: 600, y: 300))
        #expect(both.contains("Merge Areas"), "\(both)")
        #expect(!both.contains("Split Area"))
    }
}
