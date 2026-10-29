import Foundation

/// One user column as the Column Manager edits it (NL-QTY-02).
///
/// A value, not a live column: the manager edits a list of these and hands the whole list to
/// ``LedgerColumnManaging/applyColumnSpecs(_:actionName:)``, which the app tier turns into one
/// undoable command. The key (``id``) never changes once minted, so formulas, saved layouts and
/// exports keep addressing a renamed column.
public struct LedgerColumnSpec: Hashable, Sendable, Identifiable {

    /// The column's stable key. A new column's is ``LedgerColumnID/custom(_:)`` over a fresh
    /// UUID.
    public var id: LedgerColumnID
    /// The header a person reads.
    public var title: String
    /// What the cells hold.
    public var kind: LedgerColumnKind
    /// For a number column: the dimension of its values (count, ratio, length, area, volume).
    /// For a money column: the currency, or a rate (money per metre, per square metre …).
    /// `nil` for text, date, checkbox and choice columns, and for a number column whose
    /// dimension is decided per row. A formula column's is computed, not chosen.
    public var dimension: QuantityDimension?
    /// Decimal places shown, or `nil` for the ledger default. Display only (rounding at the
    /// boundary, QUALITY_BAR A30).
    public var decimalPlaces: Int?
    /// A choice column's options, in order. A retired option stays readable on existing rows.
    public var choices: [LedgerChoiceOption]
    /// A choice column's default option.
    public var defaultChoiceID: UUID?
    /// A formula column's expression.
    public var formulaSource: String?
    /// Whether the column is shown in the ledger.
    public var isVisible: Bool
    /// Whether the column's values describe one row and never sum into a total — a pack size,
    /// a spacing (ADR-0039). Only a number or formula column can sum, so only theirs matters.
    public var neverSums: Bool

    /// Creates a spec.
    public init(
        id: LedgerColumnID,
        title: String,
        kind: LedgerColumnKind,
        dimension: QuantityDimension? = nil,
        decimalPlaces: Int? = nil,
        choices: [LedgerChoiceOption] = [],
        defaultChoiceID: UUID? = nil,
        formulaSource: String? = nil,
        isVisible: Bool = true,
        neverSums: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.dimension = dimension
        self.decimalPlaces = decimalPlaces
        self.choices = choices
        self.defaultChoiceID = defaultChoiceID
        self.formulaSource = formulaSource
        self.isVisible = isVisible
        self.neverSums = neverSums
    }

    /// A fresh column of `kind`, with a new key.
    public static func new(kind: LedgerColumnKind, title: String) -> LedgerColumnSpec {
        LedgerColumnSpec(id: .custom(UUID().uuidString), title: title, kind: kind)
    }
}

/// The dimensions the Column Manager offers a Number column, in menu order.
public enum LedgerColumnUnitChoice: String, CaseIterable, Identifiable, Sendable {
    /// Decided per row — what a column with no declared unit has always been.
    case unspecified
    /// A number of things.
    case count
    /// A factor: a waste percentage, a multiplier.
    case ratio
    case length
    case area
    case volume

    public var id: String { rawValue }

    /// The dimension the choice stands for.
    public var dimension: QuantityDimension? {
        switch self {
        case .unspecified: nil
        case .count: .count
        case .ratio: .ratio
        case .length: .length
        case .area: .area
        case .volume: .volume
        }
    }

    /// The choice a stored dimension reads as, or `nil` when it is none of these (a rate).
    public init?(dimension: QuantityDimension?) {
        guard let dimension else { self = .unspecified; return }
        guard let match = Self.allCases.first(where: { $0.dimension == dimension }) else { return nil }
        self = match
    }

