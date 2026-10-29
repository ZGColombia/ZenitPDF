// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation
import Observation

/// Mock implementation of ``LedgerPresenting``.
///
/// Grouping, filtering, sorting and totalling are really performed over the in-memory
/// sample rows, so the ledger UI can be developed against behaviour rather than a frozen
/// picture. Totals are recomputed from the surviving rows on every change, which is
/// what makes the consistency tests meaningful.
///
/// It publishes its outline the way the application's presenter does
/// (``suppliesDisplayOrderedOutline``, IM-011): rows in group order, a nested tree for every
/// grouping level, and each node's totals including the display `Value` column's merged
/// total, all built by ``MockLedgerOutline``. A table over the mock therefore draws the mock's
/// outline exactly as it draws the aggregation core's, and never folds rows of its own.
@MainActor
@Observable
public final class MockLedgerPresenter: LedgerPresenting, LedgerTableArrangementHosting {

    public private(set) var columns: [LedgerColumn]
    /// The table's arrangement, installed by the pane over this mock (W-029).
    @ObservationIgnored
    public var tableArrangement: LedgerTableArrangement?
    public private(set) var rootGroups: [LedgerGroupNode]
    public private(set) var grandTotals: LedgerTotals
    public private(set) var groupingColumns: [LedgerColumnID]
    public private(set) var filter: LedgerFilterGroup
    public private(set) var canvasFilterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    public private(set) var selectedRowIDs: Set<UUID> = []
    public private(set) var sortDescriptors: [LedgerSortDescriptor]
    public private(set) var isLoading: Bool = false

    /// The whole sample, before the filter. The default implementation would answer with
    /// the *filtered* count, which would make the pane's live "12 of 40" read "12 of 12".
    public var unfilteredRowCount: Int { allRows.count }

    /// Called after the selection changes from inside the ledger, so the canvas can follow.
    public var onSelectionChange: (@MainActor (Set<UUID>) -> Void)?

    private var allRows: [LedgerRow]

    /// Every row in seed order, for the audit extension (BH-271).
    var allRowsForAudit: [LedgerRow] { allRows }

    /// Bulk edits applied through the mock, oldest first — what a shell test asserts on.
    public private(set) var appliedBulkEdits: [LedgerBulkEditRequest] = []

    /// The mock's user columns (NL-QTY-02), and every column change applied, oldest first.
    public private(set) var mockColumnSpecs: [LedgerColumnSpec] = []
    public private(set) var appliedColumnChanges: [(specs: [LedgerColumnSpec], actionName: String)] = []
    /// The mock's rate library (NL-QTY-05).
    public var mockRateEntries: [LedgerRateEntrySummary] = []
    /// When true, ``removeRateEntry(_:)`` fails as a write to the office store can (V-062).
    public var mockRateRemovalFails = false
    /// Every ``removeRateEntry(_:)`` call, oldest first (V-062).
    public private(set) var removedRateEntryIDs: [UUID] = []
    /// The mock's takeoff snapshots, newest first (NL-QTY-16).
    public var mockSnapshots: [LedgerSnapshotSummary] = []
    /// Assemblies applied through the mock, oldest first (NL-QTY-07).
    public private(set) var appliedAssemblies: [(id: UUID?, parameters: [String: DecimalQuantity], markupIDs: Set<UUID>)] = []
    /// The mock's saved assembly recipes (NL-QTY-07-UI), in save order.
    public var mockAssemblyRecipes: [LedgerAssemblyRecipeEntry] = []
    private var expandedGroupTitles: Set<String>

    /// Rows in display order after filtering and sorting. Private, because the protocol is
    /// index-addressed: publishing the array is the shape ADR-0003 §3.4 removed.
    private var visibleRows: [LedgerRow]
    /// Identity to display position, rebuilt with ``visibleRows`` so ``index(of:)`` is O(1).
    private var positionByMarkupID: [UUID: Int]
    /// Display positions the table has asked for ahead of the scroll. The mock has every row
    /// in memory already, so this only records the hint — which is what lets a test assert
    /// that the table prefetches at all.
    public private(set) var prefetchedRange: Range<Int> = 0..<0

