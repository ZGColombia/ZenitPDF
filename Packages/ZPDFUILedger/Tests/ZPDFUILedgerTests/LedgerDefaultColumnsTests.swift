import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Pins the mockup's default column arrangement and the
/// Value/Unit display columns that make it possible without touching the frozen ledger
/// contract: `Page · Type · Label · Subject · Comment · Value · Unit`.
@Suite("Ledger default columns", .ledgerTierSerialised)
struct LedgerDefaultColumnsTests {

    // MARK: Arrangement

    @Test("The default arrangement leads with the mockup's seven, everything else hidden after")
    func defaultArrangement() {
        let arranged = LedgerDefaultColumns.arranged(LedgerFixtures.columns)

        let visibleIDs = arranged.filter(\.visible).map(\.id)
        // The fixture set has no pageLabel/icon/comment column definitions, so the leading
        // band is whatever of the seven exists, in mockup order, plus the two display
        // columns — followed by the fixture's own custom columns, which keep their state.
        #expect(visibleIDs.starts(with: [.label, .subject]))
        #expect(visibleIDs.contains(LedgerDefaultColumns.valueColumnID))
        #expect(visibleIDs.contains(LedgerDefaultColumns.unitColumnID))

        // Standard quantity columns leave the default view; nothing is lost, only hidden.
        let hidden = arranged.filter { !$0.visible }.map(\.id)
        for id in [LedgerColumnID.planLength, .planArea, .count, .totalCost] {
            #expect(hidden.contains(id), "\(id) should start hidden")
        }
        #expect(arranged.count == LedgerFixtures.columns.count + 2)

        // User-created columns keep their own visibility.
        #expect(arranged.first { $0.id == LedgerFixtures.wasteFactor }?.visible == true)

        // Nothing stays pinned: the mockup has no frozen band, and a pinned column would
        // jump the Page column out of first place.
        #expect(arranged.allSatisfy { !$0.pinned })
    }

