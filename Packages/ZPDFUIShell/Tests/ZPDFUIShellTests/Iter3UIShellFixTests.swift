import Foundation
import Testing
@testable import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-3 "uishell" list.
// Every test names its item and
// states what the old code produced. No window is built.

@MainActor
private func iter3Page(index: Int, label: String, sheetNumber: String? = nil) -> PageDescriptor {
    let box = PDFRectValue(x: 0, y: 0, width: 612, height: 792)
    return PageDescriptor(
        id: UUID(),
        index: index,
        label: label,
        mediaBox: box,
        cropBox: box,
        rotation: .degrees0,
        sheetNumber: sheetNumber,
        hasSheetIdentity: sheetNumber != nil
    )
}

@MainActor
@Suite("Iteration 3 uishell fixes", .shellTierSerialised)
struct Iter3UIShellFixTests {

    // MARK: - T-031: imperial subtotals and chips follow the session's decimal places

    /// The pane as it is built for `environment`: the model takes the session's rounding and
    /// unit policy, then a summary chip (the pane's `summary.format`, the same call with the
    /// same inputs) and a group heading (the table's own split of the subtotal into number and
    /// unit) are read off the model's host.
    private struct Iter3LedgerReadout {
        let model: LedgerPaneModel
        let rounding: LedgerRounding
        let chip: (DecimalQuantity) -> String
        let heading: (DecimalQuantity) -> (number: String, unit: String)?
    }

    private func readout(for environment: ProjectShellEnvironment, defaults: UserDefaults) -> Iter3LedgerReadout {
        let rounding = QuantityLedgerPane.subtotalRounding(for: environment)
        let model = LedgerPaneModel(
            presenter: MockLedgerPresenter(),
            preferences: LedgerPanePreferences(defaults: defaults),
            subtotalRounding: rounding
        )
        model.setSubtotalUnitPolicy(QuantityLedgerPane.unitPolicy(for: environment))
        let host = model.host
        let locale = Locale(identifier: "en_US_POSIX")
        return Iter3LedgerReadout(
            model: model,
            rounding: rounding,
            chip: { quantity in
                LedgerNumberFormatting.display(
                    quantity, policy: host.unitPolicy, rounding: host.rounding, locale: locale
                )
            },
            heading: { quantity in
                let column: LedgerColumnID = quantity.dimension == .area ? .planArea : .planLength
                let result = LedgerAggregateResult(
                    column: column, aggregate: .sum, value: .quantity(quantity)
                )
                return LedgerValueParts.parts(
                    of: result, policy: host.controller.unitPolicy, rounding: host.controller.rounding, locale: locale
                )
            }
        )
    }

    private let tenMetres = DecimalQuantity(value: 10, dimension: .length)
    private let oneSquareMetre = DecimalQuantity(value: 1, dimension: .area)

    /// Old output: `subtotalRounding(for:)` returned `.exact` for a feet session, so the
    /// summary chip and the group heading for a 10 m row read `32.8083989501 ft` and a 1 m²
    /// row `10.7639104167 ft²`, beside a totals row at two places.
    ///
    /// Two places is what the app seeds `activePrecision` with for a new project
    /// (`DisplayUnitSelection.metricDecimalPlaces` defaults to 2). Hand-derived: 10 m ÷
    /// 0.3048 m/ft = 32.808398950… ft → 32.81; 1 m² ÷ 0.09290304 m²/ft² = 10.763910416… ft²
    /// → 10.76 (half away from zero, two places).
    @Test("T-031: an imperial session at the default two places prints two places")
    func imperialSubtotalsAreBounded() throws {
        let environment = ProjectShellEnvironment.mock()
        environment.measurement.setLengthUnit(.foot)
        environment.inspectorEditing.activePrecision = .decimalPlaces(2)
        let policy = QuantityLedgerPane.unitPolicy(for: environment)
        #expect(policy.length == .foot)
        #expect(policy.area == .squareFoot)

        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.test.it3imperial")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let pane = readout(for: environment, defaults: defaults)
        #expect(pane.rounding == .twoDigits, "old output: .exact")
        #expect(pane.chip(tenMetres) == "32.81 ft", "old output: 32.8083989501 ft")
        #expect(pane.chip(oneSquareMetre) == "10.76 ft²", "old output: 10.7639104167 ft²")
        #expect(pane.heading(tenMetres)?.number == "32.81", "old output: 32.8083989501")
        #expect(pane.heading(tenMetres)?.unit == "ft")
        #expect(pane.heading(oneSquareMetre)?.number == "10.76", "old output: 10.7639104167")
        #expect(pane.heading(oneSquareMetre)?.unit == "ft²")
    }