    /// Builds the presenter over a sample project.
    public init(project: ZenitSampleProject = .shared) {
        self.columns = project.columns
        self.allRows = project.rows
        self.visibleRows = project.rows
        self.positionByMarkupID = Self.positions(of: project.rows)
        self.rootGroups = project.rootGroups
        self.grandTotals = project.grandTotals
        self.groupingColumns = [.projectZone]
        self.filter = LedgerFilterGroup(id: SampleFormatting.sampleID(950))
        self.sortDescriptors = [LedgerSortDescriptor(column: .subject, ascending: true)]
        self.expandedGroupTitles = Set(project.rootGroups.filter(\.isExpanded).map(\.title))
        self.groupColours = Dictionary(
            project.rootGroups.compactMap { group in group.colorRGBA.map { (group.title, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        // BH-770: the rows obey the sort the header advertises from the first frame, not only
        // after the first filter or sort call — inside each group, since display order is
        // group order (IM-011).
        recompute()
    }

    /// The zone colours the sample's groups carry, kept across a rebuild (BH-770).
    private let groupColours: [String: ColorRGBA]

    /// The mock's outline is complete and addressed by display position, as the aggregation
    /// core's is (IM-011): the table draws it and never folds the mock's rows.
    public var suppliesDisplayOrderedOutline: Bool { true }

    // MARK: Mutations

    public func setGrouping(_ columns: [LedgerColumnID]) {
        groupingColumns = columns
        rebuild()
    }

    public func setFilter(_ filter: LedgerFilterGroup) {
        self.filter = filter
        rebuild()
    }

    public func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) {
        canvasFilterBehavior = behavior
    }

    public func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].visible = visible
        rebuild()
    }

    public func setColumnWidth(_ width: Double, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].width = max(24, width)
    }

