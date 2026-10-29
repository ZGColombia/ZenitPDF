import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Review rounds (NL-COLLAB-19): named checkpoints of a review, and what changed since one — the
/// markups added, removed and changed, the status transitions, and what each subject's quantity
/// did.
///
/// A round is a `review_entry` row of kind `round` filed under the project, carrying its name, the
/// History sequence it closed at and — since W-027 — the ledger's per-subject totals at that
/// moment, when they fit the row (`roundBodyText`). The markups and status moves are a query over the append-only History between two
/// sequences. The quantities are the ledger's own totals now minus the ones the round stored,
/// so a subject rename moves quantity between subjects, a Repeat × change counts, a cutout row
/// adds nothing and a depth or a slope is never summed — the ledger's rules, not a second copy.
extension AppReviewPresenter {

    /// The markup id rounds are filed under: they belong to the project, not to a markup.
    static let projectEntryMarkupID = "00000000-0000-0000-0000-000000000000"

    struct RoundBody: Codable, Hashable {
        var name: String
        var historySequence: Int
        /// The ledger's totals when the round closed, subject → field → exact decimal text.
        /// Absent from a round closed before W-027, and from one whose totals did not fit the
        /// row; that round compares by the History alone.
        var ledgerTotals: [String: [String: String]]?
    }

    public var rounds: [ReviewRound] {
        _ = threadRevision
        return entries
            .filter { $0.kind == "round" && !$0.retracted }
            .compactMap { entry in
                guard let id = UUID(uuidString: entry.id), let body = Self.roundBody(of: entry) else { return nil }
                return ReviewRound(
                    id: id, name: body.name,
                    closedAt: PersistenceTimestamp.date(from: entry.createdAt) ?? Date(timeIntervalSince1970: 0),
                    closedBy: entry.authorName, historySequence: body.historySequence
                )
            }
    }

    static func roundBody(of entry: ReviewEntryRecord) -> RoundBody? {
        try? JSONDecoder().decode(RoundBody.self, from: Data(entry.body.utf8))
    }

    public func closeRound(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty
            ? String(format: NSLocalizedString("Round %lld", comment: "Default name of a review round; its number"), rounds.count + 1)
            : trimmed
        let sequence = history?.auditRecords.map(\.sequence).max() ?? 0
        guard let text = Self.roundBodyText(name: title, historySequence: sequence, ledgerTotals: ledgerTotalsProvider?())
        else { return }
        let record = ReviewEntryRecord(
            id: UUID().uuidString, projectId: currentProjectID, markupId: Self.projectEntryMarkupID,
            kind: "round", authorName: currentAuthor, body: text,
            createdAt: PersistenceTimestamp.string(from: now())
        )
        insertBatch([record], actionName: NSLocalizedString("Close Round", comment: "Undo action name for closing a review round"))
    }

    /// A round's stored body, never longer than `ReviewEntryStore.maximumBodyBytes`. The store
    /// throws for a longer body and the write queue swallows the throw, so a round over a large
    /// ledger (some 500 area subjects) showed, was never written and was gone at the next open.
    /// Totals that do not fit are left out: that round compares by the History, as one closed
    /// before W-027 does. `nil` when even the name does not fit — a round the store would refuse
    /// is never shown.
    static func roundBodyText(name: String, historySequence: Int, ledgerTotals: ReviewRoundTotals?) -> String? {
        let encoder = JSONEncoder()
        for totals in ledgerTotals.map({ [$0.encoded, nil] }) ?? [nil] {
            let body = RoundBody(name: name, historySequence: historySequence, ledgerTotals: totals)
            guard let json = try? encoder.encode(body), json.count <= ReviewEntryStore.maximumBodyBytes else { continue }
            return String(data: json, encoding: .utf8)
        }
        return nil
    }

    public func changes(since round: ReviewRound) -> ReviewRoundDiff {
        var subjects: [UUID: String] = [:]
        for event in history?.events ?? [] {
            if let id = event.markupID, let subject = event.markupSubject { subjects[id] = subject }
        }
        var cutouts: Set<UUID> = []
        for markup in reviewMarkups {
            subjects[markup.id] = markup.subject
            // By tool: `parentID` also names a derived quantity's source, which is a quantity.
            if markup.measurementKind?.isCutout == true { cutouts.insert(markup.id) }
        }
        let stored = entries.first { $0.id == round.id.uuidString }
            .flatMap(Self.roundBody(of:))?.ledgerTotals
            .flatMap(ReviewRoundTotals.init(encoded:))
        let ledgerTotals: (before: ReviewRoundTotals, after: ReviewRoundTotals)? = stored.flatMap { before in
            ledgerTotalsProvider?().map { (before, $0) }
        }
        return Self.diff(
            records: history?.auditRecords ?? [], after: round.historySequence,
            formatter: history?.formatter ?? QuantityFormatter(), subject: { subjects[$0] },
            ledgerTotals: ledgerTotals, isCutout: { cutouts.contains($0) }
        )
    }

