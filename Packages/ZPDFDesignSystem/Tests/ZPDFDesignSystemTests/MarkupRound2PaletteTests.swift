#if canImport(XCTest)
import XCTest
@testable import ZPDFDesignSystem
import ZPDFUIPresentation

/// NL-MARKUP-14 (round 2, markup unit): twelve standard inks, the company colours, the
/// project colours and the eyedropper seam. No window, no loupe, no colour panel.
@MainActor
final class MarkupRound2PaletteTests: XCTestCase {

    func testTwelveStandardInksAllPassTheSelfCheck() {
        XCTAssertEqual(ZPDFMarkupInk.allCases.count, 12)
        let report = ZPDFSelfCheck.verifyMarkupPalette()
        XCTAssertTrue(report.passed, report.failures.map(\.description).joined(separator: "\n"))
    }

    func testCompanyColoursKeepOrderRefuseDuplicatesAndPersist() {
        var stored: Data?
        let company = ZPDFCompanyColours(load: { stored }, save: { stored = $0 })
        let red = ColorRGBA(red: 0.8, green: 0.1, blue: 0.1, alpha: 0.4)
        XCTAssertTrue(company.add(red))
        XCTAssertFalse(company.add(ColorRGBA(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)), "same hue")
        XCTAssertTrue(company.add(ZPDFMarkupInk.navy.color))
        XCTAssertEqual(company.colours.count, 2)
        XCTAssertEqual(company.colours.first?.alpha, 1, "kept opaque")
        let reread = ZPDFCompanyColours(load: { stored }, save: { stored = $0 })
        XCTAssertEqual(reread.colours.count, 2)
        reread.remove(red)
        XCTAssertEqual(reread.colours.count, 1)
        for index in 0..<20 {
            reread.add(ColorRGBA(red: Double(index) / 20, green: 0.5, blue: 0.2, alpha: 1))
        }
        XCTAssertEqual(reread.colours.count, ZPDFCompanyColours.capacity)
    }

    func testProjectColoursAreMostUsedFirstOnePerHue() {
        let blue = ZPDFMarkupInk.blue.color, red = ZPDFMarkupInk.red.color, green = ZPDFMarkupInk.green.color
        // red ×3, blue ×2 (one translucent), green ×1: red, blue, green.
        let strokes = [blue, red, green, red, ColorRGBA(red: blue.red, green: blue.green, blue: blue.blue, alpha: 0.2), red]
        let colours = ZPDFColourPalette.projectColours(from: strokes)
        XCTAssertEqual(colours.count, 3)
        XCTAssertTrue(ZPDFColourMath.sameHue(colours[0], red))
        XCTAssertTrue(ZPDFColourMath.sameHue(colours[1], blue))
        XCTAssertTrue(ZPDFColourMath.sameHue(colours[2], green))
        let many = (0..<20).map { ColorRGBA(red: Double($0) / 20, green: 0, blue: 0, alpha: 1) }
        XCTAssertEqual(ZPDFColourPalette.projectColours(from: many).count, ZPDFColourPalette.projectCapacity)
    }
}
#endif