    /// The menu title.
    public var displayName: String {
        switch self {
        case .unspecified: NSLocalizedString("No unit", comment: "Column Manager: number column without a declared unit")
        case .count: NSLocalizedString("Count (pcs)", comment: "Column Manager: number column unit")
        case .ratio: NSLocalizedString("Ratio / factor", comment: "Column Manager: number column unit")
        case .length: NSLocalizedString("Length", comment: "Column Manager: number column unit")
        case .area: NSLocalizedString("Area", comment: "Column Manager: number column unit")
        case .volume: NSLocalizedString("Volume", comment: "Column Manager: number column unit")
        }
    }
}

/// What a money column prices by, in menu order (ADR-0020: a rate never sums).
public enum LedgerMoneyBasis: Int, CaseIterable, Identifiable, Sendable {
    /// An amount — sums into group and grand totals.
    case amount = 0
    /// Money per metre.
    case perLength = 1
    /// Money per square metre.
    case perArea = 2
    /// Money per cubic metre.
    case perVolume = 3

    public var id: Int { rawValue }

    /// The dimension for a currency code.
    public func dimension(currencyCode: String) -> QuantityDimension {
        QuantityDimension(lengthPower: -rawValue, currencyCode: currencyCode)
    }

    /// The basis a stored money dimension reads as.
    public init(dimension: QuantityDimension?) {
        self = Self(rawValue: -(dimension?.lengthPower ?? 0)) ?? .amount
    }

    /// The menu title.
    public var displayName: String {
        switch self {
        case .amount: NSLocalizedString("Amount (sums)", comment: "Column Manager: money column that is an amount")
        case .perLength: NSLocalizedString("Rate per metre", comment: "Column Manager: money column that is a rate per metre")
        case .perArea: NSLocalizedString("Rate per m²", comment: "Column Manager: money column that is a rate per square metre")
        case .perVolume: NSLocalizedString("Rate per m³", comment: "Column Manager: money column that is a rate per cubic metre")
        }
    }
}

/// A ledger presenter whose user columns can be added, renamed, retyped, reordered and
/// deleted (NL-QTY-02).
///
/// Reached by a conditional cast from `any LedgerPresenting`, like ``LedgerBulkEditPresenting``.
@MainActor
public protocol LedgerColumnManaging: LedgerPresenting {

    /// The project's user columns — made in the Column Manager or by a table import — in
    /// ledger order.
    var userColumnSpecs: [LedgerColumnSpec] { get }

    /// The currency a new money column is created in.
    var defaultCurrencyCode: String { get }

    /// Replaces the user columns with `specs`, as one undoable step named `actionName`.
    ///
    /// Refused whole, with the reason in the receipt, when the list cannot stand: an empty or
    /// duplicate name, a choice column with no options, a formula that does not compile or
    /// adds unlike dimensions, a deleted column a formula reads, or a retype some stored values
    /// cannot survive.
    func applyColumnSpecs(_ specs: [LedgerColumnSpec], actionName: String) async -> LedgerBulkEditReceipt

    /// Checks a formula against the ledger's columns without changing anything: `nil` when it
    /// compiles, else the reason. The editor's live check — and the only evaluator is the one
    /// the ledger runs (QUALITY_BAR A25).
    func checkFormula(_ source: String, forColumn id: LedgerColumnID?, specs: [LedgerColumnSpec]) -> String?
}

// MARK: - Status quick filters (NL-QTY-17)

/// How many rows of the whole ledger — before any filter — carry one review status.
public struct LedgerStatusCount: Hashable, Sendable, Identifiable {
    /// The stored status value, which is what a Status filter rule compares.
    public let value: String
    /// The status as a person reads it ("In progress").
    public let title: String
    /// Rows with this status.
    public let count: Int

    public var id: String { value }

    public init(value: String, title: String, count: Int) {
        self.value = value
        self.title = title
        self.count = count
    }
}

/// A ledger presenter that can say how many rows carry each review status (NL-QTY-17).
@MainActor
public protocol LedgerStatusCounting: LedgerPresenting {
    /// One entry per status present in the ledger, in the Status column's option order.
    var statusCounts: [LedgerStatusCount] { get }
}

