import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIMeasurement

/// NL-MEASURE-02: the Page Scales list's pure rules.
@Suite("Page Scales panel (NL-MEASURE-02)")
struct PageScalesPanelTests {
    let rows = [
        PageScaleRow(id: UUID(), label: "A-101", sizeText: "A1", status: .set(ratio: "1:100", source: "Preset")),
        PageScaleRow(id: UUID(), label: "A-102", sizeText: "A1", status: .proposed(ratio: "1:50", evidence: "SCALE 1:50")),
        PageScaleRow(id: UUID(), label: "A-103", sizeText: "A1", status: .proposed(ratio: "1:100", evidence: "1:100")),
        PageScaleRow(id: UUID(), label: "A-104", sizeText: "A1", status: .none)
    ]

    @Test("Apply writes the selected proposals, or every proposal when none is selected")
    func proposalTargets() {
        #expect(PageScalesPanel.proposalTargets(rows: rows, selection: []) == [rows[1].id, rows[2].id])
        #expect(PageScalesPanel.proposalTargets(rows: rows, selection: [rows[2].id, rows[3].id]) == [rows[2].id])
        #expect(PageScalesPanel.proposalTargets(rows: rows, selection: [rows[0].id]) == [rows[1].id, rows[2].id],
                "a selection of set sheets only is not a proposal choice")
    }

    @Test("Every sheet has a status in words")
    func summary() {
        #expect(PageScalesPanel.summary(of: rows) == "4 sheets: 1 set, 2 proposed, 1 without a scale.")
        for row in rows { #expect(!row.status.title.isEmpty) }
    }
}
