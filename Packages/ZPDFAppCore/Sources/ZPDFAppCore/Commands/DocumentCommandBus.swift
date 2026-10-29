import Foundation
import Observation
import ZPDFContracts

/// The single door every document mutation goes through.
///
/// Nothing else in the app calls ``TakeoffSession/apply(_:)``. That is the whole point:
/// if there were two ways to change a document, one of them would eventually forget to
/// register undo, and the user would discover it by losing an afternoon's takeoff.
///
/// The bus is `@MainActor` because `UndoManager` is, and because the presenters it
/// refreshes are. The engine work happens inside the session; the bus awaits it.
@MainActor
@Observable
public final class DocumentCommandBus {

    /// The document's undo stack. `NSDocument` supplies its own; a standalone session gets
    /// the one created here.
    public let undoManager: UndoManager

    /// The session commands are applied to.
    public let session: TakeoffSession

    /// The most recent command that ran, for the status line and for tests.
    public private(set) var lastCommandKind: MarkupCommandKind?

    /// The most recent failure, so a refused command surfaces instead of vanishing.
    public private(set) var lastError: DocumentCommandError?

    /// Whether a command is in flight, so the UI can keep a second one from being queued
    /// on top of it.
    ///
    /// Derived from a depth count rather than set and cleared: the bus is re-entrant on the
    /// main actor, so a second command can start while the first is awaiting the session, and
    /// a plain flag went false the moment *either* of them finished (CR-17).
    public var isApplying: Bool { applyingDepth > 0 }

    /// How many commands are between their first line and their last, right now.
    private var applyingDepth: Int = 0

    /// Called after every applied, undone or redone command, with what changed.
    ///
    /// The bus does not know about presenters; the environment wires this to them. That
    /// keeps the undo mechanism testable without a single view existing.
    public var onChange: (@MainActor (DocumentChangeSet) async -> Void)?

    /// Audit hook: a command was applied. Returns an opaque token identifying the audit
    /// entry the observer recorded — the bus carries it into the undo registration so a
    /// later ⌘Z can name exactly which entry it compensates (ADR-0007 §2).
    ///
    /// Optional and side-effect-free for the bus: a session without a history feed simply
    /// leaves both hooks `nil`.
    public var onAuditApply: (@MainActor (DocumentCommandOutcome) -> String?)?

    /// Audit hook: a *batch* was applied. Returns the token of the `undo_group` the
    /// observer wrote its entries under — one entry per affected markup, one group for
    /// the whole step, which is exactly the shape ADR-0007 §2 describes. Undo compensates
    /// the group, not a row, so a bulk edit of eleven markups is undone as eleven
    /// compensating entries rather than one that names a single arbitrary markup.
    public var onAuditApplyBatch: (@MainActor (DocumentBatchOutcome, String) -> String?)?

    /// Audit hook: the entry named by `token` was undone (or a compensation was itself
    /// redone). Returns the token of the *compensating* entry, which the re-registered
    /// redo carries — so an undo/redo ping-pong reads as an append-only chain in the
    /// trail, never as edits to it.
    public var onAuditRevert: (@MainActor (String) -> String?)?

    /// Creates a bus over a session.
    public init(session: TakeoffSession, undoManager: UndoManager = UndoManager()) {
        self.session = session
        self.undoManager = undoManager
    }

    // MARK: Applying

    /// Applies a command, registers its undo, and refreshes whatever changed.
    ///
    /// - Throws: ``DocumentCommandError`` when the session refuses. A refused command
    ///   leaves both the document and the undo stack untouched — there is no half-entry.
    @discardableResult
    public func perform(_ command: DocumentCommand) async throws -> DocumentChangeSet {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        // Chained behind any undo or redo still in flight. A command performed while a revert
        // was queued reached the session first, so the document received the new command and
        // *then* the state patch of the undo — the undo stack said one thing and the document
        // another (CR-7). Waiting here is what keeps the two in the order the person acted.
        await settle()
        let step = beginStep(actionName: command.undoActionName)
        do {
            // A command that changed nothing a person can see is not a step: no undo entry, no
            // dirty document, no trail row. Its `modifiedAt` bump is taken back so the saved
            // file does not differ from the one the person thinks they have (BH-422) — inside
            // the session's own call, so no other command can land between the two (S-027).
            guard let outcome = try await session.apply(command, revertingNoOp: true) else {
                cancelStep(step)
                lastCommandKind = command.kind
                lastError = nil
                return DocumentChangeSet(invalidatesScale: command.invalidatesScale)
            }
            completeStep(step, inverse: outcome.inverse, forward: outcome.forward, auditToken: onAuditApply?(outcome))
            lastCommandKind = command.kind
            lastError = nil
            return await publish(outcome)
        } catch let error as DocumentCommandError {
            cancelStep(step)
            lastError = error
            throw error
        } catch {
            cancelStep(step)
            throw error
        }
    }

