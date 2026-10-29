import Foundation
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The reserved ledger column an assembly assignment is stored in (ADR-0024).
///
/// Like `Repeat ×` it is assembled into every session's column set, never persisted as a column
/// definition, and so cannot collide with a stored copy of itself. Unlike `Repeat ×` it is
/// hidden and not typed into: an assignment is made through ``AppCoreEnvironment/applyAssembly(_:parameters:to:)``.
public enum AssemblyColumn {

    static let namespace = "zenit.pdf/ledger/reserved-column/v1"

    /// The column's key, which saved layouts and the Column Manager recognise as reserved.
    public static let key = "zenit.assembly"

    /// The column's identity in the domain: what `record.customValues` is keyed by.
    public static let columnID = ColumnID(LedgerIdentifiers.deterministicUUID(namespace: namespace, name: "assembly"))

    /// The column definition, hidden and read-only.
    static func definition(order: Int) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: columnID,
            key: key,
            title: NSLocalizedString("Assembly", comment: "Quantity Ledger reserved column: the assembly a measurement produces rows through"),
            kind: .text,
            standard: nil,
            isEditable: false,
            isVisible: false,
            order: order
        )
    }
}

extension TakeoffSession {

    /// The rows the ledger shows: every ledger markup, each measured source followed at once by
    /// the rows its assembly derives (ADR-0024). Derived rows exist only here — never in the
    /// markup table, never on the canvas, never in the file — so they cannot be stale, edited
    /// or orphaned.
    var ledgerRecords: [MarkupRecord] {
        var output: [MarkupRecord] = []
        for record in ledgerMarkups {
            output.append(record)
            output.append(contentsOf: LedgerAssemblyExpansion.derivedRecords(
                for: record,
                assignmentColumn: AssemblyColumn.columnID,
                repeatColumn: RepetitionColumn.columnID
            ))
        }
        return output
    }

    /// The derived rows of one source markup, as the ledger would show them now.
    public func derivedRows(of source: MarkupID) -> [MarkupRecord] {
        guard let record = markup(source) else { return [] }
        return LedgerAssemblyExpansion.derivedRecords(
            for: record, assignmentColumn: AssemblyColumn.columnID, repeatColumn: RepetitionColumn.columnID
        )
    }

    /// Whether `id` is a derived row of some markup in this document.
    public func isDerivedRow(_ id: MarkupID) -> Bool {
        guard markup(id) == nil else { return false }
        return ledgerMarkups.contains { source in
            source.customValues[AssemblyColumn.columnID] != nil && derivedRows(of: source.id).contains { $0.id == id }
        }
    }

    /// The records a ledger edit list needs for the changed markups: each changed markup, and
    /// every row its assembly derives, keyed by id — so a moved wall re-derives its studs in
    /// the same incremental update.
    func ledgerRecordsAffected(by changed: Set<MarkupID>) -> [MarkupID: MarkupRecord] {
        var records: [MarkupID: MarkupRecord] = [:]
        for id in changed {
            guard let record = markup(id) else { continue }
            records[id] = record
            for derived in LedgerAssemblyExpansion.derivedRecords(
                for: record, assignmentColumn: AssemblyColumn.columnID, repeatColumn: RepetitionColumn.columnID
            ) {
                records[derived.id] = derived
            }
        }
        return records
    }
}

// MARK: - Applying an assembly

extension AppCoreEnvironment {

    /// Assigns an assembly — or, with `nil`, removes it — on every markup in `markupIDs`, as
    /// **one** undoable step (ADR-0024). Refused whole, with a reason, when a row is locked, is
    /// itself derived, or measures nothing an assembly can read.
    public func applyAssembly(
        _ assemblyID: UUID?,
        parameters: [String: Domain.Quantity],
        to markupIDs: Set<UUID>
    ) async -> LedgerBulkEditReceipt {
        let actionName = assemblyID == nil
            ? NSLocalizedString("Remove Assembly", comment: "Undo action name: an assembly removed from measurements")
            : NSLocalizedString("Apply Assembly", comment: "Undo action name: an assembly applied to measurements")
        // A built-in recipe is named by id; an office recipe also travels in the assignment, so
        // the project derives the same rows where that library is not installed.
        let assignment = assemblyID.flatMap {
            AssemblyOffer.assignment($0, parameters: parameters, office: ledger.officeAssemblies, project: ledger.projectAssemblies)
        }
        if assemblyID != nil, assignment == nil {
            return .failure(NSLocalizedString(
                "Nothing was changed: that assembly is not in this version of Zenit PDF.",
                comment: "Assembly refusal: unknown recipe"
            ))
        }
        let cell: Domain.CellValue = assignment?.cellValue ?? .empty
        var batch: [DocumentCommand] = []
        var derived = 0
        var locked = 0
        var unmeasured = 0
        for raw in markupIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let id = MarkupID(raw)
            guard let record = await session.markup(id) else {
                if await session.isDerivedRow(id) { derived += 1 }
                continue
            }
            if record.locked { locked += 1; continue }
            guard record.kind.producesQuantity, record.provenance == .measured else { unmeasured += 1; continue }
            let current = record.customValues[AssemblyColumn.columnID] ?? .empty
            guard current != cell else { continue }
            batch.append(.editCustomValue(id: id, column: AssemblyColumn.columnID, value: cell))
        }
        if derived > 0 {
            return .failure(Self.derivedRefusal(count: derived))
        }
        if locked > 0 {
            return .failure(String(format: NSLocalizedString(
                "Nothing was changed: %d of the selected markups are locked. Unlock them and try again.",
                comment: "Bulk edit refusal; the placeholder is the number of locked markups"
            ), locked))
        }
        if unmeasured > 0 {
            return .failure(String(format: NSLocalizedString(
                "Nothing was changed: %d of the selected rows measure nothing an assembly can read.",
                comment: "Assembly refusal: rows that are not measurements"
            ), unmeasured))
        }
        guard !batch.isEmpty else { return LedgerBulkEditReceipt(undoActionName: actionName) }
        do {
            let outcome = try await commands.performBatch(batch, actionName: actionName)
            await ledger.refresh()
            return LedgerBulkEditReceipt(
                changedMarkupIDs: Set((outcome?.changedMarkupIDs ?? []).map(\.rawValue)),
                undoActionName: actionName
            )
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// The refusal for an edit aimed at derived rows (ADR-0012 rule 1).
    static func derivedRefusal(count: Int) -> String {
        String(format: NSLocalizedString(
            "Nothing was changed: %d of the selected rows are derived by an assembly from their measured row. Edit the measured row instead.",
            comment: "Refusal for an edit aimed at derived rows; the placeholder is how many"
        ), count)
    }
}

// MARK: - The presenter's side

extension AppLedgerPresenter: LedgerAssemblyApplying {

    public var availableAssemblies: [LedgerAssemblySummary] {
        AssemblyOffer.summaries(office: officeAssemblies, project: projectAssemblies)
    }

    public func applyAssembly(
        _ id: UUID?,
        parameters: [String: ZPDFUIPresentation.DecimalQuantity],
        to markupIDs: Set<UUID>
    ) async -> LedgerBulkEditReceipt {
        guard let onApplyAssembly else {
            return .failure(NSLocalizedString(
                "This ledger cannot be edited.",
                comment: "Bulk edit refusal when no document is attached to the ledger"
            ))
        }
        return await onApplyAssembly(id, parameters.mapValues { Domain.Quantity(shown: $0) }, markupIDs)
    }
}
