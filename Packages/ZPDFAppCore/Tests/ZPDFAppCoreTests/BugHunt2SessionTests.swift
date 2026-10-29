import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Bug hunt 2, the session and the command bus (BH-008, 094, 103, 421, 422, 424, 430, 431,
/// 432, 433, 434, 435).
@MainActor
@Suite("Bug hunt 2: session and command bus")
struct BugHunt2SessionTests {

    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 2_000, height: 2_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page, documentID)
    }

    /// 100 pt = 10 m: 0.1 m per point.
    private func calibrate(_ environment: AppCoreEnvironment, _ page: ZPDFContracts.PageDescriptor) async throws {
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
    }

    private func record(
        id: MarkupID = MarkupID(UUID()),
        tool: MeasurementTool,
        kind: ZPDFContracts.MarkupKind = .measurement,
        page: PageID,
        documentID: DocumentID,
        geometry: MeasurementGeometry,
        subject: String = "Slab",
        locked: Bool = false
    ) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ZPDFContracts.MarkupRecord(
            id: id, documentID: documentID, pageID: page, kind: kind, tool: tool,
            subject: subject, author: "test", locked: locked, geometry: geometry,
            createdAt: stamp, modifiedAt: stamp
        )
    }

    private func polygon(_ points: [PDFPoint], page: PageID) -> MeasurementGeometry {
        MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: points, isClosed: true))])
    }

    private func square(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + w, y: y), PDFPoint(x: x + w, y: y + h), PDFPoint(x: x, y: y + h)]
    }

    // MARK: BH-008

    @Test("Moving a parent area carries its cutouts")
    func movingAParentMovesItsCutouts() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await calibrate(environment, page)
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(record(
            id: parentID, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 100, 80), page: page.id)
        )))
        try await environment.commands.perform(.addCutout(parent: parentID, cutout: record(
            id: cutoutID, tool: .polygonCutout, kind: .polygon, page: page.id, documentID: documentID,
            geometry: polygon(square(10, 10, 20, 20), page: page.id)
        )))
        // Hand-derived: 100 × 80 pt at 0.1 m/pt = 80 m²; hole 20 × 20 pt = 4 m²; net 76 m².
        #expect(await session.markup(parentID)?.measurement?.values[.netArea]?.value == 76)

        // Old output: a 500 pt move was refused as cutoutOutsideParent (the hole stayed behind);
        // a small move clipped the hole and inflated the net area.
        try await environment.commands.perform(.moveMarkup(id: parentID, dx: 500, dy: 0))
        let parent = try #require(await session.markup(parentID))
        let cutout = try #require(await session.markup(cutoutID))
        #expect(parent.measurement?.values[.netArea]?.value == 76)
        #expect(cutout.geometry?.bounds?.minX == 510)

        // One ⌘Z puts both back.
        await environment.commands.undo()
        #expect(await session.markup(cutoutID)?.geometry?.bounds?.minX == 10)
        #expect(await session.markup(parentID)?.measurement?.values[.netArea]?.value == 76)
    }

    // MARK: BH-103

    @Test("An ellipse cutout's hole is exactly the area its row reports")
    func ellipseHoleMatchesChildArea() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        try await calibrate(environment, page)
        let parentID = MarkupID(UUID())
        let cutoutID = MarkupID(UUID())
        // 10 × 10 m parent; ellipse cutout in a 10 m × 6 m box.
        try await environment.commands.perform(.addMarkup(record(
            id: parentID, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 100, 100), page: page.id)
        )))
        try await environment.commands.perform(.addCutout(parent: parentID, cutout: record(
            id: cutoutID, tool: .ellipseCutout, kind: .polygon, page: page.id, documentID: documentID,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 20), PDFPoint(x: 100, y: 80)])
        )))
        let child = try #require(await session.markup(cutoutID)?.measurement?.values[.cutoutArea]?.value)
        let parent = try #require(await session.markup(parentID)?.measurement)
        let gross = try #require(parent.values[.planArea]?.value)
        let net = try #require(parent.values[.netArea]?.value)
        // Hand-derived: πab = π · 5 · 3 = 47.1238898… m².
        #expect(abs((child as NSDecimalNumber).doubleValue - Double.pi * 15) < 1e-9)
        // Old output: gross − net = 47.064 m² (the inscribed 72-gon), 0.06 m² short of the row.
        let hole = ((gross - net) as NSDecimalNumber).doubleValue
        #expect(abs(hole - Double.pi * 15) < 1e-4, "hole \(hole)")
    }

    @Test("The hole ring is area-preserving by construction")
    func ellipseRingArea() {
        let ring = TakeoffSession.ellipseRing(corner: PDFPoint(x: 0, y: 0), opposite: PDFPoint(x: 10, y: 6))
        var twice = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            twice += a.x * b.y - b.x * a.y
        }
        // Shoelace area against π · 5 · 3.
        #expect(abs(abs(twice) / 2 - Double.pi * 15) < 1e-9)
    }

    // MARK: BH-430

    @Test("A refused column set does not poison later unit changes")
    func refusedColumnsAreRolledBack() async throws {
        let (_, session, _, _) = try await makeEnvironment()
        let column = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.a", title: "A", kind: .text)
        try await session.addCustomColumns([column])
        let duplicate = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.a", title: "A again", kind: .text)
        await #expect(throws: (any Error).self) { try await session.addCustomColumns([duplicate]) }
        // Old output: setUnits threw duplicateColumnKey for the rest of the session.
        try await session.setUnits(.imperial)
        #expect(await session.ledgerColumns.column(key: "custom.a")?.title == "A")
    }

    // MARK: BH-431

    @Test("Undo, redo, undo of a first calibration through revert leaves no orphan scale")
    func firstCalibrationRevertChain() async throws {
        let (_, session, page, _) = try await makeEnvironment()
        let outcome = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let redo = try await session.revert(outcome.inverse)
        #expect(await session.allScales.isEmpty)
        let undoAgain = try await session.revert(redo)
        #expect(await session.allScales.count == 1)
        _ = try await session.revert(undoAgain)
        // Old output: one scale left behind in `scales`, written to the next save.
        #expect(await session.allScales.isEmpty)
        #expect(await session.firstPageScale == nil)
    }

    // MARK: BH-432

    @Test("A region's own scale cannot be calibrated on a page that has no scale")
    func regionScaleNeedsAPageScale() async throws {
        let (_, session, page, _) = try await makeEnvironment()
        // Old output: the region's scale became the page's own scale.
        await #expect(throws: DocumentCommandError.noScale(page.id)) {
            _ = try await session.calibrate(
                page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre, scaleID: ScaleID(UUID())
            )
        }
        #expect(await session.allScales.isEmpty)
    }

    // MARK: BH-433

    @Test("A rescale that fails part-way leaves the document as it was")
    func failedRescaleIsAtomic() async throws {
        let (_, session, page, documentID) = try await makeEnvironment()
        let lengthID = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(record(
            id: lengthID, tool: .length, page: page.id, documentID: documentID,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)])
        )))
        _ = try await session.apply(.addMarkup(record(
            tool: .radius, page: page.id, documentID: documentID,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 200, y: 200), PDFPoint(x: 210, y: 200)])
        )))
        // A non-uniform scale: the length recomputes, the radius refuses.
        let skewed = ScaleTransform(
            id: ScaleID(UUID()), pageID: page.id, version: 1,
            matrix: AffineScaleMatrix(a: Decimal(string: "0.1")!, b: 0, c: 0, d: Decimal(string: "0.2")!),
            units: .metric, source: .preset
        )
        await #expect(throws: (any Error).self) { _ = try await session.apply(.changeScale(skewed)) }
        // Old output: the scale installed and the length restamped, with no undo registered.
        #expect(await session.allScales.isEmpty)
        #expect(await session.markup(lengthID)?.measurement == nil)
    }

    // MARK: BH-434

    @Test("A cutout that names itself as parent is refused, not a trap")
    func selfParentedCutoutIsRefused() async throws {
        let (_, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 100, 100), page: page.id)
        )))
        // Old behaviour: "Dictionary literal contains duplicate keys" — the process aborted.
        await #expect(throws: (any Error).self) {
            _ = try await session.apply(.addCutout(parent: id, cutout: self.record(
                id: id, tool: .polygonCutout, kind: .polygon, page: page.id, documentID: documentID,
                geometry: self.polygon(self.square(10, 10, 10, 10), page: page.id)
            )))
        }
    }

    // MARK: BH-435

    @Test("Status, zone and scale-region fan-outs refuse a locked markup")
    func fanOutsRespectLocks() async throws {
        let (_, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 100, 100), page: page.id), locked: true
        )))
        // Old output: each succeeded and rewrote the locked record.
        await #expect(throws: DocumentCommandError.markupLocked(id)) {
            _ = try await session.apply(.batchStatusChange(ids: [id], status: .accepted))
        }
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Z", kind: .room, pageID: page.id, boundary: square(0, 0, 10, 10),
            sortOrder: 0, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0)
        )
        _ = try await session.apply(.setProjectZones([zone]))
        await #expect(throws: DocumentCommandError.markupLocked(id)) {
            _ = try await session.apply(.setMarkupZone(ids: [id], zoneID: zone.id))
        }
        #expect(await session.markup(id)?.status == ZPDFContracts.MarkupStatus.none)
    }

    // MARK: BH-094

    @Test("A ⌘Z during an in-flight command undoes that command, not the one before")
    func undoDuringApplyUndoesTheLatestStep() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 100, 100), page: page.id)
        )))
        let edit = Task { @MainActor in
            try await environment.commands.perform(.editSubject(id: id, subject: "Beam"))
        }
        while !environment.commands.isApplying { await Task.yield() }
        // Edit ▸ Undo calls the manager directly, while the edit is awaiting the session.
        environment.commands.undoManager.undo()
        _ = try? await edit.value
        await environment.commands.settle()

        // Old output: the add was undone (the markup gone, unredoable), and the edit's late
        // registration sat on the undo stack resurrecting the pre-edit markup.
        let stored = try #require(await session.markup(id))
        #expect(stored.subject == "Slab")
        #expect(environment.commands.undoManager.canRedo)
        await environment.commands.undo()
        #expect(await session.markup(id) == nil, "the next ⌘Z takes back the add")
    }

    // MARK: BH-421, BH-422

    @Test("A refused calibration is recorded; a no-op edit registers no undo")
    func calibrationRefusalAndNoOpEdits() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let stranger = PageID(UUID())
        await #expect(throws: DocumentCommandError.unknownPage(stranger)) {
            try await environment.commands.calibrate(
                page: stranger, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 1, knownLengthUnit: .metre
            )
        }
        // Old output: lastError nil — the bus reported no failure.
        #expect(environment.commands.lastError == .unknownPage(stranger))

        let id = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 10, 10), page: page.id)
        )))
        let before = try #require(await session.markup(id))
        try await environment.commands.perform(.rotateStamp(id: id, degrees: 90))
        try await environment.commands.perform(.editSubject(id: id, subject: "Slab"))
        // Old output: two undo entries ("Undo Rotate Stamp") that do nothing.
        #expect(!environment.commands.undoManager.canUndo)
        #expect(await session.markup(id)?.modifiedAt == before.modifiedAt, "the no-op leaves no trace")
    }

    // MARK: BH-424

    @Test("A change handler that performs a command during an undo does not wedge the bus")
    func reentrantCommandDuringUndo() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 10, 10), page: page.id)
        )))
        let other = MarkupID(UUID())
        var fired = false
        environment.commands.onChange = { [weak environment] change in
            guard let environment, change == .everything, !fired else { return }
            fired = true
            try? await environment.commands.perform(.addMarkup(self.record(
                id: other, tool: .area, page: page.id, documentID: documentID,
                geometry: self.polygon(self.square(20, 20, 10, 10), page: page.id)
            )))
        }
        var finished = false
        Task { @MainActor in
            await environment.commands.undo()
            finished = true
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Old behaviour: settle() awaited the task it was running in, forever.
        #expect(finished)
        #expect(fired)
        #expect(await session.markup(other) != nil)
    }

    // MARK: BH-094 follow-up (BH-375)

    @Test("A refused or no-op command leaves the document's change count where it was")
    func refusedCommandsBalanceTheChangeCount() async throws {
        let (environment, session, page, documentID) = try await makeEnvironment()
        let manager = environment.commands.undoManager
        // NSDocument's rule: a closed undo group is a change, an undo takes one back, a redo
        // adds one.
        var changeCount = 0
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: manager, queue: nil) { _ in changeCount += 1 },
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: manager, queue: nil) { _ in changeCount -= 1 },
            center.addObserver(forName: .NSUndoManagerDidRedoChange, object: manager, queue: nil) { _ in changeCount += 1 }
        ]
        defer { tokens.forEach(center.removeObserver) }

        // Old behaviour: the pre-registered step was withdrawn, the count stayed at +1, and the
        // document read as edited with nothing to undo.
        await #expect(throws: DocumentCommandError.self) {
            try await environment.commands.perform(.removeMarkup(MarkupID(UUID())))
        }
        #expect(changeCount == 0)
        #expect(!manager.canUndo)

        let id = MarkupID(UUID())
        _ = try await session.apply(.addMarkup(record(
            id: id, tool: .area, page: page.id, documentID: documentID,
            geometry: polygon(square(0, 0, 10, 10), page: page.id)
        )))
        try await environment.commands.perform(.editSubject(id: id, subject: "Slab"))
        #expect(changeCount == 0, "a no-op edit is no change")

        try await environment.commands.perform(.editSubject(id: id, subject: "Beam"))
        #expect(changeCount == 1)
        #expect(manager.canUndo)
    }
}