// MARK: - Assemblies (NL-QTY-07, ADR-0024)

/// One assembly — a recipe that turns one measurement into several quantities — as the
/// interface lists it.
public struct LedgerAssemblySummary: Hashable, Sendable, Identifiable {
    /// One value the recipe needs.
    public struct Input: Hashable, Sendable {
        public let name: String
        public let dimension: QuantityDimension
        /// True when the estimator types it (`Spacing`); false when a measurement can supply it.
        public let isFreeParameter: Bool
        public let note: String?
        public init(name: String, dimension: QuantityDimension, isFreeParameter: Bool, note: String?) {
            self.name = name
            self.dimension = dimension
            self.isFreeParameter = isFreeParameter
            self.note = note
        }
    }
    /// One quantity the recipe produces.
    public struct Line: Hashable, Sendable {
        public let name: String
        public let formula: String
        public let dimension: QuantityDimension
        public init(name: String, formula: String, dimension: QuantityDimension) {
            self.name = name
            self.formula = formula
            self.dimension = dimension
        }
    }
    public let id: UUID
    public let name: String
    public let note: String?
    public let inputs: [Input]
    public let lines: [Line]

    public init(id: UUID, name: String, note: String?, inputs: [Input], lines: [Line]) {
        self.id = id
        self.name = name
        self.note = note
        self.inputs = inputs
        self.lines = lines
    }
}

/// A ledger presenter that can apply an assembly to measured rows (NL-QTY-07).
@MainActor
public protocol LedgerAssemblyApplying: LedgerPresenting {
    /// The recipes on offer.
    var availableAssemblies: [LedgerAssemblySummary] { get }
    /// Assigns the recipe `id` (or removes any, with `nil`) on the markups, as one undoable step.
    /// `parameters` supplies values, in SI base units, for inputs a measurement does not carry.
    func applyAssembly(_ id: UUID?, parameters: [String: DecimalQuantity], to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt
}

// MARK: - Live summaries on the sheet (NL-QTY-10, ADR-0025)

/// What the ledger can place on the sheet as a live summary.
public enum LedgerSummaryPlacementKind: String, CaseIterable, Sendable {
    /// The ledger's group totals — grouped and filtered as the ledger is now.
    case quantities
    /// The count-symbol legend.
    case countLegend
}

/// A ledger presenter that can place a live summary on the sheet (NL-QTY-10).
@MainActor
public protocol LedgerSummaryPlacing: LedgerPresenting {
    /// Places a summary of `kind` on the current sheet, as one undoable step.
    func placeSummary(_ kind: LedgerSummaryPlacementKind) async -> LedgerBulkEditReceipt
}

// MARK: - Summary matrix (NL-QTY-09)

/// A two-way summary of the ledger: one grouping down, another across, each cell the total of
/// the rows in both groups. Every total is the ledger core's own, so a row total equals that
/// group's subtotal in the ledger and a column total equals the other grouping's subtotal —
/// exactly, by construction.
public struct LedgerMatrix: Hashable, Sendable {
    /// One cell: the formatted total, and the exact value behind it when there is one number.
    public struct Cell: Hashable, Sendable {
        public let text: String
        public let quantity: DecimalQuantity?
        public let rowCount: Int
        public init(text: String, quantity: DecimalQuantity?, rowCount: Int) {
            self.text = text
            self.quantity = quantity
            self.rowCount = rowCount
        }
        public static let empty = Cell(text: "", quantity: nil, rowCount: 0)
    }
    public let rowColumn: LedgerColumnID
    public let columnColumn: LedgerColumnID
    public let rowTitles: [String]
    public let columnTitles: [String]
    /// `cells[row][column]`.
    public let cells: [[Cell]]
    public let rowTotals: [Cell]
    public let columnTotals: [Cell]
    public let grandTotal: Cell

