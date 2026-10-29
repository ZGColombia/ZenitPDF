import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// design-d6: the bottom Quantity Ledger bar of the 2026-09-23 main-window mockup — chevron
/// and title, Quantities | History, one summary chip per quantity kind, Per Sheet, Filter,
/// Bulk Edit, Detach and the options menu. Nothing here opens a window: the model is pure and
/// the one render goes through `ImageRenderer`, off screen.
@MainActor
@Suite("design-d6 ledger bar", .shellTierSerialised)
struct DesignD6LedgerBarTests {

    // MARK: Summary chips

    private func totals(
        area: String? = "2,480 SF",
        length: String? = "312' - 6\"",
        count: String? = "12",
        rowCount: Int = 8,
        incompatible: Set<LedgerColumnID> = []
    ) -> LedgerTotals {
        var quantities: [LedgerColumnID: DecimalQuantity] = [:]
        var displays: [LedgerColumnID: String] = [:]
        if let area {
            quantities[.planArea] = DecimalQuantity(value: 2480, dimension: .area)
            displays[.planArea] = area
        }
        if let length {
            quantities[.planLength] = DecimalQuantity(value: 312.5, dimension: .length)
            displays[.planLength] = length
        }
        if let count {
            quantities[.count] = DecimalQuantity(value: 12, dimension: .count)
            displays[.count] = count
        }
        return LedgerTotals(
            rowCount: rowCount,
            quantities: quantities,
            displayValues: displays,
            incompatibleColumns: incompatible
        )
    }

    @Test("The bar shows one chip per quantity kind, in the mockup's order")
    func oneChipPerQuantityKind() {
        let summary = LedgerSummary(totals: totals(), rowCount: 8, kindCounts: [:])
        #expect(summary.chips.map(\.kind) == [.areas, .lengths, .counts, .markups])
        #expect(summary.chips.map(\.kind.title) == ["Areas", "Lengths", "Counts", "Markups"])
        #expect(Set(summary.chips.map(\.id)).count == summary.chips.count)
    }

    @Test("Totals are the presenter's grand-total strings, counts its per-kind row counts")
    func chipsReadThePresenter() throws {
        let summary = LedgerSummary(
            totals: totals(),
            rowCount: 8,
            kindCounts: [.area: 1, .rectangleArea: 1, .length: 5, .polylength: 2, .count: 3, .polygonCutout: 4]
        )
        let areas = try #require(summary.chip(.areas))
        #expect(areas.rowCount == 2, "cutouts subtract from an area, they are not areas")
        #expect(areas.headline == "2,480 SF")
        #expect(areas.badge == "2")
        let lengths = try #require(summary.chip(.lengths))
        #expect(lengths.rowCount == 7)
        #expect(lengths.headline == "312' - 6\"")
        #expect(lengths.badge == "7")
        let counts = try #require(summary.chip(.counts))
        #expect(counts.headline == "12", "the Counts headline is the marks total, not the row count")
        #expect(counts.badge == nil)
        let markups = try #require(summary.chip(.markups))
        #expect(markups.headline == "8")
        #expect(markups.badge == nil)
    }

    @Test("Areas and Lengths put the row count in the count box and the total below; Counts and Markups put their figure in the box")
    func chipDisplayMapping() throws {
        let summary = LedgerSummary(totals: totals(), rowCount: 8, kindCounts: [.area: 2, .length: 7, .count: 3])
        #expect(summary.chip(.areas)?.displayCount == "2")
        #expect(summary.chip(.areas)?.displayTotal == "2,480 SF")
        #expect(summary.chip(.lengths)?.displayCount == "7")
        #expect(summary.chip(.lengths)?.displayTotal == "312' - 6\"")
        #expect(summary.chip(.counts)?.displayCount == "12")
        #expect(summary.chip(.counts)?.displayTotal == nil)
        #expect(summary.chip(.markups)?.displayCount == "8")
        #expect(summary.chip(.markups)?.displayTotal == nil)
        let unknown = LedgerSummary(totals: totals(), rowCount: 8, kindCounts: nil)
        #expect(unknown.chip(.areas)?.displayCount == nil)
        #expect(unknown.chip(.areas)?.displayTotal == "2,480 SF")
    }

    @Test("A presenter that cannot count kinds gets totals without a badge, never a guess")
    func unknownKindCountsShowNoBadge() throws {
        let summary = LedgerSummary(totals: totals(), rowCount: 8, kindCounts: nil)
        let areas = try #require(summary.chip(.areas))
        #expect(areas.rowCount == nil)
        #expect(areas.badge == nil)
        #expect(areas.headline == "2,480 SF")
        #expect(summary.chip(.markups)?.headline == "8")
    }

