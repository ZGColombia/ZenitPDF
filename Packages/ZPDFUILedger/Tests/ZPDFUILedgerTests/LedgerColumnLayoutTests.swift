import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Asserts the column system: order, width, visibility, pinning, alignment and saved layouts.
@Suite("Ledger column layouts", .ledgerTierSerialised)
struct LedgerColumnLayoutTests {

    @Test("Pinning moves a column into the leading band without losing relative order")
    func pinnedFirst() {
        var columns = LedgerFixtures.columns
        columns[3].pinned = true
        columns[0].pinned = true
        let ordered = LedgerColumnLayout.pinnedFirst(columns)
        #expect(ordered.prefix(2).map(\.id) == [.subject, .trade])
        #expect(ordered.count == columns.count)
        #expect(Set(ordered.map(\.id)) == Set(columns.map(\.id)))
    }

    @Test("Numbers use tabular digits, text does not")
    func tabularDigits() {
        let area = LedgerFixtures.columns.first { $0.id == .planArea }!
        let subject = LedgerFixtures.columns.first { $0.id == .subject }!

        #expect(LedgerColumnLayout.usesMonospacedDigits(area))
        #expect(!LedgerColumnLayout.usesMonospacedDigits(subject))
    }

    @Test("A layout restores order, width, visibility, pinning and alignment")
    func layoutRoundTrip() {
        var columns = LedgerFixtures.columns
        columns[0].width = 240
        columns[1].visible = false
        columns[2].pinned = true
        columns[5].alignment = .center

        let layout = LedgerColumnLayout.capturing(columns, name: "Estimator")
        let scrambled = LedgerFixtures.columns.reversed().map { $0 }
        let restored = layout.applied(to: scrambled)

        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        #expect(byID[.subject]?.width == 240)
        #expect(byID[.label]?.visible == false)
        #expect(byID[.projectZone]?.pinned == true)
        #expect(byID[.count]?.alignment == .center)
        #expect(restored.first?.id == .projectZone, "The pinned column leads after the layout is applied")
    }

    @Test("A layout ignores columns it does not know and keeps columns it did not mention")
    func layoutToleratesSchemaDrift() {
        let layout = LedgerColumnLayout.capturing(
            Array(LedgerFixtures.columns.prefix(3)),
            name: "Partial"
        )
        let restored = layout.applied(to: LedgerFixtures.columns)
        #expect(restored.count == LedgerFixtures.columns.count)
        #expect(Set(restored.map(\.id)) == Set(LedgerFixtures.columns.map(\.id)))

        let extra = LedgerColumn(id: .custom("unknown"), title: "Unknown", kind: .text, width: 60)
        let layoutWithGhost = LedgerColumnLayout.capturing(
            LedgerFixtures.columns + [extra],
            name: "Ghost"
        )
        let restoredWithoutGhost = layoutWithGhost.applied(to: LedgerFixtures.columns)
        #expect(!restoredWithoutGhost.contains { $0.id == extra.id })
    }

    @Test("The layout store saves, replaces by name, removes and survives a JSON round trip")
    func layoutStore() throws {
        var store = LedgerColumnLayoutStore()
        let saved = store.save(LedgerFixtures.columns, name: "Takeoff")
        let first = try #require(saved)
        #expect(store.activeLayoutID == first.id)

        var widened = LedgerFixtures.columns
        widened[0].width = 300
        let savedAgain = store.save(widened, name: "Takeoff")
        let replaced = try #require(savedAgain)
        #expect(store.layouts.count == 1, "Saving under an existing name replaces it")
        #expect(store.layout(named: "TAKEOFF")?.states.first?.width == 300)
        #expect(store.activeLayoutID == replaced.id)

        let savedReview = store.save(LedgerFixtures.columns, name: "Review")
        let review = try #require(savedReview)
        #expect(store.layouts.map(\.name) == ["Review", "Takeoff"])

        let data = try store.encoded()
        let restored = try LedgerColumnLayoutStore.decoded(from: data)
        #expect(restored.layouts.count == 2)
        #expect(restored.activeLayoutID == store.activeLayoutID)

        store.remove(id: replaced.id)
        #expect(store.layouts.map(\.name) == ["Review"])
        #expect(store.activeLayoutID == review.id)

        store.remove(id: review.id)
        #expect(store.layouts.isEmpty)
        #expect(store.activeLayoutID == nil)
    }

    @Test("An empty layout name is refused rather than creating a nameless layout")
    func emptyNameIsRefused() {
        var store = LedgerColumnLayoutStore()
        let refused = store.save(LedgerFixtures.columns, name: "   ")
        #expect(refused == nil)
        #expect(store.layouts.isEmpty)
    }
}
