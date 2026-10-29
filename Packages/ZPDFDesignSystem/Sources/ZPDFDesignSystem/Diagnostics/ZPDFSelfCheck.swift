import AppKit
import SwiftUI

/// Runtime verification of the design system's two hard invariants:
/// every semantic colour token resolves in every appearance, and every measurement glyph
/// actually draws something.
///
/// The logic lives in the library rather than only in the test target so it can run in three
/// places: the unit tests, the `zpdf-design-audit` command-line tool, and a debug menu item
/// inside the app. It performs no I/O and mutates no global state.
@MainActor
public enum ZPDFSelfCheck {

    /// One failed invariant.
    public struct Failure: Sendable, Hashable {
        public let check: String
        public let detail: String

        public init(check: String, detail: String) {
            self.check = check
            self.detail = detail
        }

        public var description: String { "\(check): \(detail)" }
    }

    /// The outcome of a full run.
    public struct Report: Sendable {
        public let assertionCount: Int
        public let failures: [Failure]

        public var passed: Bool { failures.isEmpty }
    }

    /// Runs every invariant and returns what broke.
    public static func run() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        let colorResult = verifyColorTokens()
        assertions += colorResult.assertionCount
        failures.append(contentsOf: colorResult.failures)

        let iconResult = verifyIcons()
        assertions += iconResult.assertionCount
        failures.append(contentsOf: iconResult.failures)

        let variantResult = verifyIncreaseContrastVariants()
        assertions += variantResult.assertionCount
        failures.append(contentsOf: variantResult.failures)

        let contrastResult = verifyTextContrast()
        assertions += contrastResult.assertionCount
        failures.append(contentsOf: contrastResult.failures)

        let borderResult = verifyHighContrastBorders()
        assertions += borderResult.assertionCount
        failures.append(contentsOf: borderResult.failures)

        let groundResult = verifyGroundsAreDistinguishable()
        assertions += groundResult.assertionCount
        failures.append(contentsOf: groundResult.failures)

        let mockupResult = verifyMockupContrast()
        assertions += mockupResult.assertionCount
        failures.append(contentsOf: mockupResult.failures)

        let typeResult = verifyTypography()
        assertions += typeResult.assertionCount
        failures.append(contentsOf: typeResult.failures)

        let paletteResult = verifyMarkupPalette()
        assertions += paletteResult.assertionCount
        failures.append(contentsOf: paletteResult.failures)

