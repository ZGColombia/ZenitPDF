import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// The reserved hidden column a live summary's specification is stored in (ADR-0025).
public enum LiveSummaryColumn {

    /// The column's key.
    public static let key = "zenit.summary"

    /// The column's identity in the domain.
    public static let columnID = ColumnID(
        LedgerIdentifiers.deterministicUUID(namespace: AssemblyColumn.namespace, name: "summary")
    )

    static func definition(order: Int) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: columnID,
            key: key,
            title: NSLocalizedString("Summary", comment: "Quantity Ledger reserved column: the specification of a live summary on the sheet"),
            kind: .text,
            standard: nil,
            isEditable: false,
            isVisible: false,
            order: order
        )
    }
}

/// What a live summary on the sheet shows (NL-QTY-10, ADR-0025): a saved view, never numbers.
/// The numbers are recomputed from the ledger every time the takeoff changes.
public struct LiveSummarySpec: Codable, Hashable, Sendable {

    /// The two things a summary can be.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Group totals of the primary quantity, with a grand total.
        case quantities
        /// The count-symbol legend: subject, symbol, number of marks.
        case countLegend
    }

    public var kind: Kind
    /// The heading. Empty uses the kind's default.
    public var title: String
    /// Grouping column keys, outermost first. Empty groups by Subject.
    public var grouping: [String]
    /// The filter, or `nil` for every row.
    public var filter: LedgerFilterGroup?
    /// Only the rows on the summary's own sheet.
    public var pageOnly: Bool

    public init(kind: Kind, title: String = "", grouping: [String] = [], filter: LedgerFilterGroup? = nil, pageOnly: Bool = false) {
        self.kind = kind
        self.title = title
        self.grouping = grouping
        self.filter = filter
        self.pageOnly = pageOnly
    }

    /// The stored cell.
    public var cellValue: Domain.CellValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return .empty }
        return .text(text)
    }

    /// The spec a stored cell holds.
    public init?(cell: Domain.CellValue?) {
        guard case .text(let text)? = cell, let data = text.data(using: .utf8),
              let spec = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = spec
    }
}

extension TakeoffSession {

    /// The text a live summary draws: heading, what it shows (and that it is filtered, when it
    /// is), one line per group with its total and row count, the grand total, and when it was
    /// computed. Every number is the ledger's own formatted string — the same one the table and
    /// the exports print (QUALITY_BAR A25, A29).
    public func liveSummaryText(_ spec: LiveSummarySpec, pageID: PageID) throws -> String {
        Self.stamping(try liveSummaryBody(spec, pageID: pageID), at: sessionNow, localeIdentifier: snapshotFormatter.localeIdentifier)
    }