    public init(
        rowColumn: LedgerColumnID, columnColumn: LedgerColumnID, rowTitles: [String], columnTitles: [String],
        cells: [[Cell]], rowTotals: [Cell], columnTotals: [Cell], grandTotal: Cell
    ) {
        self.rowColumn = rowColumn
        self.columnColumn = columnColumn
        self.rowTitles = rowTitles
        self.columnTitles = columnTitles
        self.cells = cells
        self.rowTotals = rowTotals
        self.columnTotals = columnTotals
        self.grandTotal = grandTotal
    }

    /// The matrix as tab-separated lines, header first, for a spreadsheet paste — written by
    /// ``LedgerTabularText``, so a title is formula-guarded and quoted like any copied cell and
    /// a total with a number behind it stays a number (X-030). The titles are group titles —
    /// Subjects, Labels — and used to be joined with a bare tab, unguarded and unquoted.
    public func tabularText(cornerTitle: String, totalTitle: String) -> String {
        func total(_ cell: Cell) -> LedgerTabularField {
            LedgerTabularField(cell.text, isNumber: cell.quantity != nil)
        }
        var lines: [[LedgerTabularField]] = [
            ([cornerTitle] + columnTitles + [totalTitle]).map(LedgerTabularField.text)
        ]
        for (index, title) in rowTitles.enumerated() {
            lines.append([.text(title)] + cells[index].map(total) + [total(rowTotals[index])])
        }
        lines.append([.text(totalTitle)] + columnTotals.map(total) + [total(grandTotal)])
        return LedgerTabularText.document(lines)
    }
}

/// A ledger presenter that can build a summary matrix (NL-QTY-09).
@MainActor
public protocol LedgerMatrixProviding: LedgerPresenting {
    /// The matrix of `rows` × `columns` over the rows the ledger's filter passes.
    func matrix(rows: LedgerColumnID, columns: LedgerColumnID) async throws -> LedgerMatrix
}

// MARK: - Snapshots and the change report (NL-QTY-16)

/// A stored snapshot, as the list shows it.
public struct LedgerSnapshotSummary: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let author: String
    public let rowCount: Int
    public init(id: String, name: String, createdAt: Date, author: String, rowCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.author = author
        self.rowCount = rowCount
    }
}

/// What changed in the takeoff since a snapshot: every added, removed and changed row, field by
/// field, and the exact change in each total.
public struct LedgerChangeReport: Hashable, Sendable {

    /// One field that changed on a row, in the words the ledger shows.
    public struct FieldChange: Hashable, Sendable {
        public let column: String
        public let before: String
        public let after: String
        public init(column: String, before: String, after: String) {
            self.column = column
            self.before = before
            self.after = after
        }
    }

    /// What happened to one row.
    public enum RowKind: String, Hashable, Sendable {
        case added, removed, changed
    }

    /// One row that is not as it was.
    public struct RowChange: Hashable, Sendable, Identifiable {
        public let markupID: UUID
        public let kind: RowKind
        public let subject: String
        public let label: String
        public let fields: [FieldChange]
        public var id: UUID { markupID }
        public init(markupID: UUID, kind: RowKind, subject: String, label: String, fields: [FieldChange]) {
            self.markupID = markupID
            self.kind = kind
            self.subject = subject
            self.label = label
            self.fields = fields
        }
    }

    /// The change in one total: a subject's, or the whole takeoff's, in one unit.
    public struct TotalChange: Hashable, Sendable, Identifiable {
        public let title: String
        public let before: DecimalQuantity
        public let after: DecimalQuantity
        public let beforeText: String
        public let afterText: String
        public let deltaText: String
        public var id: String { "\(title)|\(before.dimension.lengthPower)|\(before.dimension.currencyCode ?? "")" }
        /// `after − before`, exact.
        public var delta: Decimal { after.value - before.value }
        public init(title: String, before: DecimalQuantity, after: DecimalQuantity, beforeText: String, afterText: String, deltaText: String) {
            self.title = title
            self.before = before
            self.after = after
            self.beforeText = beforeText
            self.afterText = afterText
            self.deltaText = deltaText
        }
    }