    public func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].pinned = pinned
    }

    public func moveColumn(_ columnID: LedgerColumnID, to index: Int) {
        guard let current = columns.firstIndex(where: { $0.id == columnID }),
              columns.indices.contains(index) else { return }
        let column = columns.remove(at: current)
        columns.insert(column, at: index)
    }

    public func toggleGroup(id: LedgerGroupNode.ID) {
        guard let index = rootGroups.firstIndex(where: { $0.id == id }) else { return }
        rootGroups[index].isExpanded.toggle()
        if rootGroups[index].isExpanded {
            expandedGroupTitles.insert(rootGroups[index].title)
        } else {
            expandedGroupTitles.remove(rootGroups[index].title)
        }
    }

    public func select(rowIDs: Set<UUID>, additive: Bool) {
        selectedRowIDs = additive ? selectedRowIDs.union(rowIDs) : rowIDs
        onSelectionChange?(selectedRowIDs)
    }

    public func sort(by columnID: LedgerColumnID, ascending: Bool) {
        sortDescriptors = [LedgerSortDescriptor(column: columnID, ascending: ascending)]
        rebuild()
    }

    public func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals {
        guard let groupID else { return grandTotals }
        return allGroups.first { $0.id == groupID }?.totals ?? .empty
    }

    // MARK: Index-addressed rows

    public var rowCount: Int { visibleRows.count }

    public private(set) var contentRevision = 0

    public func row(at index: Int) -> LedgerRow? {
        visibleRows.indices.contains(index) ? visibleRows[index] : nil
    }

    public func index(of markupID: UUID) -> Int? { positionByMarkupID[markupID] }

    /// Every sample row with one of these identities, filtered out or not, in seed order
    /// (W-042), each saying whether the filter passes it.
    public func unfilteredRows(withIDs markupIDs: Set<UUID>) -> [LedgerRow] {
        allRows.filter { markupIDs.contains($0.markupID) }.map { row in
            var answered = row
            answered.matchesFilter = Self.matches(row: row, group: filter)
            return answered
        }
    }

    public func prefetchRows(in range: Range<Int>) {
        guard !visibleRows.isEmpty else {
            prefetchedRange = 0..<0
            return
        }
        prefetchedRange = range.clamped(to: 0..<visibleRows.count)
    }

    /// Applies a selection that came from the canvas without echoing it back.
    public func applyExternalSelection(_ markupIDs: Set<UUID>) {
        selectedRowIDs = markupIDs
    }

    // MARK: Recomputation

    /// Rebuilds rows, groups and totals from the unfiltered sample rows.
    func rebuildAfterBulkEdit() { rebuild() }

    private func rebuild() {
        contentRevision += 1
        recompute()
    }

    /// Filters, sorts, groups and totals the sample rows into the published outline.
    ///
    /// Rows are sorted first and grouped second, so the sort holds inside every group and the
    /// display order is the outline's (IM-011). A level that names none of the mock's columns
    /// is dropped, as the aggregation core drops a level it cannot group by (BH-102).
    private func recompute() {
        let surviving = allRows
            .map { row -> LedgerRow in
                var updated = row
                updated.matchesFilter = Self.matches(row: row, group: filter)
                return updated
            }
        let sortedRows = sorted(surviving.filter(\.matchesFilter))
        let known = Set(columns.map(\.id))
        let outline = MockLedgerOutline.build(
            rows: sortedRows,
            groupingColumns: groupingColumns.filter { known.contains($0) },
            columns: columns
        )
        visibleRows = outline.order.map { sortedRows[$0] }
        positionByMarkupID = Self.positions(of: visibleRows)
        prefetchedRange = 0..<0
        grandTotals = outline.grandTotals
        rootGroups = outline.rootGroups.map { group in
            var root = group
            root.isExpanded = expandedGroupTitles.contains(group.title)
            if let colour = groupColours[group.title] { root.colorRGBA = colour }
            return root
        }
    }

    /// Identity-to-position map for a display-ordered row array.
    private static func positions(of rows: [LedgerRow]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(rows.count)
        for (position, row) in rows.enumerated() { map[row.markupID] = position }
        return map
    }

    /// Applies ``sortDescriptors`` to a row set.
    private func sorted(_ rows: [LedgerRow]) -> [LedgerRow] {
        guard let descriptor = sortDescriptors.first else { return rows }
        return rows.sorted { lhs, rhs in
            let left = lhs.quantity(descriptor.column)
            let right = rhs.quantity(descriptor.column)
            if let left, let right, left != right {
                return descriptor.ascending ? left < right : right < left
            }
            let leftText = lhs.displayValue(descriptor.column)
            let rightText = rhs.displayValue(descriptor.column)
            if leftText == rightText {
                return lhs.markupID.uuidString < rhs.markupID.uuidString
            }
            return descriptor.ascending ? leftText < rightText : rightText < leftText
        }
    }

    // MARK: Filter evaluation

    /// Evaluates a filter group against a row.
    ///
    /// The mock implements the comparisons the UI needs to demonstrate filtering. Regular
    /// expressions and date ranges are treated as matching, because the real engine
    /// evaluates them under a complexity and time guard that does not belong in a mock.
    static func matches(row: LedgerRow, group: LedgerFilterGroup) -> Bool {
        let ruleResults = group.rules.filter(\.isEnabled).map { matches(row: row, rule: $0) }
        // BH-771: an empty nested group constrains nothing, so it is skipped — the real
        // evaluator's rule. Counting it as vacuously true defeated every sibling under "any".
        let groupResults = group.groups.filter { !$0.isEmpty }.map { matches(row: row, group: $0) }
        let all = ruleResults + groupResults
        guard !all.isEmpty else { return true }
        let combined = group.conjunction == .all ? all.allSatisfy { $0 } : all.contains(true)
        return group.isNegated ? !combined : combined
    }

    /// Evaluates one rule against a row.
    static func matches(row: LedgerRow, rule: LedgerFilterRule) -> Bool {
        let cell = row.value(rule.column)
        let text = row.displayValue(rule.column)
        // BH-272: a choice is compared by its stored value ("inProgress"), which is what the
        // filter builder emits, and not by its display title ("In Progress"). Same rule as the
        // real evaluator: `cell.asText ?? text`.
        let stored = cell.asText ?? text

        switch rule.comparison {
        case .isEmpty: return cell.isEmpty
        case .isNotEmpty: return !cell.isEmpty
        case .isTrue: if case .checkbox(let flag) = cell { return flag } else { return false }
        case .isFalse: if case .checkbox(let flag) = cell { return !flag } else { return false }
        default: break
        }

        switch (rule.comparison, rule.operand) {
        case let (.contains, .text(needle)):
            return text.localizedCaseInsensitiveContains(needle)
        case let (.notContains, .text(needle)):
            return !text.localizedCaseInsensitiveContains(needle)
        case let (.beginsWith, .text(needle)):
            return text.lowercased().hasPrefix(needle.lowercased())
        case let (.endsWith, .text(needle)):
            return text.lowercased().hasSuffix(needle.lowercased())
        case let (.equals, .text(needle)):
            return stored.caseInsensitiveCompare(needle) == .orderedSame
        case let (.notEquals, .text(needle)):
            return stored.caseInsensitiveCompare(needle) != .orderedSame
        case let (.isAnyOf, .choices(values)):
            return values.contains { $0.caseInsensitiveCompare(stored) == .orderedSame }
        // BH-273: these used to fall into `default: return true`, so "Count is 12" kept
        // every row and the filtered totals equalled the unfiltered ones.
        case let (.equals, .number(value)):
            return (cell.asQuantity?.value).map { $0 == value } ?? false
        case let (.notEquals, .number(value)):
            return (cell.asQuantity?.value).map { $0 != value } ?? true
        case let (.equals, .boolean(flag)):
            if case .checkbox(let value) = cell { return value == flag } else { return false }
        case let (.notEquals, .boolean(flag)):
            if case .checkbox(let value) = cell { return value != flag } else { return true }
        case let (.equals, .date(date)):
            if case .date(let value) = cell {
                return Calendar(identifier: .gregorian).isDate(value, inSameDayAs: date)
            }
            return false
        case let (.notEquals, .date(date)):
            if case .date(let value) = cell {
                return !Calendar(identifier: .gregorian).isDate(value, inSameDayAs: date)
            }
            return true
        case let (.lessThan, .number(bound)):
            return (cell.asQuantity?.value).map { $0 < bound } ?? false
        case let (.lessThanOrEqual, .number(bound)):
            return (cell.asQuantity?.value).map { $0 <= bound } ?? false
        case let (.greaterThan, .number(bound)):
            return (cell.asQuantity?.value).map { $0 > bound } ?? false
        case let (.greaterThanOrEqual, .number(bound)):
            return (cell.asQuantity?.value).map { $0 >= bound } ?? false
        case let (.between, .numberRange(lower, upper)):
            return (cell.asQuantity?.value).map { $0 >= lower && $0 <= upper } ?? false
        default:
            return true
        }
    }
}

