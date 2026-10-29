import Foundation
import Observation
import ZPDFUIPresentation

/// The Column Manager's state (NL-QTY-02): the project's user columns, the one column being
/// added or edited, and the outcome of the last change.
///
/// Every change — add, edit, delete, move, show/hide — is applied the moment it is committed,
/// as **one** undoable step through ``LedgerColumnManaging``, so ⌘Z takes back exactly the last
/// thing done in the manager. A refusal leaves the list as it was and says why.
@MainActor
@Observable
public final class LedgerColumnManagerModel {

    /// The user columns as the ledger has them now, in order.
    public private(set) var columns: [LedgerColumnSpec]

    /// The column being added or edited, or `nil`.
    public var draft: LedgerColumnSpec?

    /// Whether ``draft`` is a new column.
    public private(set) var isDraftNew = false

    /// The outcome of the last change, success or refusal, in words.
    public private(set) var message: String?

    /// Whether the last change was refused.
    public private(set) var lastChangeFailed = false

    /// Whether a change is being applied, so a second click cannot race it.
    public private(set) var isApplying = false

    /// The currency a new money column starts in.
    public let defaultCurrencyCode: String

    @ObservationIgnored private let presenter: any LedgerColumnManaging

    /// Creates the model over a presenter that can manage columns.
    public init(presenter: any LedgerColumnManaging) {
        self.presenter = presenter
        self.columns = presenter.userColumnSpecs
        self.defaultCurrencyCode = presenter.defaultCurrencyCode
    }

    /// Re-reads the columns from the ledger — after an undo, say.
    public func reload() {
        columns = presenter.userColumnSpecs
    }

    // MARK: Drafts

    /// Starts a new column of `kind`.
    public func beginAdd(kind: LedgerColumnKind = .text) {
        var spec = LedgerColumnSpec.new(kind: kind, title: "")
        Self.prepare(&spec, for: kind, currencyCode: defaultCurrencyCode)
        draft = spec
        isDraftNew = true
        message = nil
    }

    /// Starts editing an existing column.
    public func beginEdit(_ id: LedgerColumnID) {
        guard let spec = columns.first(where: { $0.id == id }) else { return }
        draft = spec
        isDraftNew = false
        message = nil
    }

    /// Abandons the draft.
    public func cancelDraft() {
        draft = nil
        isDraftNew = false
    }

    /// Changes the draft's kind, giving it the settings the new kind needs.
    public func setDraftKind(_ kind: LedgerColumnKind) {
        guard var spec = draft, spec.kind != kind else { return }
        spec.kind = kind
        Self.prepare(&spec, for: kind, currencyCode: defaultCurrencyCode)
        draft = spec
    }

    /// The settings a kind starts with: a money column gets the ledger's currency, a choice
    /// column one empty option to fill in, a number column no unit.
    static func prepare(_ spec: inout LedgerColumnSpec, for kind: LedgerColumnKind, currencyCode: String) {
        switch kind {
        case .currency:
            if spec.dimension?.currencyCode == nil { spec.dimension = .currency(currencyCode) }
        case .number:
            if spec.dimension?.currencyCode != nil { spec.dimension = nil }
        default:
            spec.dimension = nil
        }
        if kind == .choice, spec.choices.isEmpty {
            spec.choices = [Self.newOption(order: 0)]
        }
        if kind == .formula, spec.formulaSource == nil { spec.formulaSource = "" }
    }

