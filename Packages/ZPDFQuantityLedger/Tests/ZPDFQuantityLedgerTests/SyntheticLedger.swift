import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// A deterministic ledger whose exact totals are known in closed form.
///
/// The point of a synthetic fixture is that the expected total is derived from arithmetic that
/// the code under test never runs. Every quantity here is a linear function of the row index, so
/// each total is `N(N+1)/2` scaled by an exact power-of-ten or power-of-two divisor — a number
/// this file computes with a Gauss sum, not by adding 100 000 things up the way the aggregator
/// does.
enum SyntheticLedger {

    static let subjects = ["Concrete", "Steel", "Glazing", "Insulation", "Roofing", "Doors", "Windows"]
    static let labels = ["A", "B", "C", "D"]
    static let pageCount = 8
    static let zoneCount = 5
    static let currencyCode = "SEK"

    // MARK: - Columns

    static func columnID(_ standard: StandardLedgerColumn) -> ColumnID {
        LedgerIdentifiers.columnID(for: standard)
    }

    static let costColumnID = ColumnID(
        LedgerIdentifiers.deterministicUUID(namespace: "test/synthetic", name: "cost")
    )
    static let doubledColumnID = ColumnID(
        LedgerIdentifiers.deterministicUUID(namespace: "test/synthetic", name: "doubled")
    )

    static let standardColumns: [StandardLedgerColumn] = [
        .subject, .label, .pageLabel, .projectZone, .status, .count, .planArea, .planLength
    ]

