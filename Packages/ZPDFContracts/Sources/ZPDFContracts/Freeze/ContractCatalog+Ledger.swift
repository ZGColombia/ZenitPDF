import Foundation

extension ContractCatalog {

    static func ledgerContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(.enumeration(
            StandardLedgerColumn.self,
            name: "StandardLedgerColumn",
            summary: "The standard Quantity Ledger columns (spec 15.2).",
            invariants: [
                "Built-in columns are identified by a stable key, not by position, so re-ordering the ledger never rewrites a saved layout or a formula.",
                "Derived quantity columns are read-only. That is the difference between a takeoff and a spreadsheet.",
                "A quantity column reads the net field where one exists: planArea reads netArea and wallArea reads netWallArea (ADR-0016). Plan Area is therefore the quantity after cutouts, the same number Volume, True Area and the formula variable Area are built from.",
                "Every column with a measurementField is read-only, Depth and Height included (ADR-0017): a value typed into such a cell would have nowhere to go.",
                "grossArea reads the planArea field (the outline before cutouts) and cutoutArea reads the cutoutArea field (ADR-0018). Both are reported beside Plan Area and neither is summed into it; cutoutArea is never summed at all, because a parent and its cutout rows report the same area.",
                "A cutout is part of its parent, never a quantity of its own (ADR-0018): every quantity cell of a cutout's own row is empty under every CutoutPolicy, so a cutout row adds nothing to and subtracts nothing from any subtotal or grand total. The one exception is cutoutArea, which shows the cutout's area when the parent's policy is subtractAndReportSeparately (showsValueOnCutoutRow(parentPolicy:))."
            ],
            note: { "\($0.kind.rawValue)\($0.isUserEditable ? ", editable" : ", read-only")" }
        ))

        types.append(.enumeration(
            ColumnKind.self,
            name: "ColumnKind",
            summary: "The kinds a ledger column can be (spec 15.3)."
        ))