    /// The checker's repro: a metric project set to three places in the Inspector (the app's
    /// `onSetDecimalPrecision` sets the core's `metricDecimalPlaces` to 3 and `activePrecision`
    /// to `.decimalPlaces(3)`), then Unit ▸ Imperial, which keeps those places. A 1 m² row and
    /// the totals row read `10.764 ft²`. Old output with the fixed `.twoDigits`: the chip and
    /// the group heading read `10.76 ft²`, and a 10 m decimal-feet heading `32.81`.
    ///
    /// Hand-derived at three places: 10.763910… → 10.764; 32.808398… → 32.808. At zero places
    /// the rows read `11 ft²` and the old chip `10.76 ft²`: 10.76… → 11, 32.80… → 33.
    @Test("T-031: an imperial session's subtotals and chips follow the session's decimal places")
    func imperialSubtotalsFollowTheSessionDecimals() throws {
        let environment = ProjectShellEnvironment.mock()
        environment.measurement.setLengthUnit(.metre)
        environment.inspectorEditing.activePrecision = .decimalPlaces(3)
        environment.measurement.setLengthUnit(.foot)

        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.test.it3imperialplaces")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }

        let three = readout(for: environment, defaults: defaults)
        #expect(three.rounding == .threeDigits, "old output: .twoDigits")
        #expect(three.chip(oneSquareMetre) == "10.764 ft²", "old output: 10.76 ft²")
        #expect(three.heading(oneSquareMetre)?.number == "10.764", "old output: 10.76")
        #expect(three.heading(oneSquareMetre)?.unit == "ft²")
        #expect(three.heading(tenMetres)?.number == "32.808", "old output: 32.81")
        #expect(three.heading(tenMetres)?.unit == "ft")

        environment.inspectorEditing.activePrecision = .decimalPlaces(0)
        let zero = readout(for: environment, defaults: defaults)
        #expect(zero.rounding == .integer, "old output: .twoDigits")
        #expect(zero.chip(oneSquareMetre) == "11 ft²", "old output: 10.76 ft²")
        #expect(zero.heading(tenMetres)?.number == "33", "old output: 32.81")

        // Clamped to the ledger's four places, as the metric arm is; the core allows nine.
        environment.inspectorEditing.activePrecision = .decimalPlaces(7)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == .fourDigits)

        // A fraction pick changes the imperial setting only (BH-286), never the places.
        let model = InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: []))
        environment.inspectorEditing.activePrecision = .decimalPlaces(3)
        model.selectPrecision(choiceID: InspectorPrecision.imperialFraction(.thirtySecond).id)
        #expect(environment.measurement.imperialPrecision == .thirtySecond)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == .threeDigits)

        // No decimal value known: the two-place default.
        environment.inspectorEditing.activePrecision = .imperialFraction(.sixteenth)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == QuantityLedgerPane.imperialSubtotalRounding)
        #expect(QuantityLedgerPane.imperialSubtotalRounding == .twoDigits)
    }

    @Test("T-031: a metric session keeps its own decimals")
    func metricSubtotalsFollowThePrecision() {
        let environment = ProjectShellEnvironment.mock()
        environment.measurement.setLengthUnit(.metre)
        environment.inspectorEditing.activePrecision = .decimalPlaces(1)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == .oneDigit)
        environment.inspectorEditing.activePrecision = .decimalPlaces(4)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == .fourDigits)
    }

    // MARK: - T-033: one rule for a typed sheet reference

    /// The assertions the removed `goToPage(label:)` tests made, on the one resolver the page
    /// field uses. Old behaviour: the mock presenter compared labels case-sensitively and never
    /// read sheet numbers, `AppDocumentPresenter` had no position fallback, and the page field
    /// had both — three rules for one typed reference.
    @Test("T-033: sheet number, then case-insensitive label, then position")
    func typedSheetReferenceRule() {
        // PresenterWiringTests: labels A-101…A-103.
        let labelled = [
            iter3Page(index: 0, label: "A-101"),
            iter3Page(index: 1, label: "A-102"),
            iter3Page(index: 2, label: "A-103")
        ]
        #expect(StatusBarDisplay.pageDestination(forTyped: "A-103", pages: labelled) == 2)
        #expect(StatusBarDisplay.pageDestination(forTyped: "a-103", pages: labelled) == 2, "the mock matched case-sensitively")
        #expect(StatusBarDisplay.pageDestination(forTyped: "3", pages: labelled) == 2, "no label is '3': the position")

        // NextLevelDocumentsSheetIdentityTests: a named sheet answers to its sheet number,
        // normalised, over the PDF's own label.
        let named = [
            iter3Page(index: 0, label: "1", sheetNumber: "A-101"),
            iter3Page(index: 1, label: "2", sheetNumber: "A-102")
        ]
        #expect(StatusBarDisplay.pageDestination(forTyped: "a102", pages: named) == 1)

        // MockPresenterTests: S-201 over the mock project, through the page field's real commit
        // path, typed in lower case.
        let environment = ProjectShellEnvironment.mock()
        #expect(environment.document.currentPage?.label != "S-201")
        #expect(StatusBarDisplay.commitTypedPage("s-201", environment: environment))
        #expect(environment.document.currentPage?.label == "S-201")
        #expect(!StatusBarDisplay.commitTypedPage("nowhere", environment: environment))
        #expect(environment.document.currentPage?.label == "S-201", "a reference to no page goes nowhere")
    }
}
