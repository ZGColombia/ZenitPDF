import Foundation
import Testing
@testable import ZPDFUIShell
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Round 2, markup unit: the style strip (NL-MARKUP-03), the new Inspector rows' rules
/// (NL-MARKUP-08/16/17/18), the tool variants (NL-MARKUP-06/10), the palette services
/// (NL-MARKUP-14) and the tool style's new fields (NL-MARKUP-15). No window is shown.
@MainActor
@Suite(.shellTierSerialised)
struct MarkupRound2ShellTests {

    private static func summary(
        _ kind: MarkupKind,
        measurement: MeasurementKind? = nil,
        lineStyle: MarkupLineStyle = .solid,
        drawnText: String? = nil
    ) -> MarkupSummary {
        var markup = MarkupSummary(
            id: UUID(), kind: kind, measurementKind: measurement, subject: "", label: "", pageLabel: "A-1",
            pageID: UUID(), pageIndex: 0, author: "", colorRGBA: ZPDFMarkupInk.blue.color, lineStyle: lineStyle,
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
        markup.drawnText = drawnText
        return markup
    }

    // MARK: Style strip (NL-MARKUP-03)

    @Test("The strip edits a selection of markups, or the armed tool; never a measurement")
    func stripTarget() {
        let cloud = Self.summary(.cloud)
        let area = Self.summary(.measurement, measurement: .area)
        #expect(MarkupStyleStrip.target(selected: [cloud], armed: .select) == .selection(.init([cloud.id])))
        #expect(MarkupStyleStrip.target(selected: [cloud, area], armed: .select) == nil, "a measurement's look is the Inspector's")
        #expect(MarkupStyleStrip.target(selected: [area], armed: .select) == nil)
        #expect(MarkupStyleStrip.target(selected: [], armed: .markup(.arrow)) == .tool(.arrow))
        #expect(MarkupStyleStrip.target(selected: [], armed: .measure(.length)) == nil)
        #expect(MarkupStyleStrip.target(selected: [], armed: .select) == nil)
    }

    @Test("Arming a markup tool shows the strip in the tool options slot; Select hides it")
    func stripShowsInTheSlot() {
        let environment = ProjectShellEnvironment.mock()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "test.r2.layout")
        )
        _ = layout.view
        #expect(!layout.isToolOptionsBarVisible)
        environment.toolbar.activateShape(.arrow)
        #expect(layout.isToolOptionsBarVisible, "the strip edits the next arrow")
        environment.toolbar.selectTool(.select)
        #expect(!layout.isToolOptionsBarVisible)
    }

    @Test("With a tool armed, a strip edit becomes the tool's style for its next markup")
    func stripEditsTheTool() {
        let environment = ProjectShellEnvironment.mock()
        environment.toolbar.activateShape(.arrow)
        let strip = MarkupStyleStrip(environment: environment)
        strip.applyToTool(MarkupStyleEdit(color: ZPDFMarkupInk.red.color, lineWidth: 4, endCap: .circle))
        let style = environment.toolbar.activeSelection.style
        #expect(ZPDFColourMath.sameHue(style.stroke, ZPDFMarkupInk.red.color))
        #expect(style.lineWidth == 4)
        #expect(style.endCap == .circle)
    }

    // MARK: Inspector rules

    @Test("Round-2 Inspector rows appear only where the value means something")
    func inspectorRules() {
        #expect(InspectorPanel.holdsTextFormatting(Self.summary(.cloud, drawnText: "Revised")), "a clouded callout draws words")
        #expect(!InspectorPanel.holdsTextFormatting(Self.summary(.cloud)))
        #expect(InspectorPanel.holdsArcSize(Self.summary(.cloud)))
        #expect(InspectorPanel.holdsArcSize(Self.summary(.rectangle, lineStyle: .cloud)))
        #expect(!InspectorPanel.holdsArcSize(Self.summary(.rectangle)))
        #expect(InspectorPanel.holdsRotation(Self.summary(.text)))
        #expect(!InspectorPanel.holdsRotation(Self.summary(.measurement, measurement: .area)))
        #expect(!InspectorPanel.holdsRotation(Self.summary(.stamp)))
        var link = Self.summary(.hyperlink)
        #expect(InspectorPanel.linkDescription(link, pages: []) == "No destination yet")
        link.linkURL = "https://example.org"
        #expect(InspectorPanel.linkDescription(link, pages: []) == "https://example.org")
        #expect(InspectorMarkupFormatting.acceptsFill(Self.summary(.text)), "a Text box takes a fill (ADR-0029)")
        let edit = InspectorPanel.styleEdit(bold: true, rotationDegrees: 30)
        #expect(edit.bold == true && edit.rotationDegrees == 30 && !edit.isEmpty)
    }

    // MARK: Toolbar (NL-MARKUP-06, NL-MARKUP-10)

    @Test("Highlighter arms Pen with the multiply style and its own memory; Clouded Callout arms Cloud")
    func variants() {
        let toolbar = ZenitToolbarModel()
        toolbar.styleDefaults = MarkupStyleDefaults()
        toolbar.activateShapeVariant(.highlighter)
        #expect(toolbar.activeSelection.mode == .markup(.freehand))
        #expect(toolbar.activeSelection.variant == .highlighter)
        #expect(toolbar.activeSelection.style.multiplyBlend)
        #expect(toolbar.activeSelection.style.lineWidth == 12)
        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: MarkupStyleEdit(color: ZPDFMarkupInk.green.color)))
        toolbar.activateShape(.freehand)
        #expect(!toolbar.activeSelection.style.multiplyBlend, "the pen keeps its own look")
        toolbar.activateShapeVariant(.highlighter)
        #expect(ZPDFColourMath.sameHue(toolbar.activeSelection.style.stroke, ZPDFMarkupInk.green.color), "the highlighter remembers green")
        toolbar.activateShapeVariant(.cloudedCallout)
        #expect(toolbar.activeSelection.mode == .markup(.cloud))
        #expect(toolbar.activeSelection.variant == .cloudedCallout)
        #expect(toolbar.annotationPalette == [.freehand, .note, .hyperlink])
    }

    @Test("A style edit's text format and arc size reach the tool style; rotation never does")
    func rememberedFields() {
        var edit = MarkupStyleEdit()
        edit.bold = true
        edit.italic = true
        edit.textColor = ZPDFMarkupInk.red.color
        edit.boxBorder = true
        edit.cloudArcSize = 14
        edit.rotationDegrees = 45
        let style = ZenitToolbarModel.style(.zenitInk, applying: edit)
        #expect(style.bold && style.italic && style.boxBorder)
        #expect(style.textColor == ZPDFMarkupInk.red.color)
        #expect(style.cloudArcSize == 14)
    }

    @Test("A tool style saved before round 2 decodes unchanged; one with no round-2 field writes none")
    func toolStyleCoding() throws {
        let data = try JSONEncoder().encode(ToolStyleSelection.zenitInk)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["multiplyBlend", "cloudArcSize", "bold", "italic", "textColor", "boxBorder"] {
            #expect(object[key] == nil, "\(key) written for an unformatted style")
        }
        #expect(try JSONDecoder().decode(ToolStyleSelection.self, from: data) == .zenitInk)
        let rich = ToolStyleSelection(stroke: ZPDFMarkupInk.red.color, multiplyBlend: true, cloudArcSize: 9, bold: true)
        #expect(try JSONDecoder().decode(ToolStyleSelection.self, from: JSONEncoder().encode(rich)) == rich)
    }

    // MARK: Palette services (NL-MARKUP-14)

    final class InstantSampler: ZPDFColourSampling {
        var answer: ColorRGBA?
        var calls = 0
        func sample(_ completion: @escaping @MainActor (ColorRGBA?) -> Void) {
            calls += 1
            completion(answer)
        }
    }

    @Test("The Inspector's colour services carry the company colours, the project colours and the eyedropper")
    func paletteServices() {
        let environment = ProjectShellEnvironment.mock()
        environment.companyColours = ZPDFCompanyColours()
        environment.companyColours.add(ZPDFMarkupInk.navy.color)
        let sampler = InstantSampler()
        environment.colourSampler = sampler
        environment.projectColours = { [ZPDFMarkupInk.olive.color] }
        let services = InspectorColourServices(environment: environment)
        #expect(services.company.colours.count == 1)
        #expect(services.projectColours?() == [ZPDFMarkupInk.olive.color])
        sampler.answer = ZPDFMarkupInk.teal.color
        var picked: ColorRGBA?
        services.sampler.sample { picked = $0 }
        #expect(picked == ZPDFMarkupInk.teal.color && sampler.calls == 1)
    }
}
