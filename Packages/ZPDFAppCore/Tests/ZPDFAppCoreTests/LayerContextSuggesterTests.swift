import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// NL-AUTO-21: a traced area's drawing layer suggests a subject from the Tool Library and a
/// Project Zone — words matched deterministically, offered, never applied.
@Suite("Suggestions from the drawing layer")
struct LayerContextSuggesterTests {

    static func preset(_ name: String, subject: String) -> ToolPresetSummary {
        ToolPresetSummary(id: UUID(), name: name, category: "Finishes", panel: .myTools, markupKind: .measurement,
                          measurementKind: .area, colorRGBA: ColorRGBA.Zenit.Dark.cyan, defaultSubject: subject)
    }

    static let presets = [preset("Floor finish", subject: "Floor finish"), preset("Wall paint", subject: "Paint"),
                          preset("Ceiling", subject: "Suspended ceiling")]
    static let zones = [
        ProjectZoneSummary(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: "Level 2", kind: .floor, colorRGBA: ColorRGBA.Zenit.Dark.blue),
        ProjectZoneSummary(id: UUID(), name: "Level 3", kind: .floor, colorRGBA: ColorRGBA.Zenit.Dark.blue),
    ]

    @Test("A-FLOOR-FINI suggests the Floor finish subject; LEVEL-2-ROOMS suggests zone Level 2")
    func matches() {
        let floor = LayerContextSuggester.suggest(layerName: "A-FLOOR-FINI", presets: Self.presets, zones: Self.zones, currentSubject: "Area")
        #expect(floor.subject == "Floor finish")
        #expect(floor.presetName == "Floor finish")
        #expect(floor.zoneID == nil)
        let zone = LayerContextSuggester.suggest(layerName: "LEVEL-2-ROOMS", presets: Self.presets, zones: Self.zones, currentSubject: "Area")
        #expect(zone.zoneName == "Level 2", "all of the zone's words, and not Level 3")
        #expect(zone.subject == nil)
    }

    @Test("A three-letter abbreviation, a one-letter prefix, or the subject already set suggests nothing")
    func nothing() {
        #expect(LayerContextSuggester.suggest(layerName: "A-FLR", presets: Self.presets, zones: Self.zones, currentSubject: "Area").isEmpty)
        #expect(LayerContextSuggester.suggest(layerName: "A", presets: Self.presets, zones: Self.zones, currentSubject: "Area").isEmpty)
        #expect(LayerContextSuggester.suggest(layerName: "CEILING", presets: Self.presets, zones: [], currentSubject: "Suspended ceiling").isEmpty)
        #expect(LayerContextSuggester.words("A-WALL_PAINT.2") == ["wall", "paint", "2"])
        #expect(LayerContextSuggester.suggest(layerName: "LEVEL-3", presets: [], zones: Self.zones, currentSubject: "").zoneName == "Level 3")
    }
}
