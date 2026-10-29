// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

/// ``LedgerAuditPresenting`` over the sample project: a deterministic trail derived from
/// the sample rows, so the History pane, the inspector's derivation disclosure and the
/// audit export can all be developed and tested against real behaviour.
extension MockLedgerPresenter: LedgerAuditPresenting {

    /// One "measured" event per sample row, plus a scale change fanning out over the first
    /// page's rows — the mutation ADR-0007 singles out, so the pane's grouped rendering of
    /// an undo group is exercised by the mock too.
    public func auditEvents(matching filter: LedgerAuditFilter) -> [LedgerAuditEvent] {
        sampleAuditTrail().filter { filter.matches($0) }
    }

    public var auditPageLabels: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for event in sampleAuditTrail() {
            guard let label = event.pageLabel, seen.insert(label).inserted else { continue }
            labels.append(label)
        }
        return labels.sorted()
    }

    /// The sample trail is derived from the rows, which change only on a rebuild — and every
    /// rebuild moves `contentRevision` (V-042).
    public var auditRevision: Int { contentRevision }

    public var auditActions: [String] {
        var seen = Set<String>()
        var actions: [String] = []
        for event in sampleAuditTrail() where seen.insert(event.action).inserted {
            actions.append(event.action)
        }
        return actions
    }

    public func derivation(for markupID: UUID) -> LedgerDerivationModel? {
        // BH-271: provenance is a fact about the markup, not about the current filter — the
        // row is looked up among all rows, so a filtered-out markup still has its derivation.
        guard let row = auditSourceRows.first(where: { $0.markupID == markupID }) else { return nil }
        // BH-769: every measured quantity the row carries is a value fact, not only plan area
        // and plan length — a Count, Volume or Perimeter row claimed provenance with an empty
        // values section.
        var valueFacts: [LedgerDerivationFact] = []
        for column in Self.derivationColumns {
            guard let quantity = row.quantity(column) else { continue }
            // BH-192: value facts carry their unit symbol, as the app's
            // do ("70 ft"); the Inspector shows them verbatim.
            let symbol = ZenitSampleProject.unitSymbol(for: quantity.dimension)
            func withUnit(_ text: String) -> String { symbol.isEmpty ? text : "\(text) \(symbol)" }
            // A value fact names the measurement field behind the column, which the Inspector
            // labels by its field name: the Plan Area column reads the net area (ADR-0016).
            let field = column == .planArea ? MeasurementField.netArea.rawValue : column.rawValue
            valueFacts.append(LedgerDerivationFact(key: "value.\(field).si", value: withUnit("\(quantity.value)")))
            valueFacts.append(LedgerDerivationFact(
                key: "value.\(field).display",
                value: withUnit(row.displayValue(column))
            ))
        }
        let history = sampleAuditTrail().filter { $0.markupID == markupID }
        return LedgerDerivationModel(
            markupID: markupID,
            hasProvenance: !valueFacts.isEmpty && !history.isEmpty,
            sections: [
                LedgerDerivationSection(key: "geometry", facts: [
                    LedgerDerivationFact(key: "geometry.digest", value: "b0f2c5a7e41d9c33")
                ]),
                LedgerDerivationSection(key: "scale", facts: [
                    LedgerDerivationFact(key: "scale.id", value: "1:100 (calibrated)"),
                    LedgerDerivationFact(key: "scale.version", value: "2"),
                    LedgerDerivationFact(key: "scale.source", value: "twoPointCalibration"),
                    LedgerDerivationFact(key: "scale.calibration.enteredLength", value: "5.000 m"),
                    LedgerDerivationFact(key: "scale.calibration.points", value: "(120, 640) (620, 640)")
                ]),
                LedgerDerivationSection(key: "slope", facts: [
                    LedgerDerivationFact(key: "slope.mode", value: "flat")
                ]),
                LedgerDerivationSection(key: "parameters", facts: [
                    LedgerDerivationFact(key: "parameters.cutoutPolicy", value: "subtract"),
                    LedgerDerivationFact(key: "parameters.perimeterPolicy", value: "outerOnly")
                ]),
                LedgerDerivationSection(key: "values", facts: valueFacts),
                LedgerDerivationSection(key: "engine", facts: [
                    LedgerDerivationFact(key: "engine.formulaVersion", value: "2"),
                    LedgerDerivationFact(key: "engine.version", value: "1.0.0-sample"),
                    LedgerDerivationFact(key: "engine.computedAt", value: "2026-03-02T09:15:00Z")
                ])
            ],
            history: history
        )
    }

    /// The quantity columns a derivation reports, in a fixed order.
    static let derivationColumns: [LedgerColumnID] = [
        .count, .planLength, .trueLength, .perimeter, .planArea, .trueArea, .wallArea,
        .volume, .depth, .height, .radius, .diameter, .slopeRatio, .slopePercent, .slopeAngle,
        .rise, .run
    ]

    /// The rows the trail is derived from: every sample row in seed order, independent of
    /// the filter and the sort (BH-271).
    private var auditSourceRows: [LedgerRow] { allRowsForAudit }

    // MARK: - Sample trail

    /// The value a "markup_created" event records: the row's first measured quantity.
    private static func creationChanges(for row: LedgerRow) -> [LedgerAuditValueChange] {
        guard let column = derivationColumns.first(where: { row.quantity($0) != nil }) else { return [] }
        return [LedgerAuditValueChange(field: column.rawValue, before: nil, after: row.quantity(column).map { "\($0.value)" })]
    }

    private func sampleAuditTrail() -> [LedgerAuditEvent] {
        var events: [LedgerAuditEvent] = []
        var sequence = 1
        // BH-271: the trail is append-only history, so it is derived from every row in seed
        // order — never from the filtered, sorted view — and covers every row (BH-769).
        let rows = auditSourceRows
        for (offset, row) in rows.enumerated() {
            events.append(LedgerAuditEvent(
                sequence: sequence,
                occurredAt: SampleFormatting.sampleDate(days: -3, hours: offset),
                action: "markup_created",
                actor: offset % 3 == 0 ? "A. Berg" : "B. Lund",
                markupID: row.markupID,
                markupSubject: row.displayValue(.subject),
                pageLabel: row.displayValue(.pageLabel),
                commandName: NSLocalizedString("Measure Area", comment: "Sample audit command name"),
                changes: Self.creationChanges(for: row)
            ))
            sequence += 1
        }
        // The scale change and its fan-out share one undo group (ADR-0007 §2).
        let firstPage = rows.first?.displayValue(.pageLabel)
        events.append(LedgerAuditEvent(
            sequence: sequence,
            occurredAt: SampleFormatting.sampleDate(days: -1),
            action: "scale_changed",
            actor: "A. Berg",
            pageLabel: firstPage,
            undoGroup: "sample-scale-change",
            note: "scale 1:100 version 1 -> 2"
        ))
        sequence += 1
        for row in rows where row.displayValue(.pageLabel) == firstPage {
            let area = row.quantity(.planArea).map { "\($0.value)" }
            events.append(LedgerAuditEvent(
                sequence: sequence,
                occurredAt: SampleFormatting.sampleDate(days: -1),
                action: "markup_rescaled",
                actor: "A. Berg",
                markupID: row.markupID,
                markupSubject: row.displayValue(.subject),
                pageLabel: row.displayValue(.pageLabel),
                undoGroup: "sample-scale-change",
                changes: [LedgerAuditValueChange(field: "planArea", before: area, after: area)]
            ))
            sequence += 1
        }
        return events
    }
}
#endif