    static func makeColumnSet() throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = []
        for (order, standard) in standardColumns.enumerated() {
            let dimension = standard.measurementField?.dimension
            definitions.append(
                LedgerColumnDefinition(
                    id: columnID(standard),
                    key: standard.rawValue,
                    title: standard.rawValue,
                    kind: standard.kind,
                    standard: standard,
                    dimension: dimension,
                    displayUnit: LedgerColumnSet.displayUnit(for: dimension, policy: .metric),
                    precision: dimension == nil ? nil : PrecisionMode.decimalPlaces(3),
                    choices: standard == .status ? LedgerStatusChoices.options : [],
                    defaultChoiceID: standard == .status
                        ? LedgerIdentifiers.choiceOptionID(for: .none)
                        : nil,
                    isEditable: standard.isUserEditable,
                    order: order
                )
            )
        }
        definitions.append(
            LedgerColumnDefinition(
                id: costColumnID,
                key: "cost",
                title: "Cost",
                kind: .currency,
                dimension: .currency(currencyCode),
                displayUnit: .currency(currencyCode),
                precision: .decimalPlaces(2),
                order: definitions.count
            )
        )
        definitions.append(
            LedgerColumnDefinition(
                id: doubledColumnID,
                key: "doubled",
                title: "Doubled",
                kind: .formula,
                dimension: .area,
                displayUnit: .area(.squareMetre),
                precision: .decimalPlaces(3),
                formula: FormulaExpression(source: "[planArea] * 2"),
                isEditable: false,
                order: definitions.count
            )
        )
        return try LedgerColumnSet(columns: definitions)
    }

    // MARK: - Rows

    static func deterministicUUID(_ index: Int) -> UUID {
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

    static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func makeStore(rowCount: Int) throws -> LedgerStore {
        let columns = try makeColumnSet()
        let documentID = DocumentID(deterministicUUID(-1))
        let pageIDs = (0..<pageCount).map { PageID(deterministicUUID(-100 - $0)) }
        let zoneIDs = (0..<zoneCount).map { ZoneID(deterministicUUID(-200 - $0)) }
        let statuses = MarkupStatus.allCases

        var names = LedgerNameCatalog()
        for (index, pageID) in pageIDs.enumerated() {
            names.pages[pageID] = LedgerPageInfo(label: "Page \(index + 1)", index: index)
        }
        for (index, zoneID) in zoneIDs.enumerated() {
            names.zones[zoneID] = "Zone \(index + 1)"
        }

        var markups: [MarkupRecord] = []
        markups.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let n = index + 1
            let measurement = MeasurementResult(values: [
                .count: .count(1),
                .planArea: .area(Decimal(n) / 100), .netArea: .area(Decimal(n) / 100),
                .planLength: .length(Decimal(n) / 1000)
            ])
            markups.append(
                MarkupRecord(
                    id: MarkupID(deterministicUUID(index)),
                    documentID: documentID,
                    pageID: pageIDs[index % pageCount],
                    kind: .measurement,
                    tool: .area,
                    subject: subjects[index % subjects.count],
                    label: labels[index % labels.count],
                    comment: "",
                    author: index % 2 == 0 ? "Ada" : "Grace",
                    status: statuses[index % statuses.count],
                    zoneID: zoneIDs[index % zoneCount],
                    measurement: measurement,
                    customValues: [
                        costColumnID: .currency(amount: Decimal(n) / 4, code: currencyCode)
                    ],
                    createdAt: epoch.addingTimeInterval(Double(index)),
                    modifiedAt: epoch.addingTimeInterval(Double(index) + 0.5)
                )
            )
        }
        return try LedgerStore(markups: markups, columns: columns, names: names)
    }

    // MARK: - Closed-form oracles

    /// `1 + 2 + ... + n`, by Gauss. Never by iteration, so it cannot share a bug with the summer.
    static func triangular(_ n: Int) -> Decimal {
        Decimal(n) * Decimal(n + 1) / 2
    }

    static func expectedPlanArea(rowCount: Int) -> Decimal { triangular(rowCount) / 100 }
    static func expectedPlanLength(rowCount: Int) -> Decimal { triangular(rowCount) / 1000 }
    static func expectedCost(rowCount: Int) -> Decimal { triangular(rowCount) / 4 }
    static func expectedDoubled(rowCount: Int) -> Decimal { triangular(rowCount) / 50 }
    static func expectedCount(rowCount: Int) -> Decimal { Decimal(rowCount) }

    // MARK: - Plans and specs

    static var quantityColumns: [ColumnID] {
        [columnID(.count), columnID(.planArea), columnID(.planLength), costColumnID, doubledColumnID]
    }

    static var plan: LedgerAggregationPlan {
        var plan = LedgerAggregationPlan()
        for column in quantityColumns {
            plan.add(AggregateKey(column: column, function: .sum))
            plan.add(AggregateKey(column: column, function: .count))
        }
        return plan
    }

    static func groupings(_ columns: LedgerColumnSet) -> [[LedgerGroupingField]] {
        let subject = LedgerGroupingField(column: columnID(.subject))
        let label = LedgerGroupingField(column: columnID(.label))
        let page = LedgerGroupingField(column: columnID(.pageLabel))
        let zone = LedgerGroupingField(column: columnID(.projectZone))
        let status = LedgerGroupingField(column: columnID(.status))
        return [
            [subject],
            [page],
            [status, subject],
            [zone, label, subject],
            [subject, page, status, label]
        ]
    }

    /// An independent summation: plain `Decimal` `+=`, not ``DecimalSummation``, over cells read
    /// one at a time. Used as the oracle for filtered subtotals, where no closed form exists.
    static func referenceSum(
        _ store: LedgerStore,
        column: ColumnID,
        rows: some Sequence<Int>
    ) -> Decimal {
        var total = Decimal.zero
        for index in rows {
            guard let quantity = store.value(at: index, column: column).quantity else { continue }
            total += quantity.value
        }
        return total
    }
}

/// Unwraps an aggregate that must be a plain number, failing loudly when it is a refusal.
func exactDecimal(_ value: AggregateValue?, _ comment: Comment? = nil) throws -> Decimal {
    let unwrapped = try #require(value, comment)
    let decimal = try #require(unwrapped.decimal, "expected a number, got \(unwrapped)")
    return decimal
}

extension LedgerGroupTree {

    /// Depth-first walk, parents before children — a test helper. It was public API that
    /// nothing shipping called; it moved here in U-067.
    func forEachNode(_ body: (LedgerGroupNode) throws -> Void) rethrows {
        func visit(_ node: LedgerGroupNode) throws {
            try body(node)
            for child in node.children { try visit(child) }
        }
        for root in roots { try visit(root) }
    }
}
