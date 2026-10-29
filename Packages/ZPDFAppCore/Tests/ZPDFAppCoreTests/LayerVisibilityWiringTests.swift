import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFPDFKitBridge
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Gap 10: layer toggles must land somewhere real. These tests prove the two halves of
/// the wiring seam against the `content-three-layers` fixture — the model that turns
/// Navigator toggles into effective visibility, and the session rebuild that makes a
/// hidden layer structurally un-snappable.
@Suite("Layer visibility wiring")
struct LayerVisibilityWiringTests {

    /// The fixture's marked-content property names, from its manifest notes.
    private static let wallsName = "L0"
    private static let doorsName = "L1"
    private static let gridName = "L2"

    private static func openThreeLayers(
        in directory: URL
    ) async throws -> (fixture: OpenedFixture, tree: PDFLayerTree) {
        let fixture = try await OpenedFixture.open(.threeLayers, in: directory)
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(fixture.url), password: nil, limits: .standard)
        let tree = try await provider.layerTree(of: opened.handle)
        await provider.close(opened.handle)
        return (fixture, try #require(tree, "the three-layer fixture declares /OCProperties"))
    }

    @Test("The model resolves effective visibility, keyed by layer id, never by name")
    @MainActor
    func modelResolvesEffectiveVisibility() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (_, tree) = try await Self.openThreeLayers(in: directory.url)

        let model = DocumentLayerVisibility()
        model.adopt(tree: tree)

        #expect(model.hasLayers)
        #expect(model.items.count == 4, "Walls, Doors, Grid, and the duplicate Walls")
        // Two layers named "Walls" are two rows with distinct identities.
        let wallsRows = model.items.filter { $0.name == "Walls" }
        #expect(wallsRows.count == 2)
        #expect(Set(wallsRows.map(\.id)).count == 2)
        // Grid ships OFF; the model reports the document default as the effective state.
        let grid = try #require(model.items.first { $0.name == "Grid" })
        #expect(!grid.isVisibleByDefault)
        #expect(!grid.isVisible)
        #expect(model.matchesDocumentDefault, "no override yet: the native render is truthful")

