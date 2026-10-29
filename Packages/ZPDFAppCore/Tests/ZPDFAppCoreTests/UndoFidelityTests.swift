import Foundation
import os
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFTestingSupport

/// CR-5, CR-6, CR-7, CR-13, CR-14, CR-17: what the undo stack and the change set must not lie about.
///
/// Every test states what the old code produced.
@Suite("Undo fidelity")
struct UndoFidelityTests {

    @MainActor
    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, PageID, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page.id, documentID)
    }

    private static func page(documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
    }

    private static func markup(
        id: MarkupID = MarkupID(UUID()),
        documentID: DocumentID,
        pageID: PageID
    ) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        return MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Slab",
            author: "test",
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0),
                    PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80),
                    PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    // MARK: CR-5

    @Test("Undoing a recalibration restores the previous calibration evidence")
    @MainActor
    func undoRestoresCalibrationEvidence() async throws {
        let (environment, session, pageID, _) = try await makeEnvironment()
        try await environment.commands.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let scaleID = try #require(await session.firstPageScale).id
        let first = try #require(await session.evidence(for: scaleID))
        try await environment.commands.calibrate(
            page: pageID, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 200, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let second = try #require(await session.evidence(for: scaleID))
        #expect(first != second)

        await environment.commands.undo()
        // Old output: `second` — the transform went back to version 1, the evidence did not.
        #expect(await session.evidence(for: scaleID) == first)
        #expect(await session.firstPageScale?.version == 1)

        await environment.commands.redo()
        #expect(await session.evidence(for: scaleID) == second)
        #expect(await session.firstPageScale?.version == 2)

        // Undoing the page's first calibration removes the evidence with the scale.
        await environment.commands.undo()
        await environment.commands.undo()
        #expect(await session.firstPageScale == nil)
        #expect(await session.evidence(for: scaleID) == nil)
    }

    // MARK: CR-6

    @Test("Undo then redo of a batch of adds restores the markups in insertion order")
    @MainActor
    func batchRedoKeepsInsertionOrder() async throws {
        let (environment, session, pageID, documentID) = try await makeEnvironment()
        let ids = (0..<8).map { _ in MarkupID(UUID()) }
        try await environment.commands.performBatch(
            ids.map { .addMarkup(Self.markup(id: $0, documentID: documentID, pageID: pageID)) },
            actionName: "Add Eight"
        )
        #expect(await session.orderedMarkups.map(\.id) == ids)

        await environment.commands.undo()
        #expect(await session.orderedMarkups.isEmpty)

        await environment.commands.redo()
        // Old output: the eight ids in `Dictionary` key order — a different permutation in
        // every process (one chance in 40 320 of being right).
        #expect(await session.orderedMarkups.map(\.id) == ids)
    }

    @Test("Undoing a batch that added one markup and removed another leaves no ghost id")
    @MainActor
    func mixedBatchUndoLeavesNoGhost() async throws {
        let (environment, session, pageID, documentID) = try await makeEnvironment()
        let b = MarkupID(UUID())
        let a = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.markup(id: b, documentID: documentID, pageID: pageID)))
        try await environment.commands.performBatch(
            [.addMarkup(Self.markup(id: a, documentID: documentID, pageID: pageID)), .removeMarkup(b)],
            actionName: "Swap"
        )
        #expect(await session.orderedMarkups.map(\.id) == [a])

        await environment.commands.undo()
        #expect(await session.orderedMarkups.map(\.id) == [b])
        // Old state: `markupOrder == [b, a]` with no record for `a` — a ghost. Adding `a` again
        // appended it a second time, so the ledger listed it twice.
        try await environment.commands.perform(.addMarkup(Self.markup(id: a, documentID: documentID, pageID: pageID)))
        #expect(await session.orderedMarkups.map(\.id) == [b, a])
    }

    // MARK: CR-7

    @Test("A command performed while an undo is queued waits for the undo")
    @MainActor
    func performWaitsForAQueuedUndo() async throws {
        let (environment, session, pageID, documentID) = try await makeEnvironment()
        let id = MarkupID(UUID())
        try await environment.commands.perform(.addMarkup(Self.markup(id: id, documentID: documentID, pageID: pageID)))

        // Queues the revert without waiting for it, the way a menu ⌘Z does.
        environment.commands.undoManager.undo()
        #expect(environment.commands.pendingUndo != nil)

        // Old behaviour: the edit reached the session *before* the queued revert and succeeded;
        // the revert then removed the markup, and the undo stack held an edit of a markup the
        // document no longer had — with the redo of the add thrown away by the registration.
        await #expect(throws: DocumentCommandError.unknownMarkup(id)) {
            try await environment.commands.perform(.editSubject(id: id, subject: "Beam"))
        }
        await environment.commands.settle()
        #expect(await session.markup(id) == nil)
        #expect(environment.commands.undoManager.canRedo, "the add is still there to redo")
    }

    // MARK: CR-13

    @Test("Recalculate reports no change when only the derivation timestamp moved")
    func recalculateReportsOnlyRealChanges() async throws {
        // A ticking clock, so every recompute stamps a different `computedAt`.
        let tick = OSAllocatedUnfairLock(initialState: 0.0)
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID: documentID)
        let session = try TakeoffSession(
            documentID: documentID,
            pages: [page],
            clock: { tick.withLock { $0 += 1; return Date(timeIntervalSince1970: $0) } }
        )
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        let ids = [MarkupID(UUID()), MarkupID(UUID())]
        for id in ids {
            _ = try await session.apply(.addMarkup(Self.markup(id: id, documentID: documentID, pageID: page.id)))
        }
        let computedBefore = await session.markup(ids[0])?.measurement?.provenance?.computedAt

        let outcome = try await session.apply(.recalculateMeasurements(pageID: nil))
        // Old output: both ids, and an inverse holding both records — `computedAt` differed and
        // nothing else did, so every Recalculate was a document-wide History entry.
        #expect(outcome.changedMarkupIDs.isEmpty)
        #expect(outcome.inverse.isEmpty)
        #expect(await session.markup(ids[0])?.measurement?.provenance?.computedAt == computedBefore,
                "an unchanged record keeps the derivation it had")
    }

    // MARK: CR-14

    @Test("Scale Region commands invalidate the scale readout")
    @MainActor
    func regionCommandsInvalidateTheScale() async throws {
        let (environment, _, pageID, documentID) = try await makeEnvironment()
        let regions = try await environment.commands.perform(.setScaleRegions([]))
        // Old output: false — the region commands share the frozen `editCustomValue` kind.
        #expect(regions.invalidatesScale)
        let assignment = try await environment.commands.perform(
            .setMarkupScaleRegion(ids: [], regionID: nil, scaleID: nil)
        )
        #expect(assignment.invalidatesScale)
        let unrelated = try await environment.commands.perform(
            .addMarkup(Self.markup(documentID: documentID, pageID: pageID))
        )
        #expect(!unrelated.invalidatesScale)
    }

    // MARK: CR-17

    /// Parks the first refresh so a command stays "in flight" for as long as the test wants.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private(set) var isParked = false
        var armed = true

        func park() async {
            guard !isOpen else { return }
            isParked = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("isApplying stays true while any command is in flight")
    @MainActor
    func isApplyingHoldsWhileAnyCommandIsInFlight() async throws {
        let (environment, _, pageID, documentID) = try await makeEnvironment()
        let gate = Gate()
        environment.commands.onChange = { _ in
            guard gate.armed else { return }
            gate.armed = false
            await gate.park()
        }

        let first = Task { @MainActor in
            try await environment.commands.perform(
                .addMarkup(Self.markup(documentID: documentID, pageID: pageID))
            )
        }
        while !gate.isParked { await Task.yield() }
        #expect(environment.commands.isApplying)

        try await environment.commands.perform(.addMarkup(Self.markup(documentID: documentID, pageID: pageID)))
        // Old output: false — the second command's `defer` cleared the flag while the first was
        // still in flight.
        #expect(environment.commands.isApplying)

        gate.open()
        _ = try await first.value
        #expect(!environment.commands.isApplying)
    }
}
