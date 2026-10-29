import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// Quality loop iteration 6 (cycle 1), area "ui-presentation-measure": the Scale Region crossing
/// prompt's wording (W-073), one wording for the points a measurement still needs (W-074) and the
/// one named palette (W-075). Nothing here reaches a screen: the prompt is a value, the machine is
/// a value and the presenter is the mock.
@MainActor
@Suite("Iteration 6 ui-presentation-measure (crossing prompt, point phrases, palette)")
struct Iter6UIPresentationMeasureTests {

    // MARK: Fixtures

    private static func scale(_ ratio: String, id: UInt8) -> ScaleSummary {
        ScaleSummary(
            id: UUID(uuid: (0x22, 0x22, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x06, id)),
            name: "Plan \(ratio)",
            displayString: ratio,
            isUniform: true,
            sx: 0.0176,
            sy: 0.0176,
            unit: .metre,
            version: 1,
            locked: false
        )
    }

    private static func region(_ name: String, ratio: String, id: UInt8) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: UUID(uuid: (0x33, 0x33, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x06, id)),
            name: name,
            pageID: UUID(uuid: (0x11, 0x11, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x06, 0x73)),
            pageLabel: "A-101",
            scale: scale(ratio, id: id),
            boundary: [
                PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0),
                PDFPointValue(x: 100, y: 100), PDFPointValue(x: 0, y: 100)
            ],
            priority: Int(id),
            locked: false,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            isVisible: true
        )
    }

    private static func crossing(
        _ regions: [ScaleRegionSummary],
        pageDefault: ScaleSummary?
    ) -> ScaleRegionCrossing {
        ScaleRegionCrossing(
            id: UUID(uuid: (0x44, 0x44, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x06, 0x73)),
            measurementName: "Area",
            pageLabel: "A-101",
            regions: regions,
            canSplitAtBoundary: true,
            pageDefaultScale: pageDefault
        )
    }

    // MARK: W-073

    /// The resolver's partly-outside case hands the prompt one region and the page default.
    /// Old output: "This Area crosses 1 Scale Regions on page A-101."
    @Test("W-073: a measurement that runs out of one region onto the sheet says so, not 'crosses 1 Scale Regions'")
    func oneRegionCrossingHeadline() {
        let subject = Self.crossing([Self.region("Detail", ratio: "1:20", id: 1)], pageDefault: Self.scale("1:100", id: 9))
        #expect(subject.headline == "This Area runs out of \u{201C}Detail\u{201D} onto the sheet on page A-101.")
        #expect(!subject.headline.contains("1 Scale Regions"))
    }

    /// Old output: "This Area crosses 2 Scale Regions on page A-101." — the same for two, now
    /// through the plural phrase, so the count reads right for every number.
    @Test("W-073: two or more regions are counted through the plural phrase")
    func severalRegionsHeadline() {
        let two = Self.crossing(
            [Self.region("Stair Detail", ratio: "1:20", id: 2), Self.region("Plan", ratio: "1:50", id: 1)],
            pageDefault: nil
        )
        #expect(two.headline == "This Area crosses 2 Scale Regions on page A-101.")
        #expect(MeasurementPlurals.scaleRegions(1) == "1 Scale Region")
        #expect(MeasurementPlurals.scaleRegions(3) == "3 Scale Regions")
    }

    /// Old output, for "Use the page scale": "One measurement is created. The parts outside the
    /// chosen region are measured with that same scale." — no region was chosen.
    @Test("W-073: the page-scale option explains itself without a 'chosen region'")
    func pageScaleExplanation() {
        let detail = Self.region("Detail", ratio: "1:20", id: 1)
        let subject = Self.crossing([detail], pageDefault: Self.scale("1:100", id: 9))
        #expect(subject.offeredResolutions.contains(.useScale(regionID: nil)))

        let pageScale = subject.explanation(for: .useScale(regionID: nil))
        #expect(pageScale == "One measurement is created. All of it, including what lies inside a region, uses the page scale.")
        #expect(!pageScale.contains("chosen region"))

        // Choosing the region keeps the sentence that does have a chosen region to refer to.
        #expect(subject.explanation(for: .useScale(regionID: detail.id))
            == "One measurement is created. The parts outside the chosen region are measured with that same scale.")
        // Split, with part of the geometry on the bare sheet: that part takes the page scale.
        #expect(subject.explanation(for: .splitAtBoundary).contains("outside every region uses the page scale"))
        // Split between two regions with no page scale on offer keeps the two-region sentence.
        let between = Self.crossing(
            [Self.region("Stair Detail", ratio: "1:20", id: 2), Self.region("Plan", ratio: "1:50", id: 1)],
            pageDefault: nil
        )
        #expect(between.explanation(for: .splitAtBoundary)
            == "Two measurements are created, each measured with the scale of the region it sits in.")
    }

    // MARK: W-074

    /// Old output: Return said "Rectangle Area: 1 more point needed." while Finish said
    /// "Rectangle Area needs 1 more point before it can be finished." for the same state.
    @Test("W-074: Return and Finish refuse a too-short measurement with one sentence")
    func returnAndFinishAgree() {
        var machine = MeasurementInputStateMachine(
            configuration: MeasurementInputConfiguration(initialCursor: PDFPointValue(x: 100, y: 100))
        )
        machine.handle(.armTool(.area))
        machine.handle(.placePoint(PDFPointValue(x: 0, y: 0)))
        let placed = machine.handle(.placePoint(PDFPointValue(x: 100, y: 0)))
        let returned = machine.handle(.finish)

        let presenter = MockMeasurementToolPresenter()
        presenter.activate(kind: .area)
        presenter.placePoint(PDFPointValue(x: 0, y: 0))
        presenter.placePoint(PDFPointValue(x: 100, y: 0))

        let expected = "\(MeasurementKind.area.displayName) needs 1 more point before it can be finished."
        #expect(presenter.commitRefusalReason == expected)
        #expect(returned.contains(.rejectFinish(expected)), "\(returned)")
        // The point-placed announcement reads the same phrase.
        #expect(placed.contains(.announce("Point 2 placed. 1 more point needed.")), "\(placed)")
        #expect(MeasurementPointPhrases.finishRefusal(.area, remaining: 3)
            == "\(MeasurementKind.area.displayName) needs 3 more points before it can be finished.")
    }

    // MARK: W-075

    @Test("W-075: the region and markup palettes are the one named palette")
    func onePalette() {
        #expect(ZenitRegionPalette.self == ZenitNamedPalette.self)
        #expect(ZenitRegionPalette.entries.map(\.id) == ["cyan", "blue", "green", "amber", "coral"])
        // The id lookup the region draft uses falls back to the first entry, as before.
        #expect(ZenitNamedPalette.entry(for: "coral").color == ColorRGBA.Zenit.Dark.danger)
        #expect(ZenitNamedPalette.entry(for: "no-such-colour").id == "cyan")
        // A colour from an older file is named by its nearest palette colour, never by hex.
        var nearlyGreen = ColorRGBA.Zenit.Dark.green
        nearlyGreen.red = min(1, nearlyGreen.red + 0.02)
        #expect(!ZenitNamedPalette.entries.contains { $0.color == nearlyGreen }, "not an exact palette colour")
        #expect(ZenitNamedPalette.name(for: nearlyGreen) == ZenitNamedPalette.entry(for: "green").name)
    }
}
