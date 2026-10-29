import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// The in-memory, index-addressable row model of the Quantity Ledger.
///
/// # Why indices and not an array of view models
///
/// A 100 000-row takeoff has, at 20 visible columns, two million cells. Materialising them as
/// view-model structs costs hundreds of megabytes and has to be rebuilt on every regroup, filter
/// or sort — and a table only ever shows about forty rows at a time. So the store keeps the
/// source records once, keeps the compiled formula results once, and produces a cell only when
/// someone asks for it by index: ``rowCount``, ``row(at:)``, ``index(of:)`` and
/// ``value(at:column:)``, plus ``prefetch(_:)`` as the band hint a scrolling table gives ahead
/// of itself.
///
/// > Note: the UI binds to this shape. `LedgerPresenting` used to publish a materialised
/// > `flatRows` array, which contradicted this API and could not hold 100 000 rows; it was
/// > replaced by `rowCount` / `row(at:)` / `index(of:)` / `prefetchRows(in:)` per
/// > ADR-0003 §3.4. `ZPDFAppCore` carries the chain across, unbroken from
/// > ``value(at:column:)`` to the table's data source — see that package's README.
///
/// # One evaluation path
///
/// ``value(at:column:)`` is the *only* way a value leaves the store. The cell a table draws, the
/// number a subtotal accumulates and the field an exporter writes all come from this one call,
/// which is what makes "the same formula gives the same number on screen and in the CSV" a
/// structural property rather than a promise (QUALITY_BAR A25).
public struct LedgerStore: Sendable {

    let storage: Storage

    /// Builds a store over a set of markups.
    ///
    /// Formula columns are evaluated here, once per row, using the ``LedgerColumnSet``'s
    /// already-compiled programs. Evaluation failures become ``LedgerCellResult/error(_:)`` cells
    /// rather than aborting the load: one bad formula on one row must not make the ledger
    /// unopenable.
    ///
    /// - Parameters:
    ///   - markups: the rows, in the order they should be presented before any sort is applied.
    ///   - columns: the validated column set.
    ///   - names: page, zone, layer and scale-region names.
    ///   - measurements: optional overrides for `MarkupRecord.measurement`, used when the
    ///     measurement engine has recomputed values that have not been written back yet.
    ///   - quantityMultiplierColumn: the column whose per-row number repeats the row's measured
    ///     quantities — a markup drawn once but standing for six identical instances counts six
    ///     times in every extensive quantity, on this one evaluation path so cell, subtotal and
    ///     export cannot disagree. `nil` (the default) multiplies nothing.
    public init(
        markups: [MarkupRecord],
        columns: LedgerColumnSet,
        names: LedgerNameCatalog = .empty,
        measurements: [MarkupID: MeasurementResult] = [:],
        quantityMultiplierColumn: ColumnID? = nil
    ) throws {
        let base = Self.baseStorage(
            markups: markups,
            columns: columns,
            names: names,
            measurements: measurements,
            quantityMultiplierColumn: quantityMultiplierColumn
        )
        self.storage = base.replacingFormulaCells(try Self.evaluateFormulas(base))
    }

    /// Builds the same store as ``init(markups:columns:names:measurements:quantityMultiplierColumn:)``
    /// with the formula pass cut into chunks evaluated concurrently, reporting progress and
    /// honouring cancellation (IM-081).
    ///
    /// The result is identical to the synchronous initialiser's — every chunk runs the same
    /// per-row ``FormulaPass`` over the same immutable storage, and the chunks are assembled
    /// by row position, never by completion order — which the determinism test asserts. A
    /// cancelled build throws `CancellationError` and returns no store at all, never a
    /// partially evaluated one.
    ///
    /// - Parameters:
    ///   - chunkSize: rows per concurrent task.
    ///   - progress: called after each finished chunk, on the building task.
    public static func build(
        markups: [MarkupRecord],
        columns: LedgerColumnSet,
        names: LedgerNameCatalog = .empty,
        measurements: [MarkupID: MeasurementResult] = [:],
        quantityMultiplierColumn: ColumnID? = nil,
        chunkSize: Int = 4_096,
        progress: (@Sendable (FormulaEvaluationProgress) -> Void)? = nil
    ) async throws -> LedgerStore {
        let base = baseStorage(
            markups: markups,
            columns: columns,
            names: names,
            measurements: measurements,
            quantityMultiplierColumn: quantityMultiplierColumn
        )
        let cells = try await evaluateFormulasConcurrently(base, chunkSize: chunkSize, progress: progress)
        return LedgerStore(storage: base.replacingFormulaCells(cells))
    }

    /// The store's backing before any formula is evaluated.
    private static func baseStorage(
        markups: [MarkupRecord],
        columns: LedgerColumnSet,
        names: LedgerNameCatalog,
        measurements: [MarkupID: MeasurementResult],
        quantityMultiplierColumn: ColumnID?
    ) -> Storage {
        var indexByMarkup: [MarkupID: Int] = [:]
        indexByMarkup.reserveCapacity(markups.count)
        var resolved: [MeasurementResult] = []
        resolved.reserveCapacity(markups.count)
        for (index, markup) in markups.enumerated() {
            indexByMarkup[markup.id] = index
            resolved.append(measurements[markup.id] ?? markup.measurement ?? .empty)
        }
        return Storage(
            records: markups,
            measurements: resolved,
            measurementOverrides: measurements,
            indexByMarkup: indexByMarkup,
            columns: columns,
            names: names,
            formulaCells: [:],
            rowEdits: [:],
            quantityMultiplierColumn: quantityMultiplierColumn
        )
    }