    /// The comparison itself, pure: every History row after `sequence`, folded per markup.
    ///
    /// - Parameters:
    ///   - ledgerTotals: the ledger's totals when the round closed and now. When given, they are
    ///     the quantity deltas. Without them — a round closed before W-027 — the deltas are
    ///     folded from the History's measured values under the ledger's rules as far as the
    ///     History records them: each markup's quantity leaves the subject it had and joins the
    ///     one it has, a cutout's own values are skipped and only fields the ledger totals count.
    ///     A Repeat × change is not in the History at all, which is why the totals are stored.
    ///   - isCutout: whether a markup is a cutout, for that fallback.
    static func diff(
        records: [MeasurementAuditRecord],
        after sequence: Int,
        formatter: QuantityFormatter,
        subject subjectOf: (UUID) -> String? = { _ in nil },
        ledgerTotals: (before: ReviewRoundTotals, after: ReviewRoundTotals)? = nil,
        isCutout: (UUID) -> Bool = { _ in false }
    ) -> ReviewRoundDiff {
        var diff = ReviewRoundDiff()
        var spans: [UUID: [MeasurementAuditRecord]] = [:]
        for record in records.sorted(by: { $0.sequence < $1.sequence }) where record.sequence > sequence {
            guard let id = record.markupId.flatMap(UUID.init(uuidString:)) else { continue }
            spans[id, default: []].append(record)
        }
        var folded = ReviewRoundTotals()
        for (id, span) in spans {
            guard let first = span.first, let last = span.last else { continue }
            let before = Self.values(first.beforeValuesJson)
            let after = Self.values(last.afterValuesJson)
            // By action: created in the span and still there is added; there before and deleted
            // in it is removed; created and deleted inside it never happened as far as the round
            // is concerned. An undo or redo (a compensation) counts as a change — conservative.
            let created = first.auditAction == .markupCreated
            let deleted = last.auditAction == .markupDeleted
            switch (created, deleted) {
            case (true, true): continue
            case (true, false): diff.added.insert(id)
            case (false, true): diff.removed.insert(id)
            case (false, false): diff.changed.insert(id)
            }
            if let from = before?[ReviewAuditFields.status] ?? (created ? ZPDFContracts.MarkupStatus.none.rawValue : nil),
               let to = after?[ReviewAuditFields.status],
               from != to,
               let fromStatus = ZPDFContracts.MarkupStatus(rawValue: from), let toStatus = ZPDFContracts.MarkupStatus(rawValue: to) {
                diff.statusTransitions.append(.init(
                    markupID: id,
                    from: ZPDFUIPresentation.MarkupStatus(domain: fromStatus),
                    to: ZPDFUIPresentation.MarkupStatus(domain: toStatus)
                ))
            }
            guard ledgerTotals == nil, !isCutout(id) else { continue }
            // The subject at each end of the span: a review field is written only on the row that
            // changed it, so the first row carrying one says what it was and the last what it
            // became; with none, the markup kept the name it has. The whole delta used to go under
            // the end subject, so a rename from "Wall A" to "Wall B" moved nothing (W-027).
            let endSubject = span.reversed().lazy.compactMap { Self.values($0.afterValuesJson)?[ReviewAuditFields.subject] }.first
                ?? subjectOf(id)
            let startSubject = span.lazy.compactMap { Self.values($0.beforeValuesJson)?[ReviewAuditFields.subject] }.first
                ?? endSubject
            let measuredBefore = created ? [:] : (MeasurementAuditStore.measuredValues(before) ?? [:])
            let measuredAfter = deleted ? [:] : (MeasurementAuditStore.measuredValues(after) ?? [:])
            for (field, text) in measuredBefore where ReviewRoundTotals.summingFields[field] != nil {
                folded.add(-(Self.decimal(text) ?? 0), subject: startSubject ?? "", field: field)
            }
            for (field, text) in measuredAfter where ReviewRoundTotals.summingFields[field] != nil {
                folded.add(Self.decimal(text) ?? 0, subject: endSubject ?? "", field: field)
            }
        }
        let deltas = ledgerTotals.map { $0.after.subtracting($0.before) } ?? folded
        for subject in deltas.bySubject.keys.sorted() {
            for (field, delta) in deltas.bySubject[subject, default: [:]].sorted(by: { $0.key < $1.key }) where delta != 0 {
                var text = String(describing: delta)
                if let dimension = AppHistoryPresenter.fieldDimension(field) {
                    text = formatter.textWithUnit(Shown.Quantity(value: delta, dimension: dimension))
                }
                diff.quantityDeltas.append(.init(
                    subject: subject.isEmpty ? NSLocalizedString("(no subject)", comment: "Review round comparison: markups with no subject") : subject,
                    field: ReviewRoundTotals.title(of: field), delta: delta, deltaText: delta > 0 ? "+" + text : text
                ))
            }
        }
        diff.statusTransitions.sort { $0.markupID.uuidString < $1.markupID.uuidString }
        return diff
    }

