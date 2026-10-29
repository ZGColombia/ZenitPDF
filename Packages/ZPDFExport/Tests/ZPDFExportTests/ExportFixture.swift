import Foundation
import Testing
import ZPDFContracts
import ZPDFQuantityLedger
@testable import ZPDFExport

/// The ledgers every export test is built on.
///
/// Two of them. `goldens` is six rows chosen so that a wrong implementation cannot pass: hostile
/// CSV text, an empty cell, a formula error, a mixed-dimension total, and five numbers engineered
/// so that double rounding or `Double` formatting gives a different last digit. `synthetic(n)` is
/// the volume fixture, whose exact totals are known in closed form.
enum ExportFixture {

    static let currencyCode = "SEK"
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func standardID(_ column: StandardLedgerColumn) -> ColumnID {
        LedgerIdentifiers.columnID(for: column)
    }

    static func customID(_ name: String) -> ColumnID {
        ColumnID(LedgerIdentifiers.deterministicUUID(namespace: "test/zpdfexport", name: name))
    }

    static let goldenID = customID("golden")
    static let footprintID = customID("footprint")
    static let costID = customID("cost")
    static let mixedID = customID("mixed")

    static func uuid(_ index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        for offset in 0..<8 {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        bytes[8] = UInt8(truncatingIfNeeded: index >> 24)
        bytes[9] = UInt8(truncatingIfNeeded: index >> 16)
        bytes[10] = UInt8(truncatingIfNeeded: index >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: index)
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Golden values

    /// Values whose correct two-decimal rendering differs from what a careless implementation
    /// produces. Each one is here because a specific mistake would show up in the last digit.
    ///
    /// | value | correct | wrong, and how |
    /// |---|---|---|
    /// | `0.4449` | `0.44` | `0.45` if rounded to 3 places first and then to 2 (QUALITY_BAR A31) |
    /// | `1.005` | `1.01` | `1.00` from `String(format: "%.2f", 1.005)` — the `Double` is `1.00499999999999989` |
    /// | `2.675` | `2.68` | `2.67`, same reason |
    /// | `-0.004` | `0.00` | `-0.00`, which reads as a negative quantity |
    /// | `1234567.891` | `1234567.89` | grouping and separator mistakes surface here |
    static let goldenValues: [Decimal] = [
        Decimal(string: "0.4449")!,
        Decimal(string: "1.005")!,
        Decimal(string: "2.675")!,
        Decimal(string: "-0.004")!,
        Decimal(string: "1234567.891")!,
        Decimal(string: "8.125")!
    ]

    static let expectedGoldenText = ["0.44", "1.01", "2.68", "0.00", "1234567.89", "8.13"]

    /// Hostile text, one string per row. Every one of these has broken a CSV writer somewhere.
    static let hostileComments = [
        "plain",
        "has,comma;and semicolon",
        "has \"embedded\" quotes",
        "line one\nline two",
        "=1+1",                       // Excel formula injection
        " leading and trailing "      // whitespace a reader would trim
    ]

    // MARK: - Columns

    static func columnSet() throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = []
        var order = 0
        func append(_ definition: LedgerColumnDefinition) {
            var copy = definition
            copy.order = order
            order += 1
            definitions.append(copy)
        }

        for standard in [StandardLedgerColumn.subject, .label, .comment, .status, .created] {
            append(LedgerColumnDefinition(
                id: standardID(standard),
                key: standard.rawValue,
                title: standard.rawValue,
                kind: standard.kind,
                standard: standard,
                choices: standard == .status ? LedgerStatusChoices.options : [],
                defaultChoiceID: standard == .status
                    ? LedgerIdentifiers.choiceOptionID(for: .none)
                    : nil,
                isEditable: standard.isUserEditable
            ))
        }
        append(LedgerColumnDefinition(
            id: standardID(.planArea),
            key: StandardLedgerColumn.planArea.rawValue,
            title: "Plan Area",
            kind: .number,
            standard: .planArea,
            dimension: .area,
            displayUnit: .area(.squareMetre),
            precision: .decimalPlaces(3),
            isEditable: false
        ))
        // Same stored dimension, a different display unit: converts before it rounds.
        append(LedgerColumnDefinition(
            id: footprintID,
            key: "footprint",
            title: "Footprint",
            kind: .number,
            dimension: .area,
            displayUnit: .area(.squareFoot),
            precision: .decimalPlaces(2)
        ))
        // Dimensionless, two decimals: the double-rounding detector lives here.
        append(LedgerColumnDefinition(
            id: goldenID,
            key: "golden",
            title: "Golden",
            kind: .number,
            dimension: .count,
            displayUnit: .count,
            precision: .decimalPlaces(2)
        ))
        append(LedgerColumnDefinition(
            id: costID,
            key: "cost",
            title: "Cost",
            kind: .currency,
            dimension: .currency(currencyCode),
            displayUnit: .currency(currencyCode),
            precision: .decimalPlaces(2)
        ))
        // Deliberately mixed: metres on one row, square metres on another, so every export has
        // to render the mixed-units token (QUALITY_BAR A11, A14).
        append(LedgerColumnDefinition(
            id: mixedID,
            key: "mixed",
            title: "Mixed",
            kind: .number,
            dimension: nil,
            precision: .decimalPlaces(2)
        ))
        return try LedgerColumnSet(columns: definitions)
    }

    static var plan: LedgerAggregationPlan {
        var plan = LedgerAggregationPlan()
        for column in [standardID(.planArea), footprintID, goldenID, costID, mixedID] {
            plan.add(AggregateKey(column: column, function: .sum))
        }
        plan.add(AggregateKey(column: standardID(.subject), function: .count))
        return plan
    }

    // MARK: - The golden ledger

    static func goldenStore() throws -> LedgerStore {
        let columns = try columnSet()
        let documentID = DocumentID(uuid(-1))
        let pageID = PageID(uuid(-2))
        var markups: [MarkupRecord] = []
        for index in 0..<goldenValues.count {
            var custom: [ColumnID: LedgerCellValue] = [
                goldenID: .number(.count(goldenValues[index])),
                footprintID: .number(.area(Decimal(index + 1) * 10)),
                costID: .currency(amount: goldenValues[index] * 100, code: currencyCode)
            ]
            // Two dimensions in one column. Row 0 is metres, row 1 is square metres; the sum of
            // that column can only be a refusal.
            if index == 0 { custom[mixedID] = .number(.length(2)) }
            if index == 1 { custom[mixedID] = .number(.area(3)) }
            markups.append(MarkupRecord(
                id: MarkupID(uuid(index)),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .area,
                subject: index % 2 == 0 ? "Concrete" : "Steel",
                label: "L\(index)",
                comment: hostileComments[index],
                author: "Ada",
                status: MarkupStatus.allCases[index % MarkupStatus.allCases.count],
                // ADR-0016: the Plan Area column reads the net area; the engine writes both fields.
                measurement: MeasurementResult(values: [
                    .planArea: .area(Decimal(index + 1) / 8),
                    .netArea: .area(Decimal(index + 1) / 8)
                ]),
                customValues: custom,
                createdAt: epoch.addingTimeInterval(Double(index) * 3600),
                modifiedAt: epoch.addingTimeInterval(Double(index) * 3600 + 60)
            ))
        }
        return try LedgerStore(markups: markups, columns: columns)
    }

    static func goldenReport(
        grouped: Bool = false,
        title: String = "Golden ledger"
    ) throws -> LedgerReport {
        let store = try goldenStore()
        let spec = LedgerViewSpec(
            grouping: grouped ? [LedgerGroupingField(column: standardID(.subject))] : [],
            aggregation: plan
        )
        let view = store.makeView(spec)
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(epoch))
            .makeReport(view, title: title)
    }