// MARK: - LedgerBulkEditPresenting

/// The mock really performs the edit over its in-memory rows, so a preview's Apply changes
/// what is on screen and a test can assert on the result rather than on a stub's promise.
/// Nothing here is undoable — undo belongs to the command bus, which the mock deliberately
/// does not have.
extension MockLedgerPresenter: LedgerBulkEditPresenting {

    public func applyBulkEdit(_ request: LedgerBulkEditRequest) async -> LedgerBulkEditReceipt {
        appliedBulkEdits.append(request)
        guard !request.isEmpty else { return LedgerBulkEditReceipt() }

        var changed: Set<UUID> = []
        var lockedCount = 0
        for (index, row) in allRows.enumerated() where request.markupIDs.contains(row.markupID) {
            // BH-772: a locked markup refuses edits, as the engine does.
            if row.locked {
                lockedCount += 1
                continue
            }
            var updated = row
            var touched = false
            for (columnID, value) in request.values {
                guard updated.values[columnID] != value else { continue }
                updated.values[columnID] = value
                // BH-274: the display string follows the stored value in the column's own
                // format — not the raw choice value, and not the stale text of a currency.
                updated.displayValues[columnID] = displayText(for: value, in: columnID)
                touched = true
            }
            if let color = request.color, updated.colorRGBA != color {
                updated.colorRGBA = color
                touched = true
            }
            // BH-772: appearance lives on the canvas markup, which the mock ledger does not
            // draw; a style edit over an unlocked row counts as applied rather than vanishing
            // as a silent no-op.
            if !request.style.isEmpty { touched = true }
            guard touched else { continue }
            allRows[index] = updated
            changed.insert(row.markupID)
        }
        if changed.isEmpty, lockedCount > 0 {
            return .failure(NSLocalizedString(
                "The selected markups are locked.",
                comment: "Bulk edit refusal when every targeted markup is locked"
            ))
        }
        guard !changed.isEmpty else { return LedgerBulkEditReceipt(undoActionName: "Bulk Edit") }
        rebuildAfterBulkEdit()
        return LedgerBulkEditReceipt(
            changedMarkupIDs: changed,
            auditEntryCount: changed.count,
            undoActionName: "Bulk Edit"
        )
    }

    /// The display text the sample would show for a stored value in a column.
    func displayText(for value: LedgerCellValue, in columnID: LedgerColumnID) -> String {
        let column = columns.first { $0.id == columnID }
        switch value {
        case .empty:
            return ""
        case .text(let text):
            return text
        case .choice(let stored):
            if let title = column?.choices.first(where: { $0.value == stored })?.title { return title }
            if columnID == .status, let status = MarkupStatus(rawValue: stored) { return status.displayName }
            return stored
        case .number(let number):
            return SampleFormatting.string(number, fractionDigits: SampleFormatting.fractionDigits(for: column?.dimension ?? .count))
        case .quantity(let quantity):
            return SampleFormatting.string(quantity)
        case .currency(let amount, _):
            return SampleFormatting.string(amount, fractionDigits: 2)
        case .date(let date):
            return ZenitSampleProject.dateText(date)
        case .checkbox(let flag):
            return flag
                ? NSLocalizedString("Yes", comment: "Checkbox cell shown as text")
                : NSLocalizedString("No", comment: "Checkbox cell shown as text")
        }
    }
}

