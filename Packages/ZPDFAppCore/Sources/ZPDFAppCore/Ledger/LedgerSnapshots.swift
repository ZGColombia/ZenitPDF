import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// A takeoff snapshot's stored body (NL-QTY-16): every ledger row as the ledger showed it —
/// its words and its exact values — so a later change report compares values, not renderings,
/// and prints the renderings a person recognises.
struct LedgerSnapshotBody: Codable, Hashable, Sendable {

    struct Cell: Codable, Hashable, Sendable {
        /// A canonical, exact spelling of the value — what comparison uses.
        var raw: String
        /// The ledger's own formatted text — what the report prints.
        var display: String
    }

    struct Row: Codable, Hashable, Sendable {
        var markupID: UUID
        var subject: String
        var label: String
        /// The row's primary quantity (the `Value` column), exact, SI.
        var primary: ZPDFUIPresentation.DecimalQuantity?
        /// Whether the primary quantity may be added to another row's (a slope may not).
        var primaryAdds: Bool
        var cells: [String: Cell]
    }

    var columnTitles: [String: String]
    var columnOrder: [String]
    var rows: [Row]
}

extension TakeoffSession {

    /// The columns a snapshot records: every column the ledger shows, less `Modified`, which
    /// moves on every edit and would bury the change that matters.
    static let snapshotSkippedColumns: Set<String> = [StandardLedgerColumn.modified.rawValue]

    /// The current ledger — every row, no filter — as a snapshot body.
    func ledgerSnapshotBody() throws -> LedgerSnapshotBody {
        let projection = try ledgerProjection(.flat)
        let columns = projection.columns.filter { !Self.snapshotSkippedColumns.contains($0.id.rawValue) }
        // The ledger's own additivity rule (S-031): the column a row's `Value` came from decides,
        // through the reader the ledger's headings use. A dimension test called a Rise/Drop row's
        // rise — a length — additive, so the report's length totals counted rises the ledger refuses
        // to total (BH-240).
        let reader = LedgerBridge.PrimaryQuantityReader(view: projection.view, formatter: projection.formatter)
        var rows: [LedgerSnapshotBody.Row] = []
        rows.reserveCapacity(projection.rowCount)
        for index in 0..<projection.rowCount {
            guard let row = projection.row(at: index) else { continue }
            var cells: [String: LedgerSnapshotBody.Cell] = [:]
            for column in columns {
                let value = row.value(column.id)
                let display = row.displayValue(column.id)
                if case .empty = value, display.isEmpty { continue }
                cells[column.id.rawValue] = .init(raw: Self.canonical(value), display: display)
            }
            let primary = LedgerDefaultColumns.primaryQuantity(for: row)
            let contribution = reader.contribution(atStoreIndex: projection.view.tree.orderedRowIndices[index])
            rows.append(.init(
                markupID: row.markupID,
                subject: row.displayValue(.subject),
                label: row.displayValue(.label),
                primary: primary,
                primaryAdds: contribution.map { $0.isAdditive && !$0.quantity.dimension.ratio && !$0.quantity.dimension.angle } ?? false,
                cells: cells
            ))
        }
        return LedgerSnapshotBody(
            columnTitles: Dictionary(columns.map { ($0.id.rawValue, $0.title) }, uniquingKeysWith: { first, _ in first }),
            columnOrder: columns.map(\.id.rawValue),
            rows: rows
        )
    }

    /// An exact spelling of a cell value: two cells are the same value exactly when these agree.
    static func canonical(_ value: ZPDFUIPresentation.LedgerCellValue) -> String {
        switch value {
        case .empty: return ""
        case .text(let text): return "t:" + text
        case .number(let number): return "n:\(number)"
        case .quantity(let quantity):
            let d = quantity.dimension
            return "q:\(quantity.value)|\(d.lengthPower)|\(d.angle)|\(d.currencyCode ?? "")|\(d.ratio)"
        case .currency(let amount, let code): return "c:\(amount) \(code)"
        case .date(let date): return "d:\(date.timeIntervalSinceReferenceDate)"
        case .checkbox(let flag): return "b:\(flag)"
        case .choice(let choice): return "o:" + choice
        }
    }
}