    // MARK: - The volume ledger

    static func syntheticStore(rowCount: Int) throws -> LedgerStore {
        let columns = try columnSet()
        let documentID = DocumentID(uuid(-11))
        let pageID = PageID(uuid(-12))
        var markups: [MarkupRecord] = []
        markups.reserveCapacity(rowCount)
        let subjects = ["Concrete", "Steel", "Glazing", "Roofing"]
        for index in 0..<rowCount {
            let n = Decimal(index + 1)
            markups.append(MarkupRecord(
                id: MarkupID(uuid(index)),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                tool: .area,
                subject: subjects[index % subjects.count],
                label: "L\(index % 7)",
                comment: index % 11 == 0 ? "note, with comma" : "",
                author: "Ada",
                status: MarkupStatus.allCases[index % MarkupStatus.allCases.count],
                // ADR-0016: the Plan Area column reads the net area; the engine writes both fields.
                measurement: MeasurementResult(values: [.planArea: .area(n / 100), .netArea: .area(n / 100)]),
                customValues: [
                    goldenID: .number(.count(n / 8)),
                    footprintID: .number(.area(n / 4)),
                    costID: .currency(amount: n / 4, code: currencyCode)
                ],
                createdAt: epoch.addingTimeInterval(Double(index)),
                modifiedAt: epoch.addingTimeInterval(Double(index) + 1)
            ))
        }
        return try LedgerStore(markups: markups, columns: columns)
    }

    static func syntheticReport(rowCount: Int, grouped: Bool = true) throws -> LedgerReport {
        let store = try syntheticStore(rowCount: rowCount)
        let spec = LedgerViewSpec(
            grouping: grouped ? [LedgerGroupingField(column: standardID(.subject))] : [],
            aggregation: plan
        )
        return LedgerReportBuilder(timestamps: FixedTimestampProvider(epoch))
            .makeReport(store.makeView(spec), title: "Synthetic ledger")
    }

    // MARK: - Projections

    static func projection(
        _ report: LedgerReport,
        locale: ExportNumberLocale = .invariant,
        document: ExportDocumentContext = ExportDocumentContext(
            projectName: "Example Quay, Block C",
            documentName: "A-101.pdf",
            revision: "C",
            scaleDescription: "1:100 (calibrated, two-point)",
            unitsDescription: "Metric — m, m2, m3",
            preparedBy: "Zenit PDF"
        )
    ) throws -> ExportProjection {
        try ExportProjector().project(
            report,
            options: ExportProjectionOptions(numberLocale: locale, document: document)
        )
    }
}

func temporaryURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zpdfexport-\(UUID().uuidString).\(ext)")
}