    /// The summary's text without its "As of" line: everything a change in the takeoff can move.
    func liveSummaryBody(_ spec: LiveSummarySpec, pageID: PageID) throws -> String {
        var lines: [String] = []
        switch spec.kind {
        case .quantities:
            lines.append(spec.title.isEmpty
                ? NSLocalizedString("Quantities", comment: "Default heading of a live quantity table on the sheet")
                : spec.title)
            var request = LedgerRequest(
                grouping: (spec.grouping.isEmpty ? [StandardLedgerColumn.subject.rawValue] : spec.grouping).map { LedgerColumnID($0) }
            )
            if let filter = spec.filter { request.filter = filter }
            if spec.pageOnly {
                request.markupScope = Set(ledgerRecords.filter { $0.pageID == pageID }.map(\.id.rawValue))
            }
            let projection = try summaryLedgerProjection(request)
            lines.append(scopeLine(spec, projection: projection))
            let valueID = LedgerDefaultColumns.valueColumnID
            for group in projection.rootGroups {
                let total = group.totals.displayValues[valueID].map { " — \($0)" } ?? ""
                lines.append("\(group.title)\(total) (\(group.totals.rowCount))")
            }
            let grand = projection.grandTotals.displayValues[valueID]
            lines.append(String(
                format: NSLocalizedString("Total: %1$@ (%2$d rows)", comment: "Live quantity table: grand total line; the total, the row count"),
                grand ?? NSLocalizedString("no single total", comment: "Live quantity table: the rows carry different units"),
                projection.rowCount
            ))
        case .countLegend:
            lines.append(spec.title.isEmpty
                ? NSLocalizedString("Legend", comment: "Default heading of a live count legend on the sheet")
                : spec.title)
            let marks = spec.pageOnly ? orderedMarkups.filter { $0.pageID == pageID } : orderedMarkups
            let entries = CountSymbolLegend.entries(markups: marks)
            if entries.isEmpty {
                lines.append(NSLocalizedString("No count marks yet.", comment: "Live count legend with nothing to list"))
            }
            for entry in entries {
                let subject = entry.subject.isEmpty
                    ? NSLocalizedString("(no subject)", comment: "Live count legend: marks without a subject")
                    : entry.subject
                lines.append("\(subject) — \(entry.symbolDisplayName) ×\(entry.markCount)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `body` with its last line saying when it was computed.
    static func stamping(_ body: String, at date: Date, localeIdentifier: String) -> String {
        body + "\n" + String(
            format: NSLocalizedString("As of %@", comment: "Live summary: when its numbers were computed"),
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: localeIdentifier)))
        )
    }

    /// A stored summary caption without its "As of" line (always the last one).
    static func body(ofCaption caption: String?) -> String? {
        guard let caption, let newline = caption.lastIndex(of: "\n") else { return nil }
        return String(caption[..<newline])
    }

    /// The projection a live summary reads: the live store brought up to date under the pane's
    /// own spec, and the summary's spec evaluated on a separate view of that store. Setting the
    /// summary's spec on the shared coordinator forced a full regroup for each summary and
    /// another when the pane set its own spec back, on every command (R-059).
    func summaryLedgerProjection(_ request: LedgerRequest) throws -> LedgerProjection {
        let translation = LedgerSpecBuilder.translate(resolvingOlderScale(request), columns: ledgerColumns, formatter: snapshotFormatter)
        let live = try cachedLedgerView(for: currentLedgerSpec ?? translation.spec)
        let view = live.spec == translation.spec ? live : live.store.makeView(translation.spec)
        return LedgerBridge.project(view, formatter: snapshotFormatter, unappliedFilterRules: translation.unappliedFilterRules)
    }

    /// "All rows" or "Filtered: Status is any of Open — 12 of 40 rows", plus the sheet scope.
    func scopeLine(_ spec: LiveSummarySpec, projection: LedgerProjection) -> String {
        var parts: [String] = []
        if let filter = spec.filter, !filter.isEmpty {
            parts.append(String(
                format: NSLocalizedString("Filtered: %1$@ — %2$d of %3$d rows", comment: "Live quantity table: filter line; the filter, shown rows, all rows"),
                describe(filter), projection.rowCount, projection.unfilteredRowCount
            ))
        } else {
            parts.append(NSLocalizedString("All rows", comment: "Live quantity table: no filter"))
        }
        if spec.pageOnly {
            parts.append(NSLocalizedString("this sheet only", comment: "Live quantity table: scoped to its own sheet"))
        }
        return parts.joined(separator: " · ")
    }

    /// A filter in words, with column titles and option titles a person reads.
    func describe(_ group: LedgerFilterGroup) -> String {
        let joiner = group.conjunction == .all
            ? NSLocalizedString(" and ", comment: "Live summary filter text: rules that must all hold")
            : NSLocalizedString(" or ", comment: "Live summary filter text: rules of which one must hold")
        var parts = group.rules.filter(\.isEnabled).map { rule -> String in
            let column = ledgerColumns.column(key: rule.column.rawValue)
            let title = column.map(LedgerBridge.title(of:)) ?? rule.column.rawValue
            let operand: String
            switch rule.operand {
            case .none: operand = ""
            case .text(let text), .regex(let text): operand = "“\(text)”"
            case .number(let value): operand = "\(value)"
            case .numberRange(let lower, let upper): operand = "\(lower)–\(upper)"
            case .date(let date): operand = LedgerBridge.dateText(date, localeIdentifier: snapshotFormatter.localeIdentifier)
            case .dateRange(let start, let end):
                operand = LedgerBridge.dateText(start, localeIdentifier: snapshotFormatter.localeIdentifier) + "–"
                    + LedgerBridge.dateText(end, localeIdentifier: snapshotFormatter.localeIdentifier)
            case .boolean(let flag): operand = flag ? "✓" : "–"
            case .choices(let values):
                operand = values.map { value in
                    column.map { LedgerBridge.choiceTitle(value, in: $0) } ?? value
                }.joined(separator: ", ")
            }
            return [title, rule.comparison.displayName, operand].filter { !$0.isEmpty }.joined(separator: " ")
        }
        parts += group.groups.map { "(\(describe($0)))" }
        let text = parts.joined(separator: joiner)
        return group.isNegated ? NSLocalizedString("not ", comment: "Live summary filter text: a negated group") + text : text
    }

    /// Recomputes the drawn text of every live summary after a document change, into the same
    /// undo step (ADR-0025 §2.3): the previous record joins the inverse unless the step already
    /// recorded it, and the summary joins the changed set so the canvas redraws it.
    ///
    /// A summary whose text cannot be computed — the ledger refused to build — keeps its last
    /// text; its "As of" line then says how old it is, which is the honest failure.
    ///
    /// A summary is rewritten — and restamped "As of" — only when its heading, scope, groups or
    /// totals changed. Comparing the whole text made the first command after each minute
    /// boundary rewrite every summary into its undo step and the audit trail, and turned a
    /// command that changed nothing into an undo step, against the no-op rule (R-051).
    ///
    /// `commands` lets a step that cannot have moved any summary skip the work (R-059): every
    /// command local to the markups it names, none of which is — before or after — a ledger
    /// row, a count mark or a live summary itself.
    func refreshLiveSummaries(inverse: inout DocumentCommandInverse, changed: inout Set<MarkupID>, commands: [DocumentCommand]) {
        let summaries = orderedMarkups.compactMap { record -> (MarkupRecord, LiveSummarySpec)? in
            guard let spec = LiveSummarySpec(cell: record.customValues[LiveSummaryColumn.columnID]) else { return nil }
            return (record, spec)
        }
        guard !summaries.isEmpty else { return }
        if stepLeavesSummariesAlone(commands, touched: Set(inverse.markups.keys).union(changed), before: inverse.markups) { return }
        let now = sessionNow
        let localeIdentifier = snapshotFormatter.localeIdentifier
        for (record, spec) in summaries {
            guard let body = try? liveSummaryBody(spec, pageID: record.pageID) else { continue }
            let caption: String
            if let previous = inverse.markups[record.id] ?? nil, previous.caption != record.caption {
                // The step wrote over the summary's text (Edit Text): the numbers go back — the
                // previous caption, "As of" line and all, while they still hold (R-059).
                if let old = previous.caption, Self.body(ofCaption: old) == body {
                    caption = old
                } else {
                    caption = Self.stamping(body, at: now, localeIdentifier: localeIdentifier)
                }
            } else if body != Self.body(ofCaption: record.caption) {
                caption = Self.stamping(body, at: now, localeIdentifier: localeIdentifier)
            } else {
                continue
            }
            guard caption != record.caption else { continue }
            if inverse.markups.index(forKey: record.id) == nil { inverse.markups[record.id] = record }
            var updated = record
            updated.caption = caption
            storeRefreshedSummary(updated)
            changed.insert(record.id)
        }
    }

    /// Whether a step can have moved no live summary: every command acts only on the markups it
    /// names, and none of the markups it touched feeds a summary before or after (R-059).
    ///
    /// A summary is itself a markup the step can touch, and it is no ledger row (a text markup
    /// with no subject): a summary pasted onto another sheet arrives with its source sheet's
    /// numbers, and text typed over a summary is not a total. Both must be recomputed in the
    /// same step, so a step touching a summary is never skipped.
    func stepLeavesSummariesAlone(_ commands: [DocumentCommand], touched: Set<MarkupID>, before: [MarkupID: MarkupRecord?]) -> Bool {
        guard !commands.isEmpty, commands.allSatisfy(\.actsOnlyOnNamedMarkups) else { return false }
        for id in touched {
            if let now = markup(id), Self.feedsLiveSummaries(now) { return false }
            if let was = before[id] ?? nil, Self.feedsLiveSummaries(was) { return false }
        }
        return true
    }

    /// Whether a live summary reads `record` or is it: a ledger row (a quantities table), a
    /// count mark (a legend), or a summary's own record.
    static func feedsLiveSummaries(_ record: MarkupRecord) -> Bool {
        isLedgerRow(record) || record.kind == .count || record.tool == .count
            || record.customValues[LiveSummaryColumn.columnID] != nil
    }

    /// The rule ``TakeoffSession/ledgerMarkups`` filters by.
    static func isLedgerRow(_ record: MarkupRecord) -> Bool {
        record.kind.producesQuantity || !record.subject.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension DocumentCommand {

    /// A command whose only effect is on the markups it names: no scale, page, column, layer,
    /// zone or region list, and no custom cell (a live summary's own specification is one).
    var actsOnlyOnNamedMarkups: Bool {
        switch self {
        case .addMarkup, .removeMarkup, .moveMarkup, .changeStyle, .editVertices, .editSubject, .editLabel,
             .editComment, .editText, .rotateStamp, .setLocked, .setHidden, .arrangeMarkups, .setMarkupGroup,
             .setMarkupLink:
            return true
        default:
            return false
        }
    }
}

// MARK: - Placing a summary

extension AppCoreEnvironment {

    /// Places a live summary on a sheet as one undoable step (NL-QTY-10). It is a text markup
    /// whose words the takeoff keeps current: it prints and exports wherever text markups do, and
    /// it is never a ledger row (it measures nothing and has no subject).
    @discardableResult
    public func placeLiveSummary(_ spec: LiveSummarySpec, onPage pageID: PageID, at origin: PDFPoint) async throws -> MarkupID {
        let id = MarkupID(UUID())
        let now = Date()
        guard let page = await session.pageDescriptors.first(where: { $0.id == pageID }) else {
            throw DocumentCommandError.unknownPage(pageID)
        }
        let text = try await session.liveSummaryText(spec, pageID: pageID)
        let record = MarkupRecord(
            id: id,
            documentID: page.documentID,
            pageID: pageID,
            kind: .text,
            tool: nil,
            subject: "",
            author: AuthorIdentity.current(),
            caption: text,
            geometry: MeasurementGeometry(pageID: pageID, points: [origin]),
            customValues: [LiveSummaryColumn.columnID: spec.cellValue],
            createdAt: now,
            modifiedAt: now
        )
        try await commands.perform(.addMarkup(record))
        return id
    }
}

extension AppCoreEnvironment {

    /// Places `spec` on the sheet the document shows, a margin in from its top-left corner.
    func placeLiveSummaryOnCurrentPage(_ spec: LiveSummarySpec) async -> LedgerBulkEditReceipt {
        let actionName = NSLocalizedString("Place Summary", comment: "Undo action name: a live summary placed on a sheet")
        let pages = await session.pageDescriptors
        guard let page = pages.first(where: { $0.id.rawValue == document.currentPageID }) ?? pages.first else {
            return .failure(NSLocalizedString(
                "Nothing was placed: the document has no sheet.",
                comment: "Live summary refusal: no page"
            ))
        }
        let media = page.boxes.media
        let origin = PDFPoint(x: media.origin.x + 36, y: media.origin.y + media.size.height - 36)
        do {
            let id = try await placeLiveSummary(spec, onPage: page.id, at: origin)
            return LedgerBulkEditReceipt(changedMarkupIDs: [id.rawValue], undoActionName: actionName)
        } catch {
            return .failure(String(describing: error))
        }
    }
}

extension AppLedgerPresenter: LedgerSummaryPlacing {

    public func placeSummary(_ kind: LedgerSummaryPlacementKind) async -> LedgerBulkEditReceipt {
        guard let onPlaceSummary else {
            return .failure(NSLocalizedString(
                "This ledger cannot be edited.",
                comment: "Bulk edit refusal when no document is attached to the ledger"
            ))
        }
        let spec: LiveSummarySpec
        switch kind {
        case .quantities:
            spec = LiveSummarySpec(
                kind: .quantities,
                grouping: groupingColumns.map(\.rawValue),
                filter: filter.isEmpty ? nil : filter
            )
        case .countLegend:
            spec = LiveSummarySpec(kind: .countLegend)
        }
        return await onPlaceSummary(spec)
    }
}