    public let snapshotName: String
    public let snapshotDate: Date
    public let rows: [RowChange]
    /// Per subject and unit, only where the total moved.
    public let subjectTotals: [TotalChange]
    /// Per unit, over the whole takeoff, only where the total moved.
    public let grandTotals: [TotalChange]

    public init(snapshotName: String, snapshotDate: Date, rows: [RowChange], subjectTotals: [TotalChange], grandTotals: [TotalChange]) {
        self.snapshotName = snapshotName
        self.snapshotDate = snapshotDate
        self.rows = rows
        self.subjectTotals = subjectTotals
        self.grandTotals = grandTotals
    }
}

/// A ledger presenter that can take snapshots and report what changed since one (NL-QTY-16).
@MainActor
public protocol LedgerSnapshotting: LedgerPresenting {
    func snapshots() async -> [LedgerSnapshotSummary]
    func takeSnapshot(named name: String) async -> LedgerBulkEditReceipt
    func changeReport(since snapshotID: String) async throws -> LedgerChangeReport
    func deleteSnapshot(_ snapshotID: String) async -> Bool
}

// MARK: - Rate library (NL-QTY-05)

/// What a rate is per.
public enum LedgerRateBasis: String, Codable, Hashable, Sendable, CaseIterable {
    case area, length, volume, count

    /// The unit a rate of this basis is per.
    public var unitSymbol: String {
        switch self {
        case .area: "m²"
        case .length: "m"
        case .volume: "m³"
        case .count: NSLocalizedString("pcs", comment: "Unit symbol for a count of pieces")
        }
    }
}

/// One rate library entry as the panel lists it.
public struct LedgerRateEntrySummary: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let basis: LedgerRateBasis
    public let rate: Decimal
    public let currencyCode: String
    public let waste: Decimal?
    public let packSize: Decimal?
    public let costCode: String
    public let trade: String
    public init(id: UUID, name: String, basis: LedgerRateBasis, rate: Decimal, currencyCode: String, waste: Decimal?, packSize: Decimal?, costCode: String, trade: String) {
        self.id = id
        self.name = name
        self.basis = basis
        self.rate = rate
        self.currencyCode = currencyCode
        self.waste = waste
        self.packSize = packSize
        self.costCode = costCode
        self.trade = trade
    }
}

/// What an import did.
public struct LedgerRateImportResult: Hashable, Sendable {
    public let imported: Int
    /// "Line 7: … is not a rate." — every line that was not read, and why.
    public let rejectedLines: [String]
    public let failure: String?
    public init(imported: Int, rejectedLines: [String], failure: String?) {
        self.imported = imported
        self.rejectedLines = rejectedLines
        self.failure = failure
    }
}

/// One row whose Unit Cost differs from the library's current rate for its Material.
public struct LedgerRateUpdate: Hashable, Sendable, Identifiable {
    public let markupID: UUID
    public let subject: String
    public let material: String
    public let before: Decimal
    public let after: Decimal
    public let currencyCode: String
    /// The money the row's total moves by, exact: quantity × (after − before).
    public let moneyDelta: Decimal
    public var id: UUID { markupID }
    public init(markupID: UUID, subject: String, material: String, before: Decimal, after: Decimal, currencyCode: String, moneyDelta: Decimal) {
        self.markupID = markupID
        self.subject = subject
        self.material = material
        self.before = before
        self.after = after
        self.currencyCode = currencyCode
        self.moneyDelta = moneyDelta
    }
}

