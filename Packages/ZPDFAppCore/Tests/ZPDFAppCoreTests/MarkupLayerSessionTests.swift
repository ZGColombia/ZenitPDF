import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// ADR-0032: markup layers in the session — the pure list, the commands and
/// their undo, the locked-layer rule, the placement of new markups, the archive round trip, and
/// the QUALITY_BAR rule that a layer's visibility never changes a total. Every expected number is
/// derived by hand in the comment beside it.
@MainActor
struct MarkupLayerSessionTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// One 1 000 × 1 000 pt page at 1 pt = 1 cm (0.01 m per point), so a 100 × 50 pt rectangle is
    /// 1.00 m × 0.50 m = 0.5 m² by hand.
    private static func environment() async throws -> (AppCoreEnvironment, TakeoffSession, PageID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page], units: .metric)
        let scale = try ScaleTransform.uniform(
            id: ScaleID(UUID()), pageID: page.id, version: 1, metresPerPoint: Decimal(string: "0.01")!,
            units: ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre),
            source: .preset
        )
        try await session.apply(.changeScale(scale))
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page.id)
    }

    private static func area(on page: PageID, x: Double, y: Double, width: Double, height: Double, layer: LayerID? = nil) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .area,
            subject: "Slab", author: "test",
            layerID: layer,
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: y), PDFPoint(x: x + width, y: y),
                PDFPoint(x: x + width, y: y + height), PDFPoint(x: x, y: y + height)
            ], isClosed: true))]),
            createdAt: now, modifiedAt: now
        )
    }

    private static func layer(_ name: String, order: Int = -1) -> MarkupLayer {
        MarkupLayer(id: LayerID(UUID()), name: name, order: order)
    }

    // MARK: The pure list

    @Test("The list always holds the default layer, never duplicates, and renumbers in order")
    func setNormalises() throws {
        let walls = Self.layer("Walls", order: 5)
        let doors = Self.layer("Doors", order: 2)
        // Doors (2) before Walls (5); the default layer, missing, is added last; orders 0, 1, 2.
        let set = MarkupLayerSet([walls, doors, walls])
        #expect(set.layers.map(\.name) == ["Doors", "Walls", "Default"])
        #expect(set.layers.map(\.order) == [0, 1, 2])
        #expect(set.layers.last?.isDefault == true)
        // Added at the top; moved to the bottom; renamed; the default cannot be removed.
        let added = try set.adding(Self.layer("Glazing"))
        #expect(added.layers.map(\.name) == ["Glazing", "Doors", "Walls", "Default"])
        let moved = try added.moving(added.layers[0].id, to: 3)
        #expect(moved.layers.map(\.name) == ["Doors", "Walls", "Default", "Glazing"])
        #expect(try moved.renaming(walls.id, to: "  Partitions ").layer(walls.id)?.name == "Partitions")
        #expect(throws: MarkupLayerRefusal.defaultLayerCannotBeDeleted) { try moved.removing(MarkupLayer.defaultID) }
        #expect(throws: MarkupLayerRefusal.emptyName) { try moved.renaming(walls.id, to: "   ") }
        #expect(set.suggestedName() == "Layer 4")
    }

    @Test("A new markup is placed on the active layer unless it would be hidden or refused there")
    func placement() throws {
        let walls = Self.layer("Walls")
        let doors = Self.layer("Doors")
        var set = MarkupLayerSet([walls, doors, MarkupLayer.makeDefault()])
        #expect(set.placementLayer(active: doors.id) == doors.id)
        // Doors hidden: the topmost visible, unlocked layer — Walls.
        set = try set.updating(doors.id) { $0.visible = false }
        #expect(set.placementLayer(active: doors.id) == walls.id)
        // Walls locked too: the default layer, the only open one left.
        set = try set.updating(walls.id) { $0.locked = true }
        #expect(set.placementLayer(active: doors.id) == MarkupLayer.defaultID)
        // A layer that has gone resolves to the default layer.
        #expect(set.placementLayer(active: LayerID(UUID())) == MarkupLayer.defaultID)
    }

    // MARK: Commands

    @Test("New, rename, reorder and flag steps are each one undo step with their own names")
    func layerListCommands() async throws {
        let (environment, session, _) = try await Self.environment()
        let walls = Self.layer("Walls")
        let list = try await session.markupLayerList.adding(walls)
        _ = try await environment.commands.perform(.setMarkupLayers(list.layers, change: .add))
        #expect(await session.markupLayers.map(\.name) == ["Walls", "Default"])
        #expect(environment.commands.undoManager.undoActionName == "New Layer")

        let renamed = try await session.markupLayerList.renaming(walls.id, to: "Partitions")
        _ = try await environment.commands.perform(.setMarkupLayers(renamed.layers, change: .rename))
        #expect(environment.commands.undoManager.undoActionName == "Rename Layer")
        let hidden = try await session.markupLayerList.updating(walls.id) { $0.visible = false }
        _ = try await environment.commands.perform(.setMarkupLayers(hidden.layers, change: .hide))
        #expect(environment.commands.undoManager.undoActionName == "Hide Layer")
        #expect(await session.markupLayerList.layer(walls.id)?.visible == false)

        await environment.commands.undo()
        #expect(await session.markupLayerList.layer(walls.id)?.visible == true)
        await environment.commands.undo()
        #expect(await session.markupLayerList.layer(walls.id)?.name == "Walls")
        await environment.commands.undo()
        #expect(await session.markupLayers.map(\.name) == ["Default"])
        await environment.commands.redo()
        #expect(await session.markupLayers.map(\.name) == ["Walls", "Default"])
    }

    @Test("Move to Layer is one step; the default layer is stored as no id; undo puts it back")
    func moveToLayer() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(MarkupLayer.defaultID)
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50)
        _ = try await environment.commands.perform(.addMarkup(a))
        #expect(await session.markup(a.id)?.layerID == nil, "the default layer is stored as no id")

        _ = try await environment.commands.perform(.setMarkupLayer(ids: [a.id], layerID: walls.id))
        #expect(await session.markup(a.id)?.layerID == walls.id)
        #expect(environment.commands.undoManager.undoActionName == "Move to Layer")
        // One markup, on Walls; none left on the default layer.
        #expect(await session.orderedMarkups.map(\.layerID) == [walls.id])
        await environment.commands.undo()
        #expect(await session.markup(a.id)?.layerID == nil)
        _ = try await environment.commands.perform(.setMarkupLayer(ids: [a.id], layerID: walls.id))
        _ = try await environment.commands.perform(.setMarkupLayer(ids: [a.id], layerID: MarkupLayer.defaultID))
        #expect(await session.markup(a.id)?.layerID == nil)
    }

    @Test("A new markup goes onto the active layer; a cutout goes onto its outline's layer")
    func newMarkupOnActiveLayer() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(walls.id)
        #expect(await session.activeMarkupLayer == walls.id)
        let parent = Self.area(on: page, x: 100, y: 100, width: 400, height: 400)
        _ = try await environment.commands.perform(.addMarkup(parent))
        #expect(await session.markup(parent.id)?.layerID == walls.id)
        // A markup that names a layer the project holds keeps it (a paste of a copied markup).
        let explicit = Self.area(on: page, x: 600, y: 100, width: 50, height: 50, layer: MarkupLayer.defaultID)
        _ = try await environment.commands.perform(.addMarkup(explicit))
        #expect(await session.markup(explicit.id)?.layerID == nil)
        // The cutout follows the parent, whatever layer is active.
        await session.setActiveMarkupLayer(MarkupLayer.defaultID)
        var hole = Self.area(on: page, x: 150, y: 150, width: 50, height: 50)
        hole.tool = .polygonCutout
        hole.kind = .measurement
        _ = try await environment.commands.perform(.addCutout(parent: parent.id, cutout: hole))
        #expect(await session.markup(hole.id)?.layerID == walls.id)
    }

    @Test("Delete Layer moves its markups where the person says, in one step; the default layer refuses")
    func deleteLayer() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        let doors = Self.layer("Doors")
        var list = try await session.markupLayerList.adding(walls)
        list = try list.adding(doors)
        _ = try await environment.commands.perform(.setMarkupLayers(list.layers, change: .add))
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50, layer: walls.id)
        let b = Self.area(on: page, x: 300, y: 100, width: 100, height: 50, layer: walls.id)
        for record in [a, b] { _ = try await environment.commands.perform(.addMarkup(record)) }

        _ = try await environment.commands.perform(.deleteMarkupLayer(walls.id, moveMarkupsTo: doors.id))
        #expect(await session.markupLayerList.contains(walls.id) == false)
        #expect(await session.markup(a.id)?.layerID == doors.id)
        #expect(await session.markup(b.id)?.layerID == doors.id)
        #expect(environment.commands.undoManager.undoActionName == "Delete Layer")
        await environment.commands.undo()
        #expect(await session.markupLayerList.contains(walls.id))
        #expect(await session.markup(a.id)?.layerID == walls.id)

        await #expect(throws: DocumentCommandError.self) {
            _ = try await session.apply(.deleteMarkupLayer(MarkupLayer.defaultID, moveMarkupsTo: doors.id))
        }
        await #expect(throws: DocumentCommandError.self) {
            _ = try await session.apply(.deleteMarkupLayer(walls.id, moveMarkupsTo: walls.id))
        }
        // A list step that drops a layer takes nobody with it: its markups land on the default.
        let dropped = MarkupLayerSet(await session.markupLayers.filter { $0.id != walls.id })
        _ = try await session.apply(.setMarkupLayers(dropped.layers, change: .other))
        #expect(await session.markup(a.id)?.layerID == nil)
    }

    @Test("A locked layer refuses every edit of its markups, as a locked markup does, and changes nothing")
    func lockedLayerRefusesEdits() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50, layer: walls.id)
        _ = try await environment.commands.perform(.addMarkup(a))
        let locked = try await session.markupLayerList.updating(walls.id) { $0.locked = true }
        _ = try await environment.commands.perform(.setMarkupLayers(locked.layers, change: .lock))
        let before = await session.markup(a.id)

        for command: DocumentCommand in [
            .moveMarkup(id: a.id, dx: 10, dy: 0),
            .editSubject(id: a.id, subject: "Screed"),
            .removeMarkup(a.id),
            .setMarkupLayer(ids: [a.id], layerID: MarkupLayer.defaultID),
            .setHidden(ids: [a.id], hidden: true)
        ] {
            await #expect(throws: DocumentCommandError.markupLocked(a.id)) {
                _ = try await session.apply(command)
            }
            #expect(await session.markup(a.id) == before, "\(command) left the markup untouched")
        }
        // The effective record the canvas reads is locked; the stored one is not.
        #expect(await session.effectiveMarkups.first { $0.id == a.id }?.locked == true)
        #expect(before?.locked == false)
        #expect(await session.effectiveMarkups.filter(\.locked).map(\.id) == [a.id], "exactly the markups on locked layers")
        // A rescale still re-measures it: a scale is not an edit of the markup.
        let unlocked = try await session.markupLayerList.updating(walls.id) { $0.locked = false }
        _ = try await environment.commands.perform(.setMarkupLayers(unlocked.layers, change: .unlock))
        _ = try await session.apply(.editSubject(id: a.id, subject: "Screed"))
        #expect(await session.markup(a.id)?.subject == "Screed")
    }

    @Test("Hidden and non-printable layers fold into the canvas and output records only")
    func effectiveFlags() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50, layer: walls.id)
        _ = try await environment.commands.perform(.addMarkup(a))
        var list = try await session.markupLayerList.updating(walls.id) { $0.visible = false }
        list = try list.updating(walls.id) { $0.printable = false }
        _ = try await environment.commands.perform(.setMarkupLayers(list.layers, change: .hide))
        let effective = try #require(await session.effectiveMarkups.first { $0.id == a.id })
        #expect(effective.hidden && !effective.printable)
        let stored = try #require(await session.markup(a.id))
        #expect(!stored.hidden && stored.printable, "a layer flag never rewrites the stored markup")
        // The summary folds the flags and says they came from the layer.
        let snapshot = try await session.snapshot()
        let summary = try #require(snapshot.markups.first { $0.id == a.id.rawValue })
        #expect(summary.hidden && summary.layerHidden == true)
        #expect(summary.layer == "Walls")
        #expect(summary.layerID == walls.id.rawValue)
    }

    // MARK: QUALITY_BAR: a layer's visibility never changes a total

    @Test("Hiding or locking a layer leaves every row and total; only a ledger filter by layer narrows them")
    func totalsIgnoreVisibility() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(MarkupLayer.defaultID)
        // A: 100 × 50 pt = 1.00 m × 0.50 m = 0.5 m² on Default.
        // B: 200 × 100 pt = 2.00 m × 1.00 m = 2 m² on Walls.
        // Plan Area total = 0.5 + 2 = 2.5 m².
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50)
        let b = Self.area(on: page, x: 300, y: 300, width: 200, height: 100, layer: walls.id)
        for record in [a, b] { _ = try await environment.commands.perform(.addMarkup(record)) }
        let planArea = LedgerColumnID("planArea")
        let expected = Decimal(string: "2.5")!

        let shown = try await session.ledgerProjection(.flat).grandTotals
        #expect(shown.rowCount == 2)
        #expect(shown.total(planArea)?.value == expected)

        let hiddenList = try await session.markupLayerList.updating(walls.id) { $0.visible = false }
        _ = try await environment.commands.perform(.setMarkupLayers(hiddenList.layers, change: .hide))
        let hidden = try await session.ledgerProjection(.flat).grandTotals
        #expect(hidden.rowCount == 2, "the hidden layer's row stays in the ledger")
        #expect(hidden.total(planArea)?.value == expected, "hiding Walls changes no total")

        var lockedList = try await session.markupLayerList.updating(walls.id) { $0.locked = true }
        lockedList = try lockedList.updating(walls.id) { $0.printable = false }
        _ = try await environment.commands.perform(.setMarkupLayers(lockedList.layers, change: .lock))
        let locked = try await session.ledgerProjection(.flat).grandTotals
        #expect(locked.rowCount == 2)
        #expect(locked.total(planArea)?.value == expected, "locking or keeping off paper changes no total")

        // Only the person's own filter by layer narrows the ledger: Layer is Default → A alone,
        // 0.5 m²; Layer is Walls → B alone, 2 m².
        var request = LedgerRequest.flat
        request.filter = LedgerLayerFilter.applying(layers: ["Default"], to: request.filter)
        let onlyDefault = try await session.ledgerProjection(request).grandTotals
        #expect(onlyDefault.rowCount == 1)
        #expect(onlyDefault.total(planArea)?.value == Decimal(string: "0.5")!)
        request.filter = LedgerLayerFilter.applying(layers: ["Walls"], to: request.filter)
        let onlyWalls = try await session.ledgerProjection(request).grandTotals
        #expect(onlyWalls.rowCount == 1)
        #expect(onlyWalls.total(planArea)?.value == Decimal(2))
        // Clearing the filter restores both.
        request.filter = LedgerLayerFilter.applying(layers: nil, to: request.filter)
        #expect(try await session.ledgerProjection(request).grandTotals.total(planArea)?.value == expected)
    }

    @Test("The ledger's Layer column names the layer; no id and a gone id both read as the default layer")
    func ledgerLayerColumn() async throws {
        let (environment, session, page) = try await Self.environment()
        let walls = Self.layer("Walls")
        _ = try await environment.commands.perform(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(MarkupLayer.defaultID)
        let a = Self.area(on: page, x: 100, y: 100, width: 100, height: 50)
        let b = Self.area(on: page, x: 300, y: 300, width: 200, height: 100, layer: walls.id)
        for record in [a, b] { _ = try await environment.commands.perform(.addMarkup(record)) }
        var request = LedgerRequest.flat
        request.visibleColumns = [LedgerColumnID("layer")]
        let projection = try await session.ledgerProjection(request)
        let texts = (0..<projection.rowCount).compactMap { projection.row(at: $0)?.displayValues[LedgerColumnID("layer")] }
        #expect(Set(texts) == ["Default", "Walls"])
    }

    // MARK: Archive

    @Test("Layers, a markup's layer, the active layer and the display units survive save and reopen")
    func archiveRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-r2-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let page = fixture.firstPage.id
        let walls = Self.layer("Walls")
        _ = try await session.apply(.setMarkupLayers(try await session.markupLayerList.adding(walls).layers, change: .add))
        await session.setActiveMarkupLayer(walls.id)
        var shape = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: fixture.documentID, pageID: page, kind: .rectangle,
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 60, y: 10), PDFPoint(x: 60, y: 60)], isClosed: true))]),
            createdAt: Self.now, modifiedAt: Self.now
        )
        shape.layerID = nil
        _ = try await session.apply(.addMarkup(shape))
        // Hidden and kept off paper after the markup landed on it (a new markup never lands on
        // a hidden layer — `placement`).
        let list = try await session.markupLayerList.updating(walls.id) { $0.visible = false; $0.printable = false }
        _ = try await session.apply(.setMarkupLayers(list.layers, change: .hide))
        try await session.setUnits(.imperial)

        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("Layers.zpdfproj", isDirectory: true),
            displayName: "Layers", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        let read = try #require(try await TakeoffArchive.read(from: package))
        try await package.close()

        #expect(read.markupLayers.map(\.name) == ["Walls", "Default"])
        #expect(read.markupLayers.first?.visible == false)
        #expect(read.markupLayers.first?.printable == false)
        #expect(read.activeMarkupLayerID == walls.id)
        #expect(read.markups.first?.layerID == walls.id, "placed on the active layer, stored by id")
        #expect(read.displayUnits == .imperial, "the project reopens in its own units")

        let reopened = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: read.displayUnits ?? .metric)
        await reopened.restoreMarkupLayers(read.markupLayers, active: read.activeMarkupLayerID)
        #expect(await reopened.markupLayers == list.layers)
        #expect(await reopened.activeMarkupLayer == walls.id)
        #expect(await reopened.displayUnits == .imperial)
    }

    @Test("A package written before ADR-0032 reads with no layers, and the session restores the default layer")
    func oldPackage() async throws {
        let session = try TakeoffSession(documentID: DocumentID(UUID()))
        await session.restoreMarkupLayers([], active: nil)
        #expect(await session.markupLayers == [MarkupLayer.makeDefault()])
        #expect(await session.activeMarkupLayer == MarkupLayer.defaultID)
        #expect(ProjectSchema.defaultMarkupLayerID == MarkupLayer.defaultID.rawValue.uuidString,
                "persistence's copy of the default layer's id is the contract's")
    }
}