    private static func values(_ json: String?) -> [String: String]? {
        (try? MeasurementAuditStore.decodeValues(json)) ?? nil
    }

    private static func decimal(_ text: String) -> Decimal? {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Exact per-subject totals of every measured field the ledger totals (W-027) — what a review
/// round stores when it closes and compares against later.
struct ReviewRoundTotals: Hashable, Sendable {

    /// Subject → measurement field (stored spelling) → exact total.
    private(set) var bySubject: [String: [String: Decimal]] = [:]

    init() {}

    /// The fields the ledger totals, each with the built-in column that reads it: a column the
    /// standard aggregation plan sums (`LedgerAggregationPlan.sums`), so rise, run, depth,
    /// height, radius, diameter, the slopes and `Cutout Area` are absent.
    static let summingFields: [String: StandardLedgerColumn] = {
        var fields: [String: StandardLedgerColumn] = [:]
        for column in (try? LedgerColumnSet.standard())?.columns ?? [] {
            guard let standard = column.standard, let field = standard.measurementField,
                  LedgerAggregationPlan.sums(column) else { continue }
            fields[field.rawValue] = standard
        }
        return fields
    }()

    /// A field's name as the ledger's column heading spells it — `Plan Area` for the net area it
    /// reads (ADR-0016), `Gross Area` for the outline.
    @MainActor
    static func title(of field: String) -> String {
        if let standard = summingFields[field] { return LedgerBridge.standardTitle(standard) }
        return AppHistoryPresenter.fieldDisplayName(field) ?? field
    }

    /// The ledger's totals, read row by row through its one value path
    /// (`LedgerStore.value(at:definition:)`) over every row it holds, filter or not: Repeat ×
    /// multiplies there, and a cutout's own row has empty quantity cells (ADR-0018).
    init(store: LedgerStore) {
        let columns = store.columns.columns.compactMap { column -> (LedgerColumnDefinition, String)? in
            guard let field = column.standard?.measurementField, LedgerAggregationPlan.sums(column) else { return nil }
            return (column, field.rawValue)
        }
        for index in 0..<store.rowCount {
            let subject = store.record(at: index).subject
            for (column, field) in columns {
                switch store.value(at: index, definition: column) {
                case .value(.number(let quantity)), .value(.formulaResult(let quantity, _)):
                    add(quantity.value, subject: subject, field: field)
                default:
                    continue
                }
            }
        }
    }

    mutating func add(_ value: Decimal, subject: String, field: String) {
        bySubject[subject, default: [:]][field, default: 0] += value
    }

    /// `self − other`, field by field.
    func subtracting(_ other: ReviewRoundTotals) -> ReviewRoundTotals {
        var result = self
        for (subject, fields) in other.bySubject {
            for (field, value) in fields { result.add(-value, subject: subject, field: field) }
        }
        return result
    }

    /// The stored form: exact decimal text, never a binary float.
    var encoded: [String: [String: String]] {
        bySubject.mapValues { $0.mapValues { "\($0)" } }
    }

    init?(encoded: [String: [String: String]]) {
        for (subject, fields) in encoded {
            for (field, text) in fields {
                guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
                add(value, subject: subject, field: field)
            }
        }
    }
}
