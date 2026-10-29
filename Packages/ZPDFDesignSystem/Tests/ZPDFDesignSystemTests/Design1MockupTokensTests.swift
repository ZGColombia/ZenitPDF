#if canImport(XCTest)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import ZPDFDesignSystem

/// Design round d1 (2026-09-23 main-window mockup): tokens, paint table and components.
@MainActor
final class Design1MockupTokensTests: XCTestCase {

    // MARK: - Palette pinned to the mockup

    private static var repositoryRoot: URL {
        // .../Packages/ZPDFDesignSystem/Tests/ZPDFDesignSystemTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testNewTokenDarkValuesArePinned() {
        let expected: [(ZPDFColorToken, String)] = [
            (.inset, "#0B1522"), (.textTertiary, "#93A0B2"), (.accent, "#0A5ECC"),
            (.selectedFill, "#123F78"), (.pillFill, "#044EFC"), (.inkBlue, "#1A55CF"),
            (.inkRed, "#CB3022"), (.inkGreen, "#1E7A4E"), (.canvasBackdrop, "#0A1322"),
            (.ledgerBar, "#141F32")
        ]
        for (token, hex) in expected {
            XCTAssertEqual(ZPDFColor.rgba(token, .dark).hexString, hex, "dark \(token.rawValue)")
        }
        XCTAssertEqual(ZPDFColor.rgba(.borderStrong, .dark).alpha, 0.16, accuracy: 0.001)
        XCTAssertEqual(ZPDFColor.rgba(.stateHover, .dark).alpha, 0.06, accuracy: 0.001)
        XCTAssertEqual(ZPDFColor.rgba(.statePressed, .dark).alpha, 0.12, accuracy: 0.001)
    }

    /// Markup inks are drawn on the always-light page, so they must not change with the chrome.
    func testOnPaperInksKeepOneValueAcrossLightAndDark() {
        for token in [ZPDFColorToken.pillFill, .inkBlue, .inkRed, .inkGreen, .accent] {
            let set = ZPDFColor.set(for: token)
            XCTAssertEqual(set.light, set.dark, "\(token.rawValue) must read the same on paper in both appearances")
        }
    }