    init(storage: Storage) {
        self.storage = storage
    }

    // MARK: - Index-addressed access

    public var rowCount: Int { storage.records.count }

    public var columns: LedgerColumnSet { storage.columns }

    public var names: LedgerNameCatalog { storage.names }

    /// A lightweight handle on one row. Holds an index and a reference to the shared storage —
    /// no cells are copied, so making one is O(1) and costs nothing to throw away.
    public func row(at index: Int) -> LedgerRowView {
        precondition(
            storage.records.indices.contains(index),
            "LedgerStore.row(at:) index \(index) out of range 0..<\(rowCount)"
        )
        return LedgerRowView(index: index, storage: storage)
    }

    /// The index of a markup, or `nil` when it is not in this store. O(1).
    public func index(of markupID: MarkupID) -> Int? { storage.indexByMarkup[markupID] }

    public func markupID(at index: Int) -> MarkupID { storage.records[index].id }

    public func record(at index: Int) -> MarkupRecord { storage.record(at: index) }

    public func measurement(at index: Int) -> MeasurementResult { storage.measurement(at: index) }

    /// The rows of the cutouts belonging to the parents at `indices`, as this store and `other`
    /// record them — the rows whose cells depend on another row (ADR-0018: a cutout row's
    /// `Cutout Area` reads its parent's policy). Indices refer to this store; `other` must
    /// have the same rows in the same order (an in-place edit).
    func cutoutRowIndices(ofParentsAt indices: [Int], alsoIn other: LedgerStore) -> Set<Int> {
        var result = Set<Int>()
        for index in indices where storage.records.indices.contains(index) {
            var children = storage.record(at: index).cutoutMarkupIDs
            if other.storage.records.indices.contains(index) {
                children += other.storage.record(at: index).cutoutMarkupIDs
            }
            for child in children {
                if let row = storage.indexByMarkup[child] { result.insert(row) }
            }
        }
        return result
    }

    /// The single value path. Every cell, subtotal and exported field reads through here.
    public func value(at index: Int, column columnID: ColumnID) -> LedgerCellResult {
        storage.value(at: index, column: columnID)
    }

    /// The same path with the column already resolved.
    ///
    /// Identical semantics to ``value(at:column:)`` — it is the same function body, reached
    /// without the `ColumnID` dictionary lookup. Scans that touch one column across many rows
    /// (aggregating, sorting, filtering, grouping) resolve the definition once and call this;
    /// there is still exactly one place a value is produced.
    public func value(at index: Int, definition: LedgerColumnDefinition) -> LedgerCellResult {
        storage.value(at: index, definition: definition)
    }

    // MARK: - Row edits

    /// One row edited in place: same position, same markup identity, new content.
    public struct LedgerRowEdit: Sendable {
        public let index: Int
        public let record: MarkupRecord
        /// An engine-recomputed result that has not been written back to the record yet;
        /// `nil` reads the measurement off `record`, mirroring the store initialiser.
        public let measurement: MeasurementResult?

        public init(index: Int, record: MarkupRecord, measurement: MeasurementResult? = nil) {
            self.index = index
            self.record = record
            self.measurement = measurement
        }
    }

    /// A store with the given rows replaced, in O(edited rows), never O(rowCount).
    ///
    /// The base arrays are shared with the receiver; edits live in a sparse overlay the
    /// value path consults first. Formula columns are re-evaluated for the edited rows only,
    /// against the edited inputs. This is the store half of the GAP 3 fix: a one-row
    /// mutation must not pay for 100 000 rows anywhere on its path, and copying a
    /// 100 000-element record array — or re-running every formula — is exactly such a
    /// payment.
    ///
    /// A row edit never changes a markup's identity or the row count; inserts and deletes
    /// still build a new store, because they move every index after them.
    public func updatingRows(_ edits: [LedgerRowEdit]) throws -> LedgerStore {
        guard !edits.isEmpty else { return self }
        var rowEdits = storage.rowEdits
        let overrides = storage.measurementOverrides
        for edit in edits {
            precondition(
                storage.records.indices.contains(edit.index),
                "LedgerStore.updatingRows edit index \(edit.index) out of range 0..<\(rowCount)"
            )
            precondition(
                edit.record.id == storage.records[edit.index].id,
                "a row edit may not change markup identity; replace the store instead"
            )
            // CR-68: mirror the initialiser exactly — an override beats the record's own
            // measurement. An edit that omits its measurement keeps the override the store was
            // built with, or the one a previous edit of this row supplied; it used to fall
            // back to `record.measurement`, silently dropping the engine's recomputed values
            // for that row. An edit that carries a measurement is, by its own definition, the
            // recomputed result not yet written back — so it becomes the row's override.
            //
            // IM-080: the override a row carries since the last compaction lives on its overlay
            // entry (`isOverride`), not in a store-wide dictionary that every edit would copy.
            // A row with an overlay entry has an override exactly when that entry says so: a
            // store-built override is kept by the row's first edit, which marks it.
            let inherited: MeasurementResult?
            if let existing = rowEdits[edit.index] {
                inherited = existing.isOverride ? existing.measurement : nil
            } else {
                inherited = overrides[edit.record.id]
            }
            let override = edit.measurement ?? inherited
            rowEdits[edit.index] = Storage.RowEdit(
                record: edit.record,
                measurement: override ?? edit.record.measurement ?? .empty,
                formulaCells: [:],
                isOverride: override != nil
            )
        }
        // An interim storage so the formulas read the edited inputs, not the old ones.
        let interim = Storage(
            records: storage.records,
            measurements: storage.measurements,
            measurementOverrides: overrides,
            indexByMarkup: storage.indexByMarkup,
            columns: storage.columns,
            names: storage.names,
            formulaCells: storage.formulaCells,
            rowEdits: rowEdits,
            quantityMultiplierColumn: storage.quantityMultiplierColumn
        )
        if let pass = FormulaPass(columns: storage.columns) {
            for edit in edits {
                guard var updated = rowEdits[edit.index] else { continue }
                updated.formulaCells = try pass.cells(at: edit.index, in: interim)
                rowEdits[edit.index] = updated
            }
        }
        let edited = LedgerStore(storage: Storage(
            records: storage.records,
            measurements: storage.measurements,
            measurementOverrides: overrides,
            indexByMarkup: storage.indexByMarkup,
            columns: storage.columns,
            names: storage.names,
            formulaCells: storage.formulaCells,
            rowEdits: rowEdits,
            quantityMultiplierColumn: storage.quantityMultiplierColumn
        ))
        return rowEdits.count > Self.compactionThreshold(rowCount: rowCount) ? edited.compacted() : edited
    }

