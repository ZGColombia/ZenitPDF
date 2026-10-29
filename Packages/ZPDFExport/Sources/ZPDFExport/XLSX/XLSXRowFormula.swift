import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// A ledger formula column written as a spreadsheet formula over the cells of its own row
/// (NL-QTY-13).
///
/// The formula is taken from the one engine's syntax tree (``FormulaEngine/parse(_:)``), never
/// re-parsed by hand, and translated only when every piece has a spreadsheet counterpart that
/// computes the **same** number:
///
/// - `+ - * / ^`, comparisons, `and`/`or`/`not`, literals;
/// - `IF`, `ABS`, `SQRT`, `MIN`, `MAX`, `POW` (as `POWER`);
/// - `ROUND` (half away from zero in both), `ROUNDUP` (away from zero), `ROUNDDOWN` (toward
///   zero), and `CEILING`/`FLOOR`, which the engine defines toward ±infinity and are therefore
///   spelled with `IF(x<0, …)` rather than the spreadsheet's own `CEILING`, whose sign rules
///   differ.
///
/// Anything else — `%` (the two disagree on the sign of a remainder), `COALESCE`, `CONVERT`,
/// the group aggregates — and any reference to a column that is not exported leaves the column
/// as plain numbers. Every operator is parenthesised, because the spreadsheet binds a prefix
/// minus tighter than `^` and the engine does not.
///
/// The spreadsheet computes in the unit the cell holds, the engine in the SI base unit. So a
/// formula is written only on a row where the result and every operand are numbers whose
/// display value is their SI value (``ExportNumber/raw`` equals ``ExportNumber/convertedRaw``) —
/// an imperial display unit keeps the number, which is right without a formula.
struct XLSXRowFormula: Hashable, Sendable {

    enum Piece: Hashable, Sendable {
        case literal(String)
        /// An operand: the index of the exported ledger column it reads.
        case column(Int)
    }

    let pieces: [Piece]

    /// The ledger columns this formula reads, in order of first appearance.
    var operandColumns: [Int] {
        var seen = Set<Int>()
        return pieces.compactMap { piece in
            guard case .column(let index) = piece, seen.insert(index).inserted else { return nil }
            return index
        }
    }

    /// The text with each operand replaced by `letter(sheetColumn) + excelRow`.
    func render(row excelRow: Int, sheetColumn: (Int) -> Int) -> String {
        pieces.map { piece in
            switch piece {
            case .literal(let text): text
            case .column(let index): XLSXExporter.columnReference(sheetColumn(index)) + String(excelRow)
            }
        }.joined()
    }

    /// The translation of `canonicalText` against `columns`, or `nil` when it has none.
    static func translate(_ canonicalText: String, columns: [ExportColumn]) -> XLSXRowFormula? {
        guard let node = try? FormulaEngine.parse(canonicalText) else { return nil }
        var pieces: [Piece] = []
        guard emit(node, columns: columns, into: &pieces) else { return nil }
        return XLSXRowFormula(pieces: pieces)
    }

    /// The exported column a builtin variable reads: the standard column over the same field.
    static func key(for variable: FormulaBuiltinVariable) -> String? {
        if variable == .unitCost { return StandardLedgerColumn.unitCost.rawValue }
        guard let field = variable.measurementField else { return nil }
        return StandardLedgerColumn.allCases.first { $0.measurementField == field }?.rawValue
    }

    private static func number(_ value: Decimal) -> String {
        value == 0 ? "0" : "\(value)"
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func emit(_ node: FormulaNode, columns: [ExportColumn], into out: inout [Piece]) -> Bool {
        func operand(_ index: Int?) -> Bool {
            guard let index, columns[index].isNumeric else { return false }
            out.append(.column(index))
            return true
        }
        func wrap(_ open: String, _ children: [FormulaNode], separator: String = ",") -> Bool {
            out.append(.literal(open))
            for (position, child) in children.enumerated() {
                if position > 0 { out.append(.literal(separator)) }
                guard emit(child, columns: columns, into: &out) else { return false }
            }
            out.append(.literal(")"))
            return true
        }
        switch node {
        case .number(let value, _):
            out.append(.literal(number(value)))
            return true
        case .boolean(let flag, _):
            out.append(.literal(flag ? "TRUE" : "FALSE"))
            return true
        case .variable(let variable, _):
            let key = key(for: variable)
            return operand(key.flatMap { key in columns.firstIndex { $0.key == key } })
        case .columnByName(let name, _):
            return operand(columns.firstIndex { $0.title == name } ?? columns.firstIndex { $0.key == name })
        case .columnByID(let id, _):
            return operand(columns.firstIndex { $0.columnID == id })
        case .unary(let symbol, let inner, _):
            switch symbol {
            case .subtract: return wrap("(-(", [inner]) && appendClose(&out)
            case .add: return wrap("((", [inner]) && appendClose(&out)
            case .not: return wrap("NOT(", [inner])
            default: return false
            }
        case .binary(let symbol, let lhs, let rhs, _):
            let infix: String
            switch symbol {
            case .add, .subtract, .multiply, .divide, .power, .lessThan, .lessThanOrEqual,
                 .greaterThan, .greaterThanOrEqual:
                infix = symbol.rawValue
            case .equal: infix = "="
            case .notEqual: infix = "<>"
            case .and: return wrap("AND(", [lhs, rhs])
            case .or: return wrap("OR(", [lhs, rhs])
            case .modulo, .not: return false
            }
            return wrap("(", [lhs, rhs], separator: infix)
        case .call(let function, let arguments, _):
            switch function {
            case .iff: return wrap("IF(", arguments)
            case .abs: return wrap("ABS(", arguments)
            case .sqrt: return wrap("SQRT(", arguments)
            case .min: return wrap("MIN(", arguments)
            case .max: return wrap("MAX(", arguments)
            case .pow: return wrap("POWER(", arguments)
            case .round, .roundUp, .roundDown:
                let name = function == .round ? "ROUND(" : function == .roundUp ? "ROUNDUP(" : "ROUNDDOWN("
                return wrap(name, arguments.count == 1 ? arguments + [.number(0, span: node.span)] : arguments)
            case .ceiling, .floor:
                // Toward +infinity: truncate a negative, round a positive away from zero; and the
                // mirror image for FLOOR (DecimalMath.ceiling / floor).
                let digits = arguments.count == 2 ? arguments[1] : .number(0, span: node.span)
                let negative = function == .ceiling ? "ROUNDDOWN(" : "ROUNDUP("
                let positive = function == .ceiling ? "ROUNDUP(" : "ROUNDDOWN("
                out.append(.literal("IF("))
                guard emit(arguments[0], columns: columns, into: &out) else { return false }
                out.append(.literal("<0,"))
                guard wrap(negative, [arguments[0], digits]) else { return false }
                out.append(.literal(","))
                guard wrap(positive, [arguments[0], digits]) else { return false }
                out.append(.literal(")"))
                return true
            case .sum, .avg, .count, .convert, .coalesce:
                return false
            }
        case .convert:
            return false
        }
    }

    private static func appendClose(_ out: inout [Piece]) -> Bool {
        out.append(.literal(")"))
        return true
    }
}
