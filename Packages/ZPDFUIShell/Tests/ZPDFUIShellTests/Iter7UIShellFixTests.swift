import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-7 "uishell" list.
// Every test names its item and
// states what the old code produced. No window is built.

@MainActor
@Suite("Iteration 7 uishell fixes", .shellTierSerialised)
struct Iter7UIShellFixTests {

    private static let english = Locale(identifier: "en_US")

    /// The `index`th measured sample markup with one Plan Length field. Distinct indices give
    /// distinct identities.
    private func length(_ index: Int, metres: Decimal, text: String, symbol: String = "ft") throws -> MarkupSummary {
        let measured = ZenitSampleProject.shared.markups.filter { !$0.measurementFields.isEmpty }
        try #require(measured.count > index)
        var markup = measured[index]
        markup.measurementKind = .length
        markup.measurementFields = [MeasurementFieldSummary(
            field: .planLength, quantity: .metres(metres), displayText: text, displayUnitSymbol: symbol
        )]
        markup.repeatCount = nil
        markup.locked = false
        return markup
    }

    // MARK: - X-021: the Repeat stepper's ceiling is the store's

    /// A markup stored at ×1500 (the ledger's Repeat × cell and a bulk edit accept up to 10 000).
    /// Old output: the stepper's range was 1...999, so + asked for min(999, 1501) = 999 and −
    /// asked for min(999, 1499) = 999 — either click cut the repetition to ×999.
    @Test("X-021: one click on a markup stored at ×1500 asks for 1501 or 1499, never 999")
    func repeatStepperReachesTheStoreMaximum() {
        #expect(MarkupSummary.maximumRepeatCount == 10_000)
        #expect(InspectorRepeatStepper.range == 1...10_000, "old output: 1...999")
        #expect(InspectorRepeatStepper.stepped(count: 1500, pending: nil, delta: 1) == 1501, "old output: 999")
        #expect(InspectorRepeatStepper.stepped(count: 1500, pending: nil, delta: -1) == 1499, "old output: 999")

        // The view's click runs the same rule and records what it asked for.
        var inFlight = InspectorStepsInFlight<Int>()
        #expect(InspectorRepeatStepper.click(delta: 1, count: 1500, inFlight: &inFlight) == 1501)
        #expect(InspectorRepeatStepper.click(delta: 1, count: 1500, inFlight: &inFlight) == 1502)

        // The ceiling itself: + stops, − steps down.
        #expect(InspectorRepeatStepper.stepped(count: 10_000, pending: nil, delta: 1) == nil)
        #expect(InspectorRepeatStepper.stepped(count: 10_000, pending: nil, delta: -1) == 9_999)
    }

    /// The guard: a click never moves the count against the way it points. With a range that
    /// stops below the stored count, the old rule clamped + to the bound — a decrease.
    @Test("X-021: a + click on a count above the range asks for nothing")
    func repeatStepperNeverDecreasesOnIncrement() {
        // Old output: 999 (min(999, 1501)), an increment that cut the count by 501.
        #expect(InspectorRepeatStepper.stepped(count: 1500, pending: nil, delta: 1, range: 1...999) == nil)
        // Below the floor, − asks for nothing either; + steps up into the range.
        #expect(InspectorRepeatStepper.stepped(count: 0, pending: nil, delta: -1) == nil)
        #expect(InspectorRepeatStepper.stepped(count: 0, pending: nil, delta: 1) == 1)
        #expect(InspectorRepeatStepper.stepped(count: 4, pending: nil, delta: 0) == nil)
    }

    // MARK: - X-022: the second-unit line follows the row's total decision