    // MARK: - Overlay compaction (IM-080)

    /// Edited rows the overlay may hold before it is folded into the base arrays.
    ///
    /// Every ``updatingRows(_:)`` copies the overlay, and every cell read probes it, so an
    /// overlay that only grows makes the thousandth edit of a session cost more than the
    /// first. Folding it back costs one pass over the base arrays; at 1 % of the rows (never
    /// fewer than 256) that pass is amortised to a constant per edit.
    static func compactionThreshold(rowCount: Int) -> Int {
        max(256, rowCount / 100)
    }

    /// The same store with the edit overlay folded into fresh base arrays and an empty overlay.
    ///
    /// Every cell reads the same afterwards — the overlay's record, measurement and formula
    /// cells simply become the base ones — which the differential test asserts cell by cell.
    /// The overlay's overrides join the store's override table: they decide what a *later*
    /// edit that omits its measurement reads (CR-68), which compaction must not change.
    func compacted() -> LedgerStore {
        guard !storage.rowEdits.isEmpty else { return self }
        var records = storage.records
        var measurements = storage.measurements
        var overrides = storage.measurementOverrides
        for (index, edit) in storage.rowEdits {
            records[index] = edit.record
            measurements[index] = edit.measurement
            if edit.isOverride { overrides[edit.record.id] = edit.measurement }
        }
        // Column by column, each array copied once and then written in place.
        var formulaCells: [ColumnID: [LedgerCellResult]] = [:]
        formulaCells.reserveCapacity(storage.formulaCells.count)
        for (id, base) in storage.formulaCells {
            var column = base
            for (index, edit) in storage.rowEdits {
                column[index] = edit.formulaCells[id] ?? .empty
            }
            formulaCells[id] = column
        }
        return LedgerStore(storage: Storage(
            records: records,
            measurements: measurements,
            measurementOverrides: overrides,
            indexByMarkup: storage.indexByMarkup,
            columns: storage.columns,
            names: storage.names,
            formulaCells: formulaCells,
            rowEdits: [:],
            quantityMultiplierColumn: storage.quantityMultiplierColumn
        ))
    }

    // MARK: - Formula evaluation

    /// The formula columns' shared evaluation machinery, prepared once per column set:
    /// compiled programs, the input columns some formula actually reads, and the special
    /// `UnitCost` channel. One row's evaluation is one call, so the bulk pass at store build
    /// and the per-row pass after an edit are the same code reading the same inputs.
    struct FormulaPass: Sendable {
        let compiled: CompiledFormulaLedger
        let inputColumns: [LedgerColumnDefinition]
        let unitCostID: ColumnID?
        /// The formula columns this pass evaluates; `nil` means all of them. Every other
        /// formula column is read back from the storage's existing cells (IM-081).
        let affected: Set<ColumnID>?
        /// Definitions of the formula columns read back rather than evaluated.
        let seededColumns: [ColumnID: LedgerColumnDefinition]

        init?(columns: LedgerColumnSet, affected: Set<ColumnID>? = nil) {
            let formulaIDs = columns.formulaColumnIDs
            guard !formulaIDs.isEmpty else { return nil }
            self.compiled = columns.compiledFormulas
            self.affected = affected
            var seeded: [ColumnID: LedgerColumnDefinition] = [:]
            if let affected {
                for id in formulaIDs where !affected.contains(id) {
                    seeded[id] = columns.column(id: id)
                }
            }
            self.seededColumns = seeded
            let unitCostID = columns.columnID(standard: .unitCost)
            self.unitCostID = unitCostID
            // Only the columns some formula actually reads. A ledger with forty columns and
            // one formula must not read forty cells per row to evaluate it.
            var referenced = Set<ColumnID>()
            for id in formulaIDs where affected?.contains(id) ?? true {
                if let program = compiled.programs[id] { referenced.formUnion(program.referencedColumns) }
            }
            if let unitCostID { referenced.insert(unitCostID) }
            self.inputColumns = columns.columns.filter {
                $0.kind != .formula && referenced.contains($0.id)
            }
        }

