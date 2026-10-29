import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// L-95 (live test 8): in the Scale Regions window's own width a region row read "Scale Re…" over
/// "1:50 · pri…", because the name and the scale shared one line with seven controls.
@MainActor
@Suite("Live test 8 — Scale Regions rows fit the panel")
struct LiveTest8ScaleRegionsLayoutTests {

    private static func region(_ name: String) -> ScaleRegionSummary {
        ScaleRegionSummary(
            id: UUID(),
            name: name,
            pageID: UUID(),
            pageLabel: "A-101",
            scale: ScaleSummary(
                id: UUID(), name: "Plan 1:50", displayString: "1:50", isUniform: true,
                sx: 0.0176, sy: 0.0176, unit: .metre, version: 1, locked: false
            ),
            boundary: [
                PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0),
                PDFPointValue(x: 100, y: 100), PDFPointValue(x: 0, y: 100)
            ],
            priority: 1,
            locked: false,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan
        )
    }

    private static func row(_ region: ScaleRegionSummary) -> ScaleRegionRow {
        ScaleRegionRow(
            region: region, order: 1, total: 2, isSelected: false, isOverlapping: false,
            onSelect: {}, onToggleLock: {}, onToggleVisibility: {}, onMoveUp: {}, onMoveDown: {},
            onEditScale: {}, scaleChoices: [], onAssignScale: { _ in },
            isRenaming: false, renameDraft: .constant(""), onBeginRename: {},
            onCommitRename: {}, onCancelRename: {}, onDelete: {}
        )
    }

    private static func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        return host.fittingSize.height
    }

    /// The whole label — name over scale — at its natural width.
    private static func labelWidth(_ region: ScaleRegionSummary) -> CGFloat {
        let label = VStack(alignment: .leading, spacing: 0) {
            Text(region.name).zpdfText(.control, .textPrimary).lineLimit(1)
            Text("1:50 · priority 1 of 2 · Cyan").zpdfText(.caption, .textSecondary).lineLimit(1)
        }
        return NSHostingView(rootView: label.fixedSize()).fittingSize.width
    }

    @Test("Narrower than the row's one-line width, the controls take a line of their own and the name and scale are whole")
    func rowStacksWhenNarrow() {
        let region = Self.region("Scale Region 1")
        let wide = Self.height(Self.row(region), width: 1_000)
        // One line needs about 415 pt for "Scale Region 1" beside the seven controls; the
        // window may be made as narrow as its 340 pt minimum.
        for width in [CGFloat(400), 340] {
            let narrow = Self.height(Self.row(region), width: width)
            // Old code: one line at every width (the same height as at 1 000 pt), the label
            // squeezed between the colour chip and seven controls.
            #expect(narrow > wide, "at \(width) pt the row is \(narrow) pt tall, one line is \(wide) pt")
            // On its own line the label has the row's width less its padding and the chip.
            let room = width - 2 * ZPDFSpacing.l - ZPDFSpacing.l - ZPDFSpacing.m
            #expect(Self.labelWidth(region) <= room, "the label needs \(Self.labelWidth(region)) pt, its line has \(room) pt")
        }
    }

    @Test("With room, the row stays one line")
    func rowStaysOneLineWithRoom() {
        let region = Self.region("Stair")
        let wide = Self.height(Self.row(region), width: 1_000)
        #expect(Self.height(Self.row(region), width: 800) == wide)
    }

    @Test("The draft's 'assign a scale' sentence has the editor's width, not the gap beside the buttons")
    func draftSentenceHasTheFullWidth() {
        let model = ScaleRegionsPanelModel(regions: [])
        model.onBeginPolygon = {}
        model.beginRegion()
        model.completePolygon(
            [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 100, y: 100), PDFPointValue(x: 0, y: 100)],
            pageID: UUID(), pageLabel: "A-101"
        )
        #expect(model.draft != nil && !model.canCommitDraft, "a draft with no scale: Create is off")
        let roomy = Self.height(ScaleRegionDraftEditor(model: model), width: 1_000)
        // At 1 000 pt the sentence is one line over the buttons' row. In the 340 pt window
        // (316 pt inside its padding), and narrower, it has the editor's width and needs one
        // more line (measured 170 → 184 pt). Old code: squeezed into the gap left of Cancel and
        // Create Region it broke into three short lines (measured 148 → 180 pt, +32).
        for width in [CGFloat(316), 260] {
            let narrow = Self.height(ScaleRegionDraftEditor(model: model), width: width)
            #expect(narrow - roomy <= 16, "at \(width) pt the editor grows \(narrow - roomy) pt (\(roomy) → \(narrow))")
        }
    }
}
