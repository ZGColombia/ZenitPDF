import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// Projects a ``LedgerView`` into a ``LedgerReport``.
///
/// Deterministic: the only outside input is the injected ``TimestampProviding``, and everything
/// else is a pure function of the view. Two builds of the same view with the same clock produce
/// equal reports, which is what QUALITY_BAR A34 needs from "two exports of the same view are
/// byte-identical".
public struct LedgerReportBuilder: Sendable {
    private let timestamps: any TimestampProviding

    public init(timestamps: any TimestampProviding) {
        self.timestamps = timestamps
    }

    /// Projects the view.
    ///
    /// The project's audit trail is not part of the projection: the PDF report's appendix is
    /// `PDFReportAuditAppendix`, which the application builds from the audit log itself.
    public func makeReport(
        _ view: LedgerView,
        title: String = "",
        unappliedFilterRules: [String] = []
    ) -> LedgerReport {
        // BH-617: a column listed twice in the view's visible columns is exported once, at
        // its first position. `Dictionary(uniqueKeysWithValues:)` used to trap the process
        // on the repeated key — an export path must never abort on a saved view's contents.
        var seen = Set<ColumnID>()
        let definitions = view.columns.filter { seen.insert($0.id).inserted }
        let formatting = Dictionary(
            definitions.map { ($0.id, LedgerValueFormatting(column: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let columns = definitions.map { definition in
            LedgerReportColumn(
                id: definition.id,
                key: definition.key,
                title: definition.title,
                kind: definition.kind,
                formatting: formatting[definition.id] ?? .plain,
                aggregationSemantics: definition.kind == .formula
                    ? (view.store.columns.formulaSemantics[definition.id] ?? .evaluateThenAggregate)
                    : nil,
                formulaCanonicalText: view.store.columns.compiledFormulas
                    .programs[definition.id]?.canonicalText
            )
        }

        let groups = view.tree.roots.map {
            makeGroup($0, view: view, definitions: definitions, formatting: formatting)
        }
        let flatRows = view.tree.isFlat
            ? view.tree.orderedRowIndices.map {
                makeRow($0, path: [], view: view, definitions: definitions, formatting: formatting)
            }
            : []

        return LedgerReport(
            title: title,
            columns: columns,
            groups: groups,
            rows: flatRows,
            grandTotals: makeTotals(
                view.tree.grandTotal,
                plan: view.spec.aggregation,
                formatting: formatting
            ),
            metadata: LedgerReportMetadata(
                generatedAt: timestamps.now(),
                ledgerContractVersion: ContractVersion.ledger,
                formulaGrammarVersion: FormulaEngine.grammarVersion,
                groupingColumnKeys: view.spec.grouping.map {
                    view.store.columns.column(id: $0.column)?.key ?? $0.column.description
                },
                sortDescription: view.spec.sort.map { descriptor in
                    let key = view.store.columns.column(id: descriptor.column)?.key
                        ?? descriptor.column.description
                    return "\(key):\(descriptor.ascending ? "asc" : "desc"):nulls\(descriptor.nulls.rawValue)"
                },
                filterDescription: Self.describe(view.spec.filter, columns: view.store.columns),
                rowCount: view.rowCount,
                totalRowCountBeforeFilter: view.store.rowCount,
                groupingColumnFormatting: view.spec.grouping.map { field in
                    view.store.columns.column(id: field.column).map { LedgerValueFormatting(column: $0) }
                },
                unappliedFilterRules: unappliedFilterRules,
                dayTimeZone: view.tree.dayCalendar.timeZone
            )
        )
    }

    private func makeGroup(
        _ node: LedgerGroupNode,
        view: LedgerView,
        definitions: [LedgerColumnDefinition],
        formatting: [ColumnID: LedgerValueFormatting]
    ) -> LedgerReportGroup {
        LedgerReportGroup(
            key: node.key,
            path: node.path,
            depth: node.depth,
            rowCount: node.descendantRowCount,
            subgroups: node.children.map {
                makeGroup($0, view: view, definitions: definitions, formatting: formatting)
            },
            rows: node.rowIndices.map {
                makeRow(
                    $0,
                    path: node.path,
                    view: view,
                    definitions: definitions,
                    formatting: formatting
                )
            },
            totals: makeTotals(
                node.aggregates,
                plan: view.spec.aggregation,
                formatting: formatting
            )
        )
    }

    private func makeRow(
        _ index: Int,
        path: [LedgerGroupKey],
        view: LedgerView,
        definitions: [LedgerColumnDefinition],
        formatting: [ColumnID: LedgerValueFormatting]
    ) -> LedgerReportRow {
        let record = view.store.record(at: index)
        // NL-MEASURE-10 / ADR-0035 §1.3: a markup with display units of its own is exported in
        // them, cell by cell, as the ledger on screen shows its row; the column's formatting
        // stays for every other row and for every total (totals sum in SI).
        let override = record.parameters?.displayOverride
        return LedgerReportRow(
            markupID: view.store.markupID(at: index),
            storeIndex: index,
            groupPath: path,
            cells: definitions.map { definition in
                let columnFormatting = formatting[definition.id] ?? .plain
                return LedgerReportCell(
                    column: definition.id,
                    // The one evaluation path. Not a copy of what the table showed — the same call.
                    value: view.store.value(at: index, column: definition.id),
                    formatting: override.map(columnFormatting.overriding) ?? columnFormatting
                )
            },
            // ADR-0012 rule 4: the exporters print this, so the report carries it.
            provenance: record.provenance
        )
    }

    private func makeTotals(
        _ aggregates: LedgerAggregates,
        plan: LedgerAggregationPlan,
        formatting: [ColumnID: LedgerValueFormatting]
    ) -> [LedgerReportTotal] {
        plan.keys.compactMap { key in
            guard let value = aggregates.value(key) else { return nil }
            return LedgerReportTotal(
                column: key.column,
                function: key.function,
                value: value,
                formatting: formatting[key.column] ?? .plain
            )
        }
    }

    /// A stable rendering of a filter tree. Not localised, not pretty: an export's audit trail.
    static func describe(_ node: LedgerFilterNode, columns: LedgerColumnSet) -> String {
        switch node {
        case .all: return "ALL"
        case .nothing: return "NONE"
        case .markups(let ids): return "SELECTED(\(ids.count))"
        case .not(let child): return "NOT(\(describe(child, columns: columns)))"
        case .and(let children):
            return "AND(\(children.map { describe($0, columns: columns) }.joined(separator: ",")))"
        case .or(let children):
            return "OR(\(children.map { describe($0, columns: columns) }.joined(separator: ",")))"
        case .rule(let rule):
            let key = columns.column(id: rule.column)?.key ?? rule.column.description
            return "\(key) \(rule.op.rawValue) \(describe(rule.value))"
        }
    }

    static func describe(_ value: LedgerFilterValue) -> String {
        switch value {
        case .text(let text): "\"\(text)\""
        case .number(let decimal): "\(decimal)"
        case .quantity(let quantity): "\(quantity.value)\(quantity.dimension.baseUnitSymbol)"
        case .date(let date): "\(date.timeIntervalSinceReferenceDate)"
        case .boolean(let flag): "\(flag)"
        case .choice(let id): id.rawValue.uuidString
        case .numberRange(let lower, let upper): "[\(lower),\(upper)]"
        case .dateRange(let lower, let upper):
            "[\(lower.timeIntervalSinceReferenceDate),\(upper.timeIntervalSinceReferenceDate)]"
        case .textSet(let texts): "{\(texts.joined(separator: ","))}"
        case .choiceSet(let ids): "{\(ids.map(\.rawValue.uuidString).joined(separator: ","))}"
        case .none: ""
        }
    }
}

/// A clock that always answers the same instant. Reports are deterministic; a test that compares
/// two exports byte for byte needs the timestamp to be an input, not a surprise.
public struct FixedTimestampProvider: TimestampProviding {
    public let instant: Date
    public init(_ instant: Date) { self.instant = instant }
    public func now() -> Date { instant }
}