    @Test("With the full standard set the default order is exactly the mockup's, plus Perimeter")
    func fullStandardSetOrder() {
        let standard = LedgerColumnID.standardColumns.map {
            LedgerColumn(id: $0, title: $0.rawValue, kind: .text, width: 100)
        }
        let visible = LedgerDefaultColumns.arranged(standard).filter(\.visible)
        // Perimeter joins the default set right after Value/Unit.
        #expect(visible.map(\.id) == [
            .pageLabel, .icon, .label, .subject, .comment,
            LedgerDefaultColumns.valueColumnID, LedgerDefaultColumns.unitColumnID,
            .perimeter
        ])
        // Everything fits the minimum window width: Value, Unit and Perimeter are on screen.
        #expect(visible.reduce(0.0) { $0 + $1.width } <= 1_000)
    }

    @Test("Perimeter keeps its projection identity: dimension, sum and trailing digits")
    func perimeterColumnShape() {
        let projection = [
            LedgerColumn(
                id: .perimeter,
                title: "Perimeter",
                kind: .number,
                dimension: .init(lengthPower: 1),
                width: 96,
                visible: false,
                alignment: .leading,
                aggregate: .sum,
                displayUnitSymbol: "m"
            )
        ]
        let arranged = LedgerDefaultColumns.arranged(projection)
        let perimeter = arranged.first { $0.id == .perimeter }
        #expect(perimeter?.visible == true)
        #expect(perimeter?.alignment == .trailing)
        #expect(perimeter?.aggregate == .sum)
        #expect(perimeter?.displayUnitSymbol == "m")
        #expect(perimeter.map(LedgerColumnLayout.usesMonospacedDigits) == true)
        // It sits directly after the two display columns.
        let ids = arranged.filter(\.visible).map(\.id)
        let unitIndex = ids.firstIndex(of: LedgerDefaultColumns.unitColumnID)
        #expect(unitIndex.map { ids.indices.contains($0 + 1) && ids[$0 + 1] == .perimeter } == true)
    }

    @Test("Value is trailing with monospaced digits, Unit is narrow")
    func displayColumnShape() {
        let value = LedgerDefaultColumns.valueColumn()
        #expect(value.alignment == .trailing)
        #expect(LedgerColumnLayout.usesMonospacedDigits(value))
        let unit = LedgerDefaultColumns.unitColumn()
        #expect(unit.width <= 60)
        #expect(!LedgerColumnLayout.usesMonospacedDigits(unit))
    }

    // MARK: Migration

    @Test("A saved layout keeps working: only the default changed")
    func savedLayoutsMigrate() {
        // A layout captured before the display columns existed…
        let layout = LedgerColumnLayout.capturing(LedgerFixtures.columns, name: "Estimator")
        // …applied to the new default arrangement restores its order and keeps the
        // display columns rather than dropping them.
        let restored = layout.applied(to: LedgerDefaultColumns.arranged(LedgerFixtures.columns))
        #expect(restored.count == LedgerFixtures.columns.count + 2)
        #expect(Array(restored.map(\.id).prefix(3)) == Array(LedgerFixtures.columns.map(\.id).prefix(3)))
        #expect(restored.contains { $0.id == LedgerDefaultColumns.valueColumnID })
        #expect(restored.contains { $0.id == LedgerDefaultColumns.unitColumnID })
    }

    // MARK: Row rendering

    @Test("The Value and Unit cells split the primary quantity the core formatted")
    func valueAndUnitTexts() throws {
        var row = try #require(LedgerFixtures.rows.first)

        row.measurementKind = .length
        #expect(LedgerDefaultColumns.valueText(for: row) == "12")
        #expect(LedgerDefaultColumns.unitText(for: row) == "m")

        row.measurementKind = .area
        #expect(LedgerDefaultColumns.valueText(for: row) == "40")
        #expect(LedgerDefaultColumns.unitText(for: row) == "m²")

        row.measurementKind = .count
        #expect(LedgerDefaultColumns.valueText(for: row) == "2")
        #expect(LedgerDefaultColumns.unitText(for: row) == "")

        // A rectangle area is an area; a dimension is a length.
        row.measurementKind = .rectangleArea
        #expect(LedgerDefaultColumns.unitText(for: row) == "m²")
        row.measurementKind = .dimension
        #expect(LedgerDefaultColumns.unitText(for: row) == "m")
    }

    @Test("A non-measurement row shows nothing rather than a guess")
    func plainMarkupHasNoValue() throws {
        var row = try #require(LedgerFixtures.rows.first)
        row.measurementKind = nil
        #expect(LedgerDefaultColumns.valueText(for: row) == "")
        #expect(LedgerDefaultColumns.unitText(for: row) == "")
    }

    @Test("The Type cell falls back to the tool's name when the core supplied no glyph text")
    func typeFallsBackToTheToolName() throws {
        var row = try #require(LedgerFixtures.rows.first)
        row.measurementKind = .length
        row.displayValues[.icon] = nil
        #expect(LedgerDefaultColumns.displayText(for: row, columnID: .icon)
            == MeasurementKind.length.displayName)
        row.displayValues[.icon] = "▭"
        #expect(LedgerDefaultColumns.displayText(for: row, columnID: .icon) == "▭")
    }

    @Test("Splitting a formatted quantity is conservative")
    func splitUnit() {
        #expect(LedgerDefaultColumns.splitUnit("14.72 m") == ("14.72", "m"))
        #expect(LedgerDefaultColumns.splitUnit("21.34 m²") == ("21.34", "m²"))
        #expect(LedgerDefaultColumns.splitUnit("1 240,5 m²") == ("1 240,5", "m²"))
        #expect(LedgerDefaultColumns.splitUnit("5") == ("5", ""))
        #expect(LedgerDefaultColumns.splitUnit("4000 SEK") == ("4000", "SEK"))
        // No digits before the token, or digits inside it: pass through untouched.
        #expect(LedgerDefaultColumns.splitUnit("1 240") == ("1 240", ""))
        #expect(LedgerDefaultColumns.splitUnit("Mixed units") == ("Mixed units", ""))
        #expect(LedgerDefaultColumns.splitUnit("") == ("", ""))
    }
}
