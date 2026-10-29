import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// Not an acceptance test — a probe that attributes the cost of one aggregation pass to its
/// parts, so an optimisation is aimed rather than guessed.
@Suite("Cost attribution probe", .serialized)
struct ProfileProbe {

    static func time(_ label: String, _ body: () -> Void) {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            best = min(best, elapsed)
        }
        print(String(format: "probe  %-34@  best=%.1f ms", label as NSString, best))
    }

    @Test("Attribute the cost of one 100 000-row column pass")
    func attribute() throws {
        let store = try BigLedger.store()
        let area = try #require(store.columns.column(id: SyntheticLedger.columnID(.planArea)))
        let cost = try #require(store.columns.column(id: SyntheticLedger.costColumnID))
        let subject = try #require(store.columns.column(id: SyntheticLedger.columnID(.subject)))
        let n = store.rowCount

        var sink = 0
        Self.time("record field access only") {
            for index in 0..<n { sink &+= store.record(at: index).subject.utf8.count }
        }
        Self.time("value() measurement column") {
            for index in 0..<n where store.value(at: index, definition: area).quantity != nil {
                sink &+= 1
            }
        }
        Self.time("value() custom currency column") {
            for index in 0..<n where store.value(at: index, definition: cost).quantity != nil {
                sink &+= 1
            }
        }
        Self.time("value() text column") {
            for index in 0..<n where store.value(at: index, definition: subject) == .value(.empty) {
                sink &+= 1
            }
        }
        var decimals: [Decimal] = (0..<n).map { Decimal($0) / 100 }
        Self.time("DecimalSummation.sum over 100 000") {
            sink &+= ((try? DecimalSummation.sum(decimals)) != nil) ? 1 : 0
        }
        Self.time("accumulator over 100 000 cells") {
            var accumulator = AggregateAccumulator()
            for index in 0..<n { accumulator.add(store.value(at: index, definition: area)) }
            sink &+= accumulator.rowCount
        }
        decimals.removeAll()
        #expect(sink > 0)
    }
}