        /// Evaluates every formula column for one row.
        func cells(at index: Int, in storage: Storage) throws -> [ColumnID: LedgerCellResult] {
            // The formulas read measurement fields directly, not through the cell path, so the
            // repeat count is applied here too — a `netArea × depth` formula must see the same
            // area the Area cell shows, or the formula column and the cell diverge (A25).
            // A cutout row's formula cells are empty (ADR-0018): a cutout is part of its parent,
            // so `Perimeter * 2` on it is neither the cutout's own perimeter summed into the
            // column total nor a "blank in arithmetic" error that would poison that total.
            // Every caller reads a missing cell as `.empty`.
            if Storage.isCutoutRow(storage.record(at: index)) { return [:] }
            var fields: [MeasurementField: DecimalQuantity] = storage.measurement(at: index).values
            let repeatCount = QuantityRepetition.repeatCount(
                record: storage.record(at: index),
                multiplierColumn: storage.quantityMultiplierColumn
            )
            if repeatCount > QuantityRepetition.minimumCount {
                for (field, quantity) in fields {
                    fields[field] = QuantityRepetition.multiplied(
                        quantity, field: field, count: repeatCount
                    )
                }
            }
            var inputs: [ColumnID: FormulaValue] = [:]
            inputs.reserveCapacity(inputColumns.count)
            // V-058: the cells on this row that were refused (division by zero, a unit
            // conflict, an overflow…), by column. A refused cell reads as blank for a formula
            // that uses it, and a blank is only "nothing to compute from" when it is really
            // blank — so a formula whose blank came from a refused input inherits that refusal
            // and its total still refuses, instead of silently leaving the row out.
            var refused: [ColumnID: LedgerCellError] = [:]
            for column in inputColumns {
                switch storage.value(at: index, definition: column) {
                case .value(let value):
                    // Typed as the catalog types the column: a currency column declared as a
                    // rate (SEK/m²) reads as that rate, not as plain money (S-088).
                    inputs[column.id] = FormulaValue(value, in: column)
                case .error(let error):
                    if !error.isMissingInput { refused[column.id] = error }
                }
            }
            // `UnitCost` is a currency column, so the engine reads it from the row rather than
            // from the generic cell map. `Slope` reads `slopeRatio`, which the measurement result
            // already keys that way: an absent field stays blank rather than becoming 0.
            //
            // ADR-0020: a Unit Cost is a **rate** — money per unit of the quantity the row prices
            // — so the formula sees it as SEK/m² on an area row, SEK/m on a length row and SEK
            // per piece on a count. `Area * UnitCost` is then money, and `Length * UnitCost` on an
            // area row is refused as a dimension mismatch instead of printing SEK·m.
            let unitCost = unitCostID.flatMap { inputs[$0]?.quantity }.map { rate -> DecimalQuantity in
                guard let code = rate.dimension.currencyCode, rate.dimension.lengthPower == 0,
                      let priced = Storage.pricedColumn(for: storage.record(at: index).tool)?.measurementField
                else { return rate }
                let power = priced.dimension.lengthPower
                guard power != 0 else { return rate }
                return DecimalQuantity(value: rate.value, dimension: .currencyRate(code, perLengthPower: power))
            }

            var output: [ColumnID: LedgerCellResult] = [:]
            // The engine's one dependency-order loop (R-139). A failed cell reads as blank for
            // every formula after it.
            try compiled.evaluateCells(
                of: FormulaRow(fields: fields, columns: inputs, unitCost: unitCost),
                source: { id in
                    guard let affected, !affected.contains(id) else { return .evaluate }
                    // Not re-evaluated: its stored cell is what a dependent reads. The round
                    // trip is exact — `FormulaValue(cell)` inverts `ledgerCellValue` — and an
                    // errored cell reads as blank, as it did when it was evaluated.
                    if let definition = seededColumns[id] {
                        switch storage.value(at: index, definition: definition) {
                        case .value(let stored):
                            return .reuse(FormulaValue(stored))
                        case .error(let error):
                            if !error.isMissingInput { refused[id] = error }
                        }
                    }
                    return .reuse(.blank)
                },
                record: { id, outcome in
                    switch outcome {
                    case .success(let value):
                        // W-061: a formula that tolerates blanks (`COALESCE([Quotient], 0) + 1`)
                        // succeeds on a refused input, because the refusal reaches it as a blank.
                        // A refusal never becomes a number (QUALITY_BAR), so the formula inherits
                        // it here as it does on the failure path. Old output: Safe = 1 on the
                        // Divisor-0 row, and Sum(Safe) quietly included it.
                        if let upstream = inheritedRefusal(of: id, refused: refused) {
                            refused[id] = upstream
                            output[id] = .error(upstream)
                            return
                        }
                        output[id] = .value(
                            value.ledgerCellValue(grammarVersion: FormulaEngine.grammarVersion)
                        )
                    case .failure(let error):
                        var cell = LedgerCellError(formulaFailure: error)
                        if cell.isMissingInput, let upstream = inheritedRefusal(of: id, refused: refused) {
                            cell = upstream
                        }
                        if !cell.isMissingInput { refused[id] = cell }
                        output[id] = .error(cell)
                    }
                }
            )
            return output
        }