// MARK: - LedgerColumnManaging (NL-QTY-02)

/// The Column Manager over the mock: the list is kept in memory and each change is recorded,
/// so a shell test drives the manager end to end without a document. Only the checks that need
/// no engine are made here — an empty or duplicate name.
extension MockLedgerPresenter: LedgerColumnManaging {

    public var userColumnSpecs: [LedgerColumnSpec] { mockColumnSpecs }

    public var defaultCurrencyCode: String { "SEK" }

    public func applyColumnSpecs(_ specs: [LedgerColumnSpec], actionName: String) async -> LedgerBulkEditReceipt {
        let titles = specs.map { $0.title.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !titles.contains(""), Set(titles).count == titles.count else {
            return .failure(NSLocalizedString(
                "Nothing was changed: every column needs its own name.",
                comment: "Mock Column Manager refusal"
            ))
        }
        appliedColumnChanges.append((specs, actionName))
        mockColumnSpecs = specs
        return LedgerBulkEditReceipt(undoActionName: actionName)
    }

    public func checkFormula(_ source: String, forColumn id: LedgerColumnID?, specs: [LedgerColumnSpec]) -> String? {
        source.trimmingCharacters(in: .whitespaces).isEmpty ? "The formula is empty." : nil
    }
}

// MARK: - LedgerStatusCounting (NL-QTY-17)

extension MockLedgerPresenter: LedgerStatusCounting {

    public var statusCounts: [LedgerStatusCount] {
        let options = columns.first { $0.id == .status }?.choices.sorted { $0.order < $1.order } ?? []
        var counts: [String: Int] = [:]
        for row in allRows {
            if case let .choice(value) = row.value(.status) { counts[value, default: 0] += 1 }
        }
        return options.compactMap { option in
            guard let count = counts[option.value], count > 0 else { return nil }
            return LedgerStatusCount(value: option.value, title: option.title, count: count)
        }
    }
}

// MARK: - LedgerAssemblyApplying (NL-QTY-07)

extension MockLedgerPresenter: LedgerAssemblyApplying {

    /// One sample recipe, so the panel can be developed without the formula engine.
    public var availableAssemblies: [LedgerAssemblySummary] {
        [LedgerAssemblySummary(
            id: UUID(uuidString: "5A504446-4153-4D42-0000-000000000001")!,
            name: "Timber stud wall",
            note: nil,
            inputs: [
                .init(name: "Length", dimension: .length, isFreeParameter: false, note: nil),
                .init(name: "Height", dimension: .length, isFreeParameter: false, note: nil),
                .init(name: "Spacing", dimension: .length, isFreeParameter: true, note: nil)
            ],
            lines: [.init(name: "Studs", formula: "FLOOR(Length / Spacing) + 1", dimension: .count)]
        )]
    }

    public func applyAssembly(_ id: UUID?, parameters: [String: DecimalQuantity], to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        appliedAssemblies.append((id, parameters, markupIDs))
        return LedgerBulkEditReceipt(undoActionName: id == nil ? "Remove Assembly" : "Apply Assembly")
    }
}

// MARK: - LedgerSummaryPlacing (NL-QTY-10)

extension MockLedgerPresenter: LedgerSummaryPlacing {
    public func placeSummary(_ kind: LedgerSummaryPlacementKind) async -> LedgerBulkEditReceipt {
        LedgerBulkEditReceipt(undoActionName: "Place Summary")
    }
}

// MARK: - LedgerMatrixProviding (NL-QTY-09)

extension MockLedgerPresenter: LedgerMatrixProviding {