/// The spelling the `Type` cell had before it named the measurement tool (T-046).
///
/// The cell used to hold the markup *kind* (`"measurement"` for every measuring path); it now
/// holds the tool (`"length"`, `"area"`, `"count"`), and a markup without a tool keeps its kind.
/// Snapshots and workbooks written before that change still carry the kind. A markup's tool is
/// fixed when it is made (only the kinds that measure carry one), so an old kind token against
/// the same markup's tool token is the same Type, spelled the old way — not a change.
public enum LedgerPreToolTypeToken {

    /// Whether `stored` is the old spelling of the Type that `current` spells now: `stored` is
    /// the token of a kind that carries a tool, `current` is a tool's token, and they differ
    /// (when they agree there is nothing to reconcile).
    public static func isOldSpelling(_ stored: String, of current: String) -> Bool {
        guard stored != current,
              let kind = ZPDFContracts.MarkupKind(rawValue: stored), kind.producesQuantity,
              ZPDFContracts.MeasurementTool(rawValue: current) != nil
        else { return false }
        return true
    }

    /// The same test on two snapshot cells' canonical spellings (``TakeoffSession/canonical(_:)``,
    /// `"t:"` + the token).
    static func isOldSpelling(canonical stored: String, of current: String) -> Bool {
        let prefix = "t:"
        guard stored.hasPrefix(prefix), current.hasPrefix(prefix) else { return false }
        return isOldSpelling(String(stored.dropFirst(prefix.count)), of: String(current.dropFirst(prefix.count)))
    }
}

/// Builds the change report between a snapshot and the ledger now (NL-QTY-16).
enum LedgerChangeReportBuilder {

    /// The `Type` column's key in a snapshot body.
    static let typeColumnKey = StandardLedgerColumn.icon.rawValue

    /// `before` with every row of a markup still in the ledger carried over to what the markup's
    /// tool says now: whether its quantity adds, and its `Type` cell when the snapshot spelled it
    /// the old way (T-046). Both are properties of the markup's tool, which never changes.
    static func carriedOver(_ before: LedgerSnapshotBody, to after: LedgerSnapshotBody) -> LedgerSnapshotBody {
        let now = Dictionary(after.rows.map { ($0.markupID, $0) }, uniquingKeysWith: { first, _ in first })
        var body = before
        body.rows = before.rows.map { row in
            guard let current = now[row.markupID] else { return row }
            var row = row
            // A snapshot written before S-031 stored a Rise/Drop row as adding; without this its
            // report would show the rise leaving the length totals as a change nobody made.
            row.primaryAdds = current.primaryAdds
            // A snapshot written before T-046 stored every measured row's Type as the kind
            // ("t:measurement"); without this every measured row read as changed, "Type: Length
            // → Length". The words stay the snapshot's own.
            if let stored = row.cells[typeColumnKey], let type = current.cells[typeColumnKey],
               LedgerPreToolTypeToken.isOldSpelling(canonical: stored.raw, of: type.raw) {
                row.cells[typeColumnKey] = LedgerSnapshotBody.Cell(raw: type.raw, display: stored.display)
            }
            return row
        }
        return body
    }