        /// The refusal a formula's blank really is (V-058): one of the columns it reads was
        /// refused on this row. Chosen by kind and then detail, so the answer does not depend
        /// on dictionary order; `nil` when every input it reads is either a value or blank.
        private func inheritedRefusal(of id: ColumnID, refused: [ColumnID: LedgerCellError]) -> LedgerCellError? {
            guard !refused.isEmpty, let referenced = compiled.programs[id]?.referencedColumns else { return nil }
            return refused
                .filter { referenced.contains($0.key) }
                .values
                .min { ($0.kind.rawValue, $0.detail) < ($1.kind.rawValue, $1.detail) }
        }
    }

    /// The formula pass over row chunks, concurrently, assembled by position (IM-081).
    private static func evaluateFormulasConcurrently(
        _ storage: Storage,
        chunkSize: Int,
        progress: (@Sendable (FormulaEvaluationProgress) -> Void)?
    ) async throws -> [ColumnID: [LedgerCellResult]] {
        let rowCount = storage.records.count
        guard let pass = FormulaPass(columns: storage.columns) else {
            progress?(FormulaEvaluationProgress(completed: rowCount, total: rowCount))
            return [:]
        }
        let ids = storage.columns.formulaColumnIDs
        var output: [ColumnID: [LedgerCellResult]] = [:]
        for id in ids {
            output[id] = [LedgerCellResult](repeating: .empty, count: rowCount)
        }
        let size = max(1, chunkSize)
        try await withThrowingTaskGroup(of: (start: Int, cells: [ColumnID: [LedgerCellResult]]).self) { group in
            for start in stride(from: 0, to: rowCount, by: size) {
                let end = min(rowCount, start + size)
                group.addTask {
                    try Task.checkCancellation()
                    var chunk: [ColumnID: [LedgerCellResult]] = [:]
                    for id in ids { chunk[id] = [] }
                    for index in start..<end {
                        let cells = try pass.cells(at: index, in: storage)
                        for id in ids { chunk[id]?.append(cells[id] ?? .empty) }
                    }
                    return (start, chunk)
                }
            }
            var completed = 0
            for try await chunk in group {
                for (id, cells) in chunk.cells {
                    output[id]?.replaceSubrange(chunk.start..<(chunk.start + cells.count), with: cells)
                }
                completed += chunk.cells.values.first?.count ?? 0
                progress?(FormulaEvaluationProgress(completed: completed, total: rowCount))
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
            }
        }
        try Task.checkCancellation()
        return output
    }

    /// A store over the same rows with a new column set, re-evaluating only the formula
    /// columns the change can affect (IM-081).
    ///
    /// A formula column is affected when its own definition changed, when it is new, or when
    /// it reads — directly or through other formulas — an affected column. Every other
    /// formula column keeps its cells. When any non-formula column changed (a formula may
    /// read it) or the column sets disagree on anything else, every formula is re-evaluated:
    /// the shortcut is taken only where it is provably the same answer, and the differential
    /// test compares it with a store built from scratch, cell by cell.
    public func replacingColumns(_ columns: LedgerColumnSet) throws -> LedgerStore {
        let base = compacted().storage
        let rebased = Storage(
            records: base.records,
            measurements: base.measurements,
            measurementOverrides: base.measurementOverrides,
            indexByMarkup: base.indexByMarkup,
            columns: columns,
            names: base.names,
            formulaCells: base.formulaCells,
            rowEdits: [:],
            quantityMultiplierColumn: base.quantityMultiplierColumn
        )
        guard let affected = Self.affectedFormulaColumns(from: base.columns, to: columns) else {
            return LedgerStore(storage: rebased.replacingFormulaCells(try Self.evaluateFormulas(rebased)))
        }
        var cells: [ColumnID: [LedgerCellResult]] = [:]
        for id in columns.formulaColumnIDs where !affected.contains(id) {
            cells[id] = base.formulaCells[id]
        }
        if !affected.isEmpty, let pass = FormulaPass(columns: columns, affected: affected) {
            let rowCount = base.records.count
            for id in affected {
                cells[id] = [LedgerCellResult](repeating: .empty, count: rowCount)
            }
            for index in 0..<rowCount {
                for (id, cell) in try pass.cells(at: index, in: rebased) where affected.contains(id) {
                    cells[id]?[index] = cell
                }
            }
        }
        return LedgerStore(storage: rebased.replacingFormulaCells(cells))
    }

