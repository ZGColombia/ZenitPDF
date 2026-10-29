import Foundation
import Testing
@testable import ZPDFPDFKitBridge
import ZPDFContracts

/// Fix round 3: an imported stamp looks as drawn by default (decided 2026-09-23, BH-167
/// follow-up, ADR-0011 §2.4).
///
/// The seal's geometry stays recolourable, with its ink regions colourless, so that the stamp
/// colour repaints fills and strokes together. What changes is that the import reports the ink
/// the seal was drawn in (`ImportedArtwork.sourceInk`), and the stamp colour starts there.
///
/// Every expected value is derived by hand from the content stream in the test: `1 0 0 rg` is
/// sRGB (1, 0, 0), which 8-bit storage keeps exact, and so on.
@Suite("Fix round 3 — an imported stamp keeps its source colour")
struct Fix3StampColourTests {

    private let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    private func importPage(_ content: String, label: String) async throws -> ImportedArtwork {
        let url = try HandBuiltPDF.onePage(content: content, mediaBox: "[0 0 100 100]", label: label)
        return try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
    }

    @Test("A red single-ink seal imports red, and its geometry stays recolourable")
    func redSealImportsRed() async throws {
        // Paper, a red disc stand-in and a red ring stand-in: one ink, red, filled and stroked.
        let artwork = try await importPage(
            "1 1 1 rg 0 0 100 100 re f 1 0 0 rg 20 20 60 60 re f 1 0 0 RG 4 w 10 10 80 80 re S",
            label: "red-seal"
        )
        // Before the ruling the import said nothing about the ink, and the seal took whatever
        // colour the tool happened to have.
        #expect(artwork.sourceInk == red)
        // The white sheet is paper and is dropped; the red fill has no colour of its own so the
        // stamp colour, red by default now, paints it and the ring alike.
        #expect(artwork.geometry.regions.count == 1)
        #expect(artwork.geometry.regions.map(\.color) == [nil])
        #expect(artwork.geometry.strokes.count == 1)
    }

    @Test("A seal drawn with strokes alone still reports its ink")
    func strokeOnlySealReportsItsInk() async throws {
        let artwork = try await importPage(
            "1 0 0 RG 2 w 10 10 m 90 10 l 90 90 l 10 90 l h S",
            label: "red-ring"
        )
        #expect(artwork.geometry.regions.isEmpty)
        #expect(artwork.sourceInk == red)
    }

    @Test("A white knockout stays white and is not the seal's ink")
    func knockoutIsNotInk() async throws {
        // Red square, then a white square painted over it: a knockout, not paper.
        let artwork = try await importPage(
            "1 0 0 rg 10 10 80 80 re f 1 1 1 rg 40 40 20 20 re f",
            label: "red-knockout"
        )
        #expect(artwork.sourceInk == red)
        // The ink region follows the stamp colour (red by default, blue when blue is chosen);
        // the knockout carries its own white and stays white under any stamp colour.
        #expect(artwork.geometry.regions.map(\.color) == [nil, white])
    }

    @Test("A multi-ink seal keeps each ink and names no single one")
    func multiInkKeepsEachInk() async throws {
        let artwork = try await importPage(
            "1 1 1 rg 0 0 100 100 re f 1 0 0 rg 10 10 40 40 re f 0 0 1 rg 50 50 40 40 re f 1 1 1 rg 20 20 10 10 re f",
            label: "two-ink"
        )
        #expect(artwork.sourceInk == nil, "two inks: the tool's colour is left alone")
        #expect(artwork.geometry.regions.map(\.color) == [
            red,
            RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
            white
        ])
    }

    @Test("A red fill with a blue outline is two inks, not one")
    func fillAndStrokeInksAreBothCounted() async throws {
        let artwork = try await importPage(
            "1 0 0 rg 20 20 60 60 re f 0 0 1 RG 2 w 10 10 80 80 re S",
            label: "red-fill-blue-ring"
        )
        #expect(artwork.sourceInk == nil)
    }

    @Test("A black seal imports black")
    func blackSealImportsBlack() async throws {
        let artwork = try await importPage("0 g 10 10 80 80 re f", label: "black-seal")
        #expect(artwork.sourceInk == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
    }

    @Test("An ink the extractor cannot state is not guessed")
    func unstatedInkIsNotGuessed() async throws {
        // A Separation (spot) colour: the extractor records `nil` rather than approximate it,
        // so the import must not claim the seal has a colour.
        let separation = "[/Separation /Spot /DeviceCMYK << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 1 0] /N 1 >>]"
        let url = try HandBuiltPDF.write([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /ColorSpace << /CS1 \(separation) >> >> /Contents 4 0 R >>",
            HandBuiltPDF.stream("/CS1 cs 1 sc 10 10 80 80 re f")
        ], label: "spot-seal")
        let artwork = try await StampArtworkImporter().importArtwork(from: .pdfPage(url: url, pageIndex: 0))
        #expect(artwork.geometry.regions.count == 1)
        #expect(artwork.sourceInk == nil)
    }

    @Test("Raster artwork names no single ink: its cells carry their own colours")
    func rasterHasNoSourceInk() async throws {
        let url = try ArtworkFixtures.checkerboardPNG(edge: 8, label: "fix3-checker")
        let artwork = try await StampArtworkImporter().importArtwork(from: .image(url: url))
        #expect(artwork.geometry.kind == .raster)
        #expect(artwork.sourceInk == nil)
    }
}
