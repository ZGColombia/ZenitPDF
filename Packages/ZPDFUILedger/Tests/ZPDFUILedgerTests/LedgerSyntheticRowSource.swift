import Foundation
import ZPDFUILedger
import ZPDFUIPresentation

/// A deterministic, lazily generated ledger of arbitrary size, for the table benchmarks.
///
/// Nothing is stored up front: row `n` is synthesised the first time it is asked for, and
/// a small bounded cache keeps the rows the user is currently looking at. A 100 000 row
/// ledger therefore costs a few kilobytes until it is scrolled, which is exactly the
/// contract the real database-backed source has to honour.
///
/// It used to ship in the library "so previews, the design audit and the benchmark all
/// exercise the same code path"; only the benchmark tests ever did, so it moved into the test
/// target in loop iteration 1 (R-129) and the shipping library no longer carries it.
@MainActor
final class LedgerSyntheticRowSource: LedgerRowProviding {

    /// Columns used by the synthetic ledger, in display order.
    let columns: [LedgerColumn]
    /// Number of rows the source can produce.
    let count: Int
    /// Upper bound on cached rows. Older entries are dropped first.
    let cacheLimit: Int

    /// Number of rows synthesised since the last ``resetStatistics()``.
    private(set) var synthesisCount: Int = 0
    /// Number of cache hits since the last ``resetStatistics()``.
    private(set) var cacheHitCount: Int = 0

    private var cache: [Int: LedgerRow] = [:]
    private var insertionOrder: [Int] = []
    private let seed: UInt64

    private static let subjects = [
        "Concrete Slab", "Interior Partition", "Curtain Wall", "Steel Beam",
        "Ceiling Grid", "Floor Finish", "Roof Membrane", "Duct Run"
    ]
    private static let zones = ["Zone A", "Zone B", "Zone C", "Zone D", "Zone E"]
    private static let statuses = ["Draft", "In Review", "Approved", "Rejected"]
    private static let trades = ["Concrete", "Drywall", "Glazing", "Steel", "Finishes"]

    /// Creates a synthetic source.
    ///
    /// - Parameters:
    ///   - count: Number of rows. The benchmark uses 100 000.
    ///   - columns: Column set, defaulting to ``LedgerSyntheticRowSource/benchmarkColumns``.
    ///   - cacheLimit: How many synthesised rows stay resident.
    ///   - seed: Makes the generated values reproducible.
    init(
        count: Int,
        columns: [LedgerColumn] = LedgerSyntheticRowSource.benchmarkColumns,
        cacheLimit: Int = 4096,
        seed: UInt64 = 0x5E01_7ED6_E200_0001
    ) {
        self.count = max(0, count)
        self.columns = columns
        self.cacheLimit = max(16, cacheLimit)
        self.seed = seed
    }

    // MARK: LedgerRowProviding

    var ledgerColumns: [LedgerColumn] { columns }
    var ledgerRowCount: Int { count }

    func ledgerRow(at index: Int) -> LedgerRow? {
        guard index >= 0, index < count else { return nil }
        if let cached = cache[index] {
            cacheHitCount &+= 1
            return cached
        }
        let row = makeRow(index: index)
        synthesisCount &+= 1
        cache[index] = row
        insertionOrder.append(index)
        if insertionOrder.count > cacheLimit {
            let evictCount = insertionOrder.count - cacheLimit
            for evicted in insertionOrder.prefix(evictCount) {
                cache.removeValue(forKey: evicted)
            }
            insertionOrder.removeFirst(evictCount)
        }
        return row
    }

    /// Empties the cache so a benchmark can measure cold fetches.
    func clearCache() {
        cache.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
    }

    /// Resets the synthesis and cache-hit counters.
    func resetStatistics() {
        synthesisCount = 0
        cacheHitCount = 0
    }

    // MARK: Generation

