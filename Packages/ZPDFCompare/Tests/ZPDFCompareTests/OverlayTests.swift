import CoreGraphics
import Foundation
import Testing
import ZPDFCompare

/// Revision Overlay: N revisions as colour-tinted layers, and the composited output.
struct OverlayTests {

    private func layer(_ id: Int, colour: OverlayColor, value: UInt8) throws -> (OverlayLayer, OverlaySource) {
        (
            OverlayLayer(id: id, label: "Rev \(id)", color: colour, blendMode: .normal),
            OverlaySource(layerID: id, image: try GrayImage(width: 4, height: 4, filledWith: value))
        )
    }

    private func pixel(_ composite: OverlayComposite, x: Int, y: Int) -> (Int, Int, Int, Int) {
        let base = (y * composite.image.width + x) * 4
        return (
            Int(composite.image.pixels[base]),
            Int(composite.image.pixels[base + 1]),
            Int(composite.image.pixels[base + 2]),
            Int(composite.image.pixels[base + 3])
        )
    }

    @Test("Full-coverage ink paints the layer colour; blank paper leaves the background")
    func fullCoverageTakesTheLayerColour() throws {
        let red = OverlayColor(red: 1, green: 0, blue: 0)
        let (inkLayer, inkSource) = try layer(0, colour: red, value: 0)
        let model = RevisionOverlayModel(layers: [inkLayer])
        let inked = try OverlayCompositor.composite(model: model, sources: [inkSource])
        #expect(pixel(inked, x: 0, y: 0) == (255, 0, 0, 255))
        #expect(inked.contributingLayerIDs == [0])

        let (paperLayer, paperSource) = try layer(0, colour: red, value: 255)
        let blank = try OverlayCompositor.composite(
            model: RevisionOverlayModel(layers: [paperLayer]), sources: [paperSource]
        )
        #expect(pixel(blank, x: 0, y: 0) == (255, 255, 255, 255))
    }

    @Test("Opacity scales the coverage, so half opacity is half way to the layer colour")
    func opacityScalesCoverage() throws {
        var (inkLayer, inkSource) = try layer(0, colour: OverlayColor(red: 0, green: 0, blue: 0), value: 0)
        inkLayer.opacity = 0.5
        let composite = try OverlayCompositor.composite(
            model: RevisionOverlayModel(layers: [inkLayer]), sources: [inkSource]
        )
        // White background, black layer, alpha 0.5 → mid gray.
        #expect(pixel(composite, x: 1, y: 1) == (128, 128, 128, 255))
        _ = inkSource
    }

    @Test("An invisible layer contributes nothing and is not listed as contributing")
    func hiddenLayersAreSkipped() throws {
        var (hidden, hiddenSource) = try layer(0, colour: OverlayColor(red: 1, green: 0, blue: 0), value: 0)
        hidden.isVisible = false
        let (shown, shownSource) = try layer(1, colour: OverlayColor(red: 0, green: 0, blue: 1), value: 0)
        let composite = try OverlayCompositor.composite(
            model: RevisionOverlayModel(layers: [hidden, shown]),
            sources: [hiddenSource, shownSource]
        )
        #expect(composite.contributingLayerIDs == [1])
        #expect(pixel(composite, x: 0, y: 0) == (0, 0, 255, 255))
    }