        return Report(assertionCount: assertions, failures: failures)
    }

    // MARK: - Markup palette

    /// The colour palette's inks (NL-MARKUP-01): each holds 4.5:1 on paper — a text box's
    /// stroke is its text colour — each has a distinct name and value, and the first three are
    /// the design-system ink tokens rather than near copies of them.
    public static func verifyMarkupPalette() -> Report {
        var failures: [Failure] = []
        var assertions = 0
        for ink in ZPDFMarkupInk.allCases {
            let ratio = Double(ink.rgba.contrastRatio(against: paper))
            assertions += 1
            if ratio < 4.5 {
                failures.append(Failure(
                    check: "palette.contrast",
                    detail: String(format: "%@ on paper is %.2f:1, below 4.5:1", ink.rawValue, ratio)
                ))
            }
        }
        assertions += 2
        if Set(ZPDFMarkupInk.allCases.map(\.displayName)).count != ZPDFMarkupInk.allCases.count {
            failures.append(Failure(check: "palette.names", detail: "two palette inks share a name"))
        }
        if Set(ZPDFMarkupInk.allCases.map(\.rgba.hexString)).count != ZPDFMarkupInk.allCases.count {
            failures.append(Failure(check: "palette.values", detail: "two palette inks share a value"))
        }
        let tokens: [(ZPDFMarkupInk, ZPDFColorToken)] = [(.blue, .inkBlue), (.red, .inkRed), (.green, .inkGreen)]
        for (ink, token) in tokens {
            assertions += 1
            if ink.rgba != ZPDFColor.rgba(token, .light) {
                failures.append(Failure(check: "palette.tokens", detail: "\(ink.rawValue) is not the \(token.rawValue) token"))
            }
        }
        return Report(assertionCount: assertions, failures: failures)
    }

    // MARK: - Increase Contrast

    /// Asserts that Increase Contrast actually changes the palette rather than aliasing it.
    ///
    /// A token is allowed to keep its normal value in the high-contrast variant only when it
    /// is already at the end of the axis the variant would move it along: a light surface that
    /// is already pure white cannot get lighter, and a dark one that is already pure black
    /// cannot get darker. In that case the extra contrast is carried by the border and text
    /// tokens drawn on top, which must still differ. Anything else sharing a value means the
    /// accessibility path is decorative, so it is reported.
    public static func verifyIncreaseContrastVariants() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for token in ZPDFColorToken.allCases {
            let set = ZPDFColor.set(for: token)

            if ZPDFColorToken.appearanceInvariant.contains(token) {
                // The opposite rule: an invariant token must really be one value everywhere.
                assertions += 1
                let values = ZPDFAppearanceVariant.allCases.map { set.value(for: $0) }
                if Set(values).count != 1 {
                    failures.append(Failure(
                        check: "contrast.variant.invariant",
                        detail: "\(token.rawValue) is declared appearance-invariant but differs between variants"
                    ))
                }
                assertions += 1
                continue
            }

            assertions += 1
            if set.light == set.lightHighContrast, !isPureWhite(set.light) {
                failures.append(Failure(
                    check: "contrast.variant.light",
                    detail: "\(token.rawValue) has no distinct light Increase Contrast value"
                ))
            }

            assertions += 1
            if set.dark == set.darkHighContrast, !isPureBlack(set.dark) {
                failures.append(Failure(
                    check: "contrast.variant.dark",
                    detail: "\(token.rawValue) has no distinct dark Increase Contrast value"
                ))
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    /// Whether a colour is opaque white, the ceiling a light Increase Contrast value moves toward.
    public static func isPureWhite(_ colour: ZPDFRGBA) -> Bool {
        colour.red >= 1 && colour.green >= 1 && colour.blue >= 1 && colour.alpha >= 1
    }

    /// Whether a colour is opaque black, the floor a dark Increase Contrast value moves toward.
    public static func isPureBlack(_ colour: ZPDFRGBA) -> Bool {
        colour.red <= 0 && colour.green <= 0 && colour.blue <= 0 && colour.alpha >= 1
    }

    // MARK: - Colour

    /// Asserts that every token resolves in every appearance variant, and that the value it
    /// resolves to is exactly the one the palette declares.
    ///
    /// Two paths are checked. The pinned path (`ZPDFColor.nsColor(_:variant:)`) is checked for
    /// all four variants. The dynamic path — the `NSColor(name:dynamicProvider:)` colour that
    /// real views hold — is checked for every variant the running system will actually vend;
    /// macOS refuses to hand out the `NSAppearanceNameAccessibility*` appearances unless
    /// Increase Contrast is on, so on a normal machine the two high-contrast variants are
    /// covered by the pinned path only. Light and dark must always be covered dynamically.
    public static func verifyColorTokens() -> Report {
        var failures: [Failure] = []
        var assertions = 0
        var dynamicallyCovered: Set<ZPDFAppearanceVariant> = []

        for token in ZPDFColorToken.allCases {
            let dynamic = ZPDFColor.nsColor(token)

            for variant in ZPDFAppearanceVariant.allCases {
                let expected = ZPDFColor.rgba(token, variant)

                // Pinned resolution.
                assertions += 1
                guard let pinned = ZPDFColor.nsColor(token, variant: variant).usingColorSpace(.sRGB) else {
                    failures.append(Failure(
                        check: "colour.pinned",
                        detail: "\(token.rawValue) in \(variant.rawValue) could not be converted to sRGB"
                    ))
                    continue
                }
                if let mismatch = mismatch(pinned, expected) {
                    failures.append(Failure(
                        check: "colour.pinned.value",
                        detail: "\(token.rawValue) in \(variant.rawValue) \(mismatch)"
                    ))
                }

                // Dynamic resolution through the drawing appearance.
                guard let appearance = variant.appearance else {
                    failures.append(Failure(
                        check: "colour.appearance",
                        detail: "system did not vend appearance \(variant.appearanceName.rawValue)"
                    ))
                    continue
                }
                guard ZPDFAppearanceVariant.matching(appearance) == variant else {
                    // The system substituted a different appearance for this name; the pinned
                    // assertion above already covered the palette value.
                    continue
                }

                assertions += 1
                var resolved: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    resolved = dynamic.usingColorSpace(.sRGB)
                }
                guard let resolved else {
                    failures.append(Failure(
                        check: "colour.dynamic",
                        detail: "\(token.rawValue) did not resolve in \(variant.rawValue)"
                    ))
                    continue
                }
                if let mismatch = mismatch(resolved, expected) {
                    failures.append(Failure(
                        check: "colour.dynamic.value",
                        detail: "\(token.rawValue) in \(variant.rawValue) \(mismatch)"
                    ))
                }
                dynamicallyCovered.insert(variant)
            }
        }

        // A skipped variant must never silently empty out the dynamic path: at least one
        // light-family and one dark-family variant has to have gone through it.
        assertions += 1
        if !dynamicallyCovered.contains(where: { !$0.isDark }) {
            failures.append(Failure(
                check: "colour.coverage",
                detail: "no token was dynamically resolved in any light appearance"
            ))
        }
        assertions += 1
        if !dynamicallyCovered.contains(where: { $0.isDark }) {
            failures.append(Failure(
                check: "colour.coverage",
                detail: "no token was dynamically resolved in any dark appearance"
            ))
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    /// Describes how a resolved colour differs from its palette entry, or `nil` if it matches.
    private static func mismatch(_ resolved: NSColor, _ expected: ZPDFRGBA) -> String? {
        let tolerance: CGFloat = 1.0 / 255.0
        let matches = abs(resolved.redComponent - expected.red) <= tolerance
            && abs(resolved.greenComponent - expected.green) <= tolerance
            && abs(resolved.blueComponent - expected.blue) <= tolerance
            && abs(resolved.alphaComponent - expected.alpha) <= tolerance
        guard !matches else { return nil }
        return "resolved to "
            + String(format: "(%.3f, %.3f, %.3f, %.3f)",
                     resolved.redComponent, resolved.greenComponent,
                     resolved.blueComponent, resolved.alphaComponent)
            + " but the palette declares \(expected.hexString) at alpha \(expected.alpha)"
    }

    // MARK: - Icons

    /// Asserts that every measurement glyph renders a template image with visible ink in it.
    public static func verifyIcons() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for kind in ZPDFIconKind.allCases {
            assertions += 1
            let image = ZPDFIcon.image(kind, size: 24)

            if image.size.width <= 0 || image.size.height <= 0 {
                failures.append(Failure(check: "icon.size", detail: "\(kind.rawValue) rendered at zero size"))
                continue
            }
            if !image.isTemplate {
                failures.append(Failure(check: "icon.template", detail: "\(kind.rawValue) is not a template image"))
            }
            if (image.accessibilityDescription ?? "").isEmpty {
                failures.append(Failure(check: "icon.accessibility", detail: "\(kind.rawValue) has no accessibility description"))
            }

            let coverage = inkCoverage(of: image, pixelSide: 24)
            if coverage <= 0 {
                failures.append(Failure(check: "icon.ink", detail: "\(kind.rawValue) rendered a fully transparent image"))
            }

            assertions += 1
            if ZPDFIconGeometry.designPath(for: kind).isEmpty {
                failures.append(Failure(check: "icon.geometry", detail: "\(kind.rawValue) has an empty design path"))
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    /// The fraction of pixels in a rendered image that carry any ink at all (0.0 ... 1.0).
    public static func inkCoverage(of image: NSImage, pixelSide: Int) -> Double {
        guard pixelSide > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSide,
                pixelsHigh: pixelSide,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: pixelSide * 4,
                bitsPerPixel: 32
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(pixelSide), height: CGFloat(pixelSide)),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return 0 }
        let total = pixelSide * pixelSide
        var inked = 0
        for index in 0..<total where data[index * 4 + 3] > 0 {
            inked += 1
        }
        return Double(inked) / Double(total)
    }

    // MARK: - Contrast

    /// Asserts that primary and secondary text clear WCAG thresholds on their own grounds.
    public static func verifyTextContrast() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        let grounds: [ZPDFColorToken] = [.background, .surface, .elevated]
        for variant in ZPDFAppearanceVariant.allCases {
            for ground in grounds {
                let groundValue = ZPDFColor.rgba(ground, variant)

                assertions += 1
                let primary = ZPDFColor.rgba(.textPrimary, variant).contrastRatio(against: groundValue)
                if primary < 4.5 {
                    failures.append(Failure(
                        check: "contrast.textPrimary",
                        detail: String(format: "%@ on %@ in %@ is %.2f:1, below 4.5:1",
                                       "textPrimary", ground.rawValue, variant.rawValue, primary)
                    ))
                }

                assertions += 1
                let secondary = ZPDFColor.rgba(.textSecondary, variant).contrastRatio(against: groundValue)
                // BH-504: secondary text is drawn at caption size (11 pt) — units, labels,
                // status values — where WCAG AA asks 4.5:1. The 3:1 floor is the large-text
                // one and let a palette edit drop every unit label below AA unnoticed.
                if secondary < Self.secondaryTextMinimumContrast {
                    failures.append(Failure(
                        check: "contrast.textSecondary",
                        detail: String(format: "%@ on %@ in %@ is %.2f:1, below 4.5:1",
                                       "textSecondary", ground.rawValue, variant.rawValue, secondary)
                    ))
                }
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    // MARK: - Borders and grounds

    /// The grounds a border or a panel is ever drawn against.
    static let groundTokens: [ZPDFColorToken] = [.background, .surface, .elevated]

    /// Asserts that the Increase Contrast border clears 3:1 **as rendered** on every ground.
    ///
    /// Checked in the two high-contrast variants only. The normal hairline is a separator that
    /// carries no information on its own; in Increase Contrast the same stroke is the boundary
    /// of a control, which WCAG 1.4.11 puts at 3:1. The measurement composites the border's
    /// alpha over the ground first — measuring the declared colour instead is how a 28 % white
    /// hairline rendering at 2.4:1 was recorded as white-on-black and passed. Finding CR-194.
    public static func verifyHighContrastBorders() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for variant in [ZPDFAppearanceVariant.lightHighContrast, .darkHighContrast] {
            let border = ZPDFColor.rgba(.border, variant)
            for ground in groundTokens {
                let groundValue = ZPDFColor.rgba(ground, variant)
                let ratio = border.composited(over: groundValue).contrastRatio(against: groundValue)

                assertions += 1
                if ratio < 3.0 {
                    failures.append(Failure(
                        check: "contrast.border",
                        detail: String(format: "border on %@ in %@ renders at %.2f:1, below 3.0:1",
                                       ground.rawValue, variant.rawValue, ratio)
                    ))
                }
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    /// Asserts that the three grounds are actually three grounds in every variant.
    ///
    /// A panel standing on the canvas has to read as a panel. In Increase Contrast the light
    /// background and the light surface were both pure white, so the edge between the drawing
    /// and the inspector was carried by the hairline alone — in the one appearance chosen by
    /// people who need that edge to be obvious. Finding CR-195.
    /// WCAG AA for normal-size text; secondary text is caption-sized (BH-504).
    public static let secondaryTextMinimumContrast = 4.5

    /// The smallest step between the background and surface grounds that still reads as two
    /// tones. Every shipped variant is at 1.07:1 or more (BH-505).
    public static let groundsMinimumContrast = 1.05

    public static func verifyGroundsAreDistinguishable() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for variant in ZPDFAppearanceVariant.allCases {
            let background = ZPDFColor.rgba(.background, variant)
            let surface = ZPDFColor.rgba(.surface, variant)

            assertions += 1
            // BH-505: equality only caught bit-identical values; 0xFEFEFE against 0xFFFFFF
            // (1.01:1) passed. The two grounds must differ by a visible step.
            let ratio = background.contrastRatio(against: surface)
            if ratio < Self.groundsMinimumContrast {
                failures.append(Failure(
                    check: "contrast.grounds",
                    detail: String(format: "background and surface are %.3f:1 apart in %@, below %.2f:1",
                                   ratio, variant.rawValue, Self.groundsMinimumContrast)
                ))
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    // MARK: - Mockup tokens

    /// One contrast requirement between a foreground token and the ground it is drawn on.
    public struct ContrastPair: Sendable, Hashable {
        public let foreground: ZPDFColorToken
        public let ground: ZPDFColorToken
        public let minimum: Double
        /// What the pair is for, so a failure names the real surface.
        public let purpose: String
    }

    /// Paper white: markup inks and label pills are always drawn on a light PDF page, in dark
    /// mode too, so they are measured against the page rather than against the chrome.
    public static var paper: ZPDFRGBA { ZPDFColor.rgba(.paper, .light) }

    /// The contrast rules the 2026-09-23 mockup tokens add. Text pairs ask WCAG AA (4.5:1);
    /// the accent chip against the window chrome asks the 3:1 of a component boundary.
    public static let mockupContrastPairs: [ContrastPair] = [
        ContrastPair(foreground: .textTertiary, ground: .background, minimum: 4.5, purpose: "tagline on the top bar"),
        ContrastPair(foreground: .textTertiary, ground: .surface, minimum: 4.5, purpose: "placeholder and counts on a panel"),
        ContrastPair(foreground: .textTertiary, ground: .inset, minimum: 4.5, purpose: "placeholder in a field"),
        ContrastPair(foreground: .textTertiary, ground: .elevated, minimum: 4.5, purpose: "metadata on a raised card"),
        ContrastPair(foreground: .textPrimary, ground: .inset, minimum: 4.5, purpose: "field text"),
        ContrastPair(foreground: .textSecondary, ground: .inset, minimum: 4.5, purpose: "secondary text in a field"),
        ContrastPair(foreground: .textPrimary, ground: .selectedFill, minimum: 4.5, purpose: "selected tab label"),
        ContrastPair(foreground: .textOnAccent, ground: .accent, minimum: 4.5, purpose: "active tool label"),
        ContrastPair(foreground: .textOnAccent, ground: .pillFill, minimum: 4.5, purpose: "measurement pill label"),
        ContrastPair(foreground: .accent, ground: .background, minimum: 3.0, purpose: "active tool chip against the top bar"),
        ContrastPair(foreground: .accentBlue, ground: .surface, minimum: 3.0, purpose: "selected-tab indicator and focus ring on a panel"),
        ContrastPair(foreground: .accentBlue, ground: .elevated, minimum: 3.0, purpose: "selected card border against its raised fill"),
        ContrastPair(foreground: .accentBlue, ground: .background, minimum: 3.0, purpose: "toggled button edge on the chrome"),
        ContrastPair(foreground: .accentBlue, ground: .selectedFill, minimum: 3.0, purpose: "selected-tab underline on its own fill"),
        ContrastPair(foreground: .success, ground: .surface, minimum: 4.5, purpose: "success text on a panel"),
        ContrastPair(foreground: .success, ground: .background, minimum: 4.5, purpose: "success text on the chrome"),
        ContrastPair(foreground: .textPrimary, ground: .ledgerBar, minimum: 4.5, purpose: "ledger bar labels"),
        ContrastPair(foreground: .textSecondary, ground: .ledgerBar, minimum: 4.5, purpose: "ledger bar chip titles"),
        ContrastPair(foreground: .accentBlue, ground: .ledgerBar, minimum: 3.0, purpose: "selected ledger tab underline")
    ]

    /// Inks drawn on paper, each held to the 3:1 WCAG 1.4.11 asks of meaningful graphics.
    public static let paperInks: [ZPDFColorToken] = [.inkBlue, .inkRed, .inkGreen, .pillFill, .accent]

    /// Checks every mockup pair in every appearance, compositing translucent grounds over
    /// `background` first so the ratio is the one a person actually sees.
    public static func verifyMockupContrast() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for variant in ZPDFAppearanceVariant.allCases {
            let base = ZPDFColor.rgba(.background, variant)
            for pair in mockupContrastPairs {
                let ground = ZPDFColor.rgba(pair.ground, variant).composited(over: base)
                let foreground = ZPDFColor.rgba(pair.foreground, variant).composited(over: ground)
                let ratio = Double(foreground.contrastRatio(against: ground))
                assertions += 1
                if ratio < pair.minimum {
                    failures.append(Failure(
                        check: "contrast.mockup",
                        detail: String(format: "%@ on %@ (%@) in %@ is %.2f:1, below %.1f:1",
                                       pair.foreground.rawValue, pair.ground.rawValue, pair.purpose,
                                       variant.rawValue, ratio, pair.minimum)
                    ))
                }
            }
            for ink in paperInks {
                let ratio = Double(ZPDFColor.rgba(ink, variant).composited(over: paper).contrastRatio(against: paper))
                assertions += 1
                if ratio < 3.0 {
                    failures.append(Failure(
                        check: "contrast.paperInk",
                        detail: String(format: "%@ on paper in %@ is %.2f:1, below 3.0:1", ink.rawValue, variant.rawValue, ratio)
                    ))
                }
            }
        }

        return Report(assertionCount: assertions, failures: failures)
    }

    // MARK: - Typography

    /// Asserts that the ramp produces usable fonts and that numeric roles are tabular.
    public static func verifyTypography() -> Report {
        var failures: [Failure] = []
        var assertions = 0

        for entry in ZPDFTypography.allStyles {
            assertions += 1
            let font = ZPDFTypography.nsFont(entry.style)
            if font.pointSize <= 0 {
                failures.append(Failure(check: "type.size", detail: "\(entry.name) produced a zero point size"))
            }
            if ZPDFTypography.lineHeight(entry.style) <= 0 {
                failures.append(Failure(check: "type.lineHeight", detail: "\(entry.name) produced a zero line height"))
            }
        }

        assertions += 1
        let numericFaces: Set<ZPDFTextStyle.Face> = [.systemMonospacedDigits, .monospaced]
        if !numericFaces.contains(ZPDFTypography.monoNumeric.face) {
            failures.append(Failure(
                check: "type.tabularFigures",
                detail: "monoNumeric must use a tabular-figure face so numeric columns keep their width"
            ))
        }

        return Report(assertionCount: assertions, failures: failures)
    }
}