    /// The column set the benchmark uses.
    static let benchmarkColumns: [LedgerColumn] = [
        LedgerColumn(id: .icon, title: NSLocalizedString("Type", comment: "Ledger column header"),
                     kind: .text, width: 28, pinned: true, alignment: .center),
        LedgerColumn(id: .subject, title: NSLocalizedString("Subject", comment: "Ledger column header"),
                     kind: .text, width: 180, pinned: true, alignment: .leading, isEditable: true),
        LedgerColumn(id: .label, title: NSLocalizedString("Label", comment: "Ledger column header"),
                     kind: .text, width: 120, alignment: .leading, isEditable: true),
        LedgerColumn(id: .pageLabel, title: NSLocalizedString("Page", comment: "Ledger column header"),
                     kind: .text, width: 74, alignment: .leading),
        LedgerColumn(id: .projectZone, title: NSLocalizedString("Project Zone", comment: "Ledger column header"),
                     kind: .text, width: 110, alignment: .leading),
        LedgerColumn(id: .trade, title: NSLocalizedString("Trade", comment: "Ledger column header"),
                     kind: .text, width: 100, alignment: .leading),
        LedgerColumn(id: .status, title: NSLocalizedString("Status", comment: "Ledger column header"),
                     kind: .choice, width: 96, alignment: .leading),
        LedgerColumn(id: .count, title: NSLocalizedString("Count", comment: "Ledger column header"),
                     kind: .number, dimension: .count, width: 68, alignment: .trailing,
                     aggregate: .sum),
        LedgerColumn(id: .planLength, title: NSLocalizedString("Plan Length", comment: "Ledger column header"),
                     kind: .number, dimension: .length, width: 96, alignment: .trailing,
                     aggregate: .sum, displayUnitSymbol: "m"),
        LedgerColumn(id: .planArea, title: NSLocalizedString("Plan Area", comment: "Ledger column header"),
                     kind: .number, dimension: .area, width: 96, alignment: .trailing,
                     aggregate: .sum, displayUnitSymbol: "m²"),
        LedgerColumn(id: .totalCost, title: NSLocalizedString("Total Cost", comment: "Ledger column header"),
                     kind: .currency, dimension: .currency("SEK"), width: 110, alignment: .trailing,
                     aggregate: .sum, displayUnitSymbol: "SEK")
    ]

    /// Synthesises one row from its index. Pure, so the same index always yields the same row.
    private func makeRow(index: Int) -> LedgerRow {
        var state = seed &+ (UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
        let subject = Self.subjects[Int(Self.next(&state) % UInt64(Self.subjects.count))]
        let zone = Self.zones[Int(Self.next(&state) % UInt64(Self.zones.count))]
        let status = Self.statuses[Int(Self.next(&state) % UInt64(Self.statuses.count))]
        let trade = Self.trades[Int(Self.next(&state) % UInt64(Self.trades.count))]
        let pageIndex = Int(Self.next(&state) % 240)
        let countValue = Decimal(1 + Int(Self.next(&state) % 12))
        let lengthHundredths = Int(Self.next(&state) % 90_000)
        let areaHundredths = Int(Self.next(&state) % 400_000)
        let costHundredths = Int(Self.next(&state) % 9_000_000)
        let lengthValue = Decimal(lengthHundredths) / 100
        let areaValue = Decimal(areaHundredths) / 100
        let costValue = Decimal(costHundredths) / 100
        let label = "L-" + Self.padded(index, width: 6)
        let pageLabel = "A-\(100 + pageIndex)"

        let values: [LedgerColumnID: LedgerCellValue] = [
            .subject: .text(subject),
            .label: .text(label),
            .pageLabel: .text(pageLabel),
            .pageIndex: .number(Decimal(pageIndex)),
            .projectZone: .text(zone),
            .trade: .text(trade),
            .status: .choice(status),
            .count: .quantity(.count(countValue)),
            .planLength: .quantity(.metres(lengthValue)),
            .planArea: .quantity(.squareMetres(areaValue)),
            .totalCost: .currency(amount: costValue, code: "SEK")
        ]
        let displayValues: [LedgerColumnID: String] = [
            .subject: subject,
            .label: label,
            .pageLabel: pageLabel,
            .pageIndex: "\(pageIndex)",
            .projectZone: zone,
            .trade: trade,
            .status: status,
            .count: "\(countValue)",
            .planLength: Self.hundredths(lengthHundredths) + " m",
            .planArea: Self.hundredths(areaHundredths) + " m²",
            .totalCost: Self.hundredths(costHundredths) + " SEK"
        ]
        return LedgerRow(
            markupID: Self.deterministicID(index: index),
            values: values,
            displayValues: displayValues,
            colorRGBA: Self.colors[index % Self.colors.count],
            kind: .measurement,
            measurementKind: index.isMultiple(of: 3) ? .area : .length
        )
    }

    /// Renders a hundredths value as fixed two-decimal text.
    ///
    /// The synthetic source deliberately avoids `NumberFormatter`: the benchmark is meant
    /// to measure the table's fetch path, not Foundation's formatter, and the real source
    /// hands the table strings the database already produced.
    private static func hundredths(_ value: Int) -> String {
        let whole = value / 100
        let fraction = value % 100
        return "\(whole)." + (fraction < 10 ? "0\(fraction)" : "\(fraction)")
    }

    /// Zero-pads an index without going through a format string.
    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    private static let colors: [ColorRGBA] = [
        ColorRGBA.Zenit.Dark.cyan,
        ColorRGBA.Zenit.Dark.blue,
        ColorRGBA.Zenit.Dark.green,
        ColorRGBA.Zenit.Dark.warning
    ]

    /// A stable UUID for a row index, so selection survives a reload.
    static func deterministicID(index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(bitPattern: Int64(index))
        for offset in 0..<8 {
            bytes[15 - offset] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        bytes[0] = 0x5E
        bytes[1] = 0x01
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// SplitMix64, so generated values do not depend on the platform's RNG.
    private static func next(_ state: inout UInt64) -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
