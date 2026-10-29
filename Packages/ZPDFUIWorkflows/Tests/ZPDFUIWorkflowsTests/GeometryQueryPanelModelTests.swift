import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// NL-AUTO-24: the geometry query panel, windowless.
@MainActor
@Suite(.workflowsTierSerialised)
struct GeometryQueryPanelModelTests {

    @Test("Circles: the query runs with the typed radius and a 2 % default tolerance, and Count These commits")
    func circlesCountThese() async {
        var asked: (GeometryQueryKind, Double, Double)?
        var committed: GeometryQueryKind?
        let model = GeometryQueryPanelModel(
            unitLabel: "mm",
            onRun: { kind, value, tolerance in
                asked = (kind, value, tolerance)
                return GeometryQueryPanelResult(matchBounds: Array(repeating: PDFRectValue(x: 0, y: 0, width: 1, height: 1), count: 7), truncated: false)
            },
            onCommit: { committed = $0 },
            onClose: {}
        )
        model.valueText = "75"
        await model.run()
        #expect(asked?.0 == .circles && asked?.1 == 75 && abs((asked?.2 ?? 0) - 1.5) < 1e-12)
        #expect(model.matchCount == 7)
        #expect(model.resultText == "7 found, highlighted on the sheet.")
        model.commit()
        #expect(committed == .circles)
    }

    @Test("Parallel pairs are highlights only: nothing can be committed from them")
    func parallelPairsNeverCommit() async {
        var committed = false
        let model = GeometryQueryPanelModel(
            unitLabel: "mm",
            onRun: { _, _, _ in GeometryQueryPanelResult(matchBounds: [PDFRectValue(x: 0, y: 0, width: 1, height: 1)], truncated: true) },
            onCommit: { _ in committed = true },
            onClose: {}
        )
        model.kind = .parallelPairs
        model.valueText = "150"
        model.toleranceText = "5"
        await model.run()
        #expect(!model.canCommit)
        model.commit()
        #expect(!committed)
        #expect(model.resultText?.contains("highlights only") == true)
        #expect(model.resultText?.contains("may be more") == true)
    }

    @Test("A value that is not a number cannot be run")
    func invalidValue() {
        let model = GeometryQueryPanelModel(unitLabel: "pt", onRun: { _, _, _ in GeometryQueryPanelResult(matchBounds: [], truncated: false) }, onCommit: { _ in }, onClose: {})
        model.valueText = "12,5,1"
        #expect(!model.canRun)
        model.valueText = "12,5"
        #expect(model.canRun)
        let host = NSHostingController(rootView: GeometryQueryPanelView(model: model))
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.fittingSize.width > 0)
    }
}
