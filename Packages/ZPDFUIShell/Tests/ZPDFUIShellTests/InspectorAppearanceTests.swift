import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Inspector's appearance controls: formatting, parsing and the mixed state.
///
/// Reported 2026-08-26 and again 2026-08-27: the section showed `Colour #50D6DE` and
/// `Hidden Visible` as plain text, and neither the colour nor the size of an arrow could be
/// changed.
///
/// These pin the arithmetic and the refusals, which is where a number field goes wrong quietly:
/// a typo that navigates somewhere absurd, a clamp that silently discards, a mixed selection that
/// reports one member's value as if it were everyone's.
@Suite("Inspector appearance", .shellTierSerialised)
struct InspectorAppearanceTests {

    // MARK: - Formatting

    @Test("A whole number prints without decimals, a fraction keeps two")
    func numberFormatting() {
        #expect(InspectorNumberControl.format(2) == "2")
        #expect(InspectorNumberControl.format(2.0) == "2")
        #expect(InspectorNumberControl.format(0.25) == "0.25")
        #expect(InspectorNumberControl.format(6.5) == "6.50")
        #expect(InspectorNumberControl.format(100) == "100")
    }

    @Test("No value prints as nothing, so the field shows its mixed prompt instead")
    func noValueFormatsEmpty() {
        #expect(InspectorNumberControl.format(nil).isEmpty)
    }

    // MARK: - The selection summary

    private func summary(lineWidths: [Double]) -> InspectorSelectionSummary {
        let sample = ZenitSampleProject.shared.markups
        let markups = lineWidths.enumerated().map { index, width -> MarkupSummary in
            var markup = sample[index % sample.count]
            markup.lineWidth = width
            return markup
        }
        return InspectorSelectionSummary(markups: markups)
    }

    @Test("One markup reports its own width")
    func singleSelectionHasACommonValue() {
        let selection = summary(lineWidths: [4])
        #expect(selection.common(\.lineWidth) == 4)
        #expect(selection.isMixed(\.lineWidth) == false)
    }

    @Test("A selection that agrees reports the agreed width")
    func agreeingSelectionHasACommonValue() {
        let selection = summary(lineWidths: [3, 3, 3])
        #expect(selection.common(\.lineWidth) == 3)
        #expect(selection.isMixed(\.lineWidth) == false)
    }

    @Test("A selection that disagrees reports mixed, and no value at all")
    func disagreeingSelectionIsMixed() {
        let selection = summary(lineWidths: [1, 4, 9])
        #expect(selection.isMixed(\.lineWidth))
        #expect(
            selection.common(\.lineWidth) == nil,
            """
            A mixed selection must not report a value. Showing the first markup's width invites \
            the reader to confirm a number they never chose and flatten the rest.
            """
        )
    }

    // MARK: - What a control writes

    @Test("A style edit names only the field it changed")
    func aStyleEditNamesOneField() {
        let edit = MarkupStyleEdit(lineWidth: 6)
        #expect(edit.lineWidth == 6)
        #expect(edit.color == nil)
        #expect(edit.opacity == nil)
        #expect(edit.lineStyle == nil)
        #expect(edit.fontSize == nil)
        #expect(edit.isEmpty == false)
    }

    @Test("Opacity is carried as a fraction, however it is shown")
    func opacityIsAFraction() {
        // The control shows 0…100 and writes 0…1. Getting this backwards makes every markup
        // either invisible or unchanged, and both look like the control is broken.
        let shown: Double = 40
        let edit = MarkupStyleEdit(opacity: shown / 100)
        #expect(edit.opacity == 0.4)
    }

    @Test("Every line style has a name a person can pick from a menu")
    func lineStylesAreNamed() {
        for style in MarkupLineStyle.allCases {
            #expect(!style.displayName.isEmpty, "\(style) has no name")
        }
        #expect(MarkupLineStyle.allCases.count == 5)
    }
}