    static func report(
        name: String,
        date: Date,
        before: LedgerSnapshotBody,
        after: LedgerSnapshotBody,
        formatter: QuantityFormatter
    ) -> LedgerChangeReport {
        // Whether a row adds, and its Type, are properties of its markup's tool, which never
        // changes, so a markup still in the ledger answers for its snapshot row too.
        let before = carriedOver(before, to: after)
        let old = Dictionary(before.rows.map { ($0.markupID, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.rows.map { ($0.markupID, $0) }, uniquingKeysWith: { first, _ in first })
        var titles = before.columnTitles
        for (key, title) in after.columnTitles { titles[key] = title }
        var order = after.columnOrder
        for key in before.columnOrder where !order.contains(key) { order.append(key) }

        var changes: [LedgerChangeReport.RowChange] = []
        // Rows in the ledger's current order, then the removed ones in the snapshot's order.
        for row in after.rows {
            guard let previous = old[row.markupID] else {
                changes.append(.init(markupID: row.markupID, kind: .added, subject: row.subject, label: row.label,
                                     fields: fieldChanges(nil, row, order: order, titles: titles)))
                continue
            }
            let fields = fieldChanges(previous, row, order: order, titles: titles)
            if !fields.isEmpty {
                changes.append(.init(markupID: row.markupID, kind: .changed, subject: row.subject, label: row.label, fields: fields))
            }
        }
        for row in before.rows where new[row.markupID] == nil {
            changes.append(.init(markupID: row.markupID, kind: .removed, subject: row.subject, label: row.label,
                                 fields: fieldChanges(row, nil, order: order, titles: titles)))
        }

        return LedgerChangeReport(
            snapshotName: name,
            snapshotDate: date,
            rows: changes,
            subjectTotals: totals(before.rows, after.rows, key: { $0.subject }, formatter: formatter),
            grandTotals: totals(before.rows, after.rows, key: { _ in
                NSLocalizedString("Whole takeoff", comment: "Change report: the grand total's row title")
            }, formatter: formatter)
        )
    }

    static func fieldChanges(
        _ before: LedgerSnapshotBody.Row?,
        _ after: LedgerSnapshotBody.Row?,
        order: [String],
        titles: [String: String]
    ) -> [LedgerChangeReport.FieldChange] {
        order.compactMap { key in
            let lhs = before?.cells[key]
            let rhs = after?.cells[key]
            guard (lhs?.raw ?? "") != (rhs?.raw ?? "") else { return nil }
            return .init(column: titles[key] ?? key, before: lhs?.display ?? "", after: rhs?.display ?? "")
        }
    }

    /// Exact sums of the primary quantity per key and unit, before and after, where they moved.
    static func totals(
        _ before: [LedgerSnapshotBody.Row],
        _ after: [LedgerSnapshotBody.Row],
        key: (LedgerSnapshotBody.Row) -> String,
        formatter: QuantityFormatter
    ) -> [LedgerChangeReport.TotalChange] {
        struct Slot: Hashable { let key: String; let dimension: ZPDFUIPresentation.QuantityDimension }
        func sums(_ rows: [LedgerSnapshotBody.Row]) -> [Slot: Decimal] {
            var result: [Slot: Decimal] = [:]
            for row in rows {
                guard row.primaryAdds, let quantity = row.primary else { continue }
                result[Slot(key: key(row), dimension: quantity.dimension), default: 0] += quantity.value
            }
            return result
        }
        let lhs = sums(before)
        let rhs = sums(after)
        let slots = Set(lhs.keys).union(rhs.keys).sorted {
            $0.key == $1.key ? $0.dimension.lengthPower < $1.dimension.lengthPower : $0.key < $1.key
        }
        return slots.compactMap { slot in
            let was = lhs[slot] ?? 0
            let now = rhs[slot] ?? 0
            guard was != now else { return nil }
            let a = ZPDFUIPresentation.DecimalQuantity(value: was, dimension: slot.dimension)
            let b = ZPDFUIPresentation.DecimalQuantity(value: now, dimension: slot.dimension)
            let d = ZPDFUIPresentation.DecimalQuantity(value: now - was, dimension: slot.dimension)
            let deltaText = (d.value > 0 ? "+" : "") + formatter.text(d)
            return .init(title: slot.key, before: a, after: b, beforeText: formatter.text(a), afterText: formatter.text(b), deltaText: deltaText)
        }
    }
}

// MARK: - The environment's side

extension AppCoreEnvironment {

    /// Stores the takeoff as it is now under `name` (NL-QTY-16).
    public func takeLedgerSnapshot(named name: String) async throws -> String {
        guard let store = history.attachedStore else { throw DocumentCommandError.ledgerFailed("no project database") }
        let body = try await session.ledgerSnapshotBody()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(body), as: UTF8.self)
        let id = UUID().uuidString
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = LedgerSnapshotRecord(
            id: id, projectId: store.projectID,
            name: trimmed.isEmpty ? NSLocalizedString("Snapshot", comment: "Default name of a takeoff snapshot") : trimmed,
            createdAt: PersistenceTimestamp.string(from: Date()),
            author: AuthorIdentity.current(),
            rowCount: body.rows.count,
            bodyJson: json
        )
        try await store.database.write { db in try LedgerSnapshotStore.insert(record, in: db) }
        return id
    }

    /// The project's snapshots, newest first.
    public func ledgerSnapshots() async -> [LedgerSnapshotSummary] {
        guard let store = history.attachedStore else { return [] }
        let records = (try? await store.database.read { db in try LedgerSnapshotStore.list(project: store.projectID, in: db) }) ?? []
        return records.map {
            LedgerSnapshotSummary(
                id: $0.id, name: $0.name,
                createdAt: PersistenceTimestamp.date(from: $0.createdAt) ?? .distantPast,
                author: $0.author, rowCount: $0.rowCount
            )
        }
    }

    /// What changed since a snapshot.
    public func ledgerChangeReport(since snapshotID: String) async throws -> LedgerChangeReport {
        guard let store = history.attachedStore,
              let record = try await store.database.read({ db in
                  try LedgerSnapshotStore.snapshot(id: snapshotID, project: store.projectID, in: db)
              })
        else { throw DocumentCommandError.ledgerFailed("snapshot not found") }
        let before = try JSONDecoder().decode(LedgerSnapshotBody.self, from: Data(record.bodyJson.utf8))
        let after = try await session.ledgerSnapshotBody()
        return LedgerChangeReportBuilder.report(
            name: record.name,
            date: PersistenceTimestamp.date(from: record.createdAt) ?? .distantPast,
            before: before,
            after: after,
            formatter: ledger.projectionFormatter
        )
    }

    /// Deletes a snapshot.
    public func deleteLedgerSnapshot(_ snapshotID: String) async -> Bool {
        guard let store = history.attachedStore else { return false }
        return (try? await store.database.write { db in
            try LedgerSnapshotStore.delete(id: snapshotID, project: store.projectID, in: db)
        }) ?? false
    }
}

extension AppLedgerPresenter: LedgerSnapshotting {

