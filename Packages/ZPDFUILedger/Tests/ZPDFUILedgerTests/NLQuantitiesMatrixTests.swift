import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-09: the summary matrix model and view over the mock presenter. Never on screen.
@MainActor
@Suite("Quantities — summary matrix view", .ledgerTierSerialised)
struct NLQuantitiesMatrixTests {

    @Test("The model builds, reconciles and copies as a tab-separated table")
    func buildAndCopy() async throws {
        let presenter = MockLedgerPresenter()
        let model = LedgerMatrixModel(
            presenter: presenter,
            options: [.init(column: .subject, title: "Subject"), .init(column: .trade, title: "Trade")],
            rows: .subject, columns: .trade
        )
        await model.rebuild()
        let matrix = try #require(model.matrix)
        // Row totals, column totals and the grand total agree with the cells.
        let cellSum = matrix.cells.flatMap { $0 }.reduce(0) { $0 + $1.rowCount }
        #expect(cellSum == matrix.grandTotal.rowCount)
        #expect(matrix.rowTotals.reduce(0) { $0 + $1.rowCount } == matrix.grandTotal.rowCount)
        #expect(matrix.columnTotals.reduce(0) { $0 + $1.rowCount } == matrix.grandTotal.rowCount)
        let text = try #require(model.tabularText)
        #expect(text.hasPrefix("Subject \\ Trade\t"))
        #expect(text.split(separator: "\n").count == matrix.rowTitles.count + 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zenit.test.matrix.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(model.copy(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test("The view builds off-screen")
    func viewHostsOffScreen() {
        let model = LedgerMatrixModel(
            presenter: MockLedgerPresenter(),
            options: [.init(column: .subject, title: "Subject"), .init(column: .trade, title: "Trade")],
            rows: .subject, columns: .trade
        )
        let hosting = NSHostingView(rootView: LedgerMatrixView(model: model, pasteboard: NSPasteboard(name: .init("zenit.test.matrix.view")), onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
    }
}