    /// Three 12'-6" walls. Hand-derived: 12'-6" = 12.5 ft × 0.3048 m/ft = 3.81 m each; three
    /// walls are 11.43 m. A feet-and-inches text has no total (no digit count to copy), so the
    /// row is not a total and its primary reads one wall's value — the line beside it must too.
    /// Old output: "11.43 m" — the restated line summed every multi-selection on its own.
    @Test("X-022: three equal feet-and-inches walls restate one wall, 3.81 m, not their sum")
    func feetAndInchesMultiSelectionRestatesOneValue() throws {
        let walls = try (0..<3).map { try length($0, metres: Decimal(string: "3.81")!, text: "12'-6\"") }
        let summary = InspectorSelectionSummary(markups: walls)
        #expect(summary.measurementTotalText(.planLength, locale: Self.english) == nil)
        let row = try #require(InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows.first)
        #expect(row.id == .planLength)
        #expect(!row.isTotal)
        #expect(InspectorPanel.quantityLabel(for: row) == MeasurementField.planLength.displayName)
        #expect(row.text == "12'-6\"")
        #expect(
            InspectorMarkupFormatting.secondaryText(
                for: row.id, isTotal: row.isTotal, in: summary, locale: Self.english
            ) == "3.81 m",
            "old output: 11.43 m"
        )
        #expect(summary.summedQuantity(.planLength) == .metres(Decimal(string: "11.43")!), "the sum still exists for a total")
    }

    /// 12'-6" and 10'-0" walls: the primary reads "Multiple values", so there is nothing to
    /// restate. Old output: "6.86 m" (3.81 + 3.048 = 6.858 m), an unlabelled total beside it.
    @Test("X-022: differing feet-and-inches walls restate nothing beside Multiple values")
    func feetAndInchesMixedSelectionRestatesNothing() throws {
        let long = try length(0, metres: Decimal(string: "3.81")!, text: "12'-6\"")
        let short = try length(1, metres: Decimal(string: "3.048")!, text: "10'-0\"")
        let summary = InspectorSelectionSummary(markups: [long, short])
        let row = try #require(InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows.first)
        #expect(!row.isTotal)
        #expect(row.text == InspectorSelectionSummary.mixedPlaceholder)
        #expect(
            InspectorMarkupFormatting.secondaryText(
                for: row.id, isTotal: row.isTotal, in: summary, locale: Self.english
            ) == nil,
            "old output: 6.86 m"
        )
    }

    /// A decimal multi-selection is still a total, and its restated line is still the total:
    /// 2.50 m + 1.25 m = 3.75 m; 3.75 ÷ 0.3048 = 12.3031… ft → 12.3 ft.
    @Test("X-022: a decimal multi-selection still totals on both lines")
    func decimalMultiSelectionStillTotals() throws {
        let a = try length(0, metres: Decimal(string: "2.5")!, text: "2.50", symbol: "m")
        let b = try length(1, metres: Decimal(string: "1.25")!, text: "1.25", symbol: "m")
        let summary = InspectorSelectionSummary(markups: [a, b])
        let row = try #require(InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows.first)
        #expect(row.isTotal)
        #expect(row.text == "3.75 m")
        #expect(InspectorMarkupFormatting.secondaryText(
            for: row.id, isTotal: row.isTotal, in: summary, locale: Self.english
        ) == "12.3 ft")
    }

    // MARK: - X-023: a feet-and-inches length prints no second unit

    /// Old output: `100'-0" ft` and `6 1/2" in` — the unit symbol appended to a text that
    /// already carries its marks. Decimal feet, a Swiss grouping mark and every other dimension
    /// keep their symbol.
    @Test("X-023: a feet-and-inches field reads 100'-0\", decimal feet keep ft")
    func feetAndInchesFieldCarriesNoSecondUnit() {
        func field(_ text: String, _ symbol: String, _ quantity: DecimalQuantity = .metres(Decimal(string: "30.48")!)) -> MeasurementFieldSummary {
            MeasurementFieldSummary(field: .planLength, quantity: quantity, displayText: text, displayUnitSymbol: symbol)
        }
        #expect(field("100'-0\"", "ft").displayTextWithUnit == "100'-0\"", "old output: 100'-0\" ft")
        #expect(field("100' - 0\"", "ft").displayTextWithUnit == "100' - 0\"")
        #expect(field("6 1/2\"", "in", .metres(Decimal(string: "0.1651")!)).displayTextWithUnit == "6 1/2\"", "old output: 6 1/2\" in")
        #expect(field("< 1/16\"", "in", .metres(Decimal(string: "0.0001")!)).displayTextWithUnit == "< 1/16\"")
        #expect(field("100.00", "ft").displayTextWithUnit == "100.00 ft")
        #expect(field("1'234.50", "ft").displayTextWithUnit == "1'234.50 ft", "a grouping mark is not a foot mark")
        #expect(field("30.48", "m").displayTextWithUnit == "30.48 m")
        #expect(MeasurementFieldSummary(
            field: .planArea, quantity: .squareMetres(Decimal(string: "57.6")!), displayText: "620.0", displayUnitSymbol: "ft²"
        ).displayTextWithUnit == "620.0 ft²")
        #expect(MeasurementFieldSummary(
            field: .count, quantity: .count(12), displayText: "12", displayUnitSymbol: ""
        ).displayTextWithUnit == "12")
        #expect(field("100'-0\"", "ft").accessibilityValue.hasSuffix("100'-0\""))
    }

    /// The Inspector's value row and the canvas pill / VoiceOver label read the same property.
    /// Old output: row "12'-6\" ft" and label "…, 12'-6\" ft, page …".
    @Test("X-023: the Inspector row and the markup's VoiceOver label read 12'-6\" alone")
    func inspectorAndLabelReadFeetAndInchesAlone() throws {
        let wall = try length(0, metres: Decimal(string: "3.81")!, text: "12'-6\"")
        let summary = InspectorSelectionSummary(markups: [wall])
        #expect(summary.measurementText(.planLength) == "12'-6\"", "old output: 12'-6\" ft")
        let row = try #require(InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows.first)
        #expect(row.text == "12'-6\"")
        #expect(InspectorMarkupFormatting.secondaryText(
            for: row.id, isTotal: row.isTotal, in: summary, locale: Self.english
        ) == "3.81 m")
        #expect(wall.accessibilityLabel.contains("12'-6\""))
        #expect(!wall.accessibilityLabel.contains("\" ft"), "old output: 12'-6\" ft in the label")
    }
}