    /// Applies several commands as one undoable step, and refreshes whatever changed.
    ///
    /// The ledger's bulk edit is the caller this exists for: multi-selection changes to
    /// subject, label, status, colour and custom values arrive as one list, land as one
    /// entry on the undo stack, and appear in the History pane as one group of per-markup
    /// entries. See ``TakeoffSession/applyBatch(_:)`` for the atomicity guarantee.
    ///
    /// - Parameters:
    ///   - commands: the mutations, in the order they should be applied.
    ///   - actionName: what the Edit menu says after "Undo". Supplied by the caller
    ///     because "Undo Edit Value" for a step that also changed four statuses and a
    ///     colour would be a lie about what Cmd-Z is about to do.
    /// - Returns: the batch outcome, or `nil` when `commands` is empty or changed nothing.
    /// - Throws: ``DocumentCommandError`` when the session refuses. Nothing is applied and
    ///   nothing is registered.
    @discardableResult
    public func performBatch(
        _ commands: [DocumentCommand],
        actionName: String
    ) async throws -> DocumentBatchOutcome? {
        guard !commands.isEmpty else { return nil }
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        // Chained behind any undo or redo still in flight (CR-7).
        await settle()
        let step = beginStep(actionName: actionName)
        do {
            // The same rule as `perform` (BH-422): a batch that changed nothing a person can see
            // is not a step — no undo entry, no dirty document, no trail rows — and its
            // `modifiedAt` bumps are taken back (R-057), in the same session call (S-027).
            guard let outcome = try await session.applyBatch(commands, revertingNoOp: true) else {
                cancelStep(step)
                lastCommandKind = commands.last?.kind
                lastError = nil
                return nil
            }
            completeStep(
                step,
                inverse: outcome.inverse,
                forward: outcome.forward,
                auditToken: onAuditApplyBatch?(outcome, actionName)
            )
            lastCommandKind = commands.last?.kind
            lastError = nil
            _ = await publish(batch: outcome)
            return outcome
        } catch let error as DocumentCommandError {
            cancelStep(step)
            lastError = error
            throw error
        } catch {
            cancelStep(step)
            throw error
        }
    }

    /// Calibrates the document scale and registers the undo for it.
    ///
    /// Calibration lives on the bus rather than being called straight on the session so
    /// that it cannot be the one mutation nobody can take back.
    ///
    /// `scaleID` is what makes a **Scale Region's own** calibration possible: passing a fresh
    /// identifier installs a second scale beside the page scale instead of recalibrating it,
    /// which is the whole point of a region — a detail view drawn at 1:20 on a 1:100 sheet.
    ///
    /// `page` is required and is not defaulted. A calibration is always *of a sheet*: the two
    /// points were picked on one, and a call that cannot say which is a call that would have
    /// had the session guess. Passing the wrong page is still possible, but passing none is not.
    ///
    /// A refusal is recorded in ``lastError`` like every other command's. It used to rethrow
    /// without touching it, so the bus went on reporting the previous success (BH-421).
    @discardableResult
    public func calibrate(
        page: PageID,
        first: PDFPoint,
        second: PDFPoint,
        knownLength: Decimal,
        knownLengthUnit: Domain.Length,
        scaleID: ScaleID? = nil,
        label: String? = nil,
        allowExtreme: Bool = false
    ) async throws -> DocumentChangeSet {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        // Chained behind any undo or redo still in flight (CR-7).
        await settle()
        // A calibration is always a `.changeScale` step; its name is known before the outcome.
        let step = beginStep(actionName: NSLocalizedString("Change Scale", comment: "Undo action name for a scale change"))
        do {
            let outcome = try await session.calibrate(
                page: page,
                first: first,
                second: second,
                knownLength: knownLength,
                knownLengthUnit: knownLengthUnit,
                scaleID: scaleID,
                label: label,
                allowExtreme: allowExtreme
            )
            completeStep(step, inverse: outcome.inverse, forward: outcome.forward, auditToken: onAuditApply?(outcome))
            lastCommandKind = outcome.command.kind
            lastError = nil
            return await publish(outcome)
        } catch let error as DocumentCommandError {
            cancelStep(step)
            lastError = error
            throw error
        } catch {
            cancelStep(step)
            lastError = .ledgerFailed(String(describing: error))
            throw error
        }
    }