/// A ledger presenter with a rate library (NL-QTY-05).
@MainActor
public protocol LedgerRateLibraryManaging: LedgerPresenting {
    var rateEntries: [LedgerRateEntrySummary] { get }
    func importRateList(_ text: String) async -> LedgerRateImportResult
    func removeRateEntry(_ id: UUID) async -> Bool
    func applyRateEntry(_ id: UUID, to markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt
    func pendingRateUpdates() async -> [LedgerRateUpdate]
    func applyRateUpdates(_ markupIDs: Set<UUID>) async -> LedgerBulkEditReceipt
}

// MARK: - Whole-project summary (NL-QTY-15)

/// One other open drawing, as a contributor to the whole-project summary.
public struct ProjectLedgerSource: Identifiable, Sendable {
    public let documentID: UUID
    public let title: String
    /// The drawing's subject totals, from its own ledger.
    public let totals: @MainActor @Sendable () async -> [LedgerSubjectTotal]
    public var id: UUID { documentID }
    public init(documentID: UUID, title: String, totals: @escaping @MainActor @Sendable () async -> [LedgerSubjectTotal]) {
        self.documentID = documentID
        self.title = title
        self.totals = totals
    }
}

/// One subject's total in one unit, exact.
public struct LedgerSubjectTotal: Hashable, Sendable {
    public let subject: String
    public let quantity: DecimalQuantity
    public let rowCount: Int
    /// The total as the ledger formats it.
    public let text: String
    public init(subject: String, quantity: DecimalQuantity, rowCount: Int, text: String = "") {
        self.subject = subject
        self.quantity = quantity
        self.rowCount = rowCount
        self.text = text
    }
}

/// Every open drawing's subject totals and their exact combination (NL-QTY-15).
public struct LedgerProjectSummary: Hashable, Sendable {
    /// One drawing's part.
    public struct Drawing: Hashable, Sendable, Identifiable {
        public let documentID: UUID
        public let title: String
        public let totals: [LedgerSubjectTotal]
        public var id: UUID { documentID }
        public init(documentID: UUID, title: String, totals: [LedgerSubjectTotal]) {
            self.documentID = documentID
            self.title = title
            self.totals = totals
        }
    }
    public let drawings: [Drawing]
    /// Per subject and unit across every drawing — each exactly the sum of the drawings' totals.
    public let combined: [LedgerSubjectTotal]
    public init(drawings: [Drawing], combined: [LedgerSubjectTotal]) {
        self.drawings = drawings
        self.combined = combined
    }
}

/// A ledger presenter that can summarise every open drawing together (NL-QTY-15).
@MainActor
public protocol LedgerProjectSummarizing: LedgerPresenting {
    /// Whether other drawings are open to combine with.
    var hasProjectSources: Bool { get }
    /// This drawing and every other open drawing, subject by subject, and combined.
    func projectSummary() async -> LedgerProjectSummary
}

// MARK: - Explain a number

/// The rows behind a total, and where each number came from.
public struct LedgerExplanation: Hashable, Sendable {
    /// One row behind the total.
    public struct Row: Hashable, Sendable, Identifiable {
        public let markupID: UUID
        public let subject: String
        public let label: String
        /// The row's primary quantity as the ledger shows it.
        public let valueText: String
        public let value: DecimalQuantity?
        /// How the number was made: "Measured on A-101 at 1:100", or the formula of a derived row.
        public let provenance: String
        public var id: UUID { markupID }
        public init(markupID: UUID, subject: String, label: String, valueText: String, value: DecimalQuantity?, provenance: String) {
            self.markupID = markupID
            self.subject = subject
            self.label = label
            self.valueText = valueText
            self.value = value
            self.provenance = provenance
        }
    }
    public let rows: [Row]
    /// The exact sum per unit — one line per unit; a unit never absorbs another.
    public let totals: [String]
    public init(rows: [Row], totals: [String]) {
        self.rows = rows
        self.totals = totals
    }
}

/// A ledger presenter that can explain the numbers of a selection.
@MainActor
public protocol LedgerExplaining: LedgerPresenting {
    func explain(_ markupIDs: Set<UUID>) async -> LedgerExplanation
}