    @Test("Nothing of a kind measured reads 0; unknown or mixed units read as a dash")
    func emptyAndMixedStates() throws {
        let empty = LedgerSummary(totals: .empty, rowCount: 0, kindCounts: [:])
        for chip in empty.chips {
            #expect(chip.headline == "0", "\(chip.kind) on an empty ledger")
            #expect(chip.badge == nil)
        }
        let mixed = LedgerSummary(
            totals: totals(incompatible: [.planArea]),
            rowCount: 8,
            kindCounts: nil
        )
        #expect(mixed.chip(.areas)?.total == nil, "mixed-unit areas have no total to show")
        #expect(mixed.chip(.areas)?.headline == LedgerSummary.missingValue)
    }

    @Test("Every chip has one VoiceOver sentence naming its kind and figures")
    func chipAccessibilityLabels() throws {
        let summary = LedgerSummary(totals: totals(), rowCount: 8, kindCounts: [.area: 2, .length: 7, .count: 3])
        let areas = try #require(summary.chip(.areas))
        #expect(areas.accessibilityLabel.contains("Areas"))
        #expect(areas.accessibilityLabel.contains("2"))
        #expect(areas.accessibilityLabel.contains("2,480 SF"))
        #expect(summary.chip(.markups)?.accessibilityLabel == "Markups, 8 items")
        #expect(summary.chip(.counts)?.accessibilityLabel == "Counts, 12 items")
    }

    @Test("The mock presenter counts kinds from its own rows, and the chips agree with its totals")
    func mockPresenterSummary() {
        let presenter = MockLedgerPresenter()
        var expected: [MeasurementKind: Int] = [:]
        for index in 0..<presenter.rowCount {
            if let kind = presenter.row(at: index)?.measurementKind { expected[kind, default: 0] += 1 }
        }
        #expect(presenter.rowCountsByMeasurementKind == expected)
        let summary = LedgerSummary(
            totals: presenter.grandTotals,
            rowCount: presenter.rowCount,
            kindCounts: presenter.rowCountsByMeasurementKind
        )
        #expect(summary.chip(.markups)?.rowCount == presenter.rowCount)
        let areaCount = [MeasurementKind.area, .rectangleArea, .ellipseArea].reduce(0) { $0 + (expected[$1] ?? 0) }
        #expect(summary.chip(.areas)?.rowCount == areaCount)
        if areaCount > 0, !presenter.grandTotals.displayValue(.planArea).isEmpty {
            #expect(summary.chip(.areas)?.total == presenter.grandTotals.displayValue(.planArea))
        }
    }

    // MARK: Bar metrics and controls

    @Test("The bar's height is the design system's ledger bar token, and the collapsed pane is exactly the bar")
    func barHeightUsesTheToken() {
        #expect(ZPDFSpacing.Chrome.ledgerBarHeight == 56, "the bar is 56 pt collapsed")
        #expect(QuantityLedgerPane.collapsedBarHeight == ZPDFSpacing.Chrome.ledgerBarHeight)
        #expect(QuantityLedgerPane.headerHeight == QuantityLedgerPane.collapsedBarHeight - 2)
        #expect(Double(QuantityLedgerPane.collapsedBarHeight) < ProjectWindowLayoutState.minimumLedgerHeight)
        #expect(ZPDFSpacing.Chrome.summaryChipHeight < QuantityLedgerPane.headerHeight)
    }

    @Test("Chip totals carry the display unit through the table's own totals formatter")
    func chipTotalsCarryTheUnit() throws {
        let policy = LedgerUnitPolicy(length: .foot, area: .squareFoot)
        let locale = Locale(identifier: "en_US")
        let area = DecimalQuantity(value: Decimal(string: "230.40")!, dimension: .area)
        let length = DecimalQuantity(value: Decimal(string: "95.25")!, dimension: .length)
        let totals = LedgerTotals(
            rowCount: 3,
            quantities: [.planArea: area, .planLength: length],
            displayValues: [.planArea: "230.40", .planLength: "95.25"]
        )
        let format: (DecimalQuantity) -> String = {
            LedgerNumberFormatting.display($0, policy: policy, rounding: .twoDigits, locale: locale)
        }
        let summary = LedgerSummary(
            totals: totals, rowCount: 3, kindCounts: [.area: 1, .length: 2], format: format,
            speak: { QuantityLedgerPane.spokenTotal($0, policy: policy, rounding: .twoDigits, locale: locale) }
        )
        let areaTotal = try #require(summary.chip(.areas)?.displayTotal)
        #expect(areaTotal == format(area), "the chip prints exactly what the table's totals print")
        #expect(areaTotal.hasSuffix(AreaUnit.squareFoot.symbol))
        #expect(areaTotal.contains(","), "grouping separators, as the table's totals have them")
        let lengthTotal = try #require(summary.chip(.lengths)?.displayTotal)
        #expect(lengthTotal == format(length))
        #expect(lengthTotal.hasSuffix(LengthUnit.foot.symbol))
        let spoken = try #require(summary.chip(.areas)?.accessibilityLabel)
        #expect(spoken.contains("square feet"), "VoiceOver hears the unit's name, not its symbol: \(spoken)")
        #expect(!spoken.contains(AreaUnit.squareFoot.symbol))
    }

