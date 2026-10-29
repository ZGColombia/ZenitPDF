import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

// MARK: - Specs ↔ definitions

extension LedgerBridge {

    /// Whether the Column Manager may change a column: a user column — made in the manager or
    /// by a table import — and never a built-in or the reserved `Repeat ×` (NL-QTY-02).
    public static func isManageable(_ definition: LedgerColumnDefinition) -> Bool {
        definition.standard == nil && definition.id != RepetitionColumn.columnID
            && definition.id != AssemblyColumn.columnID && definition.id != LiveSummaryColumn.columnID
    }

    /// A user column as the Column Manager edits it.
    public static func spec(of definition: LedgerColumnDefinition) -> LedgerColumnSpec {
        let places: Int? = {
            if case .decimalPlaces(let places)? = definition.precision { return places }
            return nil
        }()
        return LedgerColumnSpec(
            id: LedgerColumnID(definition.key),
            title: definition.title,
            kind: columnKind(definition.kind),
            dimension: definition.dimension.map { Shown.Dimension(domain: $0) },
            decimalPlaces: places,
            choices: definition.choices.map {
                LedgerChoiceOption(
                    id: $0.id.rawValue,
                    value: $0.value,
                    title: $0.value,
                    colorRGBA: $0.color.map { ColorRGBA(domain: $0) } ?? ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0),
                    order: $0.order,
                    isRetired: $0.isRetired
                )
            },
            defaultChoiceID: definition.defaultChoiceID?.rawValue,
            formulaSource: definition.formula?.source,
            isVisible: definition.isVisible,
            neverSums: definition.neverSums == true
        )
    }

    static func domainKind(_ kind: LedgerColumnKind) -> ColumnKind {
        switch kind {
        case .text: .text
        case .number: .number
        case .currency: .currency
        case .date: .date
        case .checkbox: .checkbox
        case .choice: .choice
        case .formula: .formula
        }
    }

    /// The domain definition a spec stands for. An existing column keeps its identity; a new
    /// one takes the UUID its key was minted with.
    static func definition(
        from spec: LedgerColumnSpec,
        existing: LedgerColumnDefinition?,
        order: Int,
        policy: DisplayUnitPolicy,
        formulaDimension: Domain.Dimension? = nil
    ) -> LedgerColumnDefinition {
        let kind = domainKind(spec.kind)
        let id = existing?.id ?? ColumnID(
            UUID(uuidString: String(spec.id.rawValue.dropFirst("custom.".count))) ?? UUID()
        )
        var dimension: Domain.Dimension?
        switch kind {
        case .number, .currency: dimension = spec.dimension.map { Domain.Dimension(shown: $0) }
        case .formula: dimension = formulaDimension
        case .text, .date, .checkbox, .choice: dimension = nil
        }
        let displayUnit: AnyDisplayUnit?
        if let code = dimension?.currencyCode {
            displayUnit = .currency(code)
        } else {
            displayUnit = LedgerColumnSet.displayUnit(for: dimension, policy: policy)
        }
        let precision: PrecisionMode? = spec.decimalPlaces.map { .decimalPlaces($0) }
            ?? (dimension == nil ? nil : (dimension?.currencyCode != nil ? .decimalPlaces(2) : policy.precision))
        return LedgerColumnDefinition(
            id: id,
            key: spec.id.rawValue,
            title: spec.title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            standard: nil,
            dimension: dimension,
            displayUnit: displayUnit,
            precision: precision,
            choices: kind == .choice ? spec.choices.enumerated().map { index, option in
                ChoiceOption(
                    id: ChoiceOptionID(option.id),
                    value: option.value.trimmingCharacters(in: .whitespacesAndNewlines),
                    color: option.colorRGBA.alpha > 0 ? RGBAColor(shown: option.colorRGBA) : nil,
                    order: index,
                    isRetired: option.isRetired
                )
            } : [],
            defaultChoiceID: kind == .choice ? spec.defaultChoiceID.map(ChoiceOptionID.init) : nil,
            formula: kind == .formula ? spec.formulaSource.map { FormulaExpression(source: $0) } : nil,
            isEditable: kind != .formula,
            isVisible: spec.isVisible,
            order: order,
            // ADR-0039: only a number or formula column can sum, so only theirs is kept.
            neverSums: spec.neverSums && (kind == .number || kind == .formula)
        )
    }
}

