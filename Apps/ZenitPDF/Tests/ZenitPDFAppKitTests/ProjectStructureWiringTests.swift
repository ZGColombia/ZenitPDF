import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUILedger
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The three panels nobody could reach, driven through the shipping document and the shipping
/// window: Scale Regions, Project Zones, and the two canvas view modes.
///
/// Every assertion here is about *reachability plus consequence*. The panels' own logic is
/// tested in their packages; what could not be tested there — and what was in fact broken, in
/// the exact way a wiring review described it — is that nothing in the application ever
/// filled their hooks, so every one of them refused in silence.
@MainActor
@Suite(.appTierSerialised)
struct ProjectStructureWiringTests {

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
        /// The page default: 100 pt = 10 m, so 1 pt = 0.1 m.
        let pageScaleID: ScaleID
        /// A second scale, 100 pt = 1 m — ten times finer, so a wrong pick is unmistakable.
        let detailScale: ScaleSummary
    }

    /// A real drawing, opened by the shipping document, calibrated, with a second scale
    /// available for a region to be given.
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
            knownLength: 10,
            knownLengthUnit: .metre
        )
        let pageScaleID = try #require(await core.session.firstPageScale?.id)
        let detailScaleID = ScaleID(UUID())
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre,
            scaleID: detailScaleID
        )
        // Snap off. These tests are about which *scale* a click is measured with, and a snap
        // that pulls a click onto a nearby drawing edge would make the assertion about the
        // snap engine instead — which has two hundred tests of its own.
        var settings = await core.session.currentSnapSettings
        settings.isEnabled = false
        settings.enabledKinds = []
        try await core.session.setSnapSettings(settings)
        await core.refresh()
        document.refreshProjectStructureIfPossible()
        let detail = try #require(await core.session.scaleTransform(detailScaleID))
        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        _ = canvas.view
        canvas.onShellCommand = { command in shell.perform(command) }
        return Harness(
            document: document,
            core: core,
            shell: shell,
            canvas: canvas,
            directory: url.deletingLastPathComponent(),
            pageScaleID: pageScaleID,
            detailScale: ScaleSummary(domain: detail, name: nil)
        )
    }

    /// Draws a boundary the way the panel asks for one: arm, click the corners on the
    /// shipping canvas, finish.
    private func drawBoundary(_ points: [PDFPointValue], in harness: Harness) async {
        for point in points {
            harness.canvas.handleClick(at: point, additive: false)
        }
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()
    }

    private func square(_ originX: Double, _ originY: Double, _ side: Double) -> [PDFPointValue] {
        [
            PDFPointValue(x: originX, y: originY),
            PDFPointValue(x: originX + side, y: originY),
            PDFPointValue(x: originX + side, y: originY + side),
            PDFPointValue(x: originX, y: originY + side)
        ]
    }

    // MARK: - 1. The hooks exist at all

    @Test("Opening a document fills every hook both panels refuse without")
    func everyPanelHookIsWired() async throws {
        let harness = try await makeHarness(named: "Wiring A.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let regions = harness.shell.scaleRegions
        #expect(regions.onBeginPolygon != nil)
        #expect(regions.onCreateRegion != nil)
        #expect(regions.onRenameRegion != nil)
        #expect(regions.onAssignScale != nil)
        #expect(regions.onCalibrateRegion != nil)
        #expect(regions.onCalibrateDraft != nil)
        #expect(regions.onReorderRegions != nil)
        #expect(regions.onSetLocked != nil)
        #expect(regions.onSetVisible != nil)
        #expect(regions.onRevealOverlap != nil)
        #expect(regions.onResolveCrossing != nil)

        let zones = harness.shell.projectZones
        #expect(zones.onBeginBoundary != nil)
        #expect(zones.onCreateZone != nil)
        #expect(zones.onRenameZone != nil)
        #expect(zones.onSetZoneKind != nil)
        #expect(zones.onSetZoneColor != nil)
        #expect(zones.onSetZoneParent != nil)
        #expect(zones.onSetZoneVisible != nil)
        #expect(zones.onDeleteZone != nil)
        #expect(zones.onAssignSelection != nil)
        #expect(zones.onGroupLedger != nil)

        // The Scale Region row in the Inspector, inert since it was drawn.
        #expect(harness.shell.inspectorEditing.onAssignScaleRegion != nil)

        harness.document.close()
    }

    // MARK: - 2. A Scale Region, drawn on the real canvas

    @Test("Draw a boundary, give it a scale, and the region exists in the document")
    func drawingARegionCreatesIt() async throws {
        let harness = try await makeHarness(named: "Wiring B.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let panel = harness.shell.scaleRegions

        #expect(panel.beginRegion(), "refusal: \(panel.refusal?.message ?? "none")")
        #expect(panel.isAwaitingPolygon)
        #expect(harness.core.measurement.isCapturingBoundary)

        await drawBoundary(square(100, 100, 300), in: harness)
        #expect(await wait { panel.draft != nil })
        #expect(!panel.isAwaitingPolygon)
        #expect(harness.core.snapshot.markups.isEmpty, "a boundary is not a measurement")

        // No scale, no region — the refusal the panel exists to make.
        #expect(!panel.canCommitDraft)
        #expect(!panel.commitDraft())
        #expect(panel.refusal == .scaleNotAssigned)

        panel.setDraftName("Stair Detail")
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.canCommitDraft)
        #expect(panel.commitDraft())

        #expect(await wait { panel.regions.count == 1 })
        let region = try #require(panel.regions.first)
        #expect(region.name == "Stair Detail")
        #expect(region.scale.id == harness.detailScale.id)
        #expect(region.boundary.count == 4)
        #expect(await harness.core.session.scaleRegionDefinitions.count == 1)

        harness.document.close()
    }

    @Test("A measurement inside the region reads the region's scale, and undo puts the region back")
    func aRegionChangesTheNumberAndSurvivesUndo() async throws {
        let harness = try await makeHarness(named: "Wiring C.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let panel = harness.shell.scaleRegions

        panel.beginRegion()
        await drawBoundary(square(50, 50, 400), in: harness)
        #expect(await wait { panel.draft != nil })
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.commitDraft())
        #expect(await wait { panel.regions.count == 1 })

        // A 200 pt length inside it. At the page scale that is 20 m; at the region's, 2 m.
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()

        #expect(await wait { harness.core.snapshot.markups.count == 1 })
        let stored = try #require(await harness.core.session.orderedMarkups.first)
        #expect(stored.scaleRegionID?.rawValue == panel.regions.first?.id)
        #expect(stored.measurement?.values[.planLength]?.value == Decimal(2))

        // A region that still measures something refuses to be deleted, with the count — the
        // deletion would re-measure two metres into twenty without anyone deciding to.
        let regionID = try #require(panel.regions.first?.id)
        #expect(await wait { panel.markupCount(of: regionID) == 1 })
        #expect(!panel.delete(regionID: regionID))
        #expect(panel.refusal == .regionInUse(name: panel.regions[0].name, markupCount: 1))
        #expect(await harness.core.session.scaleRegionDefinitions.count == 1)

        // Move the measurement out through the Inspector's Scale Region row, then the
        // deletion is allowed — and one ⌘Z brings the region and the reading back together.
        harness.shell.inspectorEditing.onAssignScaleRegion?([stored.id.rawValue], nil)
        #expect(await wait { panel.markupCount(of: regionID) == 0 })
        #expect(await harness.core.session.orderedMarkups.first?
            .measurement?.values[.planLength]?.value == Decimal(20))
        #expect(panel.delete(regionID: regionID), "refusal: \(panel.refusal?.message ?? "none")")
        #expect(await wait { panel.regions.isEmpty })

        await harness.core.commands.undo()
        harness.document.refreshProjectStructureIfPossible()
        #expect(await wait { panel.regions.count == 1 })
        harness.document.close()
    }

    @Test("Two regions that share area raise the overlap warning, and nothing resolves it")
    func overlappingRegionsWarn() async throws {
        let harness = try await makeHarness(named: "Wiring D.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let panel = harness.shell.scaleRegions

        panel.beginRegion()
        await drawBoundary(square(0, 0, 200), in: harness)
        #expect(await wait { panel.draft != nil })
        panel.setDraftName("A")
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.commitDraft())
        #expect(await wait { panel.regions.count == 1 })

        panel.beginRegion()
        await drawBoundary(square(100, 100, 200), in: harness)
        #expect(await wait { panel.draft != nil })
        panel.setDraftName("B")
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.commitDraft())

        #expect(await wait { !panel.overlaps.isEmpty })
        let overlap = try #require(panel.overlaps.first)
        #expect(overlap.message.contains("A") && overlap.message.contains("B"))
        #expect(panel.overlaps.contains { $0.first == overlap.first || $0.second == overlap.first })
        harness.document.close()
    }

    // MARK: - 3. The crossing, with its three legal outcomes

    /// Two abutting regions and a length drawn through both.
    private func drawCrossing(_ harness: Harness) async throws -> ScaleRegionCrossing {
        let panel = harness.shell.scaleRegions
        panel.beginRegion()
        await drawBoundary(square(0, 0, 200), in: harness)
        #expect(await wait { panel.draft != nil })
        panel.setDraftName("Left")
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.commitDraft())
        #expect(await wait { panel.regions.count == 1 })

        panel.beginRegion()
        await drawBoundary(square(300, 0, 200), in: harness)
        #expect(await wait { panel.draft != nil })
        panel.setDraftName("Right")
        panel.assignDraftScale(harness.detailScale)
        #expect(panel.commitDraft())
        #expect(await wait { panel.regions.count == 2 })

        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 100), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()

        #expect(await wait { panel.crossing != nil })
        return try #require(panel.crossing)
    }

    @Test("A length across two regions reaches the panel unanswered, with nothing preselected")
    func aCrossingReachesThePanel() async throws {
        let harness = try await makeHarness(named: "Wiring E.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let crossing = try await drawCrossing(harness)

        #expect(crossing.regions.count == 2)
        #expect(harness.shell.scaleRegions.chosenCrossingResolution == nil)
        #expect(harness.core.snapshot.markups.isEmpty, "nothing exists before the answer")
        // All three legal outcomes, and the split really is deliverable for a polyline.
        #expect(crossing.offeredResolutions.contains(.splitAtBoundary))
        #expect(crossing.offeredResolutions.contains(.block))
        #expect(crossing.offeredResolutions.contains { resolution in
            if case .useScale = resolution { return true }
            return false
        })
        harness.document.close()
    }

    @Test("Choosing one region's scale creates one measurement at that scale")
    func choosingAScaleCreatesTheMeasurement() async throws {
        let harness = try await makeHarness(named: "Wiring F.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let crossing = try await drawCrossing(harness)
        let panel = harness.shell.scaleRegions
        let left = try #require(crossing.regions.first { $0.name == "Left" })

        #expect(panel.chooseCrossingResolution(.useScale(regionID: left.id)))
        #expect(panel.confirmCrossing())
        #expect(await wait { harness.core.snapshot.markups.count == 1 })
        let stored = try #require(await harness.core.session.orderedMarkups.first)
        #expect(stored.scaleRegionID?.rawValue == left.id)
        // The whole 300 pt chain at 1 pt = 0.01 m.
        #expect(stored.measurement?.values[.planLength]?.value == Decimal(3))
        #expect(panel.crossing == nil)
        harness.document.close()
    }

    @Test("Splitting creates one measurement per region, and Escape blocks instead of guessing")
    func splittingAndEscaping() async throws {
        let harness = try await makeHarness(named: "Wiring G.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await drawCrossing(harness)
        let panel = harness.shell.scaleRegions

        #expect(panel.chooseCrossingResolution(.splitAtBoundary))
        #expect(panel.confirmCrossing())
        #expect(await wait { harness.core.snapshot.markups.count == 3 })

        // Now the same measurement again, escaped. Escape is not a fourth outcome: it is
        // `block`, so the drawing gains nothing rather than a measurement nobody scaled.
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 150), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 150), additive: false)
        await harness.core.measurement.settlePlacements()
        harness.core.measurement.commitActiveMeasurement()
        #expect(await wait { panel.crossing != nil })
        panel.cancelCrossing()
        #expect(await wait { panel.crossing == nil })
        #expect(harness.core.snapshot.markups.count == 3, "Escape must create nothing")
        harness.document.close()
    }

    // MARK: - 4. Project Zones, and the ledger totalling by them

    @Test("A zone can be created, renamed, hidden, and the ledger subtotals by it")
    func zonesGroupTheLedger() async throws {
        let harness = try await makeHarness(named: "Wiring H.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let panel = harness.shell.projectZones

        panel.beginZone()
        panel.setDraftName("Ground Floor")
        panel.setDraftKind(.floor)
        #expect(panel.commitDraft())
        #expect(await wait { panel.zones.count == 1 })
        let zoneID = try #require(panel.zones.first?.id)
        #expect(panel.zones.first?.kind == .floor)

        // Two lengths, filed into the zone through the panel's own action.
        for y in [100.0, 200.0] {
            harness.shell.toolbar.activateMeasurement(.length)
            harness.canvas.handleClick(at: PDFPointValue(x: 100, y: y), additive: false)
            harness.canvas.handleClick(at: PDFPointValue(x: 300, y: y), additive: false)
            await harness.core.measurement.settlePlacements()
            harness.core.measurement.commitActiveMeasurement()
        }
        #expect(await wait { harness.core.snapshot.markups.count == 2 })
        harness.core.canvas.select(
            markupIDs: Set(harness.core.canvas.visibleMarkups.map(\.id)),
            additive: false
        )
        harness.shell.refreshProjectZones()
        #expect(panel.assignSelection(to: zoneID), "refusal: \(panel.refusal?.message ?? "none")")
        #expect(await wait { panel.zones.first?.markupCount == 2 })

        // The grouping the ledger has offered all along, now with something in it.
        #expect(panel.groupLedgerByZone())
        #expect(harness.shell.ledgerGrouping.pending == [.projectZone])
        let projection = try await harness.core.session.ledgerProjection(
            LedgerRequest(grouping: [.projectZone])
        )
        let names = (0..<projection.rowCount).compactMap {
            projection.row(at: $0)?.displayValue(.projectZone)
        }
        #expect(names == ["Ground Floor", "Ground Floor"], "got \(names)")

        // Renaming and hiding both reach the document.
        #expect(panel.rename(zoneID: zoneID, to: "Level 0"))
        #expect(await wait { panel.zones.first?.name == "Level 0" })
        #expect(panel.setVisible(false, zoneID: zoneID))
        #expect(await wait { panel.zones.first?.isVisible == false })

        // A zone holding markups refuses to be deleted, with the count.
        #expect(!panel.delete(zoneID: zoneID))
        #expect(panel.refusal == .zoneNotEmpty(name: "Level 0", markupCount: 2))
        harness.document.close()
    }

    @Test("A zone boundary is drawn on the real canvas and makes no markup")
    func zoneBoundaryComesFromTheCanvas() async throws {
        let harness = try await makeHarness(named: "Wiring I.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let panel = harness.shell.projectZones

        panel.beginZone()
        #expect(panel.beginBoundary())
        #expect(harness.core.measurement.isCapturingBoundary)
        await drawBoundary(square(20, 20, 120), in: harness)
        #expect(await wait { panel.draft?.hasBoundary == true })
        #expect(harness.core.snapshot.markups.isEmpty)

        panel.setDraftName("Room 101")
        #expect(panel.commitDraft())
        #expect(await wait { panel.zones.count == 1 })
        #expect(panel.zones.first?.boundary.count == 4)
        #expect(panel.zones.first?.pageID != nil)
        harness.document.close()
    }

    // MARK: - 5. The two canvas view modes, from the shipping window

    @Test("Split Canvas and Revision Overlay open over the canvas and give it back unchanged")
    func canvasViewModesAreReachableFromTheWindow() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Modes A.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        let layout = try #require(controller.contentViewController as? ProjectWindowLayoutController)
        let shell = try #require(document.shell)
        let canvasBefore = layout.documentCanvasController

        for mode in [ZPDFCommandID.splitCanvas, .revisionOverlay] {
            shell.perform(mode)
            #expect(layout.isShowingCanvasMode, "\(mode.rawValue) did not take the canvas")
            // Registered *before* it is on screen: there is no instant with no way out.
            #expect(shell.modeRegistry.hasActiveMode)

            shell.perform(.cancelTool)
            #expect(!layout.isShowingCanvasMode, "Escape did not leave \(mode.rawValue)")
            #expect(!shell.modeRegistry.hasActiveMode)
            // The canvas was never rebuilt, so its scroll and zoom are the same object's.
            #expect(layout.documentCanvasController === canvasBefore)
        }

        // The Scale Regions panel is the third reachable surface, and it closes the same way.
        shell.perform(.scaleRegions)
        #expect(layout.isShowingScaleRegionsPanel)
        let exit = try #require(shell.modeRegistry.topmost?.exitRoute)
        exit.performExit()
        #expect(!layout.isShowingScaleRegionsPanel)

        document.close()
    }
}
