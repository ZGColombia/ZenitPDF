import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Fix round 3, stamps: an imported stamp looks as drawn by default (decided 2026-09-23,
/// BH-167 follow-up, ADR-0011 §2.4).
///
/// The import reports the one ink a seal was drawn in (`StampArtworkDescriptor.sourceInk`);
/// adopting that artwork into a stamp preset starts the stamp's colour there. The seal's ink
/// regions carry no colour of their own, so the stamp colour is what paints them — and a colour
/// the person chooses afterwards is the explicit recolour.
@MainActor
@Suite("Fix round 3 — a stamp preset starts in its artwork's colour", .workflowsTierSerialised)
struct Fix3StampColourTests {

    private let red = ColorRGBA(red: 1, green: 0, blue: 0)
    private let blue = ColorRGBA(red: 0, green: 0, blue: 1)
    private let toolColour = ColorRGBA(red: 0.2, green: 0.6, blue: 0.3)

    private func artwork(ink: ColorRGBA?, kind: StampArtworkKind = .vector) -> StampArtworkDescriptor {
        StampArtworkDescriptor(
            kind: kind,
            digest: String(repeating: "c", count: 64),
            byteCount: 2048,
            sourceName: "Seal.pdf",
            sourcePageIndex: kind == .vector ? 0 : nil,
            sourceInk: ink
        )
    }

    private func draft(markup: MarkupKind, measurement: MeasurementKind? = nil) -> ToolPresetDraft {
        ToolPresetDraft(
            isNew: true,
            panel: .myTools,
            name: "Approved",
            category: "Stamps",
            markupKind: markup,
            measurementKind: measurement,
            colorRGBA: toolColour,
            defaultSubject: "Approved"
        )
    }

    @Test("A red single-ink seal makes a red stamp")
    func redSealMakesARedStamp() {
        var stamp = draft(markup: .stamp)
        stamp.adoptArtwork(artwork(ink: red))
        // Old output: the tool's own green, so the red seal drew green.
        #expect(stamp.colorRGBA == red)
        #expect(stamp.makePreset().colorRGBA == red)
        #expect(stamp.stamp?.artwork?.sourceInk == red)
    }

    @Test("Choosing another stamp colour afterwards is the recolour, and it sticks")
    func explicitColourWins() {
        var stamp = draft(markup: .stamp)
        stamp.adoptArtwork(artwork(ink: red))
        stamp.colorRGBA = blue
        #expect(stamp.makePreset().colorRGBA == blue)
        // Reopening the saved preset does not snap back to the artwork's ink: the adoption
        // happens once, at import.
        let reopened = ToolPresetDraft(editing: stamp.makePreset())
        #expect(reopened.colorRGBA == blue)
    }

    @Test("A multi-ink seal, raster artwork and an old descriptor leave the stamp colour alone")
    func noSingleInkLeavesTheColour() {
        for descriptor in [artwork(ink: nil), artwork(ink: nil, kind: .raster)] {
            var stamp = draft(markup: .stamp)
            stamp.adoptArtwork(descriptor)
            #expect(stamp.colorRGBA == toolColour)
        }
    }

    @Test("A count symbol keeps the count's colour: it is the takeoff's colour code")
    func countKeepsItsColour() {
        var count = draft(markup: .count, measurement: .count)
        count.adoptArtwork(artwork(ink: red))
        #expect(count.colorRGBA == toolColour)
        #expect(count.stamp?.artwork != nil)
    }

    @Test("A descriptor saved before the ruling decodes with no ink; a new one round-trips it")
    func descriptorCoding() throws {
        let old = Data("""
        {"kind":"vector","digest":"\(String(repeating: "d", count: 64))","byteCount":10,"sourceName":"Old.pdf","sourcePageIndex":0}
        """.utf8)
        let decoded = try JSONDecoder().decode(StampArtworkDescriptor.self, from: old)
        #expect(decoded.sourceInk == nil)

        let current = artwork(ink: red)
        let data = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(StampArtworkDescriptor.self, from: data) == current)
    }
}
