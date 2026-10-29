#if canImport(XCTest)
import AppKit
import SwiftUI
import XCTest
@testable import ZPDFDesignSystem

/// Gate G12 foundation tests.
///
/// The whole file is wrapped in `#if canImport(XCTest)` on purpose: a machine with only the
/// Command Line Tools installed has no XCTest framework to link against, and the design system
/// still has to build there. The same assertions run without XCTest through
/// `ZPDFSelfCheck` and the `zpdf-design-audit` command-line tool.
@MainActor
final class ZPDFDesignSystemTests: XCTestCase {

    // MARK: - Colour

    /// Every semantic token must resolve in light and in dark, to exactly the declared value.
    func testEverySemanticTokenResolvesInBothAppearances() throws {
        let variants: [ZPDFAppearanceVariant] = [.light, .dark]
        let appearances: [(ZPDFAppearanceVariant, NSAppearance)] = try variants.map { variant in
            let appearance = try XCTUnwrap(
                variant.appearance,
                "the system did not vend \(variant.appearanceName.rawValue)"
            )
            return (variant, appearance)
        }

        // 15 Graphite Workshop tokens + 14 added for the 2026-09-23 main-window mockup (incl. paper, ledgerBar).
        XCTAssertEqual(ZPDFColorToken.allCases.count, 29, "the semantic token set changed; update the design docs too")

        for token in ZPDFColorToken.allCases {
            let dynamic = ZPDFColor.nsColor(token)

            for (variant, appearance) in appearances {
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = dynamic.usingColorSpace(.sRGB)
                }

                let colour = try XCTUnwrap(
                    resolved,
                    "\(token.rawValue) did not resolve in \(variant.rawValue)"
                )
                let expected = ZPDFColor.rgba(token, variant)
                let tolerance: CGFloat = 1.0 / 255.0
                XCTAssertEqual(colour.redComponent, expected.red, accuracy: tolerance, "\(token.rawValue) red in \(variant.rawValue)")
                XCTAssertEqual(colour.greenComponent, expected.green, accuracy: tolerance, "\(token.rawValue) green in \(variant.rawValue)")
                XCTAssertEqual(colour.blueComponent, expected.blue, accuracy: tolerance, "\(token.rawValue) blue in \(variant.rawValue)")
                XCTAssertEqual(colour.alphaComponent, expected.alpha, accuracy: tolerance, "\(token.rawValue) alpha in \(variant.rawValue)")
            }
        }
    }

    /// Both Increase Contrast variants must be defined for every token, and must differ from
    /// their normal counterpart — otherwise the accessibility path is decorative only.
    ///
    /// The one permitted exception is a token already at the end of the axis the variant moves
    /// along: light `surface` is pure white by spec and cannot get lighter, so its extra
    /// contrast comes from the border and text drawn on it, which do change. The rule is
    /// expressed in ``ZPDFSelfCheck/verifyIncreaseContrastVariants()`` so the audit executable
    /// — which is what verifies this package when XCTest is unavailable — checks the same thing.
    func testEverySemanticTokenHasAnIncreaseContrastVariant() {
        let report = ZPDFSelfCheck.verifyIncreaseContrastVariants()
        XCTAssertTrue(
            report.passed,
            report.failures.map(\.description).joined(separator: "\n")
        )
        XCTAssertEqual(report.assertionCount, ZPDFColorToken.allCases.count * 2)
    }

    /// The exception above must stay narrow: `surface` is the only token allowed to reuse its
    /// light value, and no token at all may reuse its dark one.
    func testOnlyPureWhiteLightSurfaceReusesItsContrastValue() {
        // Design round 2026-09-23: `paper` is declared appearance-invariant (page white in all
        // four variants) and is held to the opposite, equal-everywhere rule by the self-check.
        // Every other token is still under the original narrow exception.
        for token in ZPDFColorToken.allCases where !ZPDFColorToken.appearanceInvariant.contains(token) {
            let set = ZPDFColor.set(for: token)
            if set.light == set.lightHighContrast {
                XCTAssertEqual(token, .surface, "\(token.rawValue) unexpectedly reuses its light value")
                XCTAssertTrue(ZPDFSelfCheck.isPureWhite(set.light), "surface light is expected to be pure white")
            }
            XCTAssertNotEqual(
                set.dark, set.darkHighContrast,
                "\(token.rawValue) has no distinct dark Increase Contrast value"
            )
        }
    }

    /// The palette hex values the Zenit design system specifies, spot-checked verbatim.
    ///
    /// Design round 2026-09-23: the dark grounds, text, `accentBlue` and `selection` moved from
    /// the graphite values (#101317 / #171B21 / #202630 / #F5F7F9 / #9DA8B4 / #6E9FFF /
    /// #2B6CB0) to the navy family sampled from the binding main-window mockup. The light
    /// appearance and the status colours are unchanged and still pinned verbatim.
    /// d10 accessibility pass: dark `accentBlue` is pinned at #5AA4F7, not the sampled #3F94F5,
    /// because the selected-tab underline on `selectedFill` must reach 3:1 (2.77 -> 3.31);
    /// light `success` moved #1F8F5F -> #187A50 for 4.5:1 text on white.
    /// Polish round (d9 QA): the dark grounds were re-sampled from the mockup's raw sRGB bytes
    /// (the first pass had read them through a display-profile conversion, 5-15 levels light);
    /// `accent` (and `selection`, which tracks it) sits at #0A5ECC, the nearest value to the raw
    /// #0854BE that keeps the active chip at 3:1 against the top bar.
    func testPaletteMatchesTheSpecifiedHexValues() {
        let dark: [(ZPDFColorToken, String)] = [
            (.background, "#081324"), (.surface, "#0E1927"), (.elevated, "#16263F"),
            (.textPrimary, "#F3F6FA"), (.textSecondary, "#B8C3D1"),
            (.accentCyan, "#50D6DE"), (.accentBlue, "#5AA4F7"), (.success, "#4FD095"),
            (.warning, "#EFB957"), (.danger, "#F0616E"), (.selection, "#0A5ECC")
        ]
        for (token, hex) in dark {
            XCTAssertEqual(ZPDFColor.rgba(token, .dark).hexString, hex, "dark \(token.rawValue)")
        }

        let light: [(ZPDFColorToken, String)] = [
            (.background, "#F3F5F7"), (.surface, "#FFFFFF"), (.elevated, "#E9EEF2"),
            (.border, "#D3DCE3"), (.textPrimary, "#11171D"), (.textSecondary, "#5E6B77"),
            (.accentCyan, "#087D84"), (.accentBlue, "#245FAF"), (.success, "#187A50")
        ]
        for (token, hex) in light {
            XCTAssertEqual(ZPDFColor.rgba(token, .light).hexString, hex, "light \(token.rawValue)")
        }

        // The dark border is specified as rgba(255,255,255,0.10), not as an opaque hex.
        let border = ZPDFColor.rgba(.border, .dark)
        XCTAssertEqual(border.hexString, "#FFFFFF")
        XCTAssertEqual(border.alpha, 0.10, accuracy: 0.001)
    }

    // MARK: - Icons

    /// Every measurement glyph must render a template image that actually contains ink.
    func testAllIconKindsProduceNonEmptyImage() {
        XCTAssertEqual(ZPDFIconKind.allCases.count, 19, "the measurement glyph set changed")

        for kind in ZPDFIconKind.allCases {
            let image = ZPDFIcon.image(kind, size: 24)

            XCTAssertGreaterThan(image.size.width, 0, "\(kind.rawValue) has zero width")
            XCTAssertGreaterThan(image.size.height, 0, "\(kind.rawValue) has zero height")
            XCTAssertTrue(image.isTemplate, "\(kind.rawValue) must be a template image")
            XCTAssertFalse(
                (image.accessibilityDescription ?? "").isEmpty,
                "\(kind.rawValue) has no accessibility description"
            )
            XCTAssertGreaterThan(
                ZPDFSelfCheck.inkCoverage(of: image, pixelSide: 24), 0,
                "\(kind.rawValue) rendered a fully transparent image"
            )
            XCTAssertFalse(
                ZPDFIconGeometry.designPath(for: kind).isEmpty,
                "\(kind.rawValue) has an empty design path"
            )
        }
    }

    /// A glyph must scale without collapsing or leaving its box.
    func testIconGeometryFitsItsRectAtEverySize() {
        for kind in ZPDFIconKind.allCases {
            for side in [CGFloat(12), 16, 24, 48] {
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                let bounds = ZPDFIconGeometry.path(for: kind, in: rect).boundingRect
                XCTAssertFalse(bounds.isEmpty, "\(kind.rawValue) at \(side)pt produced an empty bounding box")
                XCTAssertGreaterThanOrEqual(bounds.minX, -0.5, "\(kind.rawValue) at \(side)pt overflows on the left")
                XCTAssertGreaterThanOrEqual(bounds.minY, -0.5, "\(kind.rawValue) at \(side)pt overflows on the top")
                XCTAssertLessThanOrEqual(bounds.maxX, side + 0.5, "\(kind.rawValue) at \(side)pt overflows on the right")
                XCTAssertLessThanOrEqual(bounds.maxY, side + 0.5, "\(kind.rawValue) at \(side)pt overflows on the bottom")
            }
        }
    }

    // MARK: - Typography and metrics

    func testNumericRolesUseTabularFigures() {
        XCTAssertEqual(ZPDFTypography.monoNumeric.face, .systemMonospacedDigits)
        XCTAssertEqual(ZPDFTypography.monoNumericStrong.face, .systemMonospacedDigits)
        XCTAssertEqual(ZPDFTypography.code.face, .monospaced)
    }

    func testEveryTypeRoleProducesAUsableFont() {
        for entry in ZPDFTypography.allStyles {
            XCTAssertGreaterThan(ZPDFTypography.nsFont(entry.style).pointSize, 0, entry.name)
            XCTAssertGreaterThan(ZPDFTypography.lineHeight(entry.style), 0, entry.name)
        }
    }

    func testSpacingRampMatchesTheSpecifiedScale() {
        XCTAssertEqual(ZPDFSpacing.ramp, [4, 6, 8, 12, 16, 24])
        XCTAssertGreaterThanOrEqual(ZPDFSpacing.Control.minimumHitTarget, 24)
        XCTAssertEqual(ZPDFStroke.devicePixel(displayScale: 2), 0.5)
        XCTAssertEqual(ZPDFStroke.devicePixel(displayScale: 1), 1)
    }

    // MARK: - Motion

    func testReduceMotionCollapsesEveryTokenToAnInstantChange() {
        let tokens: [ZPDFMotion.Token] = [.micro, .quick, .standard]
        for token in tokens {
            XCTAssertNil(ZPDFMotion.animation(token, reduceMotion: true))
            XCTAssertNotNil(ZPDFMotion.animation(token, reduceMotion: false))
            XCTAssertGreaterThan(token.duration, 0)
            XCTAssertLessThanOrEqual(token.duration, 0.4, "Zenit motion must stay out of the user's way")
        }
    }

    // MARK: - Whole-system audit

    /// The same invariants the `zpdf-design-audit` tool runs, so the two can never drift.
    func testDesignSystemSelfCheckPasses() {
        let report = ZPDFSelfCheck.run()
        XCTAssertGreaterThan(report.assertionCount, 0)
        XCTAssertTrue(
            report.passed,
            "self-check failures:\n" + report.failures.map(\.description).joined(separator: "\n")
        )
    }
}
#endif
