import Foundation
import ZPDFContracts

/// What a formula needs to know about one ledger column.
public struct FormulaColumnDescriptor: Hashable, Sendable {
    public let id: ColumnID
    /// The name a formula writes inside brackets: `[Waste factor]`.
    public let name: String
    /// An optional second spelling, normally the column's stable key.
    public let key: String?
    /// The column's static type. `dynamicNumber` means "a number, dimension decided per row",
    /// which is what pushes dimensional analysis from parse time to evaluation time.
    public let type: FormulaStaticType
    /// The column's own formula, if it is a formula column. Used for cycle detection.
    public let formula: FormulaExpression?
    /// Set when the column holds values a formula cannot read — text, a date or a choice.
    ///
    /// Such a column stays in the catalog (so its name is known and a table of imported text
    /// columns never stops the ledger from building), but a formula that references it is
    /// refused at compile time with a message naming the column's kind. Before BH-157 these
    /// columns typed as numbers and every filled cell read as blank, so `COALESCE([Material], 0)`
    /// silently became 0 on a row that said "Concrete".
    public let unreadableKind: ColumnKind?

    public init(
        id: ColumnID,
        name: String,
        key: String? = nil,
        type: FormulaStaticType,
        formula: FormulaExpression? = nil,
        unreadableKind: ColumnKind? = nil
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.type = type
        self.formula = formula
        self.unreadableKind = unreadableKind
    }

    /// Builds a descriptor from the frozen ledger column definition.
    ///
    /// A checkbox becomes boolean, a currency column becomes its declared money dimension — a
    /// rate such as SEK/m² when it declares one — and any numeric or formula column with a
    /// declared dimension becomes that dimension. A numeric column that declared none becomes
    /// ``FormulaStaticType/dynamicNumber``. A text, date or choice column is recorded as
    /// ``unreadableKind`` so a formula cannot read it.
    public init(_ column: LedgerColumnDefinition) {
        let type: FormulaStaticType
        var unreadable: ColumnKind?
        switch column.kind {
        case .checkbox:
            type = .boolean
        case .currency:
            // S-088: the declared dimension wins, so a "Rate per m²" column types as SEK/m² and
            // `Area * [Rate]` is money. Reading only the display code typed it as plain money,
            // and the product came out as SEK·m², which never totals and cannot be added to
            // other money. A currency column that declared no money dimension falls back to its
            // display code.
            if let declared = column.declaredMoneyDimension {
                type = .number(declared)
            } else if case .currency(let code)? = column.displayUnit {
                type = .number(.currency(code))
            } else {
                type = .dynamicNumber
            }
        case .number, .formula:
            type = column.dimension.map { FormulaStaticType.number($0) } ?? .dynamicNumber
        case .text, .date, .choice:
            type = .dynamicNumber
            unreadable = column.kind
        }
        self.init(
            id: column.id,
            name: column.title,
            key: column.key,
            type: type,
            formula: column.formula,
            unreadableKind: unreadable
        )
    }
}

/// The set of columns a formula may reference, with case-insensitive name lookup.
///
/// # Ambiguous names are refused where they are used, not where they are declared
///
/// A ledger routinely holds two columns whose titles normalise to the same text: a table import
/// whose header says `Material` next to the built-in `material` column, or a schedule with two
/// `Qty` headers. Refusing the whole catalog for that (the behaviour before BH-022) refused the
/// import and every later rebuild of the column set, although no formula mentioned either name.
/// Now every spelling that more than one column claims is recorded as ambiguous; a formula that
/// writes it is refused with ``FormulaEngineErrorCode/duplicateColumnName(_:)`` naming it, and
/// every other formula compiles. Nothing is ever resolved by luck: an ambiguous name resolves to
/// no column at all. A column with a blank title (BH-545) is simply not reachable by name; it is
/// still reachable by its key and by `[col:<id>]`.
public struct FormulaColumnCatalog: Sendable {
    /// The columns in their declared order. Iteration order is stable, which is what makes cycle
    /// detection and compilation order deterministic.
    public let columns: [FormulaColumnDescriptor]

    private let byID: [ColumnID: FormulaColumnDescriptor]
    private let byName: [String: FormulaColumnDescriptor]
    /// Normalised spellings claimed by more than one column.
    private let ambiguous: Set<String>

    public static let empty = FormulaColumnCatalog()

    private init() {
        columns = []
        byID = [:]
        byName = [:]
        ambiguous = []
    }

    /// - Throws: ``FormulaEngineError`` when two columns share an id. Shared *names* are not an
    ///   error here; see the type documentation.
    public init(columns: [FormulaColumnDescriptor]) throws {
        var byID: [ColumnID: FormulaColumnDescriptor] = [:]
        var byName: [String: FormulaColumnDescriptor] = [:]
        var ambiguous: Set<String> = []
        func register(_ spelling: String, _ column: FormulaColumnDescriptor) {
            guard !spelling.isEmpty else { return }
            if let existing = byName[spelling] {
                if existing.id != column.id { ambiguous.insert(spelling) }
                return
            }
            byName[spelling] = column
        }
        for column in columns {
            guard byID.updateValue(column, forKey: column.id) == nil else {
                throw FormulaEngineError(code: .duplicateColumnID(column.id))
            }
            register(FormulaColumnCatalog.normalise(column.name), column)
            if let key = column.key {
                register(FormulaColumnCatalog.normalise(key), column)
            }
        }
        for spelling in ambiguous { byName[spelling] = nil }
        self.columns = columns
        self.byID = byID
        self.byName = byName
        self.ambiguous = ambiguous
    }

    public init(ledgerColumns: [LedgerColumnDefinition]) throws {
        try self.init(columns: ledgerColumns.map(FormulaColumnDescriptor.init))
    }

    public func column(id: ColumnID) -> FormulaColumnDescriptor? { byID[id] }

    /// The single column this spelling names, or nil when no column — or more than one column —
    /// is called that. ``isAmbiguous(_:)`` tells the two apart.
    public func column(named name: String) -> FormulaColumnDescriptor? {
        byName[FormulaColumnCatalog.normalise(name)]
    }

    /// True when more than one column claims this spelling as its name or key.
    public func isAmbiguous(_ name: String) -> Bool {
        ambiguous.contains(FormulaColumnCatalog.normalise(name))
    }

    /// Resolves a name for a formula: the column, nil when nothing is called that, or a thrown
    /// ``FormulaEngineErrorCode/duplicateColumnName(_:)`` when the name is ambiguous.
    func resolve(
        named name: String,
        span: FormulaSourceSpan? = nil,
        subexpression: String? = nil
    ) throws -> FormulaColumnDescriptor? {
        if isAmbiguous(name) {
            throw FormulaEngineError(
                code: .duplicateColumnName(name),
                span: span,
                subexpression: subexpression
            )
        }
        return column(named: name)
    }

    static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
