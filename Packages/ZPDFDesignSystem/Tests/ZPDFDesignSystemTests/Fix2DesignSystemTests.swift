#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import ZPDFDesignSystem
import ZPDFUIPresentation

/// Bug hunt 2 / improvements, the design-system components.
@MainActor
final class Fix2DesignSystemTests: XCTestCase {

    /// BH-502. Old output: the trailing ear rounded (topLeading, topTrailing) — a copy of the
    /// bottom case — and left both leading corners square.
    func testTrailingEarRoundsItsLeadingCorners() {
        let radii = ZPDFPaneEar.cornerRadii(for: .trailing, radius: 6)
        XCTAssertEqual(radii.topLeading, 6)
        XCTAssertEqual(radii.bottomLeading, 6)
        XCTAssertEqual(radii.bottomTrailing, 0)
        XCTAssertEqual(radii.topTrailing, 0)
        let leading = ZPDFPaneEar.cornerRadii(for: .leading, radius: 6)
        XCTAssertEqual(leading.topLeading, 0)
        XCTAssertEqual(leading.bottomTrailing, 6)
    }

    /// BH-503. Old output: "1 items".
    func testCountBadgeIsPluralised() {
        XCTAssertEqual(ZPDFPanelHeader<EmptyView>.countAccessibilityLabel(1), "1 item")
        XCTAssertEqual(ZPDFPanelHeader<EmptyView>.countAccessibilityLabel(4), "4 items")
    }

    /// BH-504 / BH-505. Old thresholds: secondary text passed at 3.0:1, and grounds only failed
    /// when bit-identical — 0xFEFEFE on 0xFFFFFF (1.01:1) passed.
    func testSelfCheckThresholds() {
        XCTAssertEqual(ZPDFSelfCheck.secondaryTextMinimumContrast, 4.5)
        let almost = ZPDFRGBA(red: 254.0 / 255, green: 254.0 / 255, blue: 254.0 / 255, alpha: 1)
        let white = ZPDFRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertLessThan(almost.contrastRatio(against: white), ZPDFSelfCheck.groundsMinimumContrast)
        XCTAssertTrue(ZPDFSelfCheck.verifyGroundsAreDistinguishable().failures.isEmpty)
    }

    /// BH-506. Old output: `.light` (-0.4) mapped to `.thin`, `.thin` (-0.6) to `.ultraLight`.
    func testEachAppKitWeightMapsToItsOwnSwiftUIWeight() {
        let pairs: [(NSFont.Weight, Font.Weight)] = [
            (.ultraLight, .ultraLight), (.thin, .thin), (.light, .light), (.regular, .regular),
            (.medium, .medium), (.semibold, .semibold), (.bold, .bold), (.heavy, .heavy), (.black, .black)
        ]
        for (appKit, swiftUI) in pairs {
            XCTAssertEqual(ZPDFTypography.body.withWeight(appKit).swiftUIWeight, swiftUI, "\(appKit.rawValue)")
        }
    }

    /// BH-507. Old output: the Previous Page glyph was spoken "Show the pane below".
    func testChevronUpIsSpokenAsPreviousPage() {
        XCTAssertEqual(ZPDFSymbol.chevronUp.accessibilityLabel, "Previous page")
        XCTAssertEqual(ZPDFSymbol.chevronDown.accessibilityLabel, "Next page")
    }

    /// IM-059. Old output: the hint VoiceOver read was the printed "⌥⌘I".
    func testShortcutHintsAreSpokenAsWords() {
        XCTAssertEqual(ZPDFKeyboardHintSpeech.spoken("\u{2325}\u{2318}I"), "Option Command I")
        XCTAssertEqual(ZPDFKeyboardHintSpeech.spoken("\u{21E7}\u{2318}S"), "Shift Command S")
        XCTAssertEqual(ZPDFKeyboardHintSpeech.spoken("\u{238B}"), "Escape")
        XCTAssertEqual(ZPDFToolbarButton.spokenHint(display: "\u{2318}F", spoken: nil), "Command F")
        XCTAssertEqual(ZPDFToolbarButton.spokenHint(display: "\u{2318}F", spoken: "Command F key"), "Command F key")
        XCTAssertEqual(ZPDFToolbarButton.spokenHint(display: nil, spoken: nil), "")
    }

    /// IM-060. Old output: the open precision menu listed "1", "0.0", "0.00".
    func testUnitMenuRowsCarryTheFullName() {
        let option = ZPDFUnitOption(id: "d2", name: "2 decimal places", abbreviation: "0.00")
        XCTAssertEqual(ZPDFUnitPicker.menuTitle(for: option), "2 decimal places (0.00)")
        let same = ZPDFUnitOption(id: "x", name: "Page default", abbreviation: "Page default")
        XCTAssertEqual(ZPDFUnitPicker.menuTitle(for: same), "Page default")
    }

    /// IM-188. Old output: "Information: Length" for a tool badge, an unlocalised interpolation.
    func testStatusPillSpokenLabel() {
        XCTAssertEqual(ZPDFStatusPill.accessibilityLabel(severity: .info, title: "Length"), "Length")
        XCTAssertEqual(ZPDFStatusPill.accessibilityLabel(severity: .neutral, title: "Length"), "Length")
        XCTAssertEqual(
            ZPDFStatusPill.accessibilityLabel(severity: .warning, title: "Scale inherited"),
            "\(ZPDFSeverity.warning.spokenName): Scale inherited"
        )
    }
}
#endif
