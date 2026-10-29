import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

enum FormulaTestFailure: Error { case expectedAnError }

/// A deterministic column id. No `UUID()` anywhere in the tests, so a failure is always
/// reproducible from the source alone.
func makeColumnID(_ index: UInt8) -> ColumnID {
    ColumnID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, index)))
}

/// Locale-free decimal literal for tests.
func dec(_ text: String) throws -> Decimal {
    try #require(Decimal(string: text, locale: nil), "\(text) is not a decimal")
}

/// Runs `body` and returns the ``FormulaEngineError`` it threw.
@discardableResult
func captureFormulaError<T>(_ body: () throws -> T) throws -> FormulaEngineError {
    do {
        _ = try body()
    } catch let error as FormulaEngineError {
        return error
    }
    Issue.record("Expected a FormulaEngineError but none was thrown")
    throw FormulaTestFailure.expectedAnError
}

extension FormulaValue {
    /// The numeric value, for assertions.
    func decimal() throws -> Decimal {
        try #require(quantity, "expected a number, got \(self)").value
    }

    func dimension() throws -> QuantityDimension {
        try #require(quantity, "expected a number, got \(self)").dimension
    }
}

/// A row carrying one plausible takeoff measurement.
func sampleRow(
    area: String = "12.5",
    perimeter: String = "15",
    length: String = "4",
    depth: String = "0.2"
) throws -> FormulaRow {
    FormulaRow(fields: [
        .netArea: .area(try dec(area)),
        .perimeter: .length(try dec(perimeter)),
        .planLength: .length(try dec(length)),
        .depth: .length(try dec(depth)),
        .count: .count(1)
    ])
}

/// Evaluates a formula with no columns against one row.
func evaluate(
    _ source: String,
    row: FormulaRow = FormulaRow(),
    catalog: FormulaColumnCatalog = .empty
) throws -> FormulaValue {
    try FormulaEngine.compile(source, catalog: catalog).evaluate(row: row)
}

/// Evaluates a formula that needs no row at all.
func number(_ source: String) throws -> Decimal {
    try evaluate(source).decimal()
}

extension CompiledFormulaLedger {
    /// Fills a row through the ledger's one evaluation loop, ``evaluateCells(of:source:record:)``
    /// — the loop the ledger store runs — and throws the first cell failure, for tests that
    /// expect every cell to succeed.
    func filledRow(_ row: FormulaRow) throws -> FormulaRow {
        var firstFailure: FormulaEngineError?
        let filled = try evaluateCells(of: row, record: { _, outcome in
            if case .failure(let error) = outcome, firstFailure == nil { firstFailure = error }
        })
        if let firstFailure { throw firstFailure }
        return filled
    }
}