        // Hiding the first Walls layer flips exactly that row, records exactly one override,
        // and raises the change callback the app tier rebuilds from.
        var changes = 0
        model.onVisibilityChange = { changes += 1 }
        let firstWalls = try #require(wallsRows.first)
        model.setVisible(false, layerID: firstWalls.id)
        #expect(changes == 1)
        #expect(model.overrides == [firstWalls.id: false])
        #expect(!model.matchesDocumentDefault)
        let rowsAfter = model.items.filter { $0.name == "Walls" }
        #expect(rowsAfter.first { $0.id == firstWalls.id }?.isVisible == false)
        #expect(
            rowsAfter.first { $0.id != firstWalls.id }?.isVisible == true,
            "hiding one 'Walls' must not hide the other: identity is the id, not the name"
        )
        #expect(model.hiddenMarkedContentNames(onPageIndex: 0).contains(Self.wallsName))
        #expect(model.hiddenMarkedContentNames(onPageIndex: 0).contains(Self.gridName))

        // Setting the layer back to its default removes the override instead of storing a
        // redundant one, so "matches the default" is exactly the emptiness of the diff.
        model.setVisible(true, layerID: firstWalls.id)
        #expect(changes == 2)
        #expect(model.overrides.isEmpty)
        #expect(model.matchesDocumentDefault)

        // Repeating the current state is not a change and must not trigger a rebuild.
        model.setVisible(true, layerID: firstWalls.id)
        #expect(changes == 2)
    }

    @Test("A hidden layer is structurally un-snappable after the session rebuild")
    func hiddenLayerIsNotSnappable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (fixture, tree) = try await Self.openThreeLayers(in: directory.url)
        let extraction = try #require(fixture.extraction)
        let page = fixture.firstPage

        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )

        // With everything at the document default, the Walls corner at (100, 600) snaps.
        let availability = try await session.buildSnapIndex(page: page, extraction: extraction)
        #expect(availability.allowsVectorCandidates)
        let layout = PageViewLayout(zoom: 1, backingScale: 2)
        let before = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 102, y: 602),
            layout: layout
        )
        let winner = try #require(before.winner, "the Walls corner is 3 pt away, inside the radius")
        #expect(winner.kind == .endpoint)
        #expect(abs(before.resolvedPagePoint.x - 100) < 1e-9)
        #expect(abs(before.resolvedPagePoint.y - 600) < 1e-9)

        // Hide Walls through the model, rebuild through the session seam: the same pointer
        // sample now finds nothing — the layer is not filtered, it is absent from the index.
        let model = await MainActor.run {
            let model = DocumentLayerVisibility()
            model.adopt(tree: tree)
            let walls = model.items.first { $0.name == "Walls" }
            if let walls { model.setVisible(false, layerID: walls.id) }
            return model
        }
        let hidden = await model.hiddenMarkedContentNames(onPageIndex: 0)
        #expect(hidden.contains(Self.wallsName))

        _ = try await session.buildSnapIndex(
            page: page,
            extraction: extraction,
            hiddenLayerIDs: hidden
        )
        let after = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 102, y: 602),
            layout: layout
        )
        #expect(after.winner == nil, "a hidden layer must not be snappable")

        // The Doors layer stays snappable: hiding one layer must not degrade the others.
        let doors = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 100, y: 202),
            layout: layout
        )
        #expect(doors.winner != nil, "the Doors endpoint at (100, 200) is 2 pt away")
    }

    // MARK: - Feature 30: measure on one layer

    @Test("A measure lock hides every other layer from the snap set — and only from it")
    @MainActor
    func measureLockNarrowsTheSnapSetOnly() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (_, tree) = try await Self.openThreeLayers(in: directory.url)

        let model = DocumentLayerVisibility()
        model.adopt(tree: tree)
        let doors = try #require(model.items.first { $0.name == "Doors" })

        var changes = 0
        model.onVisibilityChange = { changes += 1 }
        model.setMeasureLock(doors.id)
        #expect(changes == 1, "a lock rebuilds the snap index like any visibility change")
        #expect(model.measureLockLayerName == "Doors")

        // Snap set: everything except Doors. Render set: untouched — Grid ships OFF by
        // default and stays the only render-hidden layer; the person still sees exactly
        // what they saw before the lock.
        let renderHiddenBefore = model.hiddenMarkedContentNames(onPageIndex: 0)
        let snapHidden = model.snapHiddenMarkedContentNames(onPageIndex: 0)
        #expect(snapHidden.contains(Self.wallsName))
        #expect(snapHidden.contains(Self.gridName))
        #expect(!snapHidden.contains(Self.doorsName))
        #expect(model.hiddenMarkedContentNames(onPageIndex: 0) == renderHiddenBefore,
                "a measure lock must never change what the person sees")
        #expect(model.matchesDocumentDefault,
                "the native render stays truthful under a lock")

        // Lifting the lock restores the plain visibility set, and says so.
        model.setMeasureLock(nil)
        #expect(changes == 2)
        #expect(model.snapHiddenMarkedContentNames(onPageIndex: 0) == renderHiddenBefore,
                "with the lock lifted the snap set is the render set again")
        #expect(model.measureLockLayerName == nil)

        // A lock on a layer that does not exist is refused, not honoured: locking to
        // nothing would silently make every snap miss.
        model.setMeasureLock("no-such-layer")
        #expect(model.measureLockLayerID == nil)
        #expect(changes == 2, "a refused lock must not trigger a rebuild")
    }

    @Test("With a lock in force, geometry on another layer does not snap; the locked layer does")
    @MainActor
    func lockedSnapIndexIgnoresOtherLayers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let (fixture, tree) = try await Self.openThreeLayers(in: directory.url)

        let model = DocumentLayerVisibility()
        model.adopt(tree: tree)
        let doors = try #require(model.items.first { $0.name == "Doors" })
        model.setMeasureLock(doors.id)

        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        let page = fixture.firstPage
        let extraction = try #require(fixture.extraction)
        _ = try await session.buildSnapIndex(
            page: page,
            extraction: extraction,
            hiddenLayerIDs: model.snapHiddenMarkedContentNames(onPageIndex: 0)
        )
        let layout = PageViewLayout(zoom: 1, backingScale: 2)

        // The Walls corner that snapped in the tests above is dead under the lock.
        let walls = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 102, y: 602),
            layout: layout
        )
        #expect(walls.winner == nil,
                "a click near another layer's geometry must not snap while locked")

        // The locked layer itself still snaps — the lock is an aid, not an outage.
        let locked = try await session.resolveSnap(
            pageID: page.id,
            pagePoint: PDFPoint(x: 100, y: 202),
            layout: layout
        )
        #expect(locked.winner != nil, "the locked Doors layer must stay snappable")
    }
}
