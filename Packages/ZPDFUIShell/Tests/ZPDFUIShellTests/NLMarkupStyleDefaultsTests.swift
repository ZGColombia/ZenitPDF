import Foundation
import Testing
@testable import ZPDFUIShell
import ZPDFUIPresentation

/// NL-MARKUP-04 (nl-markup): each markup tool remembers its own last style, and *Set as
/// Default* survives a restart. Plus the Inspector rules for NL-MARKUP-07/08/16.
@MainActor
@Suite(.shellTierSerialised)
struct NLMarkupStyleDefaultsTests {

    /// An in-memory defaults store that outlives a table, standing in for a restart.
    final class MemoryStore: ZPDFDefaultsStoring {
        var data: [String: Data] = [:]
        func persistedData(forKey key: String) -> Data? { data[key] }
        func setPersistedData(_ value: Data?, forKey key: String) { data[key] = value }
    }

    private static let red = ColorRGBA(red: 0.86, green: 0.1, blue: 0.1, alpha: 1)

    private static func cloud(color: ColorRGBA) -> MarkupSummary {
        MarkupSummary(
            id: UUID(), kind: .cloud, subject: "", label: "", pageLabel: "A-1", pageID: UUID(), pageIndex: 0,
            author: "", colorRGBA: color, lineWidth: 3, lineStyle: .dashed,
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
    }

    @Test("Recolour a cloud red: with memory off the next cloud is blue; after Set as Default it is red, and a restart keeps it")
    func setAsDefaultSurvivesRestart() {
        let store = MemoryStore()
        let toolbar = ZenitToolbarModel()
        toolbar.styleDefaults = MarkupStyleDefaults(store: store)
        toolbar.styleDefaults.remembersLastUsed = false

        // Restyling a cloud does not change what the Cloud tool draws while memory is off.
        toolbar.rememberStyle(MarkupStyleEdit(color: Self.red), kinds: [.cloud])
        toolbar.activateShape(.cloud)
        #expect(toolbar.activeSelection.style.stroke == ToolStyleSelection.zenitInk.stroke)

        // Set as Default for Cloud.
        toolbar.setAsDefault(Self.cloud(color: Self.red))
        toolbar.selectTool(.select)
        toolbar.activateShape(.cloud)
        #expect(toolbar.activeSelection.style.stroke == Self.red)
        #expect(toolbar.activeSelection.style.lineWidth == 3)
        #expect(toolbar.activeSelection.style.lineStyle == .dashed)

        // A restart: a new toolbar over the same store.
        let restarted = ZenitToolbarModel()
        restarted.styleDefaults = MarkupStyleDefaults(store: store)
        restarted.activateShape(.cloud)
        #expect(restarted.activeSelection.style.stroke == Self.red)
        // Another kind is untouched by the Cloud default.
        restarted.activateShape(.arrow)
        #expect(restarted.activeSelection.style.stroke == ToolStyleSelection.zenitInk.stroke)
    }

    @Test("With memory on, each kind's tool draws the style last given to that kind")
    func lastUsedPerKind() {
        let toolbar = ZenitToolbarModel()
        toolbar.styleDefaults = MarkupStyleDefaults(store: MemoryStore())
        toolbar.activateShape(.cloud)
        toolbar.setStyle(ZenitToolbarModel.style(toolbar.toolStyle, applying: MarkupStyleEdit(color: Self.red, endCap: .circle)))
        toolbar.activateShape(.arrow)
        toolbar.setStyle(ZenitToolbarModel.style(toolbar.toolStyle, applying: MarkupStyleEdit(lineWidth: 6)))
        toolbar.activateShape(.cloud)
        #expect(toolbar.activeSelection.style.stroke == Self.red)
        #expect(toolbar.activeSelection.style.endCap == .circle, "the tool style carries line ends now")
        toolbar.activateShape(.arrow)
        #expect(toolbar.activeSelection.style.lineWidth == 6)
    }

    @Test("A style edit folds line style, opacity, ends, font and alignment into a tool style")
    func styleFolding() {
        let folded = ZenitToolbarModel.style(.zenitInk, applying: MarkupStyleEdit(
            opacity: 0.4, lineStyle: .dotted, startCap: .slash, endCap: .openArrow,
            fontName: "Georgia", textAlignment: .trailing
        ))
        #expect(folded.opacity == 0.4 && folded.lineStyle == .dotted)
        #expect(folded.startCap == .slash && folded.endCap == .openArrow)
        #expect(folded.fontName == "Georgia" && folded.textAlignment == .trailing)
    }

    @Test("The Inspector offers ends only on open kinds, fonts only on text, Cloud only where it draws")
    func inspectorRules() {
        #expect(InspectorPanel.holdsLineEnds(.line) && InspectorPanel.holdsLineEnds(.callout))
        #expect(!InspectorPanel.holdsLineEnds(.rectangle))
        #expect(InspectorPanel.holdsTextFormatting(.text) && !InspectorPanel.holdsTextFormatting(.arrow))
        #expect(InspectorPanel.drawsCloudStyle(.rectangle) && InspectorPanel.drawsCloudStyle(.ellipse))
        #expect(!InspectorPanel.drawsCloudStyle(.line) && !InspectorPanel.drawsCloudStyle(.measurement))
        // An imported family missing from the list still shows under its own name.
        #expect(InspectorPanel.fontChoices(including: ["Futura"]).last == "Futura")
        #expect(InspectorPanel.setAsDefaultTitle(for: .cloud) == "Set as Default for Cloud")
    }
}