    public func snapshots() async -> [LedgerSnapshotSummary] {
        await snapshotSeam?.list() ?? []
    }

    public func takeSnapshot(named name: String) async -> LedgerBulkEditReceipt {
        guard let seam = snapshotSeam else { return .failure(NSLocalizedString(
            "This ledger cannot be edited.", comment: "Bulk edit refusal when no document is attached to the ledger"
        )) }
        do {
            _ = try await seam.take(name)
            return LedgerBulkEditReceipt(undoActionName: NSLocalizedString("Take Snapshot", comment: "Name of the take-snapshot action"))
        } catch {
            return .failure(String(format: NSLocalizedString(
                "The snapshot was not stored: %@", comment: "Snapshot refusal with the reason"
            ), String(describing: error)))
        }
    }

    public func changeReport(since snapshotID: String) async throws -> LedgerChangeReport {
        guard let seam = snapshotSeam else { throw DocumentCommandError.ledgerFailed("no document") }
        return try await seam.report(snapshotID)
    }

    public func deleteSnapshot(_ snapshotID: String) async -> Bool {
        await snapshotSeam?.delete(snapshotID) ?? false
    }
}

/// The snapshot operations the presenter reaches, installed by the environment.
public struct LedgerSnapshotSeam: Sendable {
    public let list: @MainActor @Sendable () async -> [LedgerSnapshotSummary]
    public let take: @MainActor @Sendable (String) async throws -> String
    public let report: @MainActor @Sendable (String) async throws -> LedgerChangeReport
    public let delete: @MainActor @Sendable (String) async -> Bool
}