    /// Runs one session mutation that is not a plain ``DocumentCommand`` — a preset scale, an
    /// X/Y calibration — as one undoable step, with the same settle, step registration, audit
    /// and refusal bookkeeping as ``calibrate(page:first:second:knownLength:knownLengthUnit:scaleID:label:allowExtreme:)``.
    /// The scale entry points in `DocumentCommandBus+ScaleEntry.swift` are its callers.
    @discardableResult
    func performSessionStep(
        actionName: String,
        _ body: (TakeoffSession) async throws -> DocumentCommandOutcome
    ) async throws -> DocumentChangeSet {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        await settle()
        let step = beginStep(actionName: actionName)
        do {
            let outcome = try await body(session)
            completeStep(step, inverse: outcome.inverse, forward: outcome.forward, auditToken: onAuditApply?(outcome))
            lastCommandKind = outcome.command.kind
            lastError = nil
            return await publish(outcome)
        } catch let error as DocumentCommandError {
            cancelStep(step)
            lastError = error
            throw error
        } catch {
            cancelStep(step)
            lastError = .ledgerFailed(String(describing: error))
            throw error
        }
    }

    /// The batch form of ``performSessionStep(actionName:_:)``: several pages' scales as one ⌘Z.
    @discardableResult
    func performSessionBatchStep(
        actionName: String,
        _ body: (TakeoffSession) async throws -> DocumentBatchOutcome
    ) async throws -> DocumentBatchOutcome {
        applyingDepth += 1
        defer { applyingDepth -= 1 }
        await settle()
        let step = beginStep(actionName: actionName)
        do {
            let outcome = try await body(session)
            completeStep(
                step,
                inverse: outcome.inverse,
                forward: outcome.forward,
                auditToken: onAuditApplyBatch?(outcome, actionName)
            )
            lastCommandKind = outcome.commands.last?.kind
            lastError = nil
            _ = await publish(batch: outcome)
            return outcome
        } catch let error as DocumentCommandError {
            cancelStep(step)
            lastError = error
            throw error
        } catch {
            cancelStep(step)
            lastError = .ledgerFailed(String(describing: error))
            throw error
        }
    }

    // MARK: Undo

    /// One user-visible step on the undo stack, registered **before** the session is asked to
    /// apply it and filled in when it answers.
    ///
    /// The session is an actor, so a command spends time between the key press and the
    /// moment its outcome exists. The step used to be registered only at the end of that
    /// time, and a ⌘Z pressed inside it — Edit ▸ Undo calls `UndoManager.undo()` directly —
    /// popped the *previous* step: the document then received the new command and the old
    /// step's revert in that order, while the new step landed on top of the stack and cleared
    /// the old one's redo. Draw A, drag a vertex of A, ⌘Z mid-drag: A was gone, unredoable, and
    /// the next ⌘Z resurrected it with its pre-drag shape (BH-094).
    ///
    /// Registered first, the step is where the person's intent says it is: the ⌘Z pops *it*,
    /// and its revert waits for the apply it takes back.
    @MainActor
    final class Step {
        var inverse: DocumentCommandInverse?
        var forward: DocumentCommandInverse?
        /// The audit token of the entry the next undo or redo of this step compensates.
        var auditToken: String?
        /// The Edit-menu name the step registers under.
        var actionName = ""
        /// Whether the undo entry is on the stack yet.
        var isRegistered = false
        /// Whether the step's entry sits on the undo stack (as opposed to the redo stack).
        var isOnUndoStack = false
        /// Set while a refused step is being taken back, so its entry does nothing.
        var isWithdrawing = false
        private(set) var isSettled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func settle() {
            isSettled = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }

