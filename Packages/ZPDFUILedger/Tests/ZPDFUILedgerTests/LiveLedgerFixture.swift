import Foundation
import ZPDFContracts
import ZPDFQuantityLedger

/// The six rows of ``LedgerFixtures`` as a real ledger store in the aggregation core.
///
/// Tests that used to run this package's own filter evaluator (removed as a dead duplicate in
/// loop iteration 1, R-126) run the core's ``LedgerFilterEvaluator`` over this store instead:
/// the evaluator the application filters with. Same subjects, labels, zones, trades, approval
/// states, lengths and areas as the view-model fixture, so every expected count carries over.
///
/// This file imports only the core modules, so none of its names meet the presentation
/// layer's types of the same name.
enum LiveLedgerFixture {

    private static func uuid(_ index: UInt8) -> UUID {
        UUID(uuid: (0x7E, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x2F, index))
    }

    static let subject = LedgerIdentifiers.columnID(for: .subject)
    static let label = LedgerIdentifiers.columnID(for: .label)
    static let zone = ColumnID(uuid(1))
    static let trade = ColumnID(uuid(2))
    static let approval = ColumnID(uuid(3))
    static let planLength = ColumnID(uuid(4))
    static let planArea = ColumnID(uuid(5))
    static let created = ColumnID(uuid(6))

    static let draft = ChoiceOptionID(uuid(20))
    static let approved = ChoiceOptionID(uuid(21))

    static func columns() throws -> LedgerColumnSet {
        try LedgerColumnSet(columns: [
            LedgerColumnDefinition(id: subject, key: "subject", title: "Subject", kind: .text, standard: .subject, order: 0),
            LedgerColumnDefinition(id: label, key: "label", title: "Label", kind: .text, standard: .label, order: 1),
            LedgerColumnDefinition(id: zone, key: "zone", title: "Project Zone", kind: .text, order: 2),
            LedgerColumnDefinition(id: trade, key: "trade", title: "Trade", kind: .text, order: 3),
            LedgerColumnDefinition(
                id: approval, key: "approval", title: "Status", kind: .choice,
                choices: [ChoiceOption(id: draft, value: "draft", order: 0), ChoiceOption(id: approved, value: "approved", order: 1)],
                order: 4
            ),
            LedgerColumnDefinition(id: planLength, key: "planLength", title: "Plan Length", kind: .number, dimension: .length, order: 5),
            LedgerColumnDefinition(id: planArea, key: "planArea", title: "Plan Area", kind: .number, dimension: .area, order: 6),
            LedgerColumnDefinition(id: created, key: "created", title: "Created", kind: .date, order: 7)
        ])
    }

    /// One row: subject, label, zone, trade, approved?, length (m), area (m²).
    private static let rows: [(String, String, String, String, Bool, Decimal, Decimal)] = [
        ("Concrete Slab", "S-01", "Zone A", "Concrete", true, 12, 40),
        ("Concrete Slab", "S-02", "Zone A", "Concrete", false, 8, 25),
        ("Interior Partition", "P-01", "Zone A", "Drywall", true, 20, 60),
        ("Interior Partition", "P-02", "Zone B", "Drywall", false, 5, 15),
        ("Curtain Wall", "C-01", "Zone B", "Glazing", true, 30, 90),
        ("Curtain Wall", "C-02", "Zone B", "Glazing", true, 3, 10)
    ]

    /// The store, optionally with one date on every row in the Created column.
    static func store(created date: Date? = nil) throws -> LedgerStore {
        let epoch = Date(timeIntervalSince1970: 1_788_000_000)
        let markups = rows.enumerated().map { index, row in
            var values: [ColumnID: LedgerCellValue] = [
                zone: .text(row.2),
                trade: .text(row.3),
                approval: .choice(row.4 ? approved : draft),
                planLength: .number(DecimalQuantity(value: row.5, dimension: .length)),
                planArea: .number(DecimalQuantity(value: row.6, dimension: .area))
            ]
            if let date { values[created] = .date(date) }
            return MarkupRecord(
                id: MarkupID(uuid(UInt8(100 + index))),
                documentID: DocumentID(uuid(90)),
                pageID: PageID(uuid(91)),
                kind: .measurement,
                subject: row.0,
                label: row.1,
                customValues: values,
                createdAt: epoch,
                modifiedAt: epoch
            )
        }
        return try LedgerStore(markups: markups, columns: columns())
    }

    /// How many rows of the store a filter keeps.
    static func count(_ node: LedgerFilterNode, in store: LedgerStore) -> Int {
        LedgerFilterEvaluator(store: store).filter(Array(0..<store.rowCount), with: node).count
    }

    static func rule(_ column: ColumnID, _ op: LedgerFilterOperator, _ value: LedgerFilterValue = .none) -> LedgerFilterNode {
        .rule(LedgerFilterRule(column: column, op: op, value: value))
    }
}
