import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2: stamp templates.
@Suite("Fix2 stamp templates")
struct Fix2StampTemplateTests {

    private func raster(width: Int, height: Int) -> StampArtworkDescriptor {
        StampArtworkDescriptor(kind: .raster, digest: "d", pixelWidth: width, pixelHeight: height)
    }

    /// BH-280. Old output: "Fatal error: Double value cannot be converted to Int because it is
    /// either infinite or NaN" for a preset whose box width read 1e-300.
    @Test("A corrupt box width does not trap the sharpness warning")
    func corruptWidthDoesNotTrap() {
        for width in [1e-300, Double.leastNonzeroMagnitude] {
            let template = StampTemplate(id: UUID(), widthPoints: width, heightPoints: 60, artwork: raster(width: Int.max / 2, height: 10))
            #expect(template.rasterSharpnessWarning?.isEmpty == false)
        }
    }

    /// BH-794. Old output: "Sharp to about 188 % magnification" for a 300 × 300 px seal in a
    /// 160 × 60 pt box, which the canvas draws 60 pt wide (500 %).
    ///
    /// BH-166 then capped it at the stored 96-cell mosaic: the same seal
    /// is kept at 96 × 96 cells, drawn 60 pt wide — sharp to 160 %.
    @Test("The sharpness figure follows the letterboxed artwork and the stored mosaic")
    func sharpnessFollowsTheFittedArtwork() throws {
        let artwork = raster(width: 300, height: 300)
        #expect(artwork.mosaicColumns == 96)
        let magnification = try #require(artwork.sharpUntilMagnification(inBoxWidthPoints: 160, heightPoints: 60))
        #expect(abs(magnification - 1.6) < 1e-9)
        let template = StampTemplate(id: UUID(), widthPoints: 160, heightPoints: 60, artwork: artwork)
        #expect(template.rasterSharpnessWarning?.contains("160") == true)
        // A small image is stored at its own size: 48 × 24 px in a 48 × 24 pt box, 100 %.
        let small = raster(width: 48, height: 24)
        #expect(small.mosaicColumns == 48)
        #expect(small.sharpUntilMagnification(inBoxWidthPoints: 48, heightPoints: 24) == 1)
    }

    /// BH-795 / BH-796. Old output: two free-text fields both keyed "freeText" (slot 0), and
    /// both resolved to the single prompted text: "Checked by: J. Berg / Note: J. Berg".
    @Test("Two free-text fields get distinct keys and their own answers")
    func twoFreeTextFieldsAreDistinct() {
        let template = StampTemplate(id: UUID(), fields: [
            StampFieldDefinition(kind: .freeText, prompt: "Checked by", textPrefix: "Checked by: "),
            StampFieldDefinition(kind: .freeText, prompt: "Note", textPrefix: "Note: ")
        ])
        let prompts = template.placementPrompts
        #expect(prompts.map(\.prompt) == ["Checked by", "Note"])
        #expect(Set(prompts.map(\.slot)).count == 2)
        #expect(Set(template.normalizedFields.map(\.key)).count == 2)

        let context = StampResolutionContext(
            now: Date(timeIntervalSince1970: 0), promptedText: "J. Berg",
            promptedTexts: [prompts[1].slot: "Re-check"]
        )
        let resolved = template.resolve(in: context)
        #expect(resolved.map(\.text) == ["Checked by: J. Berg", "Note: Re-check"])
        #expect(Set(resolved.map(\.slot)).count == 2)

        // A single-question caller still fills the first field only.
        let single = template.resolve(in: StampResolutionContext(now: Date(timeIntervalSince1970: 0), promptedText: "J. Berg"))
        #expect(single.map(\.text) == ["Checked by: J. Berg", "Note: "])
        #expect(template.placementPrompt == "Checked by")
    }
}
