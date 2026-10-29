import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore: session and command-bus fixes (S-027, S-034, S-038).
@Suite("Iter2 appcore: session")
struct Iter2AppCoreSessionTests {

    // MARK: S-027

    @Test("A no-op performed just before an edit of the same markup does not take the edit back")
    @MainActor
    func noOpRevertCannotEraseAConcurrentEdit() async throws {
        let fixture = try await Iter2AppCoreSummaryTests.fixture()
        var record = Iter2AppCoreSummaryTests.record(
            fixture, tool: .area, subject: "Slab", geometry: Iter2AppCoreSummaryTests.rectangle(fixture, width: 100, height: 50)
        )
        record.label = "Original"
        try await Iter2AppCoreSummaryTests.add(fixture, record)
        let bus = DocumentCommandBus(session: fixture.session)

        for round in 0..<10 {
            let before = try #require(await fixture.session.markup(record.id)?.label)
            let edited = "Edit \(round)"
            // A: the same label again — a no-op. B: a real edit of the same markup, started while
            // A's apply is on the session actor.
            let noOp = Task { @MainActor in try await bus.perform(.editLabel(id: record.id, label: before)) }
            let edit = Task { @MainActor in try await bus.perform(.editLabel(id: record.id, label: edited)) }
            _ = try await noOp.value
            _ = try await edit.value
            // Old output: `before` — A's separate revert reached the actor after B's apply and
            // wrote the pre-A record back, while B's undo entry stayed on the stack.
            #expect(await fixture.session.markup(record.id)?.label == edited, "round \(round)")
        }
        // Only the ten real edits are steps; undoing all of them leaves the original label.
        for _ in 0..<10 { await bus.undo() }
        #expect(await fixture.session.markup(record.id)?.label == "Original")
        #expect(!bus.undoManager.canUndo)
    }

    @Test("The session answers a no-op with nil and leaves the record byte-identical")
    func sessionRevertsANoOpInOneCall() async throws {
        let fixture = try await Iter2AppCoreSummaryTests.fixture()
        var record = Iter2AppCoreSummaryTests.record(
            fixture, tool: .area, subject: "Slab", geometry: Iter2AppCoreSummaryTests.rectangle(fixture, width: 100, height: 50)
        )
        record.label = "Same"
        try await Iter2AppCoreSummaryTests.add(fixture, record)
        let stored = try #require(await fixture.session.markup(record.id))
        #expect(try await fixture.session.apply(.editLabel(id: record.id, label: "Same"), revertingNoOp: true) == nil)
        #expect(await fixture.session.markup(record.id) == stored, "modifiedAt taken back too")
        #expect(try await fixture.session.applyBatch([.editLabel(id: record.id, label: "Same")], revertingNoOp: true) == nil)
        #expect(await fixture.session.markup(record.id) == stored)
        #expect(try await fixture.session.apply(.editLabel(id: record.id, label: "Other"), revertingNoOp: true) != nil)
        #expect(await fixture.session.markup(record.id)?.label == "Other")
    }

    // MARK: S-034

    @Test("A detector's capture method on an uncalibrated sheet survives move, undo and calibration")
    @MainActor
    func captureSurvivesEditThenUndoUncalibrated() async throws {
        let documentID = DocumentID(UUID())
        let page = Iter1AppCoreSessionTests.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let traced = CaptureStamp.stamped(Iter1AppCoreSessionTests.rectangle(on: page, subject: "Room", width: 40, height: 30),
                                          method: .autoTraced(closureWidthsPoints: [25.4]))
        _ = try await session.apply(.addMarkup(traced))
        #expect(await session.uncalibratedCapture(of: traced.id)?.kind == .autoTraced)

        // Moved by hand while the sheet has no scale: it reads as drawn by hand...
        let move = try await session.apply(.moveMarkup(id: traced.id, dx: 5, dy: 0))
        #expect(await session.uncalibratedCapture(of: traced.id) == nil)
        // ...and the undo puts the traced geometry back, so the tracer's stamp counts again.
        _ = try await session.revert(move.inverse)
        // Old output: nil — the move had deleted the side-table entry, and the undo's state patch
        // does not recompute, so nothing brought it back.
        #expect(await session.uncalibratedCapture(of: traced.id)?.kind == .autoTraced)
        #expect(await session.takeoffState().uncalibratedCaptures[traced.id]?.kind == .autoTraced, "the save writes it")

        // Calibrating carries it onto the measurement: 40 × 30 pt at 0.1 m/pt = 12 m², traced.
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        #expect(await session.markup(traced.id)?.measurement?[.planArea]?.value == 12)
        // Old output: nil — the markup read "drawn by hand".
        #expect(await session.markup(traced.id)?.measurement?.provenance?.captureMethod?.kind == .autoTraced)
    }
}
