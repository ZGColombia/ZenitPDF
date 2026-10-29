import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Quality loop, iteration 1, area app-canvas: the iteration-1 findings
/// through the shipping window controller. No window is ordered on screen and every modal goes
/// through `ZenitModalPresenter` (NLMeasureR2Harness).
@MainActor
@Suite(.appTierSerialised)
struct Iter1AppCanvasTests {

    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private static func polling<T>(_ attempts: Int = 150, _ read: () async -> T?) async -> T? {
        for _ in 0..<attempts {
            if let value = await read() { return value }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: - R-001 a cancelled pick never takes the next calibration

    /// R-001. Old output: after Pick Fall Line… and Escape, `FallLinePick.isArmed` stayed true;
    /// the next calibration's two clicks ran `FallLinePick.finish`, which set the roof's azimuth
    /// to 90°, and no scale sheet opened.
    @Test("Escape out of Pick Fall Line, then Calibrate: the clicks open the scale sheet and the slope is untouched")
    func escapedFallLineDoesNotStealCalibration() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 FallLine.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        var parameters = MeasurementParameters.default
        parameters.slope = .uniformPlane(.riseOverRun(rise: 6, run: 12))
        let roof = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .trueSlopedArea, subject: "Roof", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 172, y: 100), PDFPoint(x: 172, y: 172), PDFPoint(x: 100, y: 172)
            ]))]),
            parameters: parameters, createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        try await core.commands.perform(.addMarkup(roof))
        let canvas = try #require(harness.controller.canvasController(for: harness.document))

        harness.shell.inspectorEditing.onPickFallLine?([roof.id.rawValue])
        #expect(FallLinePick.isArmed(harness.document))
        #expect(canvas.isCalibrating)
        // Escape: the calibration machine cancels and the flow ends uncollected.
        #expect(canvas.handle(key: .escape))
        #expect(!canvas.isCalibrating)
        #expect(!PendingPointPicks.anyArmed(harness.document), "Escape left a pick armed")

        harness.controller.beginPageCalibration(for: harness.document)
        harness.controller.finishCalibration(
            points: [PDFPointValue(x: 120, y: 110), PDFPointValue(x: 120, y: 160)],
            for: harness.document
        )
        #expect(ScaleSheetCoordinator.active(for: harness.document) != nil, "the calibration's clicks opened no scale sheet")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.session.markup(roof.id)?.parameters?.slope.azimuth == nil, "the stale fall line set a direction")
    }

    /// R-001. Old output: `FencePick` and `CurveEdgePick` had no disarm, so arming Pick Fall Line
    /// after Draw Fence Line left both armed, and the fence (checked first) took the fall line's
    /// clicks.
    @Test("Arming one borrowed pick disarms the others; ending an uncollected calibration disarms all")
    func picksAreExclusive() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 Picks.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let document = harness.document
        let canvas = try #require(harness.controller.canvasController(for: document))

        harness.controller.beginFenceLine(for: document)
        #expect(FencePick.isArmed(document))
        FallLinePick.arm(document, markups: [UUID()])
        #expect(FallLinePick.isArmed(document))
        #expect(!FencePick.isArmed(document), "a fence line armed before still shadows the fall line")
        CurveEdgePick.arm(document, markup: UUID())
        #expect(CurveEdgePick.isArmed(document) && !FallLinePick.isArmed(document))

        canvas.endCalibration(collected: false)
        #expect(!PendingPointPicks.anyArmed(document))

        harness.controller.beginFenceLine(for: document)
        #expect(FencePick.isArmed(document))
        // The toolbar's Calibrate (beginPageCalibration) is the page's calibration, never a pick's.
        harness.controller.beginPageCalibration(for: document)
        #expect(!FencePick.isArmed(document))
        canvas.endCalibration(collected: false)
    }

    /// R-001 (re-fix), the two calibration doors that bypassed the rule. Old output: after
    /// Inspector ▸ Pick Fall Line… (no Escape), Scale Regions ▸ Calibrate and the scale sheet's
    /// Pick points both called `beginCalibration(for:)` with the fall line still armed, and
    /// `finishCalibration` served it first — the roof's azimuth became 90° and the region's
    /// sheet opened with no line, or the stepped-aside sheet never got its points.
    @Test("Pick Fall Line, then Scale Regions ▸ Calibrate or the sheet's Pick points: the clicks go to the scale, the slope is untouched")
    func regionAndSheetCalibrationDisarmPicks() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 FallLine Doors.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let document = harness.document
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        await core.refresh()
        var parameters = MeasurementParameters.default
        parameters.slope = .uniformPlane(.riseOverRun(rise: 6, run: 12))
        let roof = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .trueSlopedArea, subject: "Roof", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 172, y: 100), PDFPoint(x: 172, y: 172), PDFPoint(x: 100, y: 172)
            ]))]),
            parameters: parameters, createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        try await core.commands.perform(.addMarkup(roof))
        let points = [PDFPointValue(x: 120, y: 110), PDFPointValue(x: 120, y: 160)]

        // 1. Scale Regions ▸ Calibrate (the region door, `document.onBeginCalibration`).
        harness.shell.inspectorEditing.onPickFallLine?([roof.id.rawValue])
        #expect(FallLinePick.isArmed(document))
        let regionID = UUID()
        let calibrateRegion = try #require(harness.shell.scaleRegions.onCalibrateRegion)
        calibrateRegion(regionID)
        #expect(document.pendingScaleCalibration == .region(regionID))
        #expect(!PendingPointPicks.anyArmed(document), "the region's calibration left the fall line armed")
        harness.controller.finishCalibration(points: points, for: document)
        let regionSheet = try #require(ScaleSheetCoordinator.active(for: document), "the region's clicks opened no scale sheet")
        #expect(regionSheet.model.draft.primary.start == points[0] && regionSheet.model.draft.primary.end == points[1])
        #expect(document.pendingScaleCalibration == .region(regionID), "the region lost its destination")
        regionSheet.cancel()

        // 2. Measure ▸ Calibrate Scale… ▸ Pick points (the sheet door, `beginPicking`).
        harness.shell.inspectorEditing.onPickFallLine?([roof.id.rawValue])
        #expect(FallLinePick.isArmed(document))
        harness.controller.presentPageScaleSheet(for: document)
        let sheet = try #require(ScaleSheetCoordinator.active(for: document))
        #expect(sheet !== regionSheet)
        sheet.model.onPickPoint(.primaryStart)
        #expect(sheet.pendingPick == .primaryStart)
        #expect(!PendingPointPicks.anyArmed(document), "Pick points left the fall line armed")
        harness.controller.finishCalibration(points: points, for: document)
        #expect(sheet.pendingPick == nil, "the sheet never received its points")
        #expect(sheet.model.draft.primary.start == points[0] && sheet.model.draft.primary.end == points[1])
        sheet.cancel()

        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.session.markup(roof.id)?.parameters?.slope.azimuth == nil, "a stale fall line set a direction")
        harness.controller.canvasController(for: document)?.endCalibration(collected: false)
    }

    // MARK: - R-014 Curve an Edge's tolerance is a screen distance

    /// 100 pt = 1 m. R-014. Old output: the tolerance was 12 page points at every zoom, so at
    /// 400 % a first click 10 pt (40 screen points) off the edge still curved it, and at 25 % a
    /// click 20 pt (5 screen points) off it was refused.
    @Test("Curve an Edge: 8 view points at 400 % and at 25 %")
    func curveEdgeToleranceFollowsZoom() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 Arc Tolerance.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
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
        core.canvas.select(markupIDs: [bay.id.rawValue], additive: false)

        // 400 %: 8 view points are 2 page points; a click 10 pt off the right side is refused.
        core.canvas.setZoom(4)
        let zoomedIn = core.canvas.viewport.zoom
        harness.controller.beginCurveEdge(for: harness.document)
        let tight = try #require(CurveEdgePick.armedTolerance(harness.document))
        #expect(Swift.abs(tight - 8 / zoomedIn) < 1e-9)
        await CurveEdgePick.finish(points: [PDFPointValue(x: 1110, y: 350), PDFPointValue(x: 1350, y: 350)], document: harness.document)
        let untouched = NSDecimalNumber(decimal: try #require(await core.session.markup(bay.id)?.measurement?[.netArea]?.value)).doubleValue
        #expect(Swift.abs(untouched - 50) <= 50 * 1e-12, "a click 40 screen points away curved the edge")

        // 25 %: 8 view points are 32 page points; a click 20 pt off it curves the edge.
        core.canvas.setZoom(0.25)
        let zoomedOut = core.canvas.viewport.zoom
        harness.controller.beginCurveEdge(for: harness.document)
        let loose = try #require(CurveEdgePick.armedTolerance(harness.document))
        #expect(Swift.abs(loose - 8 / zoomedOut) < 1e-9)
        await CurveEdgePick.finish(points: [PDFPointValue(x: 1120, y: 350), PDFPointValue(x: 1350, y: 350)], document: harness.document)
        let curved = NSDecimalNumber(decimal: try #require(await core.session.markup(bay.id)?.measurement?[.netArea]?.value)).doubleValue
        let expected = 50 + 3.125 * Double.pi
        #expect(Swift.abs(curved - expected) <= expected * 1e-12, "a click 5 screen points away was refused")
        harness.controller.canvasController(for: harness.document)?.endCalibration(collected: false)
    }

    // MARK: - R-002 / R-013 typed segments

    /// A sheet at 1:100 with a 1:50 Scale Region over its top-left 800 × 800 pt.
    ///
    /// Hand-derived: at 1:50 one inch of paper (72 pt) is 25.4 mm × 50 = 1.27 m, so 4.2 m is
    /// 4.2 / 1.27 × 72 = 238.110236… pt. R-002. Old output: the entry was converted at the
    /// page's 1:100 (72 pt = 2.54 m, so 119.055 pt), the commit measured it inside the region at
    /// 1:50, and the ledger said 2.1 m.
    @Test("A typed 4,2 inside a 1:50 region on a 1:100 sheet commits a 4.2 m Length")
    func typedLengthUsesTheRegionScale() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 Typed Region.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        let detail = ScaleID(UUID())
        try await core.commands.calibrate(
            page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 72, y: 0),
            knownLength: Decimal(string: "1.27")!, knownLengthUnit: .metre, scaleID: detail
        )
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: harness.page, name: "Detail",
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 800, y: 0), PDFPoint(x: 800, y: 800), PDFPoint(x: 0, y: 800)],
            scaleID: detail, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
        try await core.commands.perform(.setScaleRegions([region]))
        await core.refresh()

        harness.shell.toolbar.activateMeasurement(.length)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .length })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        for character in "4,2<0" { #expect(canvas.handle(key: .typed(character))) }
        #expect(canvas.handle(key: .finish))

        let committed = await Self.polling {
            await core.session.orderedMarkups.first { $0.tool == .length }
        }
        let record = try #require(committed, "no Length was committed; note: \(String(describing: core.status.snapshot.activeToolNote))")
        #expect(record.scaleRegionID == region.id)
        let length = NSDecimalNumber(decimal: try #require(record.measurement?[.planLength]?.value)).doubleValue
        #expect(Swift.abs(length - 4.2) <= 4.2 * 1e-9, "committed \(length) m for a typed 4.2 m")
        let end = try #require(record.geometry?.points.last)
        #expect(Swift.abs(end.x - (100 + 4.2 / 1.27 * 72)) < 1e-6)

        // The anchor on the page default converts at 1:100.
        let pageScale = await canvas.typedEntryScale(page: harness.page, at: PDFPoint(x: 1200, y: 1200))
        let regionScale = await canvas.typedEntryScale(page: harness.page, at: PDFPoint(x: 100, y: 300))
        guard case .scale(let outside) = pageScale, case .scale(let inside) = regionScale else {
            Issue.record("expected a scale on both sides, got \(pageScale) and \(regionScale)")
            return
        }
        #expect(inside.id == detail)
        #expect(outside.id != detail)
    }

    /// 1:100 → 72 pt = 2.54 m. R-013. Old output: the entry was cleared only after the session
    /// answered, so a second Return in that window placed the same vertex again — a polylength
    /// of (100, 300), (172, 300), (172, 300) and no finish.
    @Test("Two Returns on a typed segment place one vertex, then finish the shape")
    func doubleReturnPlacesOneVertex() async throws {
        let harness = try await NLMeasureR2Harness.make("Iter1 Typed Twice.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        harness.shell.toolbar.activateMeasurement(.polylength)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        for character in "2,54<0" { _ = canvas.handle(key: .typed(character)) }
        // Both Returns arrive before the session actor answers the first.
        #expect(canvas.handle(key: .finish))
        #expect(canvas.typedEntry.isEmpty, "the entry is consumed by the first Return")
        #expect(canvas.handle(key: .finish))

        let committed = await Self.polling {
            await core.session.orderedMarkups.first { $0.tool == .polylength }
        }
        let record = try #require(committed, "the second Return did not finish the shape")
        #expect(record.geometry?.points == [PDFPoint(x: 100, y: 300), PDFPoint(x: 172, y: 300)])
        let length = NSDecimalNumber(decimal: try #require(record.measurement?[.planLength]?.value)).doubleValue
        #expect(Swift.abs(length - 2.54) <= 2.54 * 1e-9)
    }

    // MARK: - R-003 / R-004 context menu

    private func openMarkupWindow(_ name: String) async throws -> (NLMeasureR2Harness.Harness, PDFCanvasViewController) {
        let harness = try await NLMeasureR2Harness.make(name)
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        harness.shell.perform(.selectTool)
        return (harness, canvas)
    }

    private func markup(
        _ kind: ZPDFContracts.MarkupKind, _ points: [PDFPoint], caption: String, rotation: Double? = nil,
        harness: NLMeasureR2Harness.Harness
    ) -> ZPDFContracts.MarkupRecord {
        var style = MarkupStyle()
        style.rotationDegrees = rotation
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: kind, style: style, caption: caption,
            geometry: MeasurementGeometry(pageID: harness.page, points: points),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
    }

    /// A rectangle markup, stored as its closed ring (the markup family's own schema).
    private func rectangle(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double, harness: NLMeasureR2Harness.Harness) -> ZPDFContracts.MarkupRecord {
        let ring = [PDFPoint(x: minX, y: minY), PDFPoint(x: maxX, y: minY), PDFPoint(x: maxX, y: maxY), PDFPoint(x: minX, y: maxY)]
        return ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(harness.core.snapshot.documentID), pageID: harness.page,
            kind: .rectangle,
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
    }

    /// A callout whose tip is far below its box, and a text box where the centre of the callout's
    /// bounds falls. R-003. Old output: Edit Text re-hit-tested (160, 375), the centre of the
    /// callout's bounds, and opened the editor on the text box there — or, with no text box,
    /// on nothing at all.
    @Test("Context menu Edit Text on a callout edits that callout, whatever lies at its centre")
    func editTextEditsTheRightClickedCallout() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Callout.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let callout = markup(.callout, [PDFPoint(x: 100, y: 100), PDFPoint(x: 120, y: 600), PDFPoint(x: 220, y: 650)], caption: "Callout words", harness: harness)
        let text = markup(.text, [PDFPoint(x: 140, y: 360), PDFPoint(x: 180, y: 390)], caption: "Other", harness: harness)
        try await core.commands.perform(.addMarkup(callout))
        try await core.commands.perform(.addMarkup(text))
        await core.refresh()
        core.canvas.setZoom(1)
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [callout.id.rawValue], additive: false)

        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 170, y: 625)))
        let edit = try #require(menu.items.first { $0.title == "Edit Text" } as? ContextMenuItem)
        #expect(NSApplication.shared.sendAction(try #require(edit.action), to: edit.target, from: edit))
        #expect(canvas.activeTextEntry?.editing == callout.id.rawValue,
                "the editor opened on \(String(describing: canvas.activeTextEntry?.editing)), not the callout")
        canvas.finishInPlaceTextEdit(commit: false)
    }

    /// R-004. Old output: both boxes ended at 90° — the selection's angles differed, so the
    /// items sent 0° + 90° to every markup as one absolute value.
    @Test("Rotate 90° Left turns boxes at 0° and 30° to 90° and 120°, as one undo step")
    func rotateIsRelativePerMarkup() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Rotate.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let upright = markup(.text, [PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 130)], caption: "One", harness: harness)
        let turned = markup(.text, [PDFPoint(x: 300, y: 300), PDFPoint(x: 420, y: 330)], caption: "Two", rotation: 30, harness: harness)
        try await core.commands.perform(.addMarkup(upright))
        try await core.commands.perform(.addMarkup(turned))
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [upright.id.rawValue, turned.id.rawValue], additive: false)
        #expect(await AppTestSupport.wait { core.canvas.selectedMarkupIDs.count == 2 })

        let menu = try #require(canvas.markupContextMenu(at: PDFPointValue(x: 150, y: 115)))
        let rotate = try #require(menu.items.first { $0.title == "Rotate" }?.submenu)
        let left = try #require(rotate.items.first { $0.title == "Rotate 90° Left" } as? ContextMenuItem)
        #expect(NSApplication.shared.sendAction(try #require(left.action), to: left.target, from: left))
        let angles = await Self.polling { () -> (Double?, Double?)? in
            let a = await core.session.markup(upright.id)?.style.rotationDegrees
            let b = await core.session.markup(turned.id)?.style.rotationDegrees
            return a == nil ? nil : (a, b)
        }
        let (first, second) = try #require(angles)
        #expect(first == 90)
        #expect(second == 120, "the 30° box ended at \(String(describing: second))°")
        #expect(harness.document.undoManager?.undoActionName == "Rotate")
        await core.commands.undo()
        #expect(await core.session.markup(upright.id)?.style.rotationDegrees == nil)
        #expect(await core.session.markup(turned.id)?.style.rotationDegrees == 30)
    }

    @Test("Folding an angle: 360° and 0° are no rotation, −90° is 270°")
    func foldedRotation() {
        #expect(PDFCanvasViewController.foldedRotation(360) == nil)
        #expect(PDFCanvasViewController.foldedRotation(0) == nil)
        #expect(PDFCanvasViewController.foldedRotation(-90) == 270)
        #expect(PDFCanvasViewController.foldedRotation(30 + 180) == 210)
    }

    // MARK: - R-006 one layer pass per gesture edge

    /// R-006. Old output: 2 — the `transform` and `liveDisplayTransform` didSets re-stacked the
    /// layers directly, so a raster batch could not defer them.
    @Test("Inside a raster batch, a new transform and entering a gesture re-stack the layers once")
    func rasterBatchDefersTransformSyncs() {
        let pageView = CanvasPageView()
        let layers = CanvasRasterLayerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pageView.rasterLayerView = layers
        pageView.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 1, origin: .zero
        )
        let before = layers.updateCount
        pageView.performRasterBatch {
            pageView.liveDisplayTransform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            pageView.transform = PageDisplayTransform(
                pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 2, origin: .zero
            )
        }
        #expect(layers.updateCount - before == 1)
        // Outside a batch each still re-stacks at once.
        pageView.liveDisplayTransform = nil
        #expect(layers.updateCount - before == 2)
    }

    // MARK: - K-14 a gesture's first frame reuses the display link

    /// K-14 (re-fix). The gesture replay's began-frame breakdown put the display link's creation
    /// at 0.13–2.14 ms in a debug build — the largest, most variable part of every gesture's
    /// first frame, and the whole of the slowest Z11 frames (3.157 ms, 2.143 of it the link).
    /// Old output: one `CADisplayLink` made per gesture and invalidated at its end, so three
    /// gestures made three links.
    @Test("Three pinches on one canvas make one display link, paused between them")
    func gesturesReuseOneDisplayLink() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Display Link.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        await canvas.settleScene()
        let scrollView = canvas.scrollViewForTesting
        let anchor = scrollView.convert(NSPoint(x: scrollView.contentSize.width / 2, y: scrollView.contentSize.height / 2), to: nil)
        let clock = canvas.frameClock
        #expect(clock.linkCreationCount == 0 && !clock.isRunning)
        for gesture in 0..<3 {
            let factor = gesture.isMultiple(of: 2) ? 1.1 : 1 / 1.1
            scrollView.handleZoomGesture(factor: factor, windowPoint: anchor, phase: .began)
            #expect(canvas.liveZoom != nil, "gesture \(gesture) did not go live")
            #expect(clock.isRunning, "gesture \(gesture) has no running display link")
            scrollView.handleZoomGesture(factor: factor, windowPoint: anchor, phase: .changed)
            scrollView.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
            #expect(canvas.liveZoom == nil)
            #expect(!clock.isRunning, "the link still runs after gesture \(gesture) ended")
        }
        #expect(clock.linkCreationCount == 1, "\(clock.linkCreationCount) display links for three gestures")
        // Leaving the screen gives the link back; the next gesture on screen makes one.
        clock.invalidate()
        #expect(!clock.isRunning)
        scrollView.handleZoomGesture(factor: 1.1, windowPoint: anchor, phase: .began)
        #expect(clock.isRunning && clock.linkCreationCount == 2)
        scrollView.handleZoomGesture(factor: 1, windowPoint: anchor, phase: .ended)
        #expect(!clock.isRunning)
    }

    // MARK: - K-14 level-tile layers are budgeted per frame

    private static func tile(_ index: Int) -> PageRaster {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let column = Double(index % 10), row = Double(index / 10)
        return PageRaster(
            image: context.makeImage()!,
            coverage: .region(PDFRectValue(x: column * 40, y: row * 40, width: 40, height: 40)),
            scale: 2
        )
    }

    /// K-14. The gesture replay's slowest frames were each gesture's first: about a hundred level
    /// tiles, whose layers the settled page had dropped, were created and given contents in one
    /// layer pass. Old output: all 40 layers created by the first update (deferredLayerCount did
    /// not exist). Now 16 per pass, and the rest on the next passes, nothing lost.
    @Test("A layer pass creates at most 16 level-tile layers; the rest come on the next passes")
    func levelLayersAreBudgeted() {
        let pageView = CanvasPageView()
        let layers = CanvasRasterLayerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pageView.rasterLayerView = layers
        pageView.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 400, height: 160), rotation: 0, zoom: 1, origin: .zero
        )
        let tiles = (0..<40).map(Self.tile)
        let before = layers.contentsAssignmentCount
        pageView.levelTileRasters = tiles
        #expect(layers.contentsAssignmentCount - before == CanvasRasterLayerView.levelLayerBudgetPerUpdate)
        #expect(layers.deferredLayerCount == 40 - 16)
        pageView.flushDeferredRasterLayers()
        #expect(layers.deferredLayerCount == 40 - 32)
        pageView.flushDeferredRasterLayers()
        #expect(layers.deferredLayerCount == 0)
        #expect(layers.contentsAssignmentCount - before == 40)
        #expect(layers.displayed.filter { $0.role == .level }.count == 40)
        // Nothing held back: a flush is not a layer pass.
        let passes = layers.updateCount
        pageView.flushDeferredRasterLayers()
        #expect(layers.updateCount == passes)
    }

    // MARK: - R-007 the drag path does not rebuild the hidden set

    /// R-007. Old output: every drag frame rebuilt the hidden set from every markup in the
    /// project (three allocations, O(all markups) per pointer event); there was no cache.
    @Test("Twenty Select-drag frames compute the scene's hidden set at most once")
    func dragFramesReuseTheHiddenSet() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Drag.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let box = rectangle(100, 100, 200, 180, harness: harness)
        try await core.commands.perform(.addMarkup(box))
        await core.refresh()
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [box.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        canvas.handleDragBegan(at: PDFPointValue(x: 150, y: 140))
        canvas.handleDragMoved(to: PDFPointValue(x: 151, y: 141))
        let before = canvas.sceneHiddenComputationCountForTesting
        for step in 2..<22 {
            canvas.handleDragMoved(to: PDFPointValue(x: 150 + Double(step), y: 140 + Double(step)))
        }
        #expect(canvas.sceneHiddenComputationCountForTesting - before <= 1)
        canvas.handleDragEnded(at: PDFPointValue(x: 171, y: 161))
        // The frames were a real move drag: the release moved the box by (21, 21).
        let moved = await Self.polling {
            await core.session.markup(box.id)?.geometry?.polygons.first?.outer.points.first.flatMap { $0.x == 100 ? nil : $0 }
        }
        #expect(moved == PDFPoint(x: 121, y: 121))
    }

    // MARK: - R-008 segment labels in a Scale Region

    /// Page at 0.005 m/pt both ways; the region at 0.01 m/pt across and 0.02 m/pt down. A
    /// polylength (0,0) → (100,0) → (100,100) measured in the region has segments of
    /// 100 × 0.01 = 1 m and 100 × 0.02 = 2 m (hand-derived). R-008. Old output: 0.5 m and 0.5 m —
    /// the page's factors, which are uniform, decided the path.
    @Test("Segment labels of a markup measured in a region use the region's X/Y factors")
    func segmentLabelsUseTheRegionScale() {
        let page = PageID(UUID())
        let region = ScaleRegionID(UUID())
        var style = MarkupStyle()
        style.measurementCaption = MeasurementCaption(showsSegmentLengths: true)
        var record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .polylength,
            style: style,
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100)]),
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        record.scaleRegionID = region
        let labelling = CanvasSegmentLabelling(
            metresPerPoint: (0.005, 0.005),
            regionMetresPerPoint: [region.rawValue: (0.01, 0.02)],
            format: { "\($0)" }
        )
        let labels = CanvasSceneBuilder.segmentLabels(for: record, labelling: labelling).map(\.text)
        #expect(labels.count == 2)
        let values = labels.compactMap { Double($0) }
        #expect(values.count == 2 && Swift.abs(values[0] - 1) < 1e-9 && Swift.abs(values[1] - 2) < 1e-9, "\(labels)")
        // A markup on the page default still reads the page's factors.
        record.scaleRegionID = nil
        let pageLabels = CanvasSceneBuilder.segmentLabels(for: record, labelling: labelling).compactMap { Double($0.text) }
        #expect(pageLabels.count == 2 && pageLabels.allSatisfy { Swift.abs($0 - 0.5) < 1e-9 })
    }

    // MARK: - R-010 the link cursor

    /// R-010. Old output: the pointing hand stayed after the pointer left the link, and it was
    /// shown while calibrating, when a click places a calibration point.
    @Test("The link hand appears over a drawing link and goes when the pointer leaves it")
    func linkCursorFollowsThePointer() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Link.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        canvas.onFollowLink = { _ in }
        let key = try #require(canvas.currentRasterKey)
        canvas.drawingLinksByPage[key] = [DrawingLink(bounds: CGRect(x: 600, y: 600, width: 80, height: 30), target: .page(1))]
        canvas.handlePointerMove(PDFPointValue(x: 640, y: 615))
        #expect(canvas.isOverDrawingLink)
        #expect(NSCursor.current == NSCursor.pointingHand)
        canvas.handlePointerMove(PDFPointValue(x: 900, y: 900))
        #expect(!canvas.isOverDrawingLink)
        #expect(NSCursor.current != NSCursor.pointingHand, "the link hand stuck after leaving the link")

        canvas.beginCalibration()
        canvas.handlePointerMove(PDFPointValue(x: 640, y: 615))
        #expect(!canvas.isOverDrawingLink, "a calibration click is not a link click")
        canvas.endCalibration(collected: false)
    }

    // MARK: - R-011 / R-012 caption frames and the count cull pad

    /// R-011. Old output: the frame survived both changes, so a press where the caption used to
    /// be started a caption drag.
    @Test("Caption hit frames go with the transform and the shape list they were drawn under")
    func captionFramesAreCleared() {
        let view = CanvasPageView()
        let id = UUID()
        view.transform = PageDisplayTransform(pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 1, origin: .zero)
        view.captionFrames[id] = CGRect(x: 10, y: 10, width: 40, height: 12)
        #expect(view.captionHit(at: CGPoint(x: 20, y: 15), among: [id]) == id)
        view.transform = PageDisplayTransform(pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: 2, origin: .zero)
        #expect(view.captionHit(at: CGPoint(x: 20, y: 15), among: [id]) == nil)
        view.captionFrames[id] = CGRect(x: 10, y: 10, width: 40, height: 12)
        view.shapes = [CanvasMarkupShape(
            id: id, pageID: UUID(), color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [], counts: [], bounds: PDFRectValue(x: 0, y: 0, width: 10, height: 10), hidden: false
        )]
        #expect(view.captionFrames.isEmpty)
    }

    /// At 1600 % the number "12" is drawn 80 pt right of and above its mark in a 112 pt face.
    /// R-012. Old output: the pad was max(48, stroke·2 + 24, 32) ≈ 56 view points, so the number's
    /// box lay outside the padded bounds and a partial redraw culled it.
    @Test("A numbered count's padded bounds hold its number at 1600 %")
    func countNumberInsideCullPad() {
        let zoom: CGFloat = 16
        let transform = PageDisplayTransform(pageBox: PDFRectValue(x: 0, y: 0, width: 600, height: 400), rotation: 0, zoom: Double(zoom), origin: .zero)
        let mark = PDFPointValue(x: 100, y: 100)
        var shape = CanvasMarkupShape(
            id: UUID(), pageID: UUID(), color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [], counts: [mark], bounds: PDFRectValue(x: 99, y: 99, width: 2, height: 2), hidden: false
        )
        shape.countNumbers = [12]
        let padded = CanvasPageView.paddedViewBounds(of: shape, transform: transform)
        // The number's backing box, exactly as CanvasCountNumbers.drawNumber lays it out.
        let size = max(8, 7 * zoom)
        let text = "12" as NSString
        let textSize = text.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)])
        let offset = max(5, 5 * zoom)
        let point = transform.viewPoint(from: mark)
        let origin = CGPoint(x: point.x + offset, y: point.y - offset - textSize.height)
        let backing = CGRect(origin: origin, size: textSize).insetBy(dx: -2, dy: -1)
        #expect(padded.contains(backing), "padded \(padded) does not hold the number \(backing)")
    }

    // MARK: - K-09 layer order is draw order (ADR-0036)

    private func onLayer(_ record: ZPDFContracts.MarkupRecord, _ layer: LayerID) -> ZPDFContracts.MarkupRecord {
        var placed = record
        placed.layerID = layer
        return placed
    }

    /// Two overlapping rectangles: A (drawn first) on "Dimensions" at the top of the list, B on
    /// the default layer below it. K-09. Old output: B drew over A and took the click at their
    /// shared corner (300, 150) on the canvas and in the flattened export, because draw order was
    /// the document's markup order [A, B] whatever the layers.
    @Test("A layer's place in the list stacks its markups on the canvas, in the hit test and in the export")
    func layerOrderIsDrawOrder() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Layer Order.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let dimensions = MarkupLayer(id: LayerID(UUID()), name: "Dimensions", order: 0)
        var base = MarkupLayer.makeDefault()
        base.order = 1
        try await core.commands.perform(.setMarkupLayers([dimensions, base], change: .add))
        let a = onLayer(rectangle(100, 100, 300, 300, harness: harness), dimensions.id)
        let b = onLayer(rectangle(150, 150, 350, 350, harness: harness), MarkupLayer.defaultID)
        try await core.commands.perform(.addMarkup(a))
        try await core.commands.perform(.addMarkup(b))
        await core.refresh()
        core.canvas.setZoom(1)
        canvas.refresh()
        await canvas.settleScene()

        // Stored and listed order is the markup order; draw order puts the upper layer last.
        #expect(await core.session.orderedMarkups.map(\.id) == [a.id, b.id])
        #expect(await core.session.drawOrderedMarkups.map(\.id) == [b.id, a.id])
        #expect(await core.session.effectiveMarkups.map(\.id) == [b.id, a.id])
        let drawn = canvas.pageViewForTesting.shapes.map(\.id).filter { $0 == a.id.rawValue || $0 == b.id.rawValue }
        #expect(drawn == [b.id.rawValue, a.id.rawValue], "the canvas drew \(drawn)")
        #expect(canvas.hitTest(PDFPointValue(x: 300, y: 150)) == a.id.rawValue, "the lower layer took the click")

        // Print and every export read the same order.
        let job = try await FlattenedDrawingExport.job(for: harness.document)
        let exported = try #require(job.pages.first).markups.map(\.id)
        let aIndex = try #require(exported.firstIndex(of: a.id)), bIndex = try #require(exported.firstIndex(of: b.id))
        #expect(aIndex > bIndex, "the export painted the lower layer over the upper")
        // The review exchange too (K-09 re-fix). Old output: XFDF wrote `orderedMarkups`, A then B,
        // so a reader stacked the lower layer's B over A.
        let xfdf = String(decoding: await core.exportXFDF(drawingName: "Iter1 Layer Order.pdf", drawingDigest: nil), as: UTF8.self)
        let aName = try #require(xfdf.range(of: "name=\"\(a.id.rawValue.uuidString)\""), "A is missing from the XFDF")
        let bName = try #require(xfdf.range(of: "name=\"\(b.id.rawValue.uuidString)\""), "B is missing from the XFDF")
        #expect(bName.lowerBound < aName.lowerBound, "the XFDF wrote the upper layer's annotation below the lower one's")

        // Moving Dimensions below the default layer restacks the canvas; no markup changed.
        var lowered = dimensions
        lowered.order = 1
        base.order = 0
        try await core.commands.perform(.setMarkupLayers([base, lowered], change: .reorder))
        await core.refresh()
        #expect(await AppTestSupport.wait {
            canvas.refresh()
            let order = canvas.pageViewForTesting.shapes.map(\.id).filter { $0 == a.id.rawValue || $0 == b.id.rawValue }
            return order == [a.id.rawValue, b.id.rawValue]
        }, "reordering the layers did not restack the canvas")
        await canvas.settleScene()
        #expect(canvas.hitTest(PDFPointValue(x: 300, y: 150)) == b.id.rawValue)
        #expect(await core.session.orderedMarkups.map(\.id) == [a.id, b.id])
    }

    /// Document order [B, A, C] with A alone on the upper layer and B, C on the default layer.
    /// K-09. Old output: Bring Forward on B swapped it with A — another layer — giving [A, B, C],
    /// under which B still drew below C: the command changed nothing anyone could see.
    @Test("Bring Forward moves a markup above the next markup of its own layer")
    func arrangeStaysInItsLayer() async throws {
        let (harness, _) = try await openMarkupWindow("Iter1 Arrange Layer.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let upper = MarkupLayer(id: LayerID(UUID()), name: "Upper", order: 0)
        var base = MarkupLayer.makeDefault()
        base.order = 1
        try await core.commands.perform(.setMarkupLayers([upper, base], change: .add))
        let b = onLayer(rectangle(100, 100, 200, 200, harness: harness), MarkupLayer.defaultID)
        let a = onLayer(rectangle(120, 120, 220, 220, harness: harness), upper.id)
        let c = onLayer(rectangle(140, 140, 240, 240, harness: harness), MarkupLayer.defaultID)
        for record in [b, a, c] { try await core.commands.perform(.addMarkup(record)) }
        #expect(await core.session.drawOrderedMarkups.map(\.id) == [b.id, c.id, a.id])

        try await core.commands.perform(.arrangeMarkups(ids: [b.id], arrangement: .bringForward))
        #expect(await core.session.orderedMarkups.map(\.id) == [c.id, a.id, b.id])
        #expect(await core.session.drawOrderedMarkups.map(\.id) == [c.id, b.id, a.id], "B did not rise above C")
        await core.commands.undo()
        #expect(await core.session.orderedMarkups.map(\.id) == [b.id, a.id, c.id])
    }

    // MARK: - K-13 Mouse wheel zooms

    /// K-13 (NL-UX-14). Old output: no such preference; a plain wheel notch always scrolled.
    @Test("Mouse wheel zooms: the rule, the stored preference and the Settings checkbox")
    func wheelZoomsPreference() {
        // A phase-less coarse notch zooms under the preference; a trackpad, Shift or no delta does not.
        #expect(ZenitCanvasScrollView.plainWheelZooms(phase: [], momentumPhase: [], precise: false, shiftHeld: false, scrollingDeltaY: 3, preference: true))
        #expect(!ZenitCanvasScrollView.plainWheelZooms(phase: [], momentumPhase: [], precise: false, shiftHeld: false, scrollingDeltaY: 3, preference: false))
        #expect(!ZenitCanvasScrollView.plainWheelZooms(phase: [], momentumPhase: [], precise: true, shiftHeld: false, scrollingDeltaY: 3, preference: true))
        #expect(!ZenitCanvasScrollView.plainWheelZooms(phase: .changed, momentumPhase: [], precise: false, shiftHeld: false, scrollingDeltaY: 3, preference: true))
        #expect(!ZenitCanvasScrollView.plainWheelZooms(phase: [], momentumPhase: [], precise: false, shiftHeld: true, scrollingDeltaY: 3, preference: true))
        #expect(!ZenitCanvasScrollView.plainWheelZooms(phase: [], momentumPhase: [], precise: false, shiftHeld: false, scrollingDeltaY: 0, preference: true))
        let wheel = ZenitCanvasScrollView.zoomDecision(
            phaseBegan: false, isGestureEvent: false, isMomentum: false, commandHeld: false,
            sequenceWasZoom: false, plainWheelZooms: true
        )
        #expect(wheel.zooming && !wheel.sequenceWasZoom)
        // A trackpad sequence is decided by ⌘ alone, whatever the preference.
        let trackpad = ZenitCanvasScrollView.zoomDecision(
            phaseBegan: true, isGestureEvent: true, isMomentum: false, commandHeld: false,
            sequenceWasZoom: false, plainWheelZooms: true
        )
        #expect(!trackpad.zooming)

        // A blob an older build stored (with the retired haptics key) keeps its smart-zoom level.
        let old = Data(#"{"snapHaptics":true,"smartZoomLevel":3}"#.utf8)
        let decoded = try? JSONDecoder().decode(ZenitCanvasPreferences.self, from: old)
        #expect(decoded == ZenitCanvasPreferences(smartZoomLevel: 3, wheelZooms: false))

        // The checkbox is in Settings ▸ Canvas, wired to its action, and writes the preference.
        // (The window is built, never ordered in.)
        let saved = ZenitCanvasPreferences.current
        defer { ZenitCanvasPreferences.current = saved }
        let settings = ZenitSettingsWindowController.shared
        // K-13 (re-fix). Old output, in the full suite: the checkbox was one `static let` that every
        // controller's Canvas section moved into its own window, so a private controller built
        // after `.shared` (DesignD8WindowWiringTests and Live8AppShellTests make their own) took it
        // out of the Settings window and re-targeted it — `box.window === settings.window` failed
        // depending on test order. Built here on purpose, after `.shared`.
        let privateSettings = ZenitSettingsWindowController()
        let box = settings.wheelZoomsCheckbox
        #expect(box !== privateSettings.wheelZoomsCheckbox, "two controllers share one checkbox")
        #expect(privateSettings.wheelZoomsCheckbox.window === privateSettings.window)
        #expect(box.window === settings.window, "the checkbox is not in the Settings window")
        #expect(box.target === settings && box.action == #selector(ZenitSettingsWindowController.wheelZoomsToggled(_:)))
        #expect(box.title == "Mouse wheel zooms")
        box.state = .on
        settings.wheelZoomsToggled(box)
        #expect(ZenitCanvasPreferences.current.wheelZooms)
        box.state = .off
        settings.wheelZoomsToggled(box)
        #expect(!ZenitCanvasPreferences.current.wheelZooms)
    }

    /// K-13 through the real scroll view: a synthesised mouse-wheel notch reaches the zoom door
    /// when the preference is on and scrolls when it is off.
    @Test("A mouse-wheel notch zooms the canvas about the pointer when Mouse wheel zooms is on")
    func wheelNotchZoomsTheCanvas() async throws {
        let (harness, canvas) = try await openMarkupWindow("Iter1 Wheel.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let scrollView = canvas.scrollViewForTesting
        var zooms: [Double] = []
        let original = scrollView.onZoomGesture
        scrollView.onZoomGesture = { factor, _, _ in zooms.append(factor) }
        defer { scrollView.onZoomGesture = original }
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(!event.hasPreciseScrollingDeltas && event.phase == [])

        scrollView.wheelZoomsPreference = { false }
        scrollView.scrollWheel(with: event)
        #expect(zooms.isEmpty, "a notch zoomed with the preference off")

        scrollView.wheelZoomsPreference = { true }
        scrollView.scrollWheel(with: event)
        #expect(zooms.count == 1)
        #expect((zooms.first ?? 1) != 1)
    }
}