// MARK: - Applying a column change

/// Why a Column Manager change was refused. Every case says what to do next.
enum ColumnChangeRefusal: Error {
    case emptyTitle
    case duplicateTitle(String)
    case noChoices(String)
    case blankOrDuplicateChoice(String)
    case missingFormula(String)
    case optionInUse(column: String, option: String, rows: Int)
    case readByFormula(column: String, formulas: [String])
    case unconvertible(column: String, rows: Int)
    case lockedRows(column: String, rows: Int)
    case invalid(String)

    var message: String {
        switch self {
        case .emptyTitle:
            return NSLocalizedString(
                "Nothing was changed: every column needs a name.",
                comment: "Column Manager refusal: a column has no name"
            )
        case .duplicateTitle(let title):
            return String(format: NSLocalizedString(
                "Nothing was changed: two columns are called “%@”. Give each column its own name.",
                comment: "Column Manager refusal: two columns share a name; the placeholder is the name"
            ), title)
        case .noChoices(let title):
            return String(format: NSLocalizedString(
                "Nothing was changed: the choice column “%@” needs at least one option.",
                comment: "Column Manager refusal: a choice column without options"
            ), title)
        case .blankOrDuplicateChoice(let title):
            return String(format: NSLocalizedString(
                "Nothing was changed: every option of “%@” needs its own, non-empty name.",
                comment: "Column Manager refusal: a blank or repeated choice option"
            ), title)
        case .missingFormula(let title):
            return String(format: NSLocalizedString(
                "Nothing was changed: the formula column “%@” has no formula.",
                comment: "Column Manager refusal: a formula column without an expression"
            ), title)
        case .optionInUse(let column, let option, let rows):
            return String(format: NSLocalizedString(
                "Nothing was changed: %3$d rows use the option “%2$@” of “%1$@”. Retire the option instead of removing it.",
                comment: "Column Manager refusal: removing a choice option that rows use; column, option, row count"
            ), column, option, rows)
        case .readByFormula(let column, let formulas):
            return String(format: NSLocalizedString(
                "Nothing was changed: “%1$@” is read by the formula column %2$@. Change that formula first.",
                comment: "Column Manager refusal: deleting or retyping a column a formula reads; the column, the formula columns"
            ), column, formulas.map { "“\($0)”" }.joined(separator: ", "))
        case .unconvertible(let column, let rows):
            return String(format: NSLocalizedString(
                "Nothing was changed: %2$d rows hold values “%1$@” cannot keep as the new type. Clear or correct them first.",
                comment: "Column Manager refusal: a retype some stored values cannot survive; column, row count"
            ), column, rows)
        case .lockedRows(let column, let rows):
            return String(format: NSLocalizedString(
                "Nothing was changed: converting “%1$@” would edit %2$d locked markups. Unlock them and try again.",
                comment: "Column Manager refusal: a retype that would edit locked markups; column, row count"
            ), column, rows)
        case .invalid(let reason):
            return String(format: NSLocalizedString(
                "Nothing was changed: %@",
                comment: "Column Manager refusal with the ledger's own reason"
            ), reason)
        }
    }
}

extension AppCoreEnvironment {

    /// The Column Manager's one write path (NL-QTY-02): the user columns become exactly
    /// `specs`, as **one** undoable step, or nothing changes and the receipt says why.
    ///
    /// A retype converts the stored values in the same step, so ⌘Z restores both the column
    /// and every value; a value that cannot become the new type refuses the whole change with
    /// a count rather than being dropped.
    public func applyColumnSpecs(_ specs: [LedgerColumnSpec], actionName: String) async -> LedgerBulkEditReceipt {
        do {
            let batch = try await columnChangeBatch(specs)
            guard !batch.isEmpty else { return LedgerBulkEditReceipt(undoActionName: actionName) }
            guard let outcome = try await commands.performBatch(batch, actionName: actionName) else {
                return LedgerBulkEditReceipt(undoActionName: actionName)
            }
            await ledger.refresh()
            return LedgerBulkEditReceipt(
                changedMarkupIDs: Set(outcome.changedMarkupIDs.map(\.rawValue)),
                undoActionName: actionName
            )
        } catch let refusal as ColumnChangeRefusal {
            return .failure(refusal.message)
        } catch {
            return .failure(ColumnChangeRefusal.invalid(LedgerColumnValidation.describe(error)).message)
        }
    }

