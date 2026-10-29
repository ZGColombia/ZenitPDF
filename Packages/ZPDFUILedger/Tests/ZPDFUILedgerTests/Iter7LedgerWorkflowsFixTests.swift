import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 7, area ui-workflows-ledger, the ledger UI half: X-030 (every route that puts
/// ledger text on the pasteboard applies the spreadsheet formula guard and the quoting rule).
@MainActor
@Suite("Loop iteration 7 — ui-workflows-ledger ledger UI fixes", .ledgerTierSerialised)
struct Iter7LedgerWorkflowsFixTests {

    final class RecordingPasteboard: LedgerPasteboardWriting {
        var payloads: [LedgerCopyPayload] = []
        func write(_ payload: LedgerCopyPayload) { payloads.append(payload) }
    }

    /// The default layout hides every column past the first few; Copy writes visible ones.
    static func showEveryColumn(_ controller: LedgerTableController) {
        controller.setColumns(controller.columns.map { column in
            var shown = column
            shown.visible = true
            return shown
        })
    }

    static let hyperlink = "=HYPERLINK(\"http://example.invalid\",\"Wall\")"
    static let dde = "-2+3+cmd|' /C calc'!A0"

    // MARK: - X-030

    @Test("X-030: the field guard — text that starts like a formula gets an apostrophe; a rendered number does not")
    func fieldGuard() {
        // Old output: every one of these went out unchanged.
        #expect(LedgerTabularText.field("=1+1") == "'=1+1")
        #expect(LedgerTabularText.field("+1") == "'+1")
        #expect(LedgerTabularText.field("@SUM(A1)") == "'@SUM(A1)")
        #expect(LedgerTabularText.field(Self.dde) == "'" + Self.dde)
        #expect(LedgerTabularText.field("-3.20") == "'-3.20", "a minus in a text cell is guarded, whatever follows (X-013)")
        #expect(LedgerTabularText.field(Self.hyperlink) == "\"'=HYPERLINK(\"\"http://example.invalid\"\",\"\"Wall\"\")\"")
        #expect(LedgerTabularText.field("\r\n=1+1") == "\"'\r\n=1+1\"", "the first scalar decides, so CRLF is guarded too")
        #expect(LedgerTabularText.field("\tTabbed") == "\"'\tTabbed\"")
        // A rendered number keeps its sign; plain text and the quoting rule are unchanged.
        #expect(LedgerTabularText.field("-3.20", isNumber: true) == "-3.20")
        #expect(LedgerTabularText.field("Concrete Slab") == "Concrete Slab")
        #expect(LedgerTabularText.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(LedgerTabularText.isNumber(.quantity(DecimalQuantity(value: -3.2, dimension: .length))))
        #expect(LedgerTabularText.isNumber(.currency(amount: -1, code: "SEK")))
        #expect(!LedgerTabularText.isNumber(.text("-3.20")))
    }

    /// Old output: `=HYPERLINK(…)`, `@SUM(A1)` and the DDE payload were copied as they are, so a
    /// spreadsheet ran them on paste; the copy only quoted.
    @Test("X-030: Copy and drag-out guard a Subject, Label or Trade that starts like a formula, and keep a negative length a number")
    func copyGuardsTextAndKeepsNumbers() throws {
        var rows = LedgerFixtures.rows
        rows[0].displayValues[.subject] = Self.hyperlink
        rows[0].displayValues[.label] = "@SUM(A1)"
        rows[0].displayValues[.trade] = Self.dde
        rows[0].values[.planLength] = .quantity(DecimalQuantity(value: Decimal(string: "-3.2")!, dimension: .length))
        rows[0].displayValues[.planLength] = "-3.20"
        let controller = LedgerTableController(rowSource: LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns))
        controller.loadViewIfNeeded()
        Self.showEveryColumn(controller)
        let pasteboard = RecordingPasteboard()
        controller.copyPasteboard = pasteboard
        controller.mainTableViewForTesting.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.copy(nil)

        let text = try #require(pasteboard.payloads.first?.tabSeparatedText)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3, "header, one row, the final line feed")
        let visible = controller.columns.filter(\.visible)
        let cells = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(cells.count == visible.count)
        func cell(_ id: LedgerColumnID) -> String? {
            visible.firstIndex { $0.id == id }.map { cells[$0] }
        }
        #expect(cell(.subject) == "\"'=HYPERLINK(\"\"http://example.invalid\"\",\"\"Wall\"\")\"")
        #expect(cell(.label) == "'@SUM(A1)")
        #expect(cell(.trade) == "'" + Self.dde)
        #expect(cell(.planLength) == "-3.20", "a measured negative stays a number")

        // A row dragged out of the table carries the same text (NL-UX-15).
        #expect(controller.tabularText(visualRows: IndexSet(integer: 0)) == text)
        #expect(controller.view.window == nil)
    }

    /// Old output: the group heading "+Danger (2)" was copied unguarded.
    @Test("X-030: a copied group heading is guarded text; its subtotal stays a number")
    func groupLineIsGuarded() throws {
        var rows = LedgerFixtures.rows
        for index in 0..<3 {
            rows[index].values[.projectZone] = .text("+Danger")
            rows[index].displayValues[.projectZone] = "+Danger"
        }
        let controller = LedgerTableController(
            rowSource: LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns),
            mode: .grouped,
            groupingColumns: [.projectZone]
        )
        controller.loadViewIfNeeded()
        Self.showEveryColumn(controller)
        let heading = try #require((0..<controller.outlineViewForTesting.numberOfRows).first { visual in
            controller.tabularText(visualRows: IndexSet(integer: visual))?.contains("+Danger") == true
        })
        let text = try #require(controller.tabularText(visualRows: IndexSet(integer: heading)))
        let line = String(text.split(separator: "\n")[1])
        #expect(line.contains("'+Danger (3)"))
        #expect(!line.contains("\t+Danger") && !line.hasPrefix("+Danger"))
        // The Count subtotal of rows 0–2 is 2 + 3 + 1 = 6, written as the number it is.
        let visible = controller.columns.filter(\.visible)
        let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let countIndex = try #require(visible.firstIndex { $0.id == .count })
        #expect(cells[countIndex].hasPrefix("6"), "\(cells[countIndex])")
    }

    /// Old output: the titles were joined with a bare tab, unguarded and unquoted, so the row
    /// title "Line one⏎Line two" split the pasted matrix into one more line than it has rows and
    /// shifted every total after it, and "=cmd…" ran on paste.
    @Test("X-030: Summary Matrix Copy as Table guards and quotes its titles, and keeps its totals numbers")
    func matrixCopyIsGuardedAndQuoted() {
        let area = { (value: String) in DecimalQuantity(value: Decimal(string: value)!, dimension: .area) }
        let matrix = LedgerMatrix(
            rowColumn: .subject,
            columnColumn: .trade,
            rowTitles: ["=cmd|' /C calc'!A0", "Line one\nLine two"],
            columnTitles: ["@risk"],
            cells: [
                [LedgerMatrix.Cell(text: "-1.50", quantity: area("-1.5"), rowCount: 1)],
                [LedgerMatrix.Cell(text: "Mixed units", quantity: nil, rowCount: 2)]
            ],
            rowTotals: [
                LedgerMatrix.Cell(text: "-1.50", quantity: area("-1.5"), rowCount: 1),
                LedgerMatrix.Cell(text: "Mixed units", quantity: nil, rowCount: 2)
            ],
            columnTotals: [LedgerMatrix.Cell(text: "Mixed units", quantity: nil, rowCount: 3)],
            grandTotal: LedgerMatrix.Cell(text: "Mixed units", quantity: nil, rowCount: 3)
        )
        let text = matrix.tabularText(cornerTitle: "Subject \\ Trade", totalTitle: "Total")
        #expect(text == """
        Subject \\ Trade\t'@risk\tTotal
        '=cmd|' /C calc'!A0\t-1.50\t-1.50
        "Line one
        Line two"\tMixed units\tMixed units
        Total\tMixed units\tMixed units

        """)
    }
}
