import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// NL-MARKUP-15 (round 2, markup unit): "Add Selection to Tool Library" captures the whole look,
/// and an edit carries it through to the saved preset.
@MainActor
@Suite(.workflowsTierSerialised)
struct MarkupRound2PresetTests {

    @Test("A draft captured from a red dashed 3 pt cloud with a 20 % fill keeps that look through save")
    func captureKeepsTheLook() {
        let red = ColorRGBA(red: 0.86, green: 0.1, blue: 0.1, alpha: 1)
        var cloud = MarkupSummary(
            id: UUID(), kind: .cloud, subject: "Revision", label: "", pageLabel: "A-1", pageID: UUID(), pageIndex: 0,
            author: "", colorRGBA: red, lineWidth: 3, lineStyle: .dashed,
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10),
            fillRGBA: ColorRGBA(red: 0.86, green: 0.1, blue: 0.1, alpha: 0.2)
        )
        cloud.cloudArcSize = 12
        let draft = ToolPresetDraft(from: cloud)
        let preset = draft.makePreset()
        #expect(preset.style?.lineWidth == 3)
        #expect(preset.style?.lineStyle == .dashed)
        #expect(preset.style?.fill?.alpha == 0.2)
        #expect(preset.style?.cloudArcSize == 12)
        // Editing keeps the captured look; the colour the editor changes wins over the stored stroke.
        var edited = ToolPresetDraft(editing: preset)
        edited.colorRGBA = ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1)
        let saved = edited.makePreset()
        #expect(saved.style?.lineStyle == .dashed)
        #expect(saved.placementStyle.stroke == ColorRGBA(red: 0, green: 0, blue: 1, alpha: 1))
        // A measurement capture carries no markup look.
        var area = cloud
        area.kind = .measurement
        area.measurementKind = .area
        #expect(ToolPresetDraft(from: area).makePreset().style == nil)
    }

    @Test("The preset editor offers the twelve palette inks, each named (NL-MARKUP-14)")
    func editorPalette() {
        let entries = ToolPresetColorPicker.entries
        #expect(entries.count == 12)
        #expect(entries.allSatisfy { !$0.name.isEmpty })
        #expect(Set(entries.map(\.id)).count == 12)
    }
}