    /// The commands a column change is made of: the new column set, then one value edit per
    /// stored cell a retype converts.
    func columnChangeBatch(_ specs: [LedgerColumnSpec]) async throws -> [DocumentCommand] {
        let fullSet = await session.ledgerColumns
        let current = await session.runtimeColumnDefinitions
        let policy = await session.displayUnits.domainPolicy
        let baseDefinitions = fullSet.columns.filter { column in !current.contains { $0.id == column.id } }

        try Self.validate(specs)
        let byKey = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let keptKeys = Set(specs.map(\.id.rawValue))

        // Deleting a column a formula reads is refused, naming the formula (unless that
        // formula goes in the same change).
        for removed in current where !keptKeys.contains(removed.key) {
            let readers = fullSet.formulaColumns(reading: removed.id)
                .compactMap { fullSet.column(id: $0) }
                .filter { keptKeys.contains($0.key) }
            if !readers.isEmpty {
                throw ColumnChangeRefusal.readByFormula(column: removed.title, formulas: readers.map(\.title))
            }
        }

        // Two passes: the formulas' result dimensions come from compiling them.
        func build(_ dimensions: [String: Domain.Dimension]) -> [LedgerColumnDefinition] {
            specs.enumerated().map { index, spec in
                LedgerBridge.definition(
                    from: spec, existing: byKey[spec.id.rawValue], order: baseDefinitions.count + index,
                    policy: policy, formulaDimension: dimensions[spec.id.rawValue]
                )
            }
        }
        let trial = try LedgerColumnSet(columns: baseDefinitions + build([:]))
        var dimensions: [String: Domain.Dimension] = [:]
        for spec in specs where spec.kind == .formula {
            if let column = trial.column(key: spec.id.rawValue), let dimension = trial.formulaResultDimension(column.id) {
                dimensions[spec.id.rawValue] = dimension
            }
        }
        let definitions = build(dimensions)
        let finalSet = try LedgerColumnSet(columns: baseDefinitions + definitions)
        guard definitions != current else { return [] }

        // Retypes and removed options, over the stored values.
        let records = await session.orderedMarkups
        var conversions: [DocumentCommand] = []
        for new in definitions {
            guard let old = byKey[new.key] else { continue }
            if old.kind == .choice, new.kind == .choice {
                let kept = Set(new.choices.map(\.id))
                for option in old.choices where !kept.contains(option.id) {
                    let rows = records.filter { $0.customValues[old.id] == .choice(option.id) }.count
                    if rows > 0 { throw ColumnChangeRefusal.optionInUse(column: new.title, option: option.value, rows: rows) }
                }
            }
            guard old.kind != new.kind || old.dimension != new.dimension else { continue }
            if new.kind != .formula, old.kind != .formula {
                let readers = fullSet.formulaColumns(reading: old.id).compactMap { finalSet.column(id: $0) }
                if !readers.isEmpty, old.kind != new.kind {
                    throw ColumnChangeRefusal.readByFormula(column: old.title, formulas: readers.map(\.title))
                }
            }
            guard new.kind != .formula else { continue }
            var failed = 0
            var locked = 0
            for record in records {
                guard let stored = record.customValues[old.id], stored != .empty else { continue }
                guard let converted = LedgerColumnValueConversion.convert(stored, from: old, to: new) else {
                    failed += 1
                    continue
                }
                guard converted != stored else { continue }
                if record.locked { locked += 1; continue }
                conversions.append(.editCustomValue(id: record.id, column: new.id, value: converted))
            }
            if failed > 0 { throw ColumnChangeRefusal.unconvertible(column: new.title, rows: failed) }
            if locked > 0 { throw ColumnChangeRefusal.lockedRows(column: new.title, rows: locked) }
        }
        return [.setCustomColumns(definitions)] + conversions
    }