    @Test("A count total prints whole, as the table's count subtotal does; measured totals keep the display precision")
    func countTotalsPrintWhole() {
        // T-048: the chip and the table's headings share one rule in
        // `LedgerNumberFormatting.displayParts`; the chip-only `chipRounding` is gone.
        let count = DecimalQuantity(value: 151, dimension: .count)
        let area = DecimalQuantity(value: 543.5, dimension: .area)
        let swedish = Locale(identifier: "sv_SE")
        #expect(LedgerNumberFormatting.display(count, policy: .metric, rounding: .threeDigits, locale: swedish) == "151")
        #expect(LedgerNumberFormatting.display(area, policy: .metric, rounding: .threeDigits, locale: swedish) == "543,500 m²")
    }

    @Test("The selected ledger tab has no ground: white label over the accent underline only")
    func selectedTabHasNoFill() {
        #expect(LedgerPaneTabButton.groundToken(isSelected: true, isHovering: false) == nil)
        #expect(LedgerPaneTabButton.groundToken(isSelected: true, isHovering: true) == nil)
        #expect(LedgerPaneTabButton.groundToken(isSelected: false, isHovering: false) == nil)
        #expect(LedgerPaneTabButton.groundToken(isSelected: false, isHovering: true) == .stateHover)
    }

    @Test("A regroup still reaches a presenter that does not supply its own outline")
    func regroupReachesThePresenter() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        model.setGrouping([.subject])
        #expect(presenter.groupingColumns == [.subject])
        model.setGrouping([])
        #expect(presenter.groupingColumns.isEmpty)
    }

    @Test("The bar is painted with the design system's ledger-bar ground")
    func barUsesLedgerBarGround() {
        #expect(QuantityLedgerPane.barGroundToken == .ledgerBar)
    }

    @Test("Per Sheet keeps one label whatever its state; the state is the selected fill and trait")
    func perSheetLabelIsConstant() {
        #expect(QuantityLedgerPane.perSheetTitle == "Per Sheet")
    }

    @Test("Chip glyph inks are the page's markup inks: blue, blue, green, red")
    func chipInks() {
        #expect(LedgerSummary.Kind.allCases.map(\.ink) == [.inkBlue, .inkBlue, .inkGreen, .inkRed])
    }

    @Test("The bar's view files paint only through design-system tokens")
    func noRawColourLiterals() throws {
        for file in ["QuantityLedgerPane.swift", "LedgerBarViews.swift", "LedgerSummary.swift", "HistoryPane.swift"] {
            let source = try String(contentsOf: Self.ledgerSource(file), encoding: .utf8)
            for forbidden in ["Color(red", "Color(white", "NSColor(red", "NSColor(calibratedRed", "NSColor(srgbRed",
                              "#colorLiteral", "Color.blue", "Color.red", "Color.green", "Color.white", "Color.black",
                              ".foregroundColor(.", "Color(hex"] {
                #expect(!source.contains(forbidden), "raw colour \(forbidden) in \(file)")
            }
        }
    }

    @Test("The collapsed bar renders off screen, dark and light, at the mockup's width")
    func collapsedBarRendersOffScreen() throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let panelState = ShellPanelState()
        panelState.isLedgerCollapsedToBar = true
        for scheme in [ColorScheme.dark, .light] {
            let pane = QuantityLedgerPane(
                environment: .mock(),
                panelState: panelState,
                preferences: LedgerPanePreferences(defaults: defaults)
            )
            .frame(width: 1672, height: QuantityLedgerPane.collapsedBarHeight)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: pane)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width == 1672)
            if let directory = ProcessInfo.processInfo.environment["ZPDF_D6_RENDER_DIR"],
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("ledger-bar-\(scheme == .dark ? "dark" : "light").png")
                try png.write(to: url)
            }
        }
    }

    private static func ledgerSource(_ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell/Ledger")
            .appendingPathComponent(file)
    }
}
