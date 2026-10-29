import Foundation
import Testing
@testable import ZPDFDesignSystem

@MainActor
struct LoupeMagnificationLabelTests {
    @Test("Cached loupe labels preserve rounding and refresh for magnification and locale")
    func magnificationAndLocale() {
        for identifier in ["en_US", "sv_SE", "ar_SA", "en_US"] {
            let locale = Locale(identifier: identifier)
            for value in [4.0, 4.0, 2.25, 1.0, 4.0] {
                let expected = String(
                    format: NSLocalizedString("%@x", comment: "Loupe magnification badge, e.g. 4x"),
                    ZPDFNumericField.format(value, fractionDigits: 1, locale: locale)
                )
                #expect(LoupeMagnificationLabel.string(value, locale: locale) == expected)
            }
        }
    }
}