    static func validate(_ specs: [LedgerColumnSpec]) throws {
        var seen: Set<String> = []
        for spec in specs {
            let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ColumnChangeRefusal.emptyTitle }
            guard seen.insert(title.lowercased()).inserted else { throw ColumnChangeRefusal.duplicateTitle(title) }
            switch spec.kind {
            case .choice:
                guard !spec.choices.isEmpty else { throw ColumnChangeRefusal.noChoices(title) }
                var values: Set<String> = []
                for option in spec.choices {
                    let value = option.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !value.isEmpty, values.insert(value).inserted else {
                        throw ColumnChangeRefusal.blankOrDuplicateChoice(title)
                    }
                }
            case .formula:
                guard let source = spec.formulaSource, !source.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ColumnChangeRefusal.missingFormula(title)
                }
            default:
                break
            }
        }
    }
}

// MARK: - The presenter's side

extension AppLedgerPresenter: LedgerColumnManaging {

    public var userColumnSpecs: [LedgerColumnSpec] {
        projectedColumnSet.columns.filter(LedgerBridge.isManageable).map(LedgerBridge.spec(of:))
    }

    /// The currency a first rate is typed in, by the session's own locale (U-031). It used to be
    /// asked with a fresh `QuantityFormatter()`, whose locale is `en_US_POSIX`: every unpriced
    /// project read USD here — rate imports, new money columns, assembly recipes — while the
    /// ledger's own money columns read the session's currency.
    public var defaultCurrencyCode: String {
        LedgerBridge.ledgerCurrencyCode(store: projectedStore, formatter: projectionFormatter)
    }

    public func applyColumnSpecs(_ specs: [LedgerColumnSpec], actionName: String) async -> LedgerBulkEditReceipt {
        guard let onApplyColumnSpecs else {
            return .failure(NSLocalizedString(
                "This ledger cannot be edited.",
                comment: "Bulk edit refusal when no document is attached to the ledger"
            ))
        }
        return await onApplyColumnSpecs(specs, actionName)
    }

    public func checkFormula(_ source: String, forColumn id: LedgerColumnID?, specs: [LedgerColumnSpec]) -> String? {
        let full = projectedColumnSet
        let base = full.columns.filter { !LedgerBridge.isManageable($0) }
        var working = specs
        let key = id ?? LedgerColumnID("custom.formula-check")
        if let index = working.firstIndex(where: { $0.id == key }) {
            working[index].kind = .formula
            working[index].formulaSource = source
        } else {
            working.append(LedgerColumnSpec(id: key, title: "\u{2063}formula-check", kind: .formula, formulaSource: source))
        }
        let existing = Dictionary(full.columns.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let definitions = working.enumerated().map { index, spec in
            LedgerBridge.definition(
                from: spec, existing: existing[spec.id.rawValue], order: base.count + index, policy: DisplayUnitPolicy()
            )
        }
        do {
            _ = try LedgerColumnSet(columns: base + definitions)
            return nil
        } catch {
            return LedgerColumnValidation.describe(error)
        }
    }
}

/// Words for a column set the ledger refused.
enum LedgerColumnValidation {
    static func describe(_ error: any Error) -> String {
        if let localized = (error as? any LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }
}

// MARK: - Converting stored values on a retype

/// How a stored value survives a column retype (NL-QTY-02). `nil` means it cannot, and the
/// retype is refused with a count — a value is never dropped or guessed.
enum LedgerColumnValueConversion {

