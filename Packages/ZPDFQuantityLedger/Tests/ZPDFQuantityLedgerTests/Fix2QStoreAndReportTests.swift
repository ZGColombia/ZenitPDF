import Foundation
import os
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// Bug hunt 2 / improvements, store and report: BH-196, BH-617, BH-618, IM-077, IM-079, IM-080,
/// IM-081. (The BH-192 and BH-616 cases exercised `MeasurementDerivation`, which nothing shipping
/// used — the Inspector's derivation is AppCore's `DerivationBridge` — and went with it, U-067.)
@Suite("Fix2 Q — store, derivation, report")
struct Fix2QStoreAndReportTests {

    // MARK: - BH-196

    @Test("BH-196: an unassigned zone, layer, scale region, scale or unknown page is no value")
    func unassignedNamesAreEmpty() throws {
        // Old output: `.text("")` — "is empty" matched none of these rows, "is not empty"
        // matched all of them, and they sorted first ascending while grouping called them
        // "(none)".
        let columns = try LedgerColumnSet.standard()
        let assigned = ZoneID(SyntheticLedger.deterministicUUID(-300))
        let knownPage = PageID(SyntheticLedger.deterministicUUID(-2))
        var names = LedgerNameCatalog()
        names.zones[assigned] = "Level 2"
        names.pages[knownPage] = LedgerPageInfo(label: "A-101", index: 0)
        func record(_ index: Int, zone: ZoneID?, page: PageID) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(index)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: page,
                kind: .measurement,
                subject: "S\(index)",
                zoneID: zone,
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
        }
        let unknownPage = PageID(SyntheticLedger.deterministicUUID(-9))
        let store = try LedgerStore(
            markups: [record(0, zone: nil, page: unknownPage), record(1, zone: assigned, page: knownPage)],
            columns: columns,
            names: names
        )
        func column(_ standard: StandardLedgerColumn) throws -> ColumnID {
            try #require(columns.columnID(standard: standard))
        }
        for standard in [StandardLedgerColumn.projectZone, .layer, .scaleRegion, .scale, .pageLabel] {
            #expect(store.value(at: 0, column: try column(standard)) == .value(.empty), "\(standard)")
        }
        #expect(store.value(at: 1, column: try column(.projectZone)) == .value(.text("Level 2")))
        #expect(store.value(at: 1, column: try column(.pageLabel)) == .value(.text("A-101")))

