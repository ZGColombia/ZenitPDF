import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

// Iteration-7 "uishell" items whose cause sits in the application target
// (iteration-7 findings). Pure label tests: no document,
// no window, nothing reaches the screen.

@MainActor
@Suite("Iteration 7 uishell fixes (app tier)", .appTierSerialised)
struct Iter7UIShellAppTests {

    private func wall(_ field: MeasurementFieldSummary) -> MarkupSummary {
        MarkupSummary(
            id: UUID(),
            kind: .measurement,
            measurementKind: .length,
            subject: "Wall",
            label: "",
            pageLabel: "A-101",
            pageID: UUID(),
            pageIndex: 0,
            author: "test",
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1),
            measurementFields: [field],
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: .zero
        )
    }

    /// The field exactly as `MarkupBridge` builds it in a session: text and symbol from the
    /// session's `QuantityFormatter`.
    private func bridged(_ quantity: DecimalQuantity, _ formatter: QuantityFormatter) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: .planLength, quantity: quantity,
            displayText: formatter.text(quantity), displayUnitSymbol: formatter.symbol(quantity)
        )
    }

    // MARK: - X-023: the canvas's VoiceOver label speaks one unit

    /// Old output: `Wall, 12'-6" ft, sheet A-101` — the canvas label joined text and symbol by
    /// hand instead of reading `displayTextWithUnit`, the rule every other surface reads.
    @Test("X-023: the canvas VoiceOver label reads 12'-6\" alone, decimal feet and metres keep their unit")
    func canvasLabelReadsFeetAndInchesAlone() throws {
        let hand = MeasurementFieldSummary(
            field: .planLength, quantity: .metres(Decimal(string: "3.81")!),
            displayText: "12'-6\"", displayUnitSymbol: "ft"
        )
        let label = CanvasAccessibilityText.label(for: wall(hand))
        #expect(label.contains("12'-6\""), "\(label)")
        #expect(!label.contains("\" ft"), "old output: Wall, 12'-6\" ft, sheet A-101 — \(label)")
        #expect(label == "Wall, 12'-6\", sheet A-101", "\(label)")

        // The production path: a feet-and-inches session formats 3.81 m as MarkupBridge does,
        // and the label carries the same text QuantityFormatter.textWithUnit gives (U-054).
        let quantity = DecimalQuantity.metres(Decimal(string: "3.81")!)
        let imperial = QuantityFormatter(units: .imperial)
        #expect(imperial.symbol(quantity) == "ft")
        let spoken = CanvasAccessibilityText.label(for: wall(bridged(quantity, imperial)))
        #expect(spoken == "Wall, \(imperial.textWithUnit(quantity)), sheet A-101", "\(spoken)")
        #expect(!spoken.contains("\" ft"), "\(spoken)")

        // Decimal feet and metres still say their unit.
        let decimalFeet = QuantityFormatter(units: DisplayUnitSelection.imperial.withImperialLengthStyle(.decimalFeet))
        let feetLabel = CanvasAccessibilityText.label(for: wall(bridged(quantity, decimalFeet)))
        #expect(feetLabel.hasSuffix(" ft, sheet A-101"), "\(feetLabel)")
        let metres = CanvasAccessibilityText.label(for: wall(bridged(quantity, QuantityFormatter(units: .metric))))
        #expect(metres == "Wall, 3.81 m, sheet A-101", "\(metres)")
    }
}
