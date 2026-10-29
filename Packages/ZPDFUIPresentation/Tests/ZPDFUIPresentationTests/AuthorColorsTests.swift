import Foundation
import Testing
@testable import ZPDFUIPresentation

/// NL-COLLAB-05/06: one colour per person, readable initials, never colour alone.
@Suite("Author colours")
struct AuthorColorsTests {

    @Test("Two authors get two colours; a renamed person keeps one; the legend names colours in words")
    func assignments() {
        let colours = AuthorColors.assignments(for: ["Bo", "Ada", "Bo", ""])
        #expect(colours.count == 2)
        #expect(colours["Ada"] != colours["Bo"])
        #expect(AuthorColors.legend(colours) == "Ada — Cyan, Bo — Blue")
        let renamed = AuthorColors.assignments(for: ["Alex", "Alex B", "Bo"], aliases: ["Alex", "Alex B"])
        #expect(renamed["Alex"] == renamed["Alex B"], "a rename does not split one person into two")
        #expect(renamed["Bo"] != renamed["Alex"])
    }

    @Test("Every palette colour has initials that pass WCAG AA (4.5:1)")
    func initialsContrast() {
        for entry in ZenitNamedPalette.entries {
            let text = AuthorColors.initialsColor(on: entry.color)
            #expect(AuthorColors.contrast(entry.color, text) >= 4.5, "\(entry.id): \(AuthorColors.contrast(entry.color, text))")
        }
        // Hand-checked end points: black on white is 21:1.
        let white = ColorRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        let black = ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1)
        #expect(abs(AuthorColors.contrast(white, black) - 21) < 0.0001)
    }
}