    /// Each dark token lies within sampling tolerance of the mockup pixels it was taken from.
    ///
    /// The samples below are the 5 x 5 median of the mockup's raw sRGB bytes (read through the
    /// PNG's CGImage data provider, no colour matching) at the listed point of the 1672 x 941
    /// image. The image itself is not distributed with the source, so the samples are recorded
    /// here. Reading through `NSBitmapImageRep.colorAt(...).usingColorSpace(.sRGB)` applies the
    /// display profile and lifts dark tones 5-15 levels, which is how the first palette went
    /// wrong (d9 QA). The 16-level tolerance covers `accent`, which the 3:1 chip rule holds at
    /// #0A5ECC against the raw #0854BE (14 levels on blue).
    func testDarkTokensMatchTheMockupPixels() {
        // (token, sampled raw sRGB, x, y) — clean patches of the 2026-09-23 main-window mockup.
        let samples: [(ZPDFColorToken, UInt32, Int, Int)] = [
            (.background, 0x081324, 5, 5),          // top bar
            (.surface, 0x0E1927, 1500, 845),        // inspector panel
            (.elevated, 0x15253F, 180, 230),        // selected page card
            (.inset, 0x0B1421, 1600, 640),          // Notes field
            (.accent, 0x0854BE, 440, 40),           // active Select chip
            (.selectedFill, 0x124287, 72, 136),     // selected Pages tab
            (.pillFill, 0x0650FF, 520, 292),        // "Area: 620 SF" pill
            (.canvasBackdrop, 0x091322, 1366, 500), // canvas edge
            (.ledgerBar, 0x151F32, 5, 900)          // ledger bar ground
        ]
        let tolerance = 16
        for (token, hex, x, y) in samples {
            let sampled = [Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF)]
            let value = ZPDFColor.rgba(token, .dark)
            let channels = [value.red, value.green, value.blue].map { Int(($0 * 255).rounded()) }
            for (index, channel) in channels.enumerated() {
                XCTAssertLessThanOrEqual(
                    abs(channel - sampled[index]), tolerance,
                    "\(token.rawValue) channel \(index): token \(channel), mockup \(sampled[index]) at (\(x), \(y))"
                )
            }
        }
    }

    func testMockupContrastPairsPassInEveryAppearance() {
        let report = ZPDFSelfCheck.verifyMockupContrast()
        XCTAssertTrue(report.passed, report.failures.map(\.description).joined(separator: "\n"))
        let perVariant = ZPDFSelfCheck.mockupContrastPairs.count + ZPDFSelfCheck.paperInks.count
        XCTAssertEqual(report.assertionCount, perVariant * ZPDFAppearanceVariant.allCases.count)
        XCTAssertTrue(ZPDFSelfCheck.run().passed)
    }

    func testOpacityHelperStaysDynamicAndScalesAlpha() throws {
        let dynamic = ZPDFColor.nsColor(.inkBlue, opacity: 0.2)
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = dynamic.usingColorSpace(.sRGB) }
        let colour = try XCTUnwrap(resolved)
        let base = ZPDFColor.rgba(.inkBlue, .dark)
        XCTAssertEqual(colour.alphaComponent, 0.2, accuracy: 0.01)
        XCTAssertEqual(colour.blueComponent, base.blue, accuracy: 1.0 / 255.0)
    }

    // MARK: - Interaction states

    func testInteractionStateResolution() {
        XCTAssertEqual(ZPDFInteractionState.resolve(isHovering: false, isPressed: false), .rest)
        XCTAssertEqual(ZPDFInteractionState.resolve(isHovering: true, isPressed: false), .hover)
        XCTAssertEqual(ZPDFInteractionState.resolve(isHovering: true, isPressed: true), .pressed)
        XCTAssertEqual(ZPDFInteractionState.resolve(isHovering: true, isPressed: true, isEnabled: false), .rest)
        XCTAssertNil(ZPDFInteractionState.rest.overlay)
        XCTAssertEqual(ZPDFInteractionState.hover.overlay, .stateHover)
        XCTAssertEqual(ZPDFInteractionState.pressed.overlay, .statePressed)
    }

    // MARK: - Paint table

    func testSelectedTabCarriesFillWeightAndIndicator() {
        for compact in [false, true] {
            let selected = ZPDFControlPaints.tab(isSelected: true, state: .rest, isEnabled: true, compact: compact)
            XCTAssertEqual(selected.fill, .selectedFill)
            XCTAssertEqual(selected.indicator, .accentBlue)
            XCTAssertEqual(selected.foreground, .textPrimary)

            let other = ZPDFControlPaints.tab(isSelected: false, state: .rest, isEnabled: true, compact: compact)
            XCTAssertNil(other.fill)
            XCTAssertNil(other.indicator)
            XCTAssertEqual(other.foreground, .textSecondary)
            XCTAssertGreaterThan(selected.textStyle.weightValue, other.textStyle.weightValue)
        }
        XCTAssertEqual(ZPDFControlPaints.tab(isSelected: true, state: .rest, isEnabled: true).textStyle, .tabSelected)
        XCTAssertEqual(ZPDFControlPaints.tabTrack(compact: false).fill, .elevated)
    }

    func testToggledToolbarButtonMatchesPerSheet() {
        let on = ZPDFControlPaints.toolbarButton(isSelected: true, prominence: .standard, state: .rest, isEnabled: true)
        XCTAssertEqual(on.fill, .selectedFill)
        XCTAssertEqual(on.stroke, .accentBlue, "state lines are accentBlue (3:1 on dark panels), accent is a fill")
        XCTAssertEqual(on.indicator, .accentBlue)
        let off = ZPDFControlPaints.toolbarButton(isSelected: false, prominence: .destructive, state: .hover, isEnabled: true)
        XCTAssertNil(off.fill)
        XCTAssertEqual(off.foreground, .danger)
        XCTAssertEqual(off.overlay, .stateHover)
    }

    func testFieldEdgeTurnsAccentWithFocus() {
        let rest = ZPDFSearchField.paint(isFocused: false, isHovering: false, isEnabled: true)
        XCTAssertEqual(rest.fill, .inset)
        XCTAssertEqual(rest.stroke, .borderStrong)
        let focused = ZPDFSearchField.paint(isFocused: true, isHovering: true, isEnabled: true)
        XCTAssertEqual(focused.stroke, .accentBlue)
        XCTAssertNil(focused.overlay, "a focused field does not flicker under the pointer")
        XCTAssertEqual(ZPDFSearchField.paint(isFocused: false, isHovering: true, isEnabled: true).overlay, .stateHover)
    }

    func testReadOutSummaryChipNeverShowsHover() {
        XCTAssertNil(ZPDFSummaryChip.paint(isSelected: false, isHovering: true, isInteractive: false).overlay)
        XCTAssertEqual(ZPDFSummaryChip.paint(isSelected: false, isHovering: true, isInteractive: true).overlay, .stateHover)
        XCTAssertEqual(ZPDFSummaryChip.paint(isSelected: true, isHovering: false, isInteractive: true).fill, .selectedFill)
    }

    /// No state line anywhere in the paint table uses the `accent` fill blue. (S-054, iteration 2:
    /// the tool-button and card paints left with the only components that drew them.)
    func testNoStateLineUsesTheAccentFillBlue() {
        var paints: [ZPDFControlPaint] = []
        for state in ZPDFInteractionState.allCases {
            for flag in [false, true] {
                paints.append(ZPDFControlPaints.tab(isSelected: flag, state: state, isEnabled: true))
                paints.append(ZPDFControlPaints.toolbarButton(isSelected: flag, prominence: .standard, state: state, isEnabled: true))
                paints.append(ZPDFControlPaints.toolbarButton(isSelected: flag, prominence: .standard, state: state, isEnabled: false))
                paints.append(ZPDFControlPaints.field(isFocused: flag, state: state, isEnabled: true))
                paints.append(ZPDFControlPaints.summaryChip(isSelected: flag, state: state, isInteractive: true))
            }
        }
        for paint in paints {
            XCTAssertNotEqual(paint.stroke, .accent)
            XCTAssertNotEqual(paint.indicator, .accent)
        }
        // And the pairs that guard it: accentBlue as a state line on the grounds it borders.
        let pairs = ZPDFSelfCheck.mockupContrastPairs.filter { $0.foreground == .accentBlue }.map(\.ground)
        XCTAssertTrue(Set(pairs).isSuperset(of: [.surface, .elevated, .background]))
    }

    func testPaperIsPageWhiteInEveryAppearance() {
        XCTAssertTrue(ZPDFColorToken.appearanceInvariant.contains(.paper))
        for variant in ZPDFAppearanceVariant.allCases {
            XCTAssertEqual(ZPDFColor.rgba(.paper, variant), ZPDFRGBA(hex: 0xFFFFFF), variant.rawValue)
        }
        XCTAssertEqual(ZPDFSelfCheck.paper, ZPDFColor.rgba(.paper, .dark))
        XCTAssertTrue(ZPDFSelfCheck.verifyIncreaseContrastVariants().passed)
    }

    func testSearchFieldFocusControllerDeliversRequests() {
        let focus = ZPDFSearchFieldFocus()
        var received: [Bool] = []
        let token = focus.requests.sink { received.append($0) }
        focus.focus()
        XCTAssertEqual(received, [true])
        XCTAssertFalse(focus.isFocused, "focus state is reported by the field, not assumed by the request")
        _ = ZPDFSearchField(text: .constant(""), placeholder: "Search in document…", focus: focus)
        token.cancel()
    }

    // MARK: - Component behaviour and accessibility

    func testSummaryChipSpokenLabel() {
        XCTAssertEqual(
            ZPDFSummaryChip.accessibilityLabel(title: "Areas", count: "2", total: "2,480 SF"),
            "Areas, 2 items, total 2,480 SF"
        )
        XCTAssertEqual(ZPDFSummaryChip.accessibilityLabel(title: "Counts", count: "12", total: nil), "Counts, 12 items")
        XCTAssertEqual(ZPDFSummaryChip.accessibilityLabel(title: "Markups", count: nil, total: ""), "Markups")
    }

    func testSearchFieldClearRuleAndLabel() {
        XCTAssertFalse(ZPDFSearchField.showsClearButton(text: ""))
        XCTAssertTrue(ZPDFSearchField.showsClearButton(text: "RFI"))
        XCTAssertFalse(ZPDFSearchField.clearLabel.isEmpty)
    }

    /// V-049: the Navigator's Search page now uses this field, and an idle Escape there must
    /// still reach the Navigator (which closes on it). The old handler ran for every Escape and
    /// swallowed the key even with nothing to clear.
    func testSearchFieldEscapeClearsFirstAndPassesThroughWhenEmpty() {
        var query = "RFI"
        let binding = Binding(get: { query }, set: { query = $0 })
        let clear = ZPDFSearchField.exitCommand(text: binding)
        XCTAssertNotNil(clear, "a query to clear takes the Escape")
        clear?()
        XCTAssertEqual(query, "")
        XCTAssertNil(ZPDFSearchField.exitCommand(text: binding), "nothing to clear: the Escape goes on to the panel")
    }

    func testNewSymbolsResolveWithLabels() {
        let added: [ZPDFSymbol] = [.zoomTool, .filter, .clear, .perSheet, .bulkEdit, .detach, .history, .person, .sliders, .textTool, .viewfinder]
        for symbol in added {
            XCTAssertFalse(symbol.accessibilityLabel.isEmpty, symbol.rawValue)
            XCTAssertNotNil(symbol.nsImage(), "\(symbol.rawValue) -> \(symbol.systemName) is not vended by this system")
        }
    }

    func testTextToolGlyphIsASingleCapitalA() {
        XCTAssertEqual(ZPDFSymbol.textTool.systemName, "character")
        XCTAssertEqual(ZPDFSymbol.textTool.accessibilityLabel, ZPDFSymbol.text.accessibilityLabel)
        XCTAssertEqual(ZPDFSymbol.text.systemName, "textformat", "text markup kinds keep their own glyph")
    }

    func testFitPageViewfinderGlyphKeepsTheFitPageLabel() {
        XCTAssertEqual(ZPDFSymbol.viewfinder.systemName, "viewfinder")
        XCTAssertEqual(ZPDFSymbol.viewfinder.accessibilityLabel, ZPDFSymbol.fitPage.accessibilityLabel)
    }

    // MARK: - Type, radii, metrics

    func testMockupTypeRolesAreRegisteredAndNumericRolesAreTabular() {
        let names = Set(ZPDFTypography.allStyles.map(\.name))
        for name in ["brandWordmark", "brandTagline", "toolLabel", "toolLabelActive", "panelTitle", "tab",
                     "tabSelected", "cardTitle", "rowLabel", "valueEmphasis", "pillLabel", "chipTitle",
                     "chipValue", "avatarInitials"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from the audited ramp")
        }
        for style in [ZPDFTypography.valueEmphasis, .pillLabel, .chipValue] {
            XCTAssertEqual(style.face, .systemMonospacedDigits, "quantities need tabular figures")
        }
        XCTAssertGreaterThan(ZPDFTypography.brandTagline.tracking, 0, "the tagline is letter-spaced")
        XCTAssertGreaterThan(ZPDFTypography.panelTitle.tracking, 0, "INSPECTOR is letter-spaced")
    }

    func testRadiiAscendAndChromeMetricsHoldTheHitTarget() {
        XCTAssertLessThan(ZPDFRadius.label, ZPDFRadius.control)
        XCTAssertLessThan(ZPDFRadius.control, ZPDFRadius.card)
        XCTAssertLessThan(ZPDFRadius.card, ZPDFRadius.panel)
        let minimum = ZPDFSpacing.Control.minimumHitTarget
        for size in [ZPDFSpacing.Chrome.toolButtonHeight, ZPDFSpacing.Chrome.barControlHeight,
                     ZPDFSpacing.Chrome.fieldHeight, ZPDFSpacing.Chrome.swatch, ZPDFSpacing.Chrome.segmentedTabHeight,
                     ZPDFSpacing.Chrome.avatarLarge] {
            XCTAssertGreaterThanOrEqual(size, minimum)
        }
        XCTAssertLessThan(ZPDFSpacing.Chrome.toolIcon + ZPDFSpacing.Chrome.toolIconLabelGap + 16, ZPDFSpacing.Chrome.toolButtonHeight)
    }

    // MARK: - Source hygiene

    /// The new components take every colour from a token (or from caller-supplied document
    /// colour); none carries a literal.
    func testComponentsCarryNoRawColourLiterals() throws {
        let components = Self.repositoryRoot
            .appendingPathComponent("Packages/ZPDFDesignSystem/Sources/ZPDFDesignSystem/Components")
        // S-054 (iteration 2): ZPDFToolButton.swift and ZPDFInspectorControls.swift were deleted
        // with the components only their previews used.
        let files = ["ZPDFChromePaint.swift", "ZPDFSearchField.swift", "ZPDFLabels.swift",
                     "ZPDFToolbarButton.swift", "ZPDFSegmentedControl.swift"]
        let forbidden = ["Color(red:", "Color(.sRGB", "NSColor(srgbRed", "NSColor(red:", "NSColor(calibratedRed",
                         "#colorLiteral", "Color.blue", "Color.white", "Color.black", ".systemBlue", "Color(hex"]
        for file in files {
            let source = try String(contentsOf: components.appendingPathComponent(file), encoding: .utf8)
            for literal in forbidden {
                XCTAssertFalse(source.contains(literal), "\(file) contains \(literal)")
            }
        }
    }
}
#endif