    /// A matrix over the sample rows, counting rows per cell — enough to develop the view
    /// against. The app's matrix totals quantities through the aggregation core.
    public func matrix(rows: LedgerColumnID, columns: LedgerColumnID) async throws -> LedgerMatrix {
        func key(_ row: LedgerRow, _ column: LedgerColumnID) -> String {
            let text = row.displayValue(column)
            return text.isEmpty ? "(none)" : text
        }
        let rowKeys = Array(Set(allRows.map { key($0, rows) })).sorted()
        let columnKeys = Array(Set(allRows.map { key($0, columns) })).sorted()
        func cell(_ count: Int) -> LedgerMatrix.Cell {
            LedgerMatrix.Cell(text: count == 0 ? "" : "\(count)", quantity: DecimalQuantity(value: Decimal(count), dimension: .count), rowCount: count)
        }
        let cells = rowKeys.map { r in
            columnKeys.map { c in cell(allRows.filter { key($0, rows) == r && key($0, columns) == c }.count) }
        }
        return LedgerMatrix(
            rowColumn: rows, columnColumn: columns, rowTitles: rowKeys, columnTitles: columnKeys, cells: cells,
            rowTotals: rowKeys.map { r in cell(allRows.filter { key($0, rows) == r }.count) },
            columnTotals: columnKeys.map { c in cell(allRows.filter { key($0, columns) == c }.count) },
            grandTotal: cell(allRows.count)
        )
    }
}

// MARK: - LedgerSnapshotting (NL-QTY-16)

extension MockLedgerPresenter: LedgerSnapshotting {

    public func snapshots() async -> [LedgerSnapshotSummary] {
        mockSnapshots
    }

    public func takeSnapshot(named name: String) async -> LedgerBulkEditReceipt {
        mockSnapshots.insert(LedgerSnapshotSummary(
            id: UUID().uuidString, name: name.isEmpty ? "Snapshot" : name, createdAt: Date(), author: "", rowCount: allRows.count
        ), at: 0)
        return LedgerBulkEditReceipt(undoActionName: "Take Snapshot")
    }

    public func changeReport(since snapshotID: String) async throws -> LedgerChangeReport {
        let snapshot = mockSnapshots.first { $0.id == snapshotID }
        return LedgerChangeReport(snapshotName: snapshot?.name ?? "", snapshotDate: snapshot?.createdAt ?? Date(), rows: [], subjectTotals: [], grandTotals: [])
    }

    public func deleteSnapshot(_ snapshotID: String) async -> Bool {
        let before = mockSnapshots.count
        mockSnapshots.removeAll { $0.id == snapshotID }
        return mockSnapshots.count < before
    }
}

// MARK: - LedgerRateLibraryManaging (NL-QTY-05)

extension MockLedgerPresenter: LedgerRateLibraryManaging {

    public var rateEntries: [LedgerRateEntrySummary] { mockRateEntries }

    public func importRateList(_ text: String) async -> LedgerRateImportResult {
        let lines = text.split(whereSeparator: \.isNewline).dropFirst()
        for line in lines {
            let fields = line.split(separator: ";").map(String.init)
            guard fields.count >= 3, let rate = Decimal(string: fields[2].replacingOccurrences(of: ",", with: ".")) else { continue }
            mockRateEntries.append(LedgerRateEntrySummary(
                id: UUID(), name: fields[0], basis: .area, rate: rate, currencyCode: "SEK",
                waste: nil, packSize: nil, costCode: "", trade: ""
            ))
        }
        return LedgerRateImportResult(imported: lines.count, rejectedLines: [], failure: nil)
    }

    public func removeRateEntry(_ id: UUID) async -> Bool {
        removedRateEntryIDs.append(id)
        guard !mockRateRemovalFails else { return false }
        mockRateEntries.removeAll { $0.id == id }
        return true
    }

    public func applyRateEntry(_ id: UUID, to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        LedgerBulkEditReceipt(changedMarkupIDs: markupIDs, undoActionName: "Bulk Edit")
    }

    public func pendingRateUpdates() async -> [LedgerRateUpdate] { [] }

    public func applyRateUpdates(_ markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt {
        LedgerBulkEditReceipt(undoActionName: "Update Rates")
    }
}

// MARK: - LedgerProjectSummarizing (NL-QTY-15)

extension MockLedgerPresenter: LedgerProjectSummarizing {
    public var hasProjectSources: Bool { true }
    public func projectSummary() async -> LedgerProjectSummary {
        let own = LedgerProjectSummary.Drawing(documentID: UUID(), title: "Sample", totals: [
            LedgerSubjectTotal(subject: "Slab", quantity: DecimalQuantity(value: 12, dimension: .area), rowCount: 1, text: "12.00 m²")
        ])
        return LedgerProjectSummary(drawings: [own], combined: own.totals)
    }
}
#endif