    @Test("Multiply darkens where two revisions overlap; difference cancels two identical ones")
    func blendModesBehaveAsNamed() throws {
        let grey = OverlayColor(red: 0.5, green: 0.5, blue: 0.5)
        var (first, firstSource) = try layer(0, colour: grey, value: 0)
        var (second, secondSource) = try layer(1, colour: grey, value: 0)
        first.blendMode = .multiply
        second.blendMode = .multiply
        let multiplied = try OverlayCompositor.composite(
            model: RevisionOverlayModel(layers: [first, second]),
            sources: [firstSource, secondSource]
        )
        // 1 × 0.5 = 0.5, then 0.5 × 0.5 = 0.25 → 64.
        #expect(pixel(multiplied, x: 0, y: 0) == (64, 64, 64, 255))

        first.blendMode = .difference
        second.blendMode = .difference
        let differenced = try OverlayCompositor.composite(
            model: RevisionOverlayModel(
                layers: [first, second], background: OverlayColor(red: 0, green: 0, blue: 0)
            ),
            sources: [firstSource, secondSource]
        )
        // |0 − 0.5| = 0.5, then |0.5 − 0.5| = 0 → two identical revisions cancel.
        #expect(pixel(differenced, x: 0, y: 0) == (0, 0, 0, 255))

        first.blendMode = .screen
        let screened = try OverlayCompositor.composite(
            model: RevisionOverlayModel(
                layers: [first], background: OverlayColor(red: 0, green: 0, blue: 0)
            ),
            sources: [firstSource]
        )
        #expect(pixel(screened, x: 0, y: 0) == (128, 128, 128, 255))
    }

    @Test("visibleLayers is the switched-on layers, in stack order")
    func visibleLayersKeepsStackOrder() {
        var model = RevisionOverlayModel.testStack(labels: ["A", "B", "C"])
        #expect(model.visibleLayers.map(\.id) == [0, 1, 2])
        model.layers[0].isVisible = false
        #expect(model.visibleLayers.map(\.id) == [1, 2])
        model.layers[2].isVisible = false
        #expect(model.visibleLayers.map(\.id) == [1])
    }

    @Test("A visible layer without a raster, and mismatched raster sizes, are typed errors")
    func mismatchedOverlayInputsThrow() throws {
        let (only, source) = try layer(0, colour: .black, value: 0)
        let orphan = OverlayLayer(id: 9, label: "orphan", color: .black)
        #expect(throws: CompareFault.self) {
            try OverlayCompositor.composite(
                model: RevisionOverlayModel(layers: [only, orphan]), sources: [source]
            )
        }
        let bigger = OverlaySource(
            layerID: 1, image: try GrayImage(width: 8, height: 8, filledWith: 0)
        )
        let second = OverlayLayer(id: 1, label: "b", color: .black)
        #expect(throws: CompareFault.self) {
            try OverlayCompositor.composite(
                model: RevisionOverlayModel(layers: [only, second]), sources: [source, bigger]
            )
        }
        #expect(throws: CompareFault.self) {
            try OverlayCompositor.composite(model: RevisionOverlayModel(layers: []), sources: [])
        }
    }

    @Test("The composited output survives the round trip to CoreGraphics")
    func compositeProducesACGImage() throws {
        let (inkLayer, inkSource) = try layer(0, colour: OverlayColor(red: 0, green: 0.5, blue: 1), value: 0)
        let composite = try OverlayCompositor.composite(
            model: RevisionOverlayModel(layers: [inkLayer]), sources: [inkSource]
        )
        let image = try composite.image.cgImage()
        #expect(image.width == 4)
        #expect(image.height == 4)
        #expect(image.bitsPerPixel == 32)
    }

    @Test("Three real revisions composite into one image through the comparator")
    func endToEndOverlayOfThreeRevisions() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let model = RevisionOverlayModel.testStack(labels: ["baseline", "revised", "revised again"])
        let composite = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised, harness.revised],
            alignments: [.identity, .identity, .identity],
            model: model,
            scale: 1
        )
        #expect(composite.contributingLayerIDs == [0, 1, 2])
        #expect(composite.image.width == 612)
        #expect(composite.image.height == 792)
        // The sheet is mostly paper, so the background colour must dominate.
        let corner = pixel(composite, x: 2, y: 2)
        #expect(corner == (255, 255, 255, 255))
        // And the added edge, which only the two revision layers carry, must be tinted.
        let inkX = 350
        let inkY = 792 - 600
        let inked = pixel(composite, x: inkX, y: inkY)
        #expect(inked != (255, 255, 255, 255), "expected tinted ink at (\(inkX), \(inkY))")
    }
}