    /// The formula columns of `new` that must be re-evaluated when a store moves from `old`
    /// to `new`, or `nil` when every one must be.
    static func affectedFormulaColumns(
        from old: LedgerColumnSet,
        to new: LedgerColumnSet
    ) -> Set<ColumnID>? {
        func inputs(_ set: LedgerColumnSet) -> [ColumnID: LedgerColumnDefinition] {
            Dictionary(
                set.columns.filter { $0.kind != .formula }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        guard inputs(old) == inputs(new) else { return nil }
        var affected = Set<ColumnID>()
        for id in new.formulaColumnIDs {
            let changed = old.column(id: id) != new.column(id: id)
                || old.compiledFormulas.programs[id]?.canonicalText
                    != new.compiledFormulas.programs[id]?.canonicalText
            let readsAffected = !(new.compiledFormulas.dependencies[id] ?? [])
                .isDisjoint(with: affected)
                || !(new.compiledFormulas.programs[id]?.referencedColumns ?? [])
                    .isDisjoint(with: affected)
            if changed || readsAffected { affected.insert(id) }
        }
        return affected
    }

    private static func evaluateFormulas(_ storage: Storage) throws -> [ColumnID: [LedgerCellResult]] {
        guard let pass = FormulaPass(columns: storage.columns) else { return [:] }
        let rowCount = storage.records.count
        var output: [ColumnID: [LedgerCellResult]] = [:]
        for id in storage.columns.formulaColumnIDs {
            output[id] = [LedgerCellResult](repeating: .empty, count: rowCount)
        }
        for index in 0..<rowCount {
            for (id, cell) in try pass.cells(at: index, in: storage) {
                output[id]?[index] = cell
            }
        }
        return output
    }
}

extension LedgerStore {

    /// The column whose quantity a Unit Cost prices for a tool (ADR-0020) — the one table Total
    /// Cost reads, for callers outside the store (T-027: the app tier kept a copy of it).
    public static func pricedColumn(for tool: MeasurementTool?) -> StandardLedgerColumn? {
        Storage.pricedColumn(for: tool)
    }

    /// Immutable shared backing. A `final class` with only `let` properties of `Sendable` types,
    /// so a `LedgerStore` value can cross an actor boundary without copying 100 000 records.
    final class Storage: Sendable {
        /// One edited row's replacement content, including its re-evaluated formula cells.
        struct RowEdit: Sendable {
            var record: MarkupRecord
            var measurement: MeasurementResult
            var formulaCells: [ColumnID: LedgerCellResult]
            /// `measurement` is an override — an edit's recomputed result, or the store's own
            /// override kept by an edit that omitted one — rather than the record's value.
            var isOverride: Bool = false
        }

        let records: [MarkupRecord]
        let measurements: [MeasurementResult]
        /// The `measurements:` the store was built with, plus every override a compacted row
        /// edit carried, by markup; the overrides of rows still in the overlay are on their
        /// ``RowEdit/isOverride`` entries (IM-080). `measurements` above is the *resolved* array — override
        /// or record value — and cannot say which of the two it holds; this can, and it is what
        /// lets a later edit that omits its measurement keep the override (CR-68).
        let measurementOverrides: [MarkupID: MeasurementResult]
        let indexByMarkup: [MarkupID: Int]
        let columns: LedgerColumnSet
        let names: LedgerNameCatalog
        let formulaCells: [ColumnID: [LedgerCellResult]]
        /// Sparse overlay of edited rows, consulted before the base arrays. Kept sparse so
        /// `updatingRows(_:)` is O(edited rows): replacing an element of a 100 000-record
        /// array would copy — and retain — the whole buffer.
        let rowEdits: [Int: RowEdit]
        /// The column whose per-row number repeats the row's extensive quantities;
        /// `nil` multiplies nothing. See ``QuantityRepetition``.
        let quantityMultiplierColumn: ColumnID?

        init(
            records: [MarkupRecord],
            measurements: [MeasurementResult],
            measurementOverrides: [MarkupID: MeasurementResult] = [:],
            indexByMarkup: [MarkupID: Int],
            columns: LedgerColumnSet,
            names: LedgerNameCatalog,
            formulaCells: [ColumnID: [LedgerCellResult]],
            rowEdits: [Int: RowEdit],
            quantityMultiplierColumn: ColumnID? = nil
        ) {
            self.records = records
            self.measurements = measurements
            self.measurementOverrides = measurementOverrides
            self.indexByMarkup = indexByMarkup
            self.columns = columns
            self.names = names
            self.formulaCells = formulaCells
            self.rowEdits = rowEdits
            self.quantityMultiplierColumn = quantityMultiplierColumn
        }

        /// The same backing with `formulaCells` replaced.
        func replacingFormulaCells(_ cells: [ColumnID: [LedgerCellResult]]) -> Storage {
            Storage(
                records: records,
                measurements: measurements,
                measurementOverrides: measurementOverrides,
                indexByMarkup: indexByMarkup,
                columns: columns,
                names: names,
                formulaCells: cells,
                rowEdits: rowEdits,
                quantityMultiplierColumn: quantityMultiplierColumn
            )
        }

        func record(at index: Int) -> MarkupRecord {
            if !rowEdits.isEmpty, let edit = rowEdits[index] { return edit.record }
            return records[index]
        }

        func measurement(at index: Int) -> MeasurementResult {
            if !rowEdits.isEmpty, let edit = rowEdits[index] { return edit.measurement }
            return measurements[index]
        }

        func value(at index: Int, column columnID: ColumnID) -> LedgerCellResult {
            guard let column = columns.column(id: columnID) else {
                return .error(
                    LedgerCellError(kind: .aggregation, detail: "unknown column \(columnID)")
                )
            }
            return value(at: index, definition: column)
        }

        func value(at index: Int, definition: LedgerColumnDefinition) -> LedgerCellResult {
            guard records.indices.contains(index) else {
                return .error(
                    LedgerCellError(kind: .aggregation, detail: "row index \(index) out of range")
                )
            }
            if definition.kind == .formula {
                if !rowEdits.isEmpty, let edit = rowEdits[index] {
                    return edit.formulaCells[definition.id] ?? .empty
                }
                return formulaCells[definition.id]?[index] ?? .empty
            }
            let record = record(at: index)
            if definition.standard == .totalCost {
                return totalCost(at: index, record: record)
            }
            if let standard = definition.standard,
               let derived = derivedValue(standard, index: index, record: record) {
                return .value(derived)
            }
            guard let stored = record.customValues[definition.id] else { return .empty }
            return .value(Self.retagged(stored, forColumnDeclaring: definition.dimension))
        }

        /// A stored dimensionless number re-tagged to the dimension its column declares
        /// (ADR-0014 §3).
        ///
        /// Before ADR-0014 a stored ratio and a stored count were the same bytes, so every
        /// pre-tag dimensionless value decodes as a **count**. The column is the consumer that
        /// knows what such a value means: a waste factor in a column declared `.ratio` is a
        /// ratio however it was stored, and a fresh `.ratio` value added to it must sum rather
        /// than be refused as `count + ratio`. The re-tag is by column identity, never by value,
        /// and touches only the count ↔ ratio tag: a length, an angle or a currency that
        /// disagrees with the column is left as it is so the mismatch stays visible.
        static func retagged(
            _ value: LedgerCellValue,
            forColumnDeclaring dimension: QuantityDimension?
        ) -> LedgerCellValue {
            guard let dimension, dimension.isDimensionless,
                  case .number(let quantity) = value,
                  quantity.dimension.isDimensionless,
                  quantity.dimension != dimension else { return value }
            return .number(DecimalQuantity(value: quantity.value, dimension: dimension))
        }

        /// Values the ledger reads off the markup itself rather than out of a stored cell.
        /// Returns `nil` for the built-ins that are plain user data (`Cost Code`, `Trade`,
        /// `Phase`, `Material`, `Unit Cost`, ...), which fall through to `customValues`.
        private func derivedValue(
            _ standard: StandardLedgerColumn,
            index: Int,
            record: MarkupRecord
        ) -> LedgerCellValue? {
            if let field = standard.measurementField {
                // ADR-0018: a cutout is part of its parent, never a quantity of its own. Its
                // row's quantity cells are empty under every policy, so it cannot reach a
                // subtotal; only `Cutout Area` reports its area, and only when the parent
                // reports cutouts separately. The parent is looked up for that one column only.
                if Self.isCutoutRow(record),
                   !standard.showsValueOnCutoutRow(
                       parentPolicy: standard == .cutoutArea ? cutoutParentPolicy(of: record) : nil
                   ) {
                    return .empty
                }
                guard let stored = measurement(at: index)[field] else { return .empty }
                // A stored `slopeRatio` / `slopePercent` decoded from a pre-tag archive is a
                // count in the bytes and a ratio by its field (ADR-0014 §2.4, §3): the field
                // is the authority for the count ↔ ratio tag on this path too.
                let quantity: DecimalQuantity
                if field.dimension.isDimensionless, stored.dimension.isDimensionless,
                   stored.dimension != field.dimension {
                    quantity = DecimalQuantity(value: stored.value, dimension: field.dimension)
                } else {
                    quantity = stored
                }
                let count = QuantityRepetition.repeatCount(
                    record: record,
                    multiplierColumn: quantityMultiplierColumn
                )
                return .number(QuantityRepetition.multiplied(quantity, field: field, count: count))
            }
            switch standard {
            // T-046: the Type cell is the measurement *tool* ("length", "area", "count"), not
            // the markup kind: every measuring path writes kind `.measurement`, so grouping by
            // Type (the default view) put Length, Area and Count rows in one "measurement"
            // group whose Value total read Mixed units, a sort on Type tied every measurement
            // and "Type contains area" matched nothing. A markup with no tool keeps its kind.
            // The same spelling the archive and the search index use for a markup's type.
            case .icon: return .text(record.tool?.rawValue ?? record.kind.rawValue)
            // S-077: a blank Subject, Label, Comment or Author is no value, as BH-196 below
            // made an unassigned zone: as `.text("")` it failed "is empty", passed "is not
            // empty" and sorted first, while grouping put it under "(none)".
            case .subject: return Self.name(record.subject)
            case .label: return Self.name(record.label)
            case .comment: return Self.name(record.comment)
            case .author: return Self.name(record.author)
            case .status: return .choice(LedgerIdentifiers.choiceOptionID(for: record.status))
            case .created: return .date(record.createdAt)
            case .modified: return .date(record.modifiedAt)
            case .color: return .text(Self.hexText(record.style.color))
            // BH-196: an unassigned zone, layer, scale region or scale — or a page the
            // catalog does not know — is *no value*, not the value "". As `.text("")` it
            // passed "is not empty", failed "is empty" and sorted first ascending, while the
            // grouping mapped the same cell to "(none)": a group whose rows the filter denied.
            case .pageLabel:
                return Self.name(names.pages[record.pageID]?.label)
            case .pageIndex:
                guard let info = names.pages[record.pageID] else { return .empty }
                return .number(.count(info.index))
            case .projectZone:
                return Self.name(record.zoneID.flatMap { names.zones[$0] })
            case .scaleRegion:
                return Self.name(record.scaleRegionID.flatMap { names.scaleRegions[$0] })
            case .layer:
                // ADR-0032: no layer id is the default layer, and so is an id the project no
                // longer holds. With no layer names installed the cell stays empty, as before.
                return Self.name(names.layers[record.effectiveLayerID] ?? names.layers[MarkupLayer.defaultID])
            case .scale:
                return Self.name(record.scaleID.flatMap { names.scales[$0] })
            case .displayUnit:
                return nil
            default:
                return nil
            }
        }

        /// The built-in `Total Cost`: the row's priced quantity times its `Unit Cost`
        /// (ADR-0020).
        ///
        /// The rate is per SI base unit of the quantity it prices — per metre, square metre,
        /// cubic metre or piece — and the quantity is the one the row's `Value` shows, read
        /// through the same cell path, so the repeat multiplier and the cutout rule apply to the
        /// total exactly as they apply to the quantity. The product is exact `Decimal`; an
        /// inexact one is an error cell, never a rounded amount (QUALITY_BAR A2).
        ///
        /// - No Unit Cost: empty. Nothing is priced.
        /// - A Unit Cost on a row with no quantity to price (a slope, an angle, a note): an
        ///   error cell, because a rate that multiplies nothing must not read as a zero cost.
        /// - A priced quantity that is itself empty (a cutout's own row, an unmeasured
        ///   markup): empty, like the quantity.
        func totalCost(at index: Int, record: MarkupRecord) -> LedgerCellResult {
            guard let unitCostID = columns.columnID(standard: .unitCost),
                  let stored = record.customValues[unitCostID] else { return .empty }
            guard case .currency(let rate, let code) = stored else {
                if case .empty = stored { return .empty }
                return .error(LedgerCellError(kind: .dimensionMismatch, detail: "Unit Cost is not money"))
            }
            guard let priced = Self.pricedColumn(for: record.tool) else {
                return .error(LedgerCellError(
                    kind: .aggregation,
                    detail: "Unit Cost on a row with no quantity to price"
                ))
            }
            guard case .number(let quantity)? = derivedValue(priced, index: index, record: record) else {
                return .empty
            }
            var left = rate
            var right = quantity.value
            var product = Decimal()
            guard NSDecimalMultiply(&product, &left, &right, .plain) == .noError else {
                return .error(LedgerCellError(kind: .aggregation, detail: "Total Cost overflowed"))
            }
            return .value(.currency(amount: product, code: code))
        }

        /// The column whose quantity a Unit Cost prices, for each tool (ADR-0020). The same
        /// column the ledger's `Value` shows first for the tool; tools whose value is a property
        /// of one markup — a radius, a slope, an angle, a rise — price nothing.
        static func pricedColumn(for tool: MeasurementTool?) -> StandardLedgerColumn? {
            switch tool {
            case .count: .count
            case .length, .dimension, .polylength, .arcLength, .temporaryMeasure: .planLength
            case .perimeter: .perimeter
            case .area, .rectangleArea, .ellipseArea, .polygonCutout, .ellipseCutout: .planArea
            case .volume: .volume
            case .wallArea: .wallArea
            case .trueSlopedLength: .trueLength
            case .trueSlopedArea: .trueArea
            case .radius, .diameter, .threePointCircle, .angle, .slope, .riseDrop, nil: nil
            }
        }

        /// Whether a row is a cutout's own row (ADR-0018): a record with a parent, or one drawn
        /// with a cutout tool — an orphaned cutout is still not a quantity.
        static func isCutoutRow(_ record: MarkupRecord) -> Bool {
            record.isCutout || record.tool == .polygonCutout || record.tool == .ellipseCutout
        }

        /// The cutout policy of a cutout row's parent, or `nil` when the parent is not in this
        /// ledger. A parent without stored parameters measured under the defaults.
        func cutoutParentPolicy(of record: MarkupRecord) -> CutoutPolicy? {
            guard let parentID = record.parentMarkupID,
                  let parentIndex = indexByMarkup[parentID] else { return nil }
            return (self.record(at: parentIndex).parameters ?? .default).cutoutPolicy
        }

        /// A resolved catalog name as a cell: `.empty` when there is no name to show.
        private static func name(_ resolved: String?) -> LedgerCellValue {
            guard let resolved, !resolved.isEmpty else { return .empty }
            return .text(resolved)
        }

        private static func hexText(_ color: RGBAColor) -> String {
            let clamped = color.clampedToUnitRange()
            func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
            return String(
                format: "#%02X%02X%02X%02X",
                channel(clamped.red),
                channel(clamped.green),
                channel(clamped.blue),
                channel(clamped.alpha)
            )
        }
    }
}

/// A row handle: an index plus the store's shared backing. Cells are produced on demand.
public struct LedgerRowView: Sendable {
    public let index: Int
    let storage: LedgerStore.Storage

    init(index: Int, storage: LedgerStore.Storage) {
        self.index = index
        self.storage = storage
    }

    public var markupID: MarkupID { storage.records[index].id }
    public var record: MarkupRecord { storage.record(at: index) }
    public var measurement: MeasurementResult { storage.measurement(at: index) }

    public func value(_ columnID: ColumnID) -> LedgerCellResult {
        storage.value(at: index, column: columnID)
    }
}
