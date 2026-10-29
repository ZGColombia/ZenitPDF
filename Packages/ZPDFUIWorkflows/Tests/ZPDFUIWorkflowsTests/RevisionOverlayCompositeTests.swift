import CoreGraphics
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Everything Revision Overlay's mode state does once there is a real composited picture in it:
/// the legend that keeps colour from being the only cue, the two-click gesture that is the only
/// way an alignment point can be created, and the outward hooks that make a layer edit reach a
/// compositor at all.
///
/// Tests never drive the screen, so the click arithmetic is proved here as arithmetic or it is
/// not proved.
@Suite("Revision Overlay composite", .workflowsTierSerialised)
@MainActor
struct RevisionOverlayCompositeTests {

    private func revision(_ name: String, label: String = "Rev A") -> RevisionSummary {
        RevisionSummary(
            id: UUID(),
            documentID: UUID(),
            name: name,
            revisionLabel: label,
            author: "",
            pageCount: 1,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            fileName: "\(name).pdf"
        )
    }

    /// A one-pixel picture. The composite's *contents* are the engine's business and are
    /// asserted in `ZPDFCompare`; what matters here is the geometry travelling with it.
    private func composite(
        pixelWidth: Int = 400,
        pixelHeight: Int = 200,
        pageBox: PDFRectValue = PDFRectValue(x: 0, y: 0, width: 200, height: 100),
        scale: Double = 2,
        requestedScale: Double = 2,
        layers: [RevisionSummary.ID] = []
    ) throws -> RevisionOverlayComposite {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return RevisionOverlayComposite(
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pageBox: pageBox,
            scale: scale,
            requestedScale: requestedScale,
            contributingLayerIDs: layers,
            elapsedNanoseconds: 12_000_000
        )
    }

    // MARK: - The legend