        /// Returns once the apply this step stands for has answered, one way or the other.
        func settled() async {
            if isSettled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Which way invoking a registration moves the document.
    private enum StepDirection {
        /// Back to the step's inverse — an undo.
        case revert
        /// Forward to the step's after-state — a redo.
        case reapply

        var opposite: StepDirection { self == .revert ? .reapply : .revert }
    }

    /// Registers a step's undo entry before its command is applied — unless there is a redo
    /// to lose.
    ///
    /// Any registration outside an undo clears the redo stack, and withdrawing the entry does
    /// not bring the redo back. A command that is then refused would have cost the person their
    /// redo for nothing, so when a redo exists the entry is registered once the outcome is
    /// known, as it always was (CR-7's "the add is still there to redo").
    private func beginStep(actionName: String) -> Step {
        let step = Step()
        step.actionName = actionName
        if !undoManager.canRedo {
            register(step, direction: .revert, actionName: actionName)
            step.isRegistered = true
            step.isOnUndoStack = true
            lastRegisteredStep = step
        }
        return step
    }

    /// The step registered most recently outside an undo or redo.
    @ObservationIgnored
    private var lastRegisteredStep: Step?

    /// Fills a step in with the command's outcome. A command whose inverse mentions nothing
    /// is not a step, and its entry is withdrawn.
    private func completeStep(
        _ step: Step,
        inverse: DocumentCommandInverse,
        forward: DocumentCommandInverse,
        auditToken: String?
    ) {
        guard !inverse.isEmpty else {
            cancelStep(step)
            return
        }
        step.inverse = inverse
        step.forward = forward
        step.auditToken = auditToken
        if !step.isRegistered {
            register(step, direction: .revert, actionName: step.actionName)
            step.isRegistered = true
            step.isOnUndoStack = true
            lastRegisteredStep = step
        }
        step.settle()
    }

    /// Withdraws a step whose command was refused or changed nothing — from both stacks, in
    /// case a ⌘Z already moved it — so no entry is left that would do nothing.
    ///
    /// A registration already told the document it changed — `NSDocument` counts a closed undo
    /// group as `.changeDone` — and withdrawing an entry does not take that back, so a refused
    /// delete left the document marked edited with nothing to undo. When the step is still the
    /// top of the undo stack it is *undone* instead, silently: the document hears
    /// `.changeUndone`, the count balances, and the entry does nothing. A step the person
    /// already undid mid-flight was balanced by that undo.
    private func cancelStep(_ step: Step) {
        if step.isRegistered, step.isOnUndoStack, lastRegisteredStep === step, undoManager.canUndo {
            step.isWithdrawing = true
            undoManager.undo()
        }
        undoManager.removeAllActions(withTarget: step)
        if lastRegisteredStep === step { lastRegisteredStep = nil }
        step.settle()
    }

    /// Registers one direction of a step with `UndoManager`.
    ///
    /// The subtlety this exists for: `UndoManager` files a registration on the redo stack
    /// only while it is *currently* undoing. The revert itself is asynchronous — the session
    /// is an actor — so the opposite direction is registered synchronously inside the
    /// invocation, before any await, and the asynchronous revert is queued afterwards. The
    /// patches are read when the queued revert runs, which is after the step has settled.
    ///
    /// `UndoManager` does not retain its targets, so the handler captures the step strongly:
    /// that is what keeps the step — the target the manager hands back, and the key
    /// ``cancelStep(_:)`` withdraws by — alive for exactly as long as an entry names it.
    private func register(_ step: Step, direction: StepDirection, actionName: String) {
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            MainActor.assumeIsolated {
                guard let self, !step.isWithdrawing else { return }
                self.register(step, direction: direction.opposite, actionName: actionName)
                step.isOnUndoStack = direction == .reapply
                self.enqueue(step, direction: direction)
            }
        }
    }

    /// Queues one direction of a step, serialised behind any patch already in flight.
    ///
    /// Serialised rather than concurrent because two reverts racing on the same document
    /// would apply in whichever order the scheduler chose, and undo order is not negotiable.
    ///
    /// The compensating audit entry is recorded only once the revert has succeeded. A revert
    /// that throws withdraws the step from both stacks instead of leaving a redo entry and a
    /// compensation that describe a revert which never happened (BH-423).
    private func enqueue(_ step: Step, direction: StepDirection) {
        let previous = pendingUndo
        pendingGeneration &+= 1
        pendingUndo = Task { @MainActor [weak self] in
            await previous?.value
            await step.settled()
            guard let self else { return }
            let patch = direction == .revert ? step.inverse : step.forward
            guard let patch else { return }
            do {
                _ = try await self.session.revert(patch)
                step.auditToken = step.auditToken.flatMap { self.onAuditRevert?($0) }
                self.lastError = nil
            } catch let error as DocumentCommandError {
                self.undoManager.removeAllActions(withTarget: step)
                self.lastError = error
            } catch {
                self.undoManager.removeAllActions(withTarget: step)
                self.lastError = .ledgerFailed(String(describing: error))
            }
            await Self.$isInsidePendingPatch.withValue(true) {
                await self.publishAll()
            }
        }
    }

