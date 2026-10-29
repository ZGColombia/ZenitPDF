import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// NL-AUTO-02 / NL-AUTO-05: the symbol count review, driven without a window.
@MainActor
@Suite(.workflowsTierSerialised)
struct SymbolCountReviewModelTests {

    static func row(_ id: Int, page: Int = 0, _ status: SymbolCountReviewRow.Status) -> SymbolCountReviewRow {
        SymbolCountReviewRow(
            id: id, pageIndex: page, pageLabel: "Page \(page + 1)",
            position: PDFPointValue(x: Double(id), y: 0),
            bounds: PDFRectValue(x: Double(id), y: 0, width: 10, height: 10),
            status: status, detail: "detail", isExemplar: id == 0
        )
    }

    @Test("Confirmed rows arrive ticked; near misses and already-counted places do not")
    func defaults() {
        let model = SymbolCountReviewModel(designation: "D-12", pageTotal: 1, onAccept: { _ in }, onCancel: {})
        model.append(
            page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 212, isTruncated: false),
            rows: (0..<6).map { Self.row($0, .confirmed) } + [Self.row(6, .nearMiss), Self.row(7, .alreadyCounted(subject: "D-13"))]
        )
        #expect(model.selectedRowIDs == Set(0..<6))
        #expect(model.phase == .ready)
        // V-068: singular agreement; it read "1 near miss(es) shown".
        #expect(model.summaryText.contains("6 confirmed, 1 near miss shown; 212 other shapes did not resemble the symbol."))
        #expect(model.summaryText.contains("Already counted: 1"))
        #expect(model.rows.last?.statusText == "Already counted as D-13")
    }

    @Test("Unticking one of six lands five, under the designation as finally typed")
    func acceptLandsTheTickedRows() {
        var outcome: SymbolCountReviewOutcome?
        let model = SymbolCountReviewModel(designation: "D-12", pageTotal: 1, onAccept: { outcome = $0 }, onCancel: {})
        model.append(
            page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 0, isTruncated: false),
            rows: (0..<6).map { Self.row($0, .confirmed) } + [Self.row(6, .nearMiss)]
        )
        model.toggle(model.rows[2])
        model.designation = " D-12A "
        model.accept()
        #expect(outcome?.selectedRowIDs == [0, 1, 3, 4, 5])
        #expect(outcome?.designation == "D-12A")
    }

    @Test("While pages are searched nothing can be accepted; stopping keeps what was found")
    func progressAndStop() {
        var stopped = false
        var accepted = false
        let model = SymbolCountReviewModel(
            designation: "D-12", pageTotal: 12,
            onAccept: { _ in accepted = true }, onCancel: {}, onStopSearch: { stopped = true }
        )
        model.append(page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 3, isTruncated: false),
                     rows: [Self.row(0, .confirmed)])
        #expect(model.phase == .searching(done: 1, total: 12))
        #expect(!model.canAccept)
        model.accept()
        #expect(!accepted)
        model.cancelSearch()
        #expect(stopped)
        #expect(model.phase == .stopped(done: 1, total: 12))
        #expect(model.canAccept)
        model.accept()
        #expect(accepted)
    }

    @Test("Cancel commits nothing and stops a running search")
    func cancel() {
        var cancelled = false
        var stopped = false
        var accepted = false
        let model = SymbolCountReviewModel(
            designation: "D-12", pageTotal: 3,
            onAccept: { _ in accepted = true }, onCancel: { cancelled = true }, onStopSearch: { stopped = true }
        )
        model.cancel()
        #expect(cancelled && stopped && !accepted)
    }

    @Test("A truncated or failed page is named in the summary")
    func truncatedAndFailedPagesAreNamed() {
        let model = SymbolCountReviewModel(designation: "D-12", pageTotal: 2, onAccept: { _ in }, onCancel: {})
        model.append(page: SymbolCountReviewPage(pageIndex: 3, pageLabel: "A-104", otherShapeCount: 0, isTruncated: true), rows: [])
        model.append(page: SymbolCountReviewPage(pageIndex: 5, pageLabel: "A-106", otherShapeCount: 0, isTruncated: false, failure: "no geometry"), rows: [])
        #expect(model.summaryText.contains("stopped early on A-104"))
        #expect(model.summaryText.contains("Not searched: A-106."))
    }

    @Test("Show reveals the row through the app tier")
    func reveal() {
        var revealed: Int?
        let model = SymbolCountReviewModel(
            designation: "D-12", pageTotal: 1, onAccept: { _ in }, onCancel: {}, onReveal: { revealed = $0.id }
        )
        model.append(page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 0, isTruncated: false),
                     rows: [Self.row(4, .nearMiss)])
        model.reveal(model.rows[0])
        #expect(revealed == 4)
        #expect(model.revealedRowID == 4)
    }

    @Test("The view builds off screen over a filled model")
    func viewBuilds() {
        let model = SymbolCountReviewModel(designation: "D-12", pageTotal: 1, onAccept: { _ in }, onCancel: {})
        model.append(page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 1, isTruncated: false),
                     rows: [Self.row(0, .confirmed), Self.row(1, .nearMiss)])
        let host = NSHostingController(rootView: SymbolCountReviewView(model: model))
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 440)
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.fittingSize.width > 0)
    }

    @Test("Symbols against tags: agreement and disagreement are both said")
    func tagCounts() {
        let model = SymbolCountReviewModel(designation: "D-12", pageTotal: 2, onAccept: { _ in }, onCancel: {})
        model.setTagCount(pageIndex: 0, symbols: 6, tags: 6, orphanTags: 0)
        #expect(model.summaryText.contains("Tags agree: 6 symbols, 6 tags."))
        model.setTagCount(pageIndex: 1, symbols: 5, tags: 6, orphanTags: 1)
        // V-068: it read "1 tag(s) with no symbol beside them are marked".
        #expect(model.summaryText.contains("11 symbols / 12 tags — 1 tag with no symbol beside it is marked on the sheet."))
        model.setTagCount(pageIndex: 2, symbols: 3, tags: 0, orphanTags: 0)
        #expect(model.tagCounts[2] == nil)
    }

    @Test("A place two types claim starts unticked, and ticking one claim unticks the other")
    func contestedPlaces() {
        let model = SymbolCountReviewModel(designation: "", pageTotal: 1, onAccept: { _ in }, onCancel: {})
        func claim(_ id: Int, _ designation: String, _ other: String) -> SymbolCountReviewRow {
            SymbolCountReviewRow(id: id, pageIndex: 0, pageLabel: "Page 1", position: PDFPointValue(x: 0, y: 0),
                                 bounds: PDFRectValue(x: 0, y: 0, width: 1, height: 1), status: .confirmed, detail: "",
                                 isExemplar: false, designation: designation, exclusiveGroup: 1, alsoClaimedBy: [other])
        }
        model.append(page: SymbolCountReviewPage(pageIndex: 0, pageLabel: "Page 1", otherShapeCount: 0, isTruncated: false),
                     rows: [claim(1, "D-12", "D-13"), claim(2, "D-13", "D-12")])
        #expect(model.selectedRowIDs.isEmpty)
        #expect(model.rows[0].statusText == "Also matches D-13 — tick the one it is")
        // V-068: it read "1 place(s) match more than one type; 1 still need a pick."
        #expect(model.summaryText.contains("1 place matches more than one type; 1 still needs a pick."))
        model.setSelected(true, for: model.rows[0])
        model.setSelected(true, for: model.rows[1])
        #expect(model.selectedRowIDs == [2])
        #expect(model.unresolvedContestedCount == 0)
    }
}