    static func convert(
        _ value: Domain.CellValue,
        from old: LedgerColumnDefinition,
        to new: LedgerColumnDefinition,
        timeZone: TimeZone = .current
    ) -> Domain.CellValue? {
        if case .empty = value { return .empty }
        switch new.kind {
        case .text:
            return text(of: value, in: old, timeZone: timeZone).map { .text($0) }
        case .number:
            guard let number = number(of: value) else { return nil }
            let target = new.dimension
            if let target {
                if number.dimension == target { return .number(number) }
                guard number.dimension.isDimensionless, target.isDimensionless else { return nil }
                return .number(Domain.Quantity(value: number.value, dimension: target))
            }
            return .number(number)
        case .currency:
            let code = new.dimension?.currencyCode
            switch value {
            case .currency(let amount, let stored):
                if let code, code != stored { return nil }
                return .currency(amount: amount, code: stored)
            default:
                guard let code, let number = number(of: value), number.dimension.isDimensionless else { return nil }
                return .currency(amount: number.value, code: code)
            }
        case .choice:
            guard let text = text(of: value, in: old)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let option = new.choices.first(where: {
                      $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == text
                  })
            else { return nil }
            return .choice(option.id)
        case .checkbox:
            switch value {
            case .checkbox: return value
            case .text(let text): return checkbox(fromText: text).map { .checkbox($0) }
            default: return nil
            }
        case .date:
            switch value {
            case .date: return value
            case .text(let text): return date(fromText: text, timeZone: timeZone).map { .date($0) }
            default: return nil
            }
        case .formula:
            return value
        }
    }

    /// The text a value reads as — what a text column keeps. A date reads as its day in
    /// `timeZone`, the zone the ledger shows it in (W-028).
    static func text(
        of value: Domain.CellValue,
        in column: LedgerColumnDefinition,
        timeZone: TimeZone = .current
    ) -> String? {
        switch value {
        case .empty: return ""
        case .text(let text): return text
        case .number(let quantity): return plain(quantity.value)
        case .formulaResult(let quantity, _): return plain(quantity.value)
        case .currency(let amount, _): return plain(amount)
        case .checkbox(let flag): return flag ? "true" : "false"
        case .choice(let id): return column.choices.first { $0.id == id }?.value
        case .date(let date):
            return dayFormatter(timeZone).string(from: date)
        }
    }

    /// The number a value reads as. Text parses by ``decimal(fromText:)``.
    static func number(of value: Domain.CellValue) -> Domain.Quantity? {
        switch value {
        case .number(let quantity): return quantity
        case .formulaResult(let quantity, _): return quantity
        case .currency(let amount, _): return .count(amount)
        case .text(let text): return decimal(fromText: text).map { .count($0) }
        default: return nil
        }
    }

    /// The number a person's text reads as, or `nil`, by ``TypedDecimalGrammar`` with exponents
    /// off — the grammar a ledger cell reads the same text with (`ZPDFDecimalParser`, a facade
    /// over it): spaces group digits, one comma or one period is the decimal mark, U+2212 is a
    /// minus, and anything not wholly a number is refused.
    ///
    /// Whole-string on purpose (V-033): "12-5", "5-" and a lone "-" are refused, not read as a
    /// prefix. One grammar on purpose (W-032): this used to swap every comma for a point and parse
    /// with the importers' strict rule, so "1 250" and "−12,50" were numbers in a cell but were
    /// skipped as a preset's default or a retype's source, while "1e3" — refused by the cell —
    /// became 1000 here.
    static func decimal(fromText text: String) -> Decimal? {
        TypedDecimalGrammar.decimal(text)
    }

    /// The flag a person's text reads as, or `nil`.
    static func checkbox(fromText text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "ja", "x", "✓": true
        case "0", "false", "no", "nej", "": false
        default: nil
        }
    }

    /// The day an ISO 8601 full date (`2026-09-27`) names — its start in `timeZone` — or `nil`.
    static func date(fromText text: String, timeZone: TimeZone = .current) -> Date? {
        dayFormatter(timeZone).date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The one reader and writer of a day-only date, in the zone the ledger displays dates in
    /// (`Date.FormatStyle`, the current zone) and widens a date-equality filter to (the local
    /// day, `SessionSnapshots`).
    ///
    /// `ISO8601DateFormatter`'s zone defaults to GMT, so a preset default or a retyped "2026-09-27"
    /// was stored as 2026-09-27T00:00Z: in UTC−5 the cell read 26 Sep and "is 27 Sep" did not match
    /// it, and east of GMT a date at local midnight retyped to text as the previous day (W-028).
    static func dayFormatter(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return formatter
    }

    static func plain(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}