    /// Set while a queued undo or redo is publishing its change.
    ///
    /// A change handler that performs a command from inside that publish reaches
    /// ``settle()``, which awaited the very task it was running in and never returned — every
    /// later command and every save then hung for the life of the document (BH-424). Inside
    /// the task there is nothing earlier left to wait for, so ``settle()`` returns at once.
    @TaskLocal static var isInsidePendingPatch = false

    /// The in-flight undo or redo, so a test can await it and the app can avoid stacking two.
    @ObservationIgnored
    public private(set) var pendingUndo: Task<Void, Never>?

    /// Bumped for every queued patch, so ``settle()`` can tell "the task I just awaited"
    /// from "another one arrived while I was waiting" without comparing `Task` values —
    /// `Task` is a struct and has no identity to compare.
    @ObservationIgnored
    private var pendingGeneration: Int = 0

    /// Awaits any in-flight undo or redo.
    ///
    /// `UndoManager.undo()` is synchronous and the revert it triggers is not, so a caller
    /// that needs the document settled — a test, or a save — waits here.
    public func settle() async {
        guard !Self.isInsidePendingPatch else { return }
        while let task = pendingUndo {
            let generation = pendingGeneration
            await task.value
            guard pendingGeneration == generation else { continue }
            pendingUndo = nil
        }
    }

    /// Undoes the last command and waits for the document to settle.
    public func undo() async {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        await settle()
    }

    /// Redoes the last undone command and waits for the document to settle.
    public func redo() async {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        await settle()
    }

    // MARK: Publishing

    private func publish(_ outcome: DocumentCommandOutcome) async -> DocumentChangeSet {
        let change = DocumentChangeSet(
            changedMarkupIDs: Set(outcome.changedMarkupIDs.map(\.rawValue)),
            changedPageIDs: Set(outcome.changedPageIDs.map(\.rawValue)),
            invalidatesLedger: true,
            // From the command, not from its frozen `kind`: the region commands share the
            // `editCustomValue` spelling and were reported as not touching the scale (CR-14).
            invalidatesScale: outcome.command.invalidatesScale
        )
        await onChange?(change)
        return change
    }

    private func publish(batch outcome: DocumentBatchOutcome) async -> DocumentChangeSet {
        let change = DocumentChangeSet(
            changedMarkupIDs: Set(outcome.changedMarkupIDs.map(\.rawValue)),
            changedPageIDs: Set(outcome.changedPageIDs.map(\.rawValue)),
            invalidatesLedger: true,
            invalidatesScale: outcome.commands.contains(where: \.invalidatesScale)
        )
        await onChange?(change)
        return change
    }

    private func publishAll() async {
        await onChange?(DocumentChangeSet.everything)
    }
}

/// What one command changed, in UI identifiers.
///
/// The presenters use it to refresh only what moved. `everything` exists for undo, where
/// the inverse can touch anything and computing a tight set would cost more than the
/// refresh it saves.
public struct DocumentChangeSet: Hashable, Sendable {

    /// Markups whose row or canvas geometry changed.
    public var changedMarkupIDs: Set<UUID>
    /// Pages whose contents or snap index changed.
    public var changedPageIDs: Set<UUID>
    /// Whether the ledger projection has to be rebuilt.
    public var invalidatesLedger: Bool
    /// Whether the scale readout has to be refreshed.
    public var invalidatesScale: Bool

    /// Creates a change set.
    public init(
        changedMarkupIDs: Set<UUID> = [],
        changedPageIDs: Set<UUID> = [],
        invalidatesLedger: Bool = false,
        invalidatesScale: Bool = false
    ) {
        self.changedMarkupIDs = changedMarkupIDs
        self.changedPageIDs = changedPageIDs
        self.invalidatesLedger = invalidatesLedger
        self.invalidatesScale = invalidatesScale
    }

    /// Everything may have changed.
    public static let everything = DocumentChangeSet(
        invalidatesLedger: true,
        invalidatesScale: true
    )
}
