import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// NL-AUTO-08: the room review, windowless.
@MainActor
@Suite(.workflowsTierSerialised)
struct RoomDetectionReviewModelTests {

    static func row(_ id: Int, _ name: String) -> RoomDetectionReviewRow {
        RoomDetectionReviewRow(id: id, name: name, areaText: "8.00 m²", notes: [], bounds: PDFRectValue(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("All rooms start ticked; unticking two of nine lands seven, names as typed")
    func acceptSeven() {
        var outcome: RoomDetectionReviewOutcome?
        let model = RoomDetectionReviewModel(rows: (0..<9).map { Self.row($0, "Rum \($0)") }, onAccept: { outcome = $0 }, onCancel: {})
        #expect(model.includedIDs.count == 9)
        model.setIncluded(false, id: 3)
        model.setIncluded(false, id: 8)
        model.rows[0].name = " Hall "
        model.accept()
        #expect(outcome?.names.count == 7)
        #expect(outcome?.names[0] == "Hall")
        #expect(model.summaryText.contains("9 rooms found; 7 ticked"))
        let host = NSHostingController(rootView: RoomDetectionReviewView(model: model))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.fittingSize.width > 0)
    }
}