        let zone = try column(.projectZone)
        let evaluator = LedgerFilterEvaluator(store: store)
        #expect(evaluator.filter([0, 1], with: .rule(LedgerFilterRule(column: zone, op: .isEmpty))) == [0])
        #expect(evaluator.filter([0, 1], with: .rule(LedgerFilterRule(column: zone, op: .isNotEmpty))) == [1])
        // Nulls last, as the grouping puts "(none)" last.
        #expect(LedgerSorter(store: store, descriptors: [LedgerSortDescriptor(column: zone)]).sorted([0, 1]) == [1, 0])
    }

    // MARK: - BH-617

    @Test("BH-617: a column listed twice is exported once instead of trapping")
    func duplicateVisibleColumnDoesNotTrap() throws {
        // Old output: `Dictionary(uniqueKeysWithValues:)` aborted the process.
        let store = try SyntheticLedger.makeStore(rowCount: 5)
        let subject = SyntheticLedger.columnID(.subject)
        let area = SyntheticLedger.columnID(.planArea)
        let view = store.makeView(LedgerViewSpec(
            aggregation: SyntheticLedger.plan,
            visibleColumns: [subject, area, subject, area]
        ))
        #expect(view.columns.map(\.id) == [subject, area])
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        #expect(report.columns.map(\.id) == [subject, area])
    }

    // MARK: - BH-618

    @Test("BH-618: a repeat count beyond the column's range reads as once, never as a saturated Int")
    func outOfRangeRepeatReadsAsOnce() {
        // Old output: `NSDecimalNumber.intValue` of 1e20 — unspecified; a saturated
        // multiplier or a negative clamped to 1 depending on the machine.
        let column = HandBuiltLedger.columnID("repeat")
        func count(_ value: Decimal) -> Int {
            let record = MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(1)),
                documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
                pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
                kind: .measurement,
                customValues: [column: .number(DecimalQuantity(value: value, dimension: .ratio))],
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
            return QuantityRepetition.repeatCount(record: record, multiplierColumn: column)
        }
        #expect(count(Decimal(string: "100000000000000000000")!) == 1)
        #expect(count(Decimal(string: "-100000000000000000000")!) == 1)
        #expect(count(10_001) == 1)
        #expect(count(10_000) == 10_000)
        #expect(count(Decimal(string: "2.9")!) == 2)
        #expect(count(0) == 1)
    }

    // MARK: - IM-079

    @Test("IM-079: one rounding entry point, and no signed zero from either door")
    func singleRoundingEntryPoint() {
        let values: [Decimal] = [
            Decimal(string: "-0.004")!, Decimal(string: "0.4449")!, Decimal(string: "1.005")!,
            Decimal(string: "-0.0")!, Decimal(string: "-1.005")!, Decimal(string: "-0.00049")!
        ]
        for value in values {
            for places in 0...4 {
                let rounding = LedgerDisplayRounding.round(value, places: places)
                let formatting = LedgerValueFormatting(precision: .decimalPlaces(places)).displayDecimal(value)
                #expect(rounding == formatting, "\(value) at \(places)")
                for result in [rounding, formatting] where result.isZero {
                    #expect(result.sign == .plus, "\(value) at \(places) must not be a signed zero")
                    #expect("\(result)" == "0")
                }
            }
        }
        #expect(LedgerValueFormatting(precision: .decimalPlaces(2)).displayDecimal(Decimal(string: "0.4449")!)
            == Decimal(string: "0.44")!)
    }

    // MARK: - IM-077

    @Test("IM-077: compiled set filters give the same rows, and a cancelled scan returns nil")
    func compiledFilterAndCancellation() throws {
        let store = try SyntheticLedger.makeStore(rowCount: 3_000)
        let status = SyntheticLedger.columnID(.status)
        let label = SyntheticLedger.columnID(.label)
        let statusTexts = MarkupStatus.allCases.prefix(3).map(\.rawValue) + (0..<17).map { "unused \($0)" }
        let nodes: [LedgerFilterNode] = [
            .rule(LedgerFilterRule(column: status, op: .inSet, value: .textSet(statusTexts))),
            .rule(LedgerFilterRule(column: status, op: .notInSet, value: .textSet(statusTexts))),
            .rule(LedgerFilterRule(column: status, op: .inSet, value: .choiceSet(
                [LedgerIdentifiers.choiceOptionID(for: MarkupStatus.allCases[1])]))),
            .rule(LedgerFilterRule(column: status, op: .equals, value: .text(MarkupStatus.allCases[2].rawValue))),
            .and([
                .rule(LedgerFilterRule(column: label, op: .contains, value: .text("b"))),
                .not(.rule(LedgerFilterRule(column: status, op: .inSet, value: .textSet(statusTexts))))
            ])
        ]
        let evaluator = LedgerFilterEvaluator(store: store)
        let all = Array(0..<3_000)
        for node in nodes {
            // The oracle: the uncompiled per-row path — the static rule evaluator with the
            // catalogue scanned for each Choice cell, exactly as before compilation.
            let expected = all.filter { Self.uncompiledMatches(store: store, row: $0, node: node) }
            #expect(evaluator.filter(all, with: node) == expected)
            #expect(evaluator.filter(all, with: node, isCancelled: { false }) == expected)
            #expect(all.filter { evaluator.matches(rowIndex: $0, node: node) } == expected)
        }

        var polls = 0
        let cancelled = evaluator.filter(all, with: nodes[0], isCancelled: {
            polls += 1
            return polls > 1
        })
        #expect(cancelled == nil)
        #expect(polls == 2, "polled before the scan and at the first stride boundary")
    }

    @Test("IM-077: a 20-value set filter over 100 000 rows is faster compiled")
    func compiledFilterMeasurement() throws {
        let store = try BigLedger.store()
        let status = SyntheticLedger.columnID(.status)
        let texts = MarkupStatus.allCases.prefix(2).map(\.rawValue) + (0..<18).map { "unused \($0)" }
        let node = LedgerFilterNode.rule(LedgerFilterRule(column: status, op: .inSet, value: .textSet(texts)))
        let all = Array(0..<store.rowCount)
        let clock = ContinuousClock()
        var compiled: [Int] = []
        var uncompiled: [Int] = []
        let compiledTime = clock.measure {
            compiled = LedgerFilterEvaluator(store: store).filter(all, with: node)
        }
        let uncompiledTime = clock.measure {
            uncompiled = all.filter { Self.uncompiledMatches(store: store, row: $0, node: node) }
        }
        print("IM-077 20-value set filter at 100 000 rows: compiled \(compiledTime), per-row \(uncompiledTime)")
        #expect(compiled == uncompiled)
        #expect(compiledTime < uncompiledTime)
    }

    /// The pre-IM-077 evaluation of one row, rebuilt from the evaluator's static pieces.
    private static func uncompiledMatches(store: LedgerStore, row: Int, node: LedgerFilterNode) -> Bool {
        switch node {
        case .all: return true
        case .nothing: return false
        case .markups(let ids): return ids.contains(store.row(at: row).markupID)
        case .not(let child): return !uncompiledMatches(store: store, row: row, node: child)
        case .and(let children): return children.allSatisfy { uncompiledMatches(store: store, row: row, node: $0) }
        case .or(let children): return children.contains { uncompiledMatches(store: store, row: row, node: $0) }
        case .rule(let rule):
            let definition = store.columns.column(id: rule.column)
            let cell = store.value(at: row, column: rule.column)
            // W-063 / X-032: "No input" is no value, for Is empty and for every other operator.
            switch rule.op {
            case .isEmpty: return cell.hasNoValue
            case .isNotEmpty: return !cell.hasNoValue && cell.cellError == nil
            default: break
            }
            let value: LedgerCellValue
            if cell.hasNoValue {
                value = .empty
            } else if case .value(let stored) = cell {
                value = stored
            } else {
                return false
            }
            return LedgerFilterEvaluator.matches(
                value: value, op: rule.op, operand: rule.value,
                choiceText: LedgerFilterEvaluator.choiceText(of: value, in: definition)
            )
        }
    }

    // MARK: - IM-080

    private func expectSameCells(_ left: LedgerStore, _ right: LedgerStore, _ comment: Comment) {
        for index in 0..<left.rowCount {
            #expect(left.record(at: index) == right.record(at: index), comment)
            #expect(left.measurement(at: index) == right.measurement(at: index), comment)
            for column in left.columns.columns {
                if left.value(at: index, column: column.id) != right.value(at: index, column: column.id) {
                    Issue.record("\(comment): row \(index) column \(column.key) differs")
                    return
                }
            }
        }
    }

    @Test("IM-080: a compacted store reads every cell as the overlay did, overrides included")
    func compactionIsInvisible() throws {
        let base = try SyntheticLedger.makeStore(rowCount: 2_000)
        var store = base
        var generator = SeededGenerator(seed: 80)
        for step in 0..<200 {
            let row = Int.random(in: 0..<2_000, using: &generator)
            var record = store.record(at: row)
            record.subject = "Edited \(step % 9)"
            let measurement: MeasurementResult? = step % 3 == 0
                ? MeasurementResult(values: [.count: .count(1), .planArea: .area(Decimal(step)), .netArea: .area(Decimal(step))])
                : nil
            store = try store.updatingRows([LedgerStore.LedgerRowEdit(index: row, record: record, measurement: measurement)])
        }
        #expect(!store.storage.rowEdits.isEmpty)
        let compacted = store.compacted()
        #expect(compacted.storage.rowEdits.isEmpty)
        expectSameCells(store, compacted, "compacted")

        // A later edit that omits its measurement keeps an override on both paths (CR-68).
        var edits: [LedgerStore.LedgerRowEdit] = []
        for row in stride(from: 0, to: 2_000, by: 97) {
            edits.append(LedgerStore.LedgerRowEdit(index: row, record: store.record(at: row)))
        }
        expectSameCells(try store.updatingRows(edits), try compacted.updatingRows(edits), "edit after compaction")
    }

    @Test("IM-080: the overlay is folded back past its threshold and the per-edit cost stays flat")
    func overlayStaysBounded() throws {
        var store = try BigLedger.store()
        let threshold = LedgerStore.compactionThreshold(rowCount: store.rowCount)
        let clock = ContinuousClock()
        var windows: [Duration] = []
        // Each edit copies the overlay, so the overlay sizes summed over a window are its copy
        // work. Unlike wall-clock time this does not move with machine load (I-30: the timing
        // ratio failed at 2.04× in a gate sweep with no store change).
        var overlayWork: [Int] = []
        var generator = SeededGenerator(seed: 5_000)
        var maximumOverlay = 0
        for window in 0..<5 {
            var work = 0
            let elapsed = try clock.measure {
                for step in 0..<1_000 {
                    let row = Int.random(in: 0..<store.rowCount, using: &generator)
                    var record = store.record(at: row)
                    record.label = "W\(window)-\(step)"
                    store = try store.updatingRows([LedgerStore.LedgerRowEdit(
                        index: row, record: record,
                        measurement: MeasurementResult(values: [.count: .count(1), .planArea: .area(1), .netArea: .area(1)])
                    )])
                    maximumOverlay = max(maximumOverlay, store.storage.rowEdits.count)
                    work += store.storage.rowEdits.count
                }
            }
            windows.append(elapsed)
            overlayWork.append(work)
        }
        print("IM-080 5 000 single-row edits at 100 000 rows, per 1 000: \(windows), overlay work \(overlayWork)")
        #expect(maximumOverlay <= threshold)
        // Without compaction the fifth thousand copies an overlay about three times the second's
        // (overlays of 4 000–5 000 rows against 1 000–2 000); with it both windows cycle through
        // the same overlay sizes, below the threshold.
        #expect(overlayWork[4] < overlayWork[1] * 2)
    }

    // MARK: - IM-081

    private static let formulaIDs = (1...4).map { HandBuiltLedger.columnID("formula \($0)") }

    /// The synthetic columns plus four formulas over them and over each other.
    private static func formulaColumns(doubled: String = "[planArea] * 2", tripled: String = "[planLength] * 3") throws
        -> LedgerColumnSet {
        var definitions = try SyntheticLedger.makeColumnSet().columns.map { definition -> LedgerColumnDefinition in
            guard definition.id == SyntheticLedger.doubledColumnID else { return definition }
            var changed = definition
            changed.formula = FormulaExpression(source: doubled)
            return changed
        }
        let specs: [(String, String, QuantityDimension, AnyDisplayUnit)] = [
            ("f1", "[doubled] + [planArea]", .area, .area(.squareMetre)),
            ("f2", tripled, .length, .length(.metre)),
            ("f3", "[f1] * 2", .area, .area(.squareMetre)),
            ("f4", "[planArea] / [f2]", .length, .length(.metre))
        ]
        for (offset, spec) in specs.enumerated() {
            definitions.append(LedgerColumnDefinition(
                id: formulaIDs[offset], key: spec.0, title: spec.0, kind: .formula,
                dimension: spec.2, displayUnit: spec.3, precision: .decimalPlaces(3),
                formula: FormulaExpression(source: spec.1), isEditable: false,
                order: definitions.count
            ))
        }
        return try LedgerColumnSet(columns: definitions)
    }

    private static func records(_ store: LedgerStore) -> [MarkupRecord] {
        (0..<store.rowCount).map { store.record(at: $0) }
    }

    @Test("IM-081: the concurrent formula pass equals the serial one, and reports progress")
    func concurrentPassIsDeterministic() async throws {
        let seed = try SyntheticLedger.makeStore(rowCount: 5_000)
        let columns = try Self.formulaColumns()
        let serial = try LedgerStore(markups: Self.records(seed), columns: columns, names: seed.names)
        let fractions = ProgressLog()
        let parallel = try await LedgerStore.build(
            markups: Self.records(seed), columns: columns, names: seed.names,
            chunkSize: 700, progress: { fractions.append($0) }
        )
        #expect(parallel.storage.formulaCells == serial.storage.formulaCells)
        let reported = fractions.values
        #expect(reported.last?.completed == 5_000)
        #expect(reported.map(\.completed) == reported.map(\.completed).sorted())
    }

    @Test("IM-081: a cancelled build throws and yields no store")
    func cancelledBuildThrows() async throws {
        let seed = try BigLedger.store()
        let markups = Self.records(seed)
        let columns = try Self.formulaColumns()
        let task = Task {
            try await LedgerStore.build(markups: markups, columns: columns, names: seed.names, chunkSize: 512)
        }
        task.cancel()
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }

    @Test("IM-081: editing one formula re-evaluates it and its dependents only, with the same cells")
    func replacingColumnsRecomputesAffectedOnly() throws {
        let seed = try SyntheticLedger.makeStore(rowCount: 1_500)
        let original = try Self.formulaColumns()
        let store = try LedgerStore(markups: Self.records(seed), columns: original, names: seed.names)

        let editTripled = try Self.formulaColumns(tripled: "[planLength] * 4")
        #expect(LedgerStore.affectedFormulaColumns(from: original, to: editTripled)
            == [Self.formulaIDs[1], Self.formulaIDs[3]])
        let editDoubled = try Self.formulaColumns(doubled: "[planArea] * 3")
        #expect(LedgerStore.affectedFormulaColumns(from: original, to: editDoubled)
            == [SyntheticLedger.doubledColumnID, Self.formulaIDs[0], Self.formulaIDs[2]])
        #expect(LedgerStore.affectedFormulaColumns(from: original, to: original) == [])

        for changed in [editTripled, editDoubled] {
            let incremental = try store.replacingColumns(changed)
            let scratch = try LedgerStore(markups: Self.records(seed), columns: changed, names: seed.names)
            #expect(incremental.storage.formulaCells == scratch.storage.formulaCells)
        }
        // An edited store is compacted first, so its edits survive the column change.
        var record = store.record(at: 7)
        record.subject = "Edited"
        let edited = try store.updatingRows([LedgerStore.LedgerRowEdit(
            index: 7, record: record,
            measurement: MeasurementResult(values: [.count: .count(1), .planArea: .area(50), .netArea: .area(50), .planLength: .length(5)])
        )])
        let replaced = try edited.replacingColumns(editDoubled)
        #expect(replaced.value(at: 7, column: SyntheticLedger.doubledColumnID).quantity?.value == 150)
        #expect(replaced.record(at: 7).subject == "Edited")
    }

    @Test("IM-081: at 100 000 rows the concurrent pass beats the serial one")
    func concurrentPassMeasurement() async throws {
        let seed = try BigLedger.store()
        let markups = Self.records(seed)
        let columns = try Self.formulaColumns()
        // Best of three interleaved rounds: swift-testing runs other suites beside this one, and
        // a single sample taken while they hold the cores measured the neighbours, not the pass
        // (it failed once in a full-suite run on a loaded machine; alone: 1.33 s vs 0.41 s).
        let clock = ContinuousClock()
        var serialTime = Duration.seconds(3600)
        var parallelTime = Duration.seconds(3600)
        var serial: LedgerStore?
        var parallel: LedgerStore?
        for _ in 0..<3 {
            let serialStart = clock.now
            serial = try LedgerStore(markups: markups, columns: columns, names: seed.names)
            serialTime = min(serialTime, clock.now - serialStart)
            let parallelStart = clock.now
            parallel = try await LedgerStore.build(markups: markups, columns: columns, names: seed.names)
            parallelTime = min(parallelTime, clock.now - parallelStart)
        }
        let serialStore = try #require(serial)
        let parallelStore = try #require(parallel)
        print("IM-081 five formula columns over 100 000 rows (best of 3): serial \(serialTime), concurrent \(parallelTime)")
        #expect(parallelStore.storage.formulaCells == serialStore.storage.formulaCells)
        // The speed-up needs idle cores. CI sets ZENIT_TIMING_ADVISORY=1 on hosted runners, and a
        // machine with few cores has none spare while the rest of the suite runs, so there a slower
        // concurrent pass is reported rather than failed. The cell equality above always holds.
        let advisory = ProcessInfo.processInfo.environment["ZENIT_TIMING_ADVISORY"] == "1"
            || ProcessInfo.processInfo.activeProcessorCount < 8
        if advisory {
            if parallelTime >= serialTime {
                print("::warning title=IM-081 speed-up not measured (advisory)::serial \(serialTime), concurrent \(parallelTime)")
            }
        } else {
            #expect(parallelTime < serialTime)
        }
    }
}

/// Collects progress reports from a `@Sendable` callback.
private final class ProgressLog: Sendable {
    private let items = OSAllocatedUnfairLock<[FormulaEvaluationProgress]>(initialState: [])
    func append(_ progress: FormulaEvaluationProgress) { items.withLock { $0.append(progress) } }
    var values: [FormulaEvaluationProgress] { items.withLock { $0 } }
}