        types.append(try .reflecting(
            ContractSamples.choiceOption,
            name: "ChoiceOption",
            summary: "One option of a Choice column (spec 15.3).",
            annotations: [
                "id": .init("-", "stable identity; renaming the display text must not change it"),
                "value": .init("-", "the stored value"),
                "color": .init("sRGB 0...1", "swatch; never the only carrier of meaning"),
                "order": .init("-", "sort position within the column"),
                "isRetired": .init("-", "stays readable on existing rows, not offered for new ones")
            ],
            invariants: [
                "A retired option may not be the column default.",
                "Choice colour is decoration: the value text is always shown too."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.column,
            name: "LedgerColumnDefinition",
            summary: "Definition of one Quantity Ledger column, standard or custom (spec 15.2, 15.3).",
            annotations: [
                "id": .init("-", "stable column identity"),
                "key": .init("-", "unique within a project; used in formulas and saved layouts"),
                "title": .init("-", "header text, localised at the view boundary"),
                "kind": .init("-", "the value kind the column holds"),
                "standard": .init("-", "set for built-ins, nil for custom columns"),
                "dimension": .init("-", "the dimension of the column's values, for number and formula columns"),
                "displayUnit": .init("-", "display unit for the column"),
                "precision": .init("-", "applied at the view and export boundary only"),
                "choices": .init("-", "options, for a Choice column"),
                "defaultChoiceID": .init("-", "default option, for a Choice column"),
                "formula": .init("-", "the expression, for a Formula column"),
                "isEditable": .init("-", "whether the user may type into the column"),
                "isVisible": .init("-", "whether the column is currently shown"),
                "order": .init("-", "left-to-right position in the current layout"),
                "neverSums": .init("-", "true: the values describe one row and never sum into a total (ADR-0039); nil: the standard rule decides")
            ],
            invariants: [
                "Two columns may not share a key (LedgerError.duplicateColumnKey).",
                "A Choice column has at least one option, and its default is not retired.",
                "A Formula column carries a FormulaExpression that passes validate().",
                "A standard column may not be marked editable when the contract says it is derived.",
                "A column with neverSums set has no Sum in the standard aggregation plan, on screen or in any export; its Count stays. The key is encoded only when set, so a definition written before ADR-0039 decodes as nil and keeps its bytes."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "LedgerCellValue",
            kind: "enum",
            summary: "One cell value (spec 15.3).",
            cases: [
                ContractCaseDescription(name: "empty", rawValue: "-"),
                ContractCaseDescription(name: "text", rawValue: "String"),
                ContractCaseDescription(name: "number", rawValue: "DecimalQuantity", note: "SI base units"),
                ContractCaseDescription(name: "currency", rawValue: "(amount: Decimal, code: String)", note: "ISO 4217 code"),
                ContractCaseDescription(name: "date", rawValue: "Date"),
                ContractCaseDescription(name: "checkbox", rawValue: "Bool"),
                ContractCaseDescription(name: "choice", rawValue: "ChoiceOptionID"),
                ContractCaseDescription(name: "formulaResult", rawValue: "(value: DecimalQuantity, grammarVersion: Int)", note: "cached with the grammar that produced it")
            ],
            invariants: [
                "A value's kind must match its column's kind, or LedgerError.cellKindMismatch; a text value can never land in a currency column.",
                "empty is accepted by any column.",
                "Numbers are stored in SI base units and are not rounded."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.row,
            name: "LedgerRowRecord",
            summary: "One row of the Quantity Ledger (spec 15.1, 15.5).",
            annotations: [
                "id": .init("-", "stable row identity"),
                "markupID": .init("-", "the markup this row reports on; nil for a group or aggregate row"),
                "parentRowID": .init("-", "the parent group row"),
                "depth": .init("-", "outline depth, 0 at top level"),
                "groupPath": .init("-", "the grouping key values that produced the row, outermost first"),
                "cells": .init("-", "cell values by column"),
                "isGroupRow": .init("-", "true for a group header / aggregate row"),
                "descendantCount": .init("-", "number of markup rows underneath, for a group row")
            ],
            invariants: [
                "Rows are a flattened tree: parentRowID and depth describe the outline the NSOutlineView draws.",
                "groupPath records how the row was produced, so a regroup can be diffed instead of rebuilt.",
                "Every cell's column must exist in the column set (LedgerError.unknownColumn)."
            ]
        ))

        types.append(.enumeration(
            LedgerGroupingKey.self,
            name: "LedgerGroupingKey",
            summary: "The grouping keys the ledger offers (spec 15.5)."
        ))

        return ContractDocument(
            contract: "LEDGER_CONTRACT",
            contractVersion: ContractVersion.ledger,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["15.1", "15.2", "15.3", "15.5"],
            summary: """
                The Quantity Ledger's data model: the standard columns, the custom column kinds, \
                the cell value union and the flattened row tree the outline view renders.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "standardColumns",
                    columns: ["column", "kind", "measurementField", "userEditable"],
                    rows: StandardLedgerColumn.allCases.map {
                        [
                            $0.rawValue,
                            $0.kind.rawValue,
                            $0.measurementField?.rawValue ?? "-",
                            $0.isUserEditable ? "true" : "false"
                        ]
                    }
                ),
                ContractTable(
                    name: "customColumnKinds",
                    columns: ["kind", "note"],
                    rows: ColumnKind.allCases.map { [$0.rawValue, columnKindNote($0)] }
                )
            ],
            invariants: [
                "The primary implementation is NSOutlineView / NSTableView with virtualized rows and background queries; SwiftUI Table may only replace it after a benchmark against 100 000 rows (spec 15.1).",
                "Columns are identified by a stable key, never by position.",
                "Derived quantity columns are read-only.",
                "Choice options carry values, colours, order, a default and retired values (spec 15.3).",
                "Numbers stored in cells are SI base units without display rounding; PrecisionMode applies at the view and export boundary only."
            ]
        )
    }

    static func formulaContract(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(try .reflecting(
            ContractSamples.formula,
            name: "FormulaExpression",
            summary: """
                A stored formula (spec 15.4). The contract freezes the persisted shape — source \
                text plus grammar version — without freezing the AST: the Pratt parser, its node \
                types and its evaluator live in the ledger engine package.
                """,
            annotations: [
                "source": .init("-", "the formula as the user typed it; never evaluated as script"),
                "grammarVersion": .init("-", "the grammar the source was authored against")
            ],
            invariants: [
                "There is no JavaScript, no host bridge and no runtime-extensible function set (spec 15.4).",
                "Persisting the source rather than a serialised AST means a grammar fix re-parses old formulas instead of migrating them.",
                "A grammarVersion newer than the build understands is FormulaError.unsupportedGrammarVersion, not a best-effort parse.",
                "An empty or whitespace-only source is FormulaError.emptySource."
            ]
        ))

        types.append(.enumeration(
            FormulaOperator.self,
            name: "FormulaOperator",
            summary: "The operators the grammar defines (spec 15.4).",
            invariants: [
                "Binding powers are fixed by the contract, so the same source always parses to the same AST.",
                "Only ^ is right-associative.",
                "not is prefix-only and has no infix binding power."
            ],
            note: { operatorNote($0) }
        ))

        types.append(.enumeration(
            FormulaFunction.self,
            name: "FormulaFunction",
            summary: "The function set the grammar defines (spec 15.4). Closed by design.",
            invariants: [
                "An identifier that is not in this set is FormulaError.unknownFunction; there is no arbitrary-function path.",
                "A wrong argument count is FormulaError.argumentCountMismatch with the permitted range."
            ],
            note: { "arity \($0.arity.lowerBound)...\($0.arity.upperBound)" }
        ))

        types.append(.enumeration(
            FormulaVariable.self,
            name: "FormulaVariable",
            summary: "The built-in variables a formula can reference (spec 15.4).",
            invariants: [
                "Custom columns are referenced by their column key, so an unknown identifier is resolved against the column set before it becomes FormulaError.unknownVariable.",
                "UnitCost has no fixed length power: it is currency per whatever it prices, resolved from the column."
            ],
            note: { variable in
                variable.measurementField.map { "reads \($0.rawValue) [\($0.dimension.baseUnitSymbol)]" }
                    ?? "resolved from the column"
            }
        ))

        return ContractDocument(
            contract: "FORMULA_CONTRACT",
            contractVersion: ContractVersion.formula,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["15.4"],
            summary: """
                The formula grammar: a closed operator set, a closed function set, a fixed \
                variable vocabulary, Decimal arithmetic and dimensional analysis. No script \
                evaluation of any kind.
                """,
            types: types,
            tables: [
                ContractTable(
                    name: "operators",
                    columns: ["operator", "infixBindingPower", "associativity", "predicate"],
                    rows: FormulaOperator.allCases.map {
                        [
                            $0.rawValue,
                            $0.infixBindingPower.map(String.init) ?? "prefix only",
                            $0.isRightAssociative ? "right" : "left",
                            $0.isPredicate ? "true" : "false"
                        ]
                    }
                ),
                ContractTable(
                    name: "functions",
                    columns: ["function", "minArgs", "maxArgs"],
                    rows: FormulaFunction.allCases.map {
                        [$0.rawValue, String($0.arity.lowerBound), String($0.arity.upperBound)]
                    }
                ),
                ContractTable(
                    name: "variables",
                    columns: ["variable", "measurementField", "baseUnit"],
                    rows: FormulaVariable.allCases.map {
                        [
                            $0.rawValue,
                            $0.measurementField?.rawValue ?? "-",
                            $0.dimension?.baseUnitSymbol ?? "-"
                        ]
                    }
                ),
                ContractTable(
                    name: "errors",
                    columns: ["error", "meaning"],
                    rows: [
                        ["emptySource", "the source is empty or whitespace only"],
                        ["unexpectedCharacter", "the lexer met a character the grammar does not define"],
                        ["unexpectedToken", "the parser met a token it cannot place"],
                        ["unexpectedEndOfInput", "the source ended while input was still expected"],
                        ["unknownFunction", "the name is not in the frozen function set"],
                        ["unknownVariable", "neither a frozen variable nor a known custom column key"],
                        ["argumentCountMismatch", "wrong number of arguments for the function"],
                        ["dimensionRejected", "the expression mixes dimensions the algebra rejects"],
                        ["cycleDetected", "column A depends on column B which depends back on A"],
                        ["unsupportedGrammarVersion", "the stored grammar is newer than this build"],
                        ["divisionByZero", "division by zero during evaluation"]
                    ]
                )
            ],
            invariants: [
                "No JavaScript and no eval of any kind. The grammar is a Zenit Pratt parser over a closed operator and function set (spec 15.4).",
                "Arithmetic is Decimal.",
                "Every expression is dimension-analysed; incompatible dimensions are a typed error, never a silent coercion.",
                "CONVERT yields a dimensionless magnitude in the target unit, so a converted value can never be added back to a quantity stored in SI base units.",
                "Cycles between formula columns are detected before evaluation and reported with the dependency path.",
                "The AST is deterministic: identical source at the same grammar version always yields the same tree.",
                "The grammar is versioned; stored formulas record the version they were authored against."
            ]
        )
    }

    /// Exhaustive on purpose (BH-483): a new operator must say here what it is, or the freeze
    /// does not compile. A `default: "predicate"` would annotate a future unary minus or
    /// string concatenation as a predicate while the operators table printed
    /// `isPredicate = false` for it in the same document.
    private static func operatorNote(_ value: FormulaOperator) -> String {
        switch value {
        case .add: "addition; requires identical dimensions"
        case .subtract: "subtraction; requires identical dimensions"
        case .multiply: "product; length powers add"
        case .divide: "quotient; length powers subtract"
        case .modulo: "remainder; dimensionless right operand"
        case .power: "integer exponent only; right-associative"
        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual,
             .and, .or, .not:
            "predicate"
        }
    }

    /// Exhaustive for the same reason (BH-482): `ColumnKind` is enumerated automatically above,
    /// and a hand-written table beside it is a second list that can silently fall behind.
    private static func columnKindNote(_ kind: ColumnKind) -> String {
        switch kind {
        case .text: "free text"
        case .number: "dimensioned Decimal in SI base units"
        case .currency: "Decimal amount plus ISO 4217 code"
        case .date: "Date"
        case .checkbox: "Bool"
        case .choice: "values, colours, order, default, retired values"
        case .formula: "FormulaExpression, see FORMULA_CONTRACT"
        }
    }
}