    /// A blank option with a fresh identity.
    static func newOption(order: Int) -> LedgerChoiceOption {
        LedgerChoiceOption(
            id: UUID(), value: "", title: "",
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0), order: order
        )
    }

    /// The formula problem the ledger's own engine finds in the draft, or `nil` when it
    /// compiles. Checked against the columns as they would be after the draft is applied.
    public var draftFormulaProblem: String? {
        guard let draft, draft.kind == .formula else { return nil }
        let source = draft.formulaSource ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return presenter.checkFormula(source, forColumn: draft.id, specs: columnsWithDraft(draft))
    }

    /// Whether the draft can be committed as it stands.
    public var canCommitDraft: Bool {
        guard let draft, !isApplying else { return false }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch draft.kind {
        case .choice:
            return draft.choices.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        case .formula:
            let source = draft.formulaSource ?? ""
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftFormulaProblem == nil
        default:
            return true
        }
    }

    // MARK: Choice options of the draft

    /// Adds a blank option to the draft.
    public func addDraftOption() {
        guard var spec = draft else { return }
        spec.choices.append(Self.newOption(order: spec.choices.count))
        draft = spec
    }

    /// Removes an option from the draft. The ledger refuses the change on commit if rows use
    /// it — retiring is how an option in use goes away.
    public func removeDraftOption(_ id: UUID) {
        guard var spec = draft else { return }
        spec.choices.removeAll { $0.id == id }
        if spec.defaultChoiceID == id { spec.defaultChoiceID = nil }
        draft = spec
    }

    /// Moves an option up (`-1`) or down (`+1`).
    public func moveDraftOption(_ id: UUID, by offset: Int) {
        guard var spec = draft, let index = spec.choices.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard spec.choices.indices.contains(target) else { return }
        spec.choices.swapAt(index, target)
        for position in spec.choices.indices { spec.choices[position].order = position }
        draft = spec
    }

    /// Renames an option. Its identity — what the rows store — stays.
    public func setDraftOptionValue(_ id: UUID, _ value: String) {
        updateOption(id) { $0.value = value; $0.title = value }
    }

    /// Sets an option's swatch colour; `nil` removes it. The name always carries the meaning.
    public func setDraftOptionColor(_ id: UUID, _ color: ColorRGBA?) {
        updateOption(id) { $0.colorRGBA = color ?? ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0) }
    }

    /// Retires or restores an option: a retired one stays readable on rows but is not offered.
    public func setDraftOptionRetired(_ id: UUID, _ retired: Bool) {
        updateOption(id) { $0.isRetired = retired }
        if retired, draft?.defaultChoiceID == id { draft?.defaultChoiceID = nil }
    }

    /// Makes an option the default, or clears the default.
    public func setDraftDefaultOption(_ id: UUID?) {
        draft?.defaultChoiceID = id
    }

    private func updateOption(_ id: UUID, _ change: (inout LedgerChoiceOption) -> Void) {
        guard var spec = draft, let index = spec.choices.firstIndex(where: { $0.id == id }) else { return }
        change(&spec.choices[index])
        draft = spec
    }

    // MARK: Committing

    /// The list the ledger would hold with `draft` in place (appended when new).
    func columnsWithDraft(_ draft: LedgerColumnSpec) -> [LedgerColumnSpec] {
        var list = columns
        if let index = list.firstIndex(where: { $0.id == draft.id }) {
            list[index] = draft
        } else {
            list.append(draft)
        }
        return list
    }

    /// Applies the draft. Returns whether it took.
    @discardableResult
    public func commitDraft() async -> Bool {
        guard var draft, canCommitDraft else { return false }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.choices = draft.choices.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let name = isDraftNew ? Self.addActionName : Self.editActionName
        let ok = await apply(columnsWithDraft(draft), actionName: name)
        if ok { cancelDraft() }
        return ok
    }

    /// Deletes a column. Refused, naming the formula, when a formula reads it.
    @discardableResult
    public func delete(_ id: LedgerColumnID) async -> Bool {
        await apply(columns.filter { $0.id != id }, actionName: Self.deleteActionName)
    }

    /// Moves a column one place left (`-1`) or right (`+1`) among the user columns.
    @discardableResult
    public func move(_ id: LedgerColumnID, by offset: Int) async -> Bool {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard columns.indices.contains(target) else { return false }
        var list = columns
        list.swapAt(index, target)
        return await apply(list, actionName: Self.moveActionName)
    }

    /// Shows or hides a column in the ledger.
    @discardableResult
    public func setVisible(_ id: LedgerColumnID, _ visible: Bool) async -> Bool {
        guard let index = columns.firstIndex(where: { $0.id == id }), columns[index].isVisible != visible else {
            return false
        }
        var list = columns
        list[index].isVisible = visible
        return await apply(list, actionName: visible ? Self.showActionName : Self.hideActionName)
    }

    private func apply(_ list: [LedgerColumnSpec], actionName: String) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        defer { isApplying = false }
        let receipt = await presenter.applyColumnSpecs(list, actionName: actionName)
        if let failure = receipt.failureDescription {
            message = failure
            lastChangeFailed = true
            return false
        }
        lastChangeFailed = false
        message = String(
            format: NSLocalizedString("Done: %@. Undo takes it back.", comment: "Column Manager confirmation; the placeholder is the change's name"),
            actionName
        )
        reload()
        return true
    }

    // MARK: Waste and order (NL-QTY-06)

    /// The quantity a waste set is built on.
    public enum WasteBasis: String, CaseIterable, Identifiable, Sendable {
        case area, length, volume, count
        public var id: String { rawValue }
        /// The formula variable that reads the net quantity.
        var variable: String {
            switch self {
            case .area: "Area"
            case .length: "Length"
            case .volume: "Volume"
            case .count: "Count"
            }
        }
        /// The dimension of one pack (a board, a roll, a bag).
        var packDimension: QuantityDimension {
            switch self {
            case .area: .area
            case .length: .length
            case .volume: .volume
            case .count: .count
            }
        }
        /// The menu title.
        public var displayName: String {
            switch self {
            case .area: NSLocalizedString("Waste and Order by Area", comment: "Column Manager: add waste, pack size, gross and order columns over area")
            case .length: NSLocalizedString("Waste and Order by Length", comment: "Column Manager: add waste, pack size, gross and order columns over length")
            case .volume: NSLocalizedString("Waste and Order by Volume", comment: "Column Manager: add waste, pack size, gross and order columns over volume")
            case .count: NSLocalizedString("Waste and Order by Count", comment: "Column Manager: add waste, pack size, gross and order columns over count")
            }
        }
    }

    /// Adds Waste (a factor per row), Pack size, Gross = net × (1 + waste) and
    /// Order = packs rounded up, as **one** change (NL-QTY-06).
    ///
    /// The net quantity is never overwritten: Gross and Order are formula columns beside it,
    /// evaluated by the ledger's one engine, and a row with no waste reads its net as gross
    /// (`COALESCE`), never a silently invented factor. A row with no pack size has no order —
    /// its Order cell reads "No input" rather than showing 0 packs — and a row of another kind
    /// (a Length row under the area preset) has no gross. Both are left out of the totals like
    /// empty cells, so the Gross total is the sum over the rows that have a gross (V-058,
    /// ADR-0040); a real refusal — a division by zero, a unit conflict — still refuses.
    ///
    /// The totals are the point (U-056, ADR-0039). Pack size is left out of totals: it
    /// describes one row, and a sum of board sizes means nothing. Order is written as a count
    /// — `CONVERT(…, 1, count)`, the grammar's way of saying a bare number is a number of
    /// things — because Gross / Pack size is area / area, which the algebra types a ratio, and
    /// a ratio never sums: the boards to order used to have no total anywhere.
    @discardableResult
    public func addWasteAndOrderColumns(basis: WasteBasis) async -> Bool {
        let waste = uniqueTitle(NSLocalizedString("Waste", comment: "Column Manager: waste factor column title"))
        let pack = uniqueTitle(NSLocalizedString("Pack size", comment: "Column Manager: pack size column title"))
        let gross = uniqueTitle(NSLocalizedString("Gross", comment: "Column Manager: gross quantity column title"))
        let order = uniqueTitle(NSLocalizedString("Order", comment: "Column Manager: packs to order column title"))
        let specs = [
            LedgerColumnSpec(id: .custom(UUID().uuidString), title: waste, kind: .number, dimension: .ratio, decimalPlaces: 2),
            LedgerColumnSpec(id: .custom(UUID().uuidString), title: pack, kind: .number, dimension: basis.packDimension, neverSums: true),
            LedgerColumnSpec(
                id: .custom(UUID().uuidString), title: gross, kind: .formula,
                formulaSource: "\(basis.variable) * (1 + COALESCE([\(waste)], 0))"
            ),
            LedgerColumnSpec(
                id: .custom(UUID().uuidString), title: order, kind: .formula, decimalPlaces: 0,
                formulaSource: "CONVERT(ROUNDUP([\(gross)] / [\(pack)], 0), 1, count)"
            )
        ]
        return await apply(columns + specs, actionName: Self.addWasteActionName)
    }

    /// `title`, or `title 2`, `title 3` … when a column already has that name.
    func uniqueTitle(_ title: String) -> String {
        let taken = Set(columns.map { $0.title.lowercased() })
        guard taken.contains(title.lowercased()) else { return title }
        var index = 2
        while taken.contains("\(title) \(index)".lowercased()) { index += 1 }
        return "\(title) \(index)"
    }

    // MARK: Names

    static var addWasteActionName: String { NSLocalizedString("Add Waste and Order Columns", comment: "Undo action name: waste, pack size, gross and order columns added") }

    static var addActionName: String { NSLocalizedString("Add Column", comment: "Undo action name: a column added in the Column Manager") }
    static var editActionName: String { NSLocalizedString("Edit Column", comment: "Undo action name: a column changed in the Column Manager") }
    static var deleteActionName: String { NSLocalizedString("Delete Column", comment: "Undo action name: a column deleted in the Column Manager") }
    static var moveActionName: String { NSLocalizedString("Move Column", comment: "Undo action name: a column moved in the Column Manager") }
    static var showActionName: String { NSLocalizedString("Show Column", comment: "Undo action name: a column shown from the Column Manager") }
    static var hideActionName: String { NSLocalizedString("Hide Column", comment: "Undo action name: a column hidden from the Column Manager") }

    /// The names a formula may use, for the editor's insert menu: the built-in variables, then
    /// every user column a formula can read, bracketed.
    public var formulaNames: [String] {
        let variables = ["Area", "Length", "Perimeter", "Count", "Volume", "WallArea",
                         "TrueLength", "TrueArea", "Depth", "Height", "Slope", "UnitCost"]
        let readable = columns.filter { spec in
            spec.id != draft?.id && [.number, .currency, .formula, .checkbox].contains(spec.kind)
        }
        return variables + readable.map { "[\($0.title)]" }
    }
}
