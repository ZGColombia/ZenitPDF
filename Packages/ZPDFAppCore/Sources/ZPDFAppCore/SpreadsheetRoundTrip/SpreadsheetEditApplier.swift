import Foundation
import ZPDFContracts
import struct ZPDFPersistence.DecimalString
import ZPDFQuantityLedger

/// One cell a spreadsheet changed and a person accepted in the review (NL-PLAT-07).
public struct SpreadsheetCellEdit: Hashable, Sendable {
    public let markupID: UUID
    /// The ledger column key (`subject`, `costCode`, a custom column's key…).
    public let columnKey: String
    /// The cell's text from the file, verbatim.
    public let text: String

    public init(markupID: UUID, columnKey: String, text: String) {
        self.markupID = markupID
        self.columnKey = columnKey
        self.text = text
    }
}

/// What applying a reviewed set of spreadsheet edits did.
public struct SpreadsheetApplyReceipt: Equatable, Sendable {
    public var applied: Int = 0
    /// Edits refused at apply time, with why, so the person is told rather than guessed at.
    public var refused: [(edit: SpreadsheetCellEdit, reason: String)] = []

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.applied == rhs.applied && lhs.refused.map(\.edit) == rhs.refused.map(\.edit)
            && lhs.refused.map(\.reason) == rhs.refused.map(\.reason)
    }
}

extension AppCoreEnvironment {

    /// The undo action name, and the audit trail's name for who made the change.
    public static var spreadsheetImportActionName: String {
        NSLocalizedString("Apply Spreadsheet Changes", comment: "Undo action name and audit label for applying reviewed spreadsheet edits")
    }

    /// Applies reviewed spreadsheet edits as **one** undoable step, through the same commands a
    /// person's own edits use: Subject, Label and Comment through their own commands, the
    /// estimating columns (Cost Code, Trade, Phase, Material, Unit Cost) and custom text columns
    /// as custom values. A measured quantity, a formula and any column that holds no typed value
    /// is refused here too — the review already refused them, and this is the second lock on the
    /// same door. Locked markups and rows no longer in the ledger are refused and named.
    public func applySpreadsheetEdits(_ edits: [SpreadsheetCellEdit]) async throws -> SpreadsheetApplyReceipt {
        var receipt = SpreadsheetApplyReceipt()
        guard !edits.isEmpty else { return receipt }
        let columns = await session.ledgerColumns
        let records = await session.orderedMarkups
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var commands: [DocumentCommand] = []
        // One currency lookup per column, not one scan of every markup per cell (R-068): a newly
        // filled column holds no amount yet, so each lookup walked the whole takeoff.
        var currencyCodes: [ColumnID: String] = [:]
        for edit in edits {
            let id = MarkupID(edit.markupID)
            guard let record = byID[id] else {
                receipt.refused.append((edit, NSLocalizedString("the markup is no longer in the ledger", comment: "Spreadsheet apply refusal")))
                continue
            }
            guard !record.locked else {
                receipt.refused.append((edit, NSLocalizedString("the markup is locked", comment: "Spreadsheet apply refusal")))
                continue
            }
            switch edit.columnKey {
            case StandardLedgerColumn.subject.rawValue:
                commands.append(.editSubject(id: id, subject: edit.text))
                continue
            case StandardLedgerColumn.label.rawValue:
                commands.append(.editLabel(id: id, label: edit.text))
                continue
            case StandardLedgerColumn.comment.rawValue:
                commands.append(.editComment(id: id, comment: edit.text))
                continue
            default:
                break
            }
            guard let column = columns.column(key: edit.columnKey), LedgerBridge.holdsUserValues(column) else {
                receipt.refused.append((edit, NSLocalizedString("the column is measured or computed; its value comes from the drawing", comment: "Spreadsheet apply refusal")))
                continue
            }
            let trimmed = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: LedgerCellValue
            switch column.kind {
            case .text:
                value = trimmed.isEmpty ? .empty : .text(edit.text)
            case .currency:
                if trimmed.isEmpty {
                    value = .empty
                } else if let amount = DecimalString(text: trimmed)?.value {
                    // The persistence layer's strict whole-string literal (R-193). The old
                    // character filter plus `Decimal(string:)`, a prefix parser, applied
                    // "1.250.00" as 1.25 and "12-5" as 12.
                    let code = currencyCodes[column.id] ?? LedgerBridge.ledgerCurrencyCode(
                        store: ledger.projectedStore, formatter: ledger.projectionFormatter, preferring: column.id
                    )
                    currencyCodes[column.id] = code
                    value = .currency(amount: amount, code: code)
                } else {
                    receipt.refused.append((edit, NSLocalizedString("the new value is not a number", comment: "Spreadsheet apply refusal")))
                    continue
                }
            default:
                receipt.refused.append((edit, NSLocalizedString("this kind of column is not brought back from a spreadsheet", comment: "Spreadsheet apply refusal")))
                continue
            }
            commands.append(.editCustomValue(id: id, column: column.id, value: value))
        }
        guard !commands.isEmpty else { return receipt }
        try await self.commands.performBatch(commands, actionName: Self.spreadsheetImportActionName)
        receipt.applied = commands.count
        await refresh()
        return receipt
    }
}