    @Test("The legend names every visible revision, its designation and its colour — never hue alone")
    func legendNamesEveryVisibleRevision() {
        let a = revision("Ground Floor", label: "Rev B")
        let b = revision("Ground Floor", label: "Rev C")
        let model = RevisionOverlayModel(revisions: [a, b])
        let entries = model.legendEntries
        #expect(entries.count == 2)
        #expect(entries.map(\.position) == [1, 2])
        #expect(entries.map(\.revisionLabel) == ["Rev B", "Rev C"])
        #expect(Set(entries.map(\.colorName)).count == 2, "two layers share a colour name")
        #expect(entries.allSatisfy { !$0.colorName.isEmpty && !$0.revisionName.isEmpty })
        for entry in entries {
            #expect(entry.accessibilityLabel.contains(entry.revisionName))
            #expect(entry.accessibilityLabel.contains(entry.colorName))
        }
        model.setVisible(false, forLayer: b.id)
        #expect(model.legendEntries.map(\.id) == [a.id],
                "a hidden layer is still named in the legend")
    }

    // MARK: - Marking a point

    @Test("Two clicks make one point pair, and the second is mapped out of the current fit")
    func twoClicksMakeAPair() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.captureStage == .off)
        #expect(model.capturePoint(PDFPointValue(x: 10, y: 10)) == false,
                "a click before arming captured something")
        #expect(model.pointPairs.isEmpty)

        model.beginPointCapture()
        #expect(model.captureStage == .awaitingBaseline)
        #expect(model.captureStage.instruction != nil)
        #expect(model.capturePoint(PDFPointValue(x: 10, y: 20)) == false)
        #expect(model.captureStage == .awaitingComparison(PDFPointValue(x: 10, y: 20)))
        #expect(model.capturePoint(PDFPointValue(x: 40, y: 20)))
        #expect(model.captureStage == .off)
        #expect(model.pointPairs.count == 1)
        // No fit yet, so the two spaces are the same and the click is stored verbatim.
        #expect(model.pointPairs[0].baselinePoint == PDFPointValue(x: 10, y: 20))
        #expect(model.pointPairs[0].comparisonPoint == PDFPointValue(x: 40, y: 20))

        // A second pair completes a two-point fit; the sheet is now drawn through it.
        model.beginPointCapture()
        model.capturePoint(PDFPointValue(x: 110, y: 20))
        model.capturePoint(PDFPointValue(x: 140, y: 20))
        #expect(model.fit != nil, "two pairs did not produce a two-point fit")

        // The next click on the composite is a click on where the comparison sheet is *drawn*.
        // It must be stored where that feature lives on the comparison sheet itself, or the
        // re-fit would chase its own tail.
        let before = model.pointPairs.count
        model.beginPointCapture()
        model.capturePoint(PDFPointValue(x: 60, y: 300))
        model.capturePoint(PDFPointValue(x: 60, y: 300))
        #expect(model.pointPairs.count == before + 1)
        let stored = model.pointPairs[before]
        #expect(stored.baselinePoint == PDFPointValue(x: 60, y: 300))
        #expect(stored.comparisonPoint != stored.baselinePoint,
                "the second click was stored in baseline space, not the comparison sheet's")
    }

    @Test("A half-finished point can be abandoned, and Start Over disarms the gesture")
    func captureCanBeAbandoned() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        model.beginPointCapture()
        model.capturePoint(PDFPointValue(x: 1, y: 1))
        model.cancelPointCapture()
        #expect(model.captureStage == .off)
        #expect(model.pointPairs.isEmpty)

        model.capturePair(baseline: .zero, comparison: .zero)
        model.beginPointCapture()
        model.clearPairs()
        #expect(model.captureStage == .off)
        #expect(model.pointPairs.isEmpty)
    }

    // MARK: - Where a click lands

    @Test("A click is placed on the aspect-fitted picture, and a click beside it is refused")
    func clicksLandOnThePicture() {
        // A 2:1 picture in a 1:1 pane: it is letterboxed, 100 pt tall in the middle of 200.
        let pane = CGSize(width: 200, height: 200)
        let centre = RevisionOverlayGeometry.unitPoint(
            forClickAt: CGPoint(x: 100, y: 100), in: pane, imagePixelWidth: 400, imagePixelHeight: 200
        )
        #expect(centre == CGPoint(x: 0.5, y: 0.5))

        let topLeft = RevisionOverlayGeometry.unitPoint(
            forClickAt: CGPoint(x: 0, y: 50), in: pane, imagePixelWidth: 400, imagePixelHeight: 200
        )
        #expect(topLeft == CGPoint(x: 0, y: 0))

        #expect(RevisionOverlayGeometry.unitPoint(
            forClickAt: CGPoint(x: 100, y: 10), in: pane,
            imagePixelWidth: 400, imagePixelHeight: 200
        ) == nil, "a click on the letterbox was placed on the sheet")

        // A 1:2 picture in the same pane: pillarboxed instead.
        #expect(RevisionOverlayGeometry.unitPoint(
            forClickAt: CGPoint(x: 10, y: 100), in: pane,
            imagePixelWidth: 200, imagePixelHeight: 400
        ) == nil)
        #expect(RevisionOverlayGeometry.unitPoint(
            forClickAt: CGPoint(x: 100, y: 100), in: pane,
            imagePixelWidth: 200, imagePixelHeight: 400
        ) == CGPoint(x: 0.5, y: 0.5))

        #expect(RevisionOverlayGeometry.unitPoint(
            forClickAt: .zero, in: .zero, imagePixelWidth: 10, imagePixelHeight: 10
        ) == nil)
    }

    @Test("A point on the picture is a point on the sheet, with y the way PDF measures it")
    func unitPointsBecomePageSpace() throws {
        let sheet = try composite(pageBox: PDFRectValue(x: 20, y: 30, width: 200, height: 100))
        // Top-left of the picture is the *upper* left of the sheet: maximum y.
        #expect(sheet.pagePoint(atUnitPoint: CGPoint(x: 0, y: 0)) == PDFPointValue(x: 20, y: 130))
        #expect(sheet.pagePoint(atUnitPoint: CGPoint(x: 1, y: 1)) == PDFPointValue(x: 220, y: 30))
        #expect(sheet.pagePoint(atUnitPoint: CGPoint(x: 0.5, y: 0.5)) == PDFPointValue(x: 120, y: 80))
    }

    // MARK: - The composite's own state

    @Test("A running composite keeps the previous picture; a failed one takes it away")
    func compositeStatusKeepsOrClearsThePicture() throws {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.composite == nil)
        #expect(model.compositeStatus == .idle)

        model.setComposite(try composite())
        #expect(model.composite != nil)
        #expect(model.compositeStatus == .ready)
        #expect(model.compositeStatus.message == nil)

        model.setCompositeStatus(.rendering)
        #expect(model.composite != nil, "the sheet was blanked while a new composite was made")
        #expect(model.compositeStatus.isRendering)

        model.setCompositeStatus(.failed("nope"))
        #expect(model.composite == nil, "a stale picture was left under an error")
        #expect(model.compositeStatus.message == "nope")

        model.setComposite(try composite())
        model.clearComposite()
        #expect(model.composite == nil)
        #expect(model.compositeStatus == .idle)
    }

    @Test("A composite coarser than the canvas says so, and one that is not says nothing")
    func reducedResolutionIsStated() throws {
        let exact = try composite(scale: 2, requestedScale: 2)
        #expect(exact.isReducedResolution == false)
        #expect(exact.resolutionSummary == nil)

        let coarse = try composite(scale: 2.4428, requestedScale: 8)
        #expect(coarse.isReducedResolution)
        #expect(coarse.resolutionFraction > 0.3 && coarse.resolutionFraction < 0.31)
        let summary = try #require(coarse.resolutionSummary)
        #expect(summary.contains("31"), "the statement does not name the percentage: \(summary)")
        #expect(coarse.elapsedNanoseconds == 12_000_000)
    }

    // MARK: - The outward hooks

    @Test("A layer edit and a re-fit both reach the compositor; a retry route exists")
    func layerAndAlignmentEditsReachTheCompositor() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        var layerEdits = 0
        var alignmentEdits = 0
        var retries = 0
        model.onLayersChange = { _ in layerEdits += 1 }
        model.onAlignmentChange = { _ in alignmentEdits += 1 }
        model.onRecomposite = { retries += 1 }

        model.setOpacity(0.25, forLayer: model.layers[0].id)
        model.setVisible(false, forLayer: model.layers[1].id)
        model.setColor(paletteID: "green", forLayer: model.layers[0].id)
        #expect(layerEdits == 3)

        // A setting re-applied is not an edit: it must not queue a composite of an unchanged
        // picture, which on a large sheet is a third of a second of nothing.
        model.setOpacity(0.25, forLayer: model.layers[0].id)
        #expect(layerEdits == 3)

        model.capturePair(baseline: .zero, comparison: .zero)
        model.capturePair(baseline: PDFPointValue(x: 100, y: 0), comparison: PDFPointValue(x: 100, y: 0))
        #expect(alignmentEdits == 2)
        model.alignmentMode = .threePoint
        #expect(alignmentEdits == 3)

        model.onRecomposite?()
        #expect(retries == 1)
    }

    // MARK: - Re-seeding, and the alternating view

    @Test("Re-seeding the stack keeps the settings the person already made")
    func reseedingKeepsSettings() {
        let a = revision("A")
        let b = revision("B")
        let model = RevisionOverlayModel(revisions: [a])
        model.setOpacity(0.2, forLayer: a.id)
        model.setColor(paletteID: "coral", forLayer: a.id)
        let keptColour = model.layers[0].colorName

        model.setRevisions([a, b])
        #expect(model.layers.count == 2)
        #expect(model.layers[0].opacity == 0.2, "a chosen opacity was thrown away")
        #expect(model.layers[0].colorName == keptColour, "a chosen colour was thrown away")
        #expect(model.layers[1].colorName != keptColour, "the new layer reused a taken colour")
        #expect(model.alignmentAppliesToSeveralSheets == false)

        model.setRevisions([a, b, revision("C")])
        #expect(model.alignmentAppliesToSeveralSheets)
        model.setRevisions([b])
        #expect(model.layers.map(\.id) == [b.id])
    }

    @Test("Alternating isolates one revision at a time and gives every visibility back")
    func alternatingRestoresWhatItBorrowed() {
        let a = revision("A")
        let b = revision("B")
        let c = revision("C")
        let model = RevisionOverlayModel(revisions: [a, b, c])
        model.setVisible(false, forLayer: c.id)

        model.setBlinking(true, reduceMotion: false)
        #expect(model.visibleLayers.map(\.id) == [a.id])
        model.advanceBlink()
        #expect(model.visibleLayers.map(\.id) == [b.id])
        model.advanceBlink()
        #expect(model.visibleLayers.map(\.id) == [c.id])
        model.advanceBlink()
        #expect(model.visibleLayers.map(\.id) == [a.id])

        model.setBlinking(false, reduceMotion: false)
        #expect(model.layers.first { $0.id == a.id }?.isVisible == true)
        #expect(model.layers.first { $0.id == b.id }?.isVisible == true)
        #expect(model.layers.first { $0.id == c.id }?.isVisible == false,
                "alternating kept a layer the person had switched off")
    }

    // MARK: - CR-196: the blend mode is part of the picture

    /// Old output: `composites == 0`. Every other setting that changes what the composite looks
    /// like — opacity, visibility, colour, stacking order, the alignment fit — leaves through
    /// `onLayersChange` or `onAlignmentChange`, which is how `RevisionOverlayCompositing` knows
    /// to build a new request. `blendMode` was a plain stored property with no `didSet`, so
    /// choosing Multiply changed the value the next request would carry and asked for no
    /// request: the difference blend stayed on screen until some unrelated edit happened.
    @Test("Choosing a different blend asks for the picture to be made again")
    func blendModeChangeReachesTheCompositor() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        var composites = 0
        model.onLayersChange = { _ in composites += 1 }

        #expect(model.blendMode == .difference, "the fixture depends on the starting blend")
        model.blendMode = .multiply
        #expect(composites == 1, "the blend changed and nothing was asked to redraw")
        #expect(model.blendMode == .multiply)

        // Setting the same blend again is not a change, and must not queue a re-composite.
        model.blendMode = .multiply
        #expect(composites == 1)
    }

    // MARK: - CR-197: a control that is on can be switched off

    /// Old output: `model.hasEnoughLayers == false` while `model.isBlinking == true`, and the
    /// view therefore greyed the
    /// alternation checkbox out with the tick still in it. Alternating works by isolating one
    /// layer, one visible layer is not "enough layers", and no other control on the panel calls
    /// `setBlinking(false, …)` — the person could turn it on and not turn it off.
    @Test("Alternating does not disable the control that turns it off")
    func alternatingLeavesItsOwnToggleUsable() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.canAlternate)
        #expect(model.hasEnoughLayers)

        model.setBlinking(true, reduceMotion: false)
        #expect(model.isBlinking)
        #expect(model.visibleLayers.count == 1, "this is what alternating does")
        #expect(!model.hasEnoughLayers, "and this is why the old gate closed on itself")

        // The exact expression the view feeds to its enabled-state modifier.
        #expect(
            model.isAlternationControlEnabled(reduceMotion: false),
            "the toggle is greyed out with the tick still in it, and nothing else turns it off"
        )

        model.setBlinking(false, reduceMotion: false)
        #expect(!model.isBlinking)
        #expect(model.hasEnoughLayers)
        #expect(model.isAlternationControlEnabled(reduceMotion: false))
    }

    /// The gate still refuses to offer alternation when there is nothing to alternate between,
    /// and Reduce Motion still wins over everything.
    @Test("One layer cannot alternate with itself, and Reduce Motion closes the control")
    func alternationGateStillRefusesWhereItShould() {
        let alone = RevisionOverlayModel(revisions: [revision("A")])
        #expect(!alone.canAlternate)
        #expect(!alone.isAlternationControlEnabled(reduceMotion: false))

        let pair = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(!pair.isAlternationControlEnabled(reduceMotion: true))
        pair.setBlinking(true, reduceMotion: true)
        #expect(!pair.isBlinking, "Reduce Motion refuses to start it at all")
        #expect(!pair.isAlternationControlEnabled(reduceMotion: true))
    }
}
