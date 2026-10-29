import Foundation
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Deterministic rows and columns the ledger tests share.
///
/// The fixtures deliberately include one column whose rows carry two different dimensions,
/// because "never sum incompatible units" is the rule most worth a regression test.
enum LedgerFixtures {

    static func id(_ index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = UInt8(truncatingIfNeeded: index)
        bytes[14] = UInt8(truncatingIfNeeded: index >> 8)
        bytes[0] = 0x7E
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static let statusChoices: [LedgerChoiceOption] = [
        LedgerChoiceOption(id: id(900), value: "draft", title: "Draft", colorRGBA: ColorRGBA.Zenit.Dark.warning, order: 0),
        LedgerChoiceOption(id: id(901), value: "approved", title: "Approved", colorRGBA: ColorRGBA.Zenit.Dark.green, order: 1)
    ]

    /// Columns covering text, choice, count, length, area, currency and a mixed column.
    static let columns: [LedgerColumn] = [
        LedgerColumn(id: .subject, title: "Subject", kind: .text, width: 160, alignment: .leading, isEditable: true),
        LedgerColumn(id: .label, title: "Label", kind: .text, width: 100, alignment: .leading, isEditable: true),
        LedgerColumn(id: .projectZone, title: "Project Zone", kind: .text, width: 110, alignment: .leading),
        LedgerColumn(id: .trade, title: "Trade", kind: .text, width: 100, alignment: .leading),
        LedgerColumn(
            id: .status, title: "Status", kind: .choice, width: 96,
            alignment: .leading, isEditable: true, choices: statusChoices
        ),
        LedgerColumn(
            id: .count, title: "Count", kind: .number, dimension: .count, width: 60,
            alignment: .trailing, aggregate: .sum
        ),
        LedgerColumn(
            id: .planLength, title: "Plan Length", kind: .number, dimension: .length, width: 90,
            alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m"
        ),
        LedgerColumn(
            id: .planArea, title: "Plan Area", kind: .number, dimension: .area, width: 90,
            alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m²"
        ),
        LedgerColumn(
            id: .totalCost, title: "Total Cost", kind: .currency, dimension: .currency("SEK"),
            width: 100, alignment: .trailing, aggregate: .sum, displayUnitSymbol: "SEK"
        ),
        LedgerColumn(
            id: wasteFactor, title: "Waste Factor", kind: .number, width: 90,
            alignment: .trailing, isEditable: true, aggregate: .average
        ),
        LedgerColumn(
            id: mixed, title: "Mixed Metric", kind: .number, width: 90,
            alignment: .trailing, aggregate: .sum
        )
    ]

    static let wasteFactor = LedgerColumnID.custom("wasteFactor")
    static let mixed = LedgerColumnID.custom("mixedMetric")

    /// Six rows in two zones and two trades.
    ///
    /// `mixedMetric` holds a length on some rows and an area on others, which must make the
    /// column refuse to total rather than add metres to square metres.
    static let rows: [LedgerRow] = [
        row(0, subject: "Concrete Slab", label: "S-01", zone: "Zone A", trade: "Concrete",
            status: "approved", count: 2, length: 12, area: 40, cost: 4_000, waste: Decimal(string: "0.05")!,
            mixedDimension: .length, mixedValue: 3),
        row(1, subject: "Concrete Slab", label: "S-02", zone: "Zone A", trade: "Concrete",
            status: "draft", count: 3, length: 8, area: 25, cost: 2_500, waste: Decimal(string: "0.10")!,
            mixedDimension: .length, mixedValue: 4),
        row(2, subject: "Interior Partition", label: "P-01", zone: "Zone A", trade: "Drywall",
            status: "approved", count: 1, length: 20, area: 60, cost: 6_000, waste: Decimal(string: "0.15")!,
            mixedDimension: .area, mixedValue: 5),
        row(3, subject: "Interior Partition", label: "P-02", zone: "Zone B", trade: "Drywall",
            status: "draft", count: 4, length: 5, area: 15, cost: 1_500, waste: Decimal(string: "0.20")!,
            mixedDimension: .area, mixedValue: 6),
        row(4, subject: "Curtain Wall", label: "C-01", zone: "Zone B", trade: "Glazing",
            status: "approved", count: 2, length: 30, area: 90, cost: 9_000, waste: Decimal(string: "0.02")!,
            mixedDimension: .length, mixedValue: 7),
        row(5, subject: "Curtain Wall", label: "C-02", zone: "Zone B", trade: "Glazing",
            status: "approved", count: 5, length: 3, area: 10, cost: 1_000, waste: Decimal(string: "0.08")!,
            mixedDimension: .area, mixedValue: 8)
    ]

    /// Rows whose `mixedMetric` values all share the length dimension.
    static var compatibleRows: [LedgerRow] {
        rows.map { original in
            var updated = original
            if let quantity = original.quantity(mixed) {
                updated.values[mixed] = .quantity(DecimalQuantity(value: quantity.value, dimension: .length))
            }
            return updated
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func row(
        _ index: Int,
        subject: String,
        label: String,
        zone: String,
        trade: String,
        status: String,
        count: Int,
        length: Decimal,
        area: Decimal,
        cost: Decimal,
        waste: Decimal,
        mixedDimension: QuantityDimension,
        mixedValue: Decimal
    ) -> LedgerRow {
        let values: [LedgerColumnID: LedgerCellValue] = [
            .subject: .text(subject),
            .label: .text(label),
            .projectZone: .text(zone),
            .trade: .text(trade),
            .status: .choice(status),
            .pageLabel: .text("A-10\(index)"),
            .pageIndex: .number(Decimal(index)),
            .count: .quantity(.count(Decimal(count))),
            .planLength: .quantity(.metres(length)),
            .planArea: .quantity(.squareMetres(area)),
            .totalCost: .currency(amount: cost, code: "SEK"),
            wasteFactor: .number(waste),
            mixed: .quantity(DecimalQuantity(value: mixedValue, dimension: mixedDimension))
        ]
        let displayValues: [LedgerColumnID: String] = [
            .subject: subject,
            .label: label,
            .projectZone: zone,
            .trade: trade,
            .status: statusChoices.first { $0.value == status }?.title ?? status,
            .pageLabel: "A-10\(index)",
            .pageIndex: "\(index)",
            .count: "\(count)",
            .planLength: "\(length) m",
            .planArea: "\(area) m²",
            .totalCost: "\(cost) SEK",
            wasteFactor: "\(waste)",
            mixed: "\(mixedValue)"
        ]
        return LedgerRow(
            markupID: id(index),
            values: values,
            displayValues: displayValues,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            kind: .measurement,
            measurementKind: .area
        )
    }

    static func rule(
        _ column: LedgerColumnID,
        _ comparison: LedgerFilterComparison,
        _ operand: LedgerFilterOperand = .none,
        index: Int = 0
    ) -> LedgerFilterRule {
        LedgerFilterRule(id: id(500 + index), column: column, comparison: comparison, operand: operand)
    }

    static func group(
        _ conjunction: LedgerFilterConjunction,
        rules: [LedgerFilterRule] = [],
        groups: [LedgerFilterGroup] = [],
        negated: Bool = false,
        index: Int = 0
    ) -> LedgerFilterGroup {
        LedgerFilterGroup(
            id: id(600 + index),
            conjunction: conjunction,
            rules: rules,
            groups: groups,
            isNegated: negated
        )
    }
}
