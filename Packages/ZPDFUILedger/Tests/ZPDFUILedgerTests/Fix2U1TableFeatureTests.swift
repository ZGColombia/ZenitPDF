import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Improvements 2 on the table controller: inline editing (IM-013), the precomputed plan
/// seam and prefetch (IM-014), Copy (IM-015), value/unit as separate fields (IM-098) and
/// multi-column sort (IM-099). No window, no sheet, and the real pasteboard is never
/// touched: Copy goes to a recorder.
@MainActor
@Suite("Fix2 U1 table features", .ledgerTierSerialised)
struct Fix2U1TableFeatureTests {

    typealias Spy = Fix2U1TableSelectionTests.Spy

    final class RecordingPasteboard: LedgerPasteboardWriting {
        var payloads: [LedgerCopyPayload] = []
        func write(_ payload: LedgerCopyPayload) { payloads.append(payload) }
    }

    static func flat(
        rows: [LedgerRow] = LedgerFixtures.rows,
        edits: (@MainActor (LedgerBulkEditRequest) -> Void)? = nil
    ) -> LedgerTableController {
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        if let edits { controller.onCommitInlineEdit = edits }
        controller.loadViewIfNeeded()
        return controller
    }

    static func keyEvent(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: IM-013

    @Test("IM-013: Return on a focused editable cell opens an editor with the cell's text")
    func returnOpensEditor() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        let table = controller.mainTableViewForTesting
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.focusColumn(.label)

        table.keyDown(with: Self.keyEvent(36, characters: "\r"))

        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 0, columnID: .label))
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        #expect(field.stringValue == "S-01")
        #expect(field.superview === table)
        #expect(field.accessibilityLabel() == "Edit Label")
        #expect(requests.isEmpty)
    }

    @Test("IM-013: Tab commits one one-markup request and moves to the next editable cell")
    func tabCommitsAndMoves() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        #expect(controller.beginInlineEdit(displayPosition: 0, columnID: .label))
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        field.stringValue = "S-01A"

        #expect(controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))

        #expect(requests == [LedgerBulkEditRequest(
            markupIDs: [LedgerFixtures.rows[0].markupID], values: [.label: .text("S-01A")]
        )])
        // Label then Subject are the visible editable columns, in display order.
        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 0, columnID: .subject))

        // NL-QTY-04: the editable number column (Waste Factor) is reachable in place too, so
        // Tab visits it after Subject; from there, the last editable column, it wraps to the
        // next row's first.
        let subject = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        _ = controller.control(subject, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 0, columnID: LedgerFixtures.wasteFactor))
        let waste = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        _ = controller.control(waste, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 1, columnID: .label))
        #expect(requests.count == 1, "an unchanged cell sends nothing")

        // Shift-Tab goes back, to the previous row's last editable column.
        let label = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        _ = controller.control(label, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 0, columnID: LedgerFixtures.wasteFactor))
    }

    @Test("NL-QTY-04: a number typed into a cell is parsed and sent as a number, never as text")
    func inlineNumberEdit() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        controller.locale = Locale(identifier: "sv_SE")
        #expect(controller.beginInlineEdit(displayPosition: 0, columnID: LedgerFixtures.wasteFactor))
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        // The editor opens on the bare editable number in the locale, not the formatted cell.
        #expect(field.stringValue == "0,05")
        field.stringValue = "0,25"
        controller.commitInlineEdit()
        // Old code: number columns opened no editor at all (`isInlineEditable` returned false).
        #expect(requests == [LedgerBulkEditRequest(
            markupIDs: [LedgerFixtures.rows[0].markupID],
            values: [LedgerFixtures.wasteFactor: .number(Decimal(string: "0.25")!)]
        )])

        // Text that is not a number sends nothing — the cell keeps its value, and the refusal
        // is signalled rather than silent.
        var rejected: [LedgerColumnID] = []
        controller.onInlineEditRejected = { rejected.append($0.id) }
        #expect(controller.beginInlineEdit(displayPosition: 1, columnID: LedgerFixtures.wasteFactor))
        let second = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        second.stringValue = "12abc"
        controller.commitInlineEdit()
        #expect(requests.count == 1)
        #expect(rejected == [LedgerFixtures.wasteFactor])
    }

    @Test("NL-QTY-01: an editable column with nowhere to store an edit opens no editor")
    func editableColumnWithoutAHomeIsNotInlineEditable() {
        let controller = Self.flat { _ in }
        // A built-in text column the producer marks editable but which holds no user value
        // (the display-unit column, say): an editor here used to send an edit the app dropped.
        let orphan = LedgerColumn(id: .displayUnit, title: "Unit", kind: .text, width: 60, isEditable: true)
        #expect(!controller.isInlineEditable(orphan))
        let costCode = LedgerColumn(
            id: .costCode, title: "Cost Code", kind: .text, width: 60, isEditable: true,
            isUserDefined: false, holdsUserValues: true
        )
        #expect(controller.isInlineEditable(costCode))
    }

    @Test("IM-013: Escape restores the value and sends nothing")
    func escapeCancels() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        controller.beginInlineEdit(displayPosition: 2, columnID: .subject)
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        field.stringValue = "Something else"

        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        #expect(requests.isEmpty)
        #expect(controller.editingCell == nil)
        #expect(field.superview == nil)
    }

    @Test("IM-013: Return commits; clearing a cell writes an empty value")
    func returnCommitsAndClears() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        controller.beginInlineEdit(displayPosition: 1, columnID: .label)
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        field.stringValue = ""
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(requests == [LedgerBulkEditRequest(markupIDs: [LedgerFixtures.rows[1].markupID], values: [.label: .empty])])
        #expect(controller.editingCell == nil)
    }

    @Test("IM-013: a choice column edits through a pop-up of its options")
    func choicePopUp() throws {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        controller.setColumn(.status, visible: true)
        #expect(controller.beginInlineEdit(displayPosition: 0, columnID: .status))
        let popUp = try #require(controller.inlineEditorForTesting as? LedgerInlinePopUpButton)
        #expect(popUp.selectedValue == "approved")
        // T-050: Status cannot be cleared, so a Status cell that holds a value offers no
        // "No value" entry (it used to, and choosing it closed the editor and changed nothing).
        // A clearable choice column still offers it: Iter3LedgerWorkflowsFixTests.
        #expect(popUp.itemTitles == ["Draft", "Approved"])

        popUp.select(value: "draft")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(requests == [LedgerBulkEditRequest(markupIDs: [LedgerFixtures.rows[0].markupID], values: [.status: .choice("draft")])])
        #expect(controller.editingCell == nil)
    }

    @Test("IM-013: Return on a non-editable column still jumps; locked rows and unwired hosts never edit")
    func returnStillJumps() {
        var requests: [LedgerBulkEditRequest] = []
        let controller = Self.flat { requests.append($0) }
        let spy = Spy()
        controller.delegate = spy
        let table = controller.mainTableViewForTesting
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        controller.focusColumn(.projectZone)  // not editable
        table.keyDown(with: Self.keyEvent(36, characters: "\r"))
        #expect(controller.editingCell == nil)
        #expect(spy.activations == [LedgerFixtures.rows[3].markupID])

        var locked = LedgerFixtures.rows
        locked[0].locked = true
        let lockedController = Self.flat(rows: locked) { requests.append($0) }
        #expect(lockedController.beginInlineEdit(displayPosition: 0, columnID: .label) == false)

        let unwired = Self.flat()
        #expect(unwired.beginInlineEdit(displayPosition: 0, columnID: .label) == false)
        #expect(unwired.inlineEditableColumns.isEmpty)
    }

    @Test("IM-013: a reload while editing reopens the editor on the same markup with the typed text")
    func reloadKeepsEditor() throws {
        let controller = Self.flat { _ in }
        controller.beginInlineEdit(displayPosition: 0, columnID: .label)
        let field = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        field.stringValue = "half typed"
        controller.rebuildPlan()
        let reopened = try #require(controller.inlineEditorForTesting as? LedgerInlineTextField)
        #expect(controller.editingCell == LedgerCellAddress(displayPosition: 0, columnID: .label))
        #expect(reopened.stringValue == "half typed")
    }

    // MARK: IM-015

    @Test("IM-015: Copy writes the header and the selected rows as tab-separated cells")
    func copySelectedRows() throws {
        // Old output: nothing — the table had no copy: responder, so Cmd-C did nothing.
        var rows = LedgerFixtures.rows
        rows[1].displayValues[.subject] = "Slab\twith\ttabs"
        rows[2].displayValues[.label] = "two\nlines"
        let controller = Self.flat(rows: rows)
        let pasteboard = RecordingPasteboard()
        controller.copyPasteboard = pasteboard
        controller.mainTableViewForTesting.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)

        let item = NSMenuItem(title: "Copy", action: #selector(LedgerTableController.copy(_:)), keyEquivalent: "c")
        #expect(controller.validateMenuItem(item))
        controller.copy(nil)

        let text = try #require(pasteboard.payloads.first?.tabSeparatedText)
        let visible = controller.columns.filter(\.visible)
        var expected = [visible.map(\.title).joined(separator: "\t")]
        for row in rows.prefix(3) {
            expected.append(visible.map {
                LedgerTabularText.field(LedgerDefaultColumns.displayText(for: row, columnID: $0.id))
            }.joined(separator: "\t"))
        }
        #expect(text == expected.joined(separator: "\n") + "\n")
        #expect(text.contains("\"Slab\twith\ttabs\""))
        #expect(text.contains("\"two\nlines\""))

        controller.mainTableViewForTesting.deselectAll(nil)
        #expect(controller.validateMenuItem(item) == false)
    }

    @Test("IM-015: a selected group heading copies its subtotal line")
    func copyGroupSubtotal() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        controller.loadViewIfNeeded()
        let pasteboard = RecordingPasteboard()
        controller.copyPasteboard = pasteboard
        controller.outlineViewForTesting.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.copy(nil)
        let lines = try #require(pasteboard.payloads.first?.tabSeparatedText).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("Zone A (3)"))
    }

    // MARK: IM-099

    @Test("IM-099: two header levels arrive as a two-level request, outermost first")
    func multiColumnSort() {
        // Old output: only `didRequestSort(.label, ascending: false)` — the first descriptor.
        let controller = Self.flat()
        let spy = Spy()
        controller.delegate = spy
        let table = controller.mainTableViewForTesting
        table.sortDescriptors = [
            NSSortDescriptor(key: "label", ascending: false),
            NSSortDescriptor(key: "subject", ascending: true)
        ]
        #expect(spy.sorts.last == [
            LedgerSortDescriptor(column: .label, ascending: false),
            LedgerSortDescriptor(column: .subject, ascending: true)
        ])
        let subjectTip = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("subject"))?.headerToolTip ?? ""
        #expect(subjectTip.contains("2 of 2"))
    }

    @Test("IM-099: a host that only knows one column still gets the outermost level")
    func singleColumnHostStillSorts() {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source)
        host.controller.loadViewIfNeeded()
        var single: [(LedgerColumnID, Bool)] = []
        host.onSort = { single.append(($0, $1)) }
        host.controller.mainTableViewForTesting.sortDescriptors = [
            NSSortDescriptor(key: "label", ascending: false),
            NSSortDescriptor(key: "subject", ascending: true)
        ]
        #expect(single.count == 1)
        #expect(single.first?.0 == .label)
        #expect(single.first?.1 == false)

        var levels: [[LedgerSortDescriptor]] = []
        host.onSortDescriptors = { levels.append($0) }
        host.controller.mainTableViewForTesting.sortDescriptors = [NSSortDescriptor(key: "subject", ascending: false)]
        #expect(levels == [[LedgerSortDescriptor(column: .subject, ascending: false)]])
        #expect(single.count == 1, "the multi-level callback replaces the single one")
    }

    // MARK: IM-098

    @Test("IM-098: group headers carry number and unit as separate fields in any locale")
    func valueAndUnitSeparate() throws {
        // Old output (ar_EG): Value "١٬٢٣٤٫٥ m²" and Unit "" — splitUnit found no ASCII digit
        // in the number and refused to split.
        var rows = LedgerFixtures.rows
        rows[0].values[.planArea] = .quantity(.squareMetres(Decimal(string: "1234.5")!))
        rows[1].values[.planArea] = .quantity(.squareMetres(0))
        rows[2].values[.planArea] = .quantity(.squareMetres(0))
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        controller.rounding = .oneDigit
        controller.loadViewIfNeeded()
        let zoneA = try #require(controller.slice(forPath: "Zone A"))
        let value = try #require(controller.column(LedgerDefaultColumns.valueColumnID))
        let unit = try #require(controller.column(LedgerDefaultColumns.unitColumnID))

        for identifier in ["ar_EG@numbers=arab", "sv_SE", "en_US"] {
            let locale = Locale(identifier: identifier)
            controller.locale = locale
            let expectedNumber = LedgerNumberFormatting.string(Decimal(string: "1234.5")!, fractionDigits: 1, locale: locale)
            #expect(controller.groupCellText(zoneA, column: value) == expectedNumber, "\(identifier)")
            #expect(controller.groupCellText(zoneA, column: unit) == "m²", "\(identifier)")
        }
    }

    // MARK: IM-014

    /// A 100 000-row source that counts every row it builds and can answer the plan itself.
    final class CountingSource: LedgerRowProviding, LedgerGroupPlanProviding, LedgerIndexedRowProviding {
        let count: Int
        var suppliesPlan: Bool
        private(set) var rowReads = 0
        private(set) var prefetched: [Range<Int>] = []
        let columns = LedgerFixtures.columns

        init(count: Int, suppliesPlan: Bool) {
            self.count = count
            self.suppliesPlan = suppliesPlan
        }

        var ledgerColumns: [LedgerColumn] { columns }
        var ledgerRowCount: Int { count }

        func ledgerRow(at index: Int) -> LedgerRow? {
            guard index >= 0, index < count else { return nil }
            rowReads += 1
            var row = LedgerFixtures.rows[index % 6]
            row = LedgerRow(
                markupID: Self.id(index), values: row.values, displayValues: row.displayValues,
                colorRGBA: row.colorRGBA, kind: row.kind, measurementKind: row.measurementKind
            )
            return row
        }

        func ledgerRowIndex(of markupID: UUID) -> Int? {
            let bytes = markupID.uuid
            let index = Int(bytes.12) << 24 | Int(bytes.13) << 16 | Int(bytes.14) << 8 | Int(bytes.15)
            return index < count ? index : nil
        }

        func prefetchLedgerRows(in range: Range<Int>) { prefetched.append(range) }

        func ledgerGroupPlan(groupingColumns: [LedgerColumnID], columns: [LedgerColumn]) -> LedgerGroupPlan? {
            guard suppliesPlan else { return nil }
            let half = count / 2
            let groups = groupingColumns.isEmpty ? [] : [
                LedgerPrecomputedGroup(title: "Zone A", column: groupingColumns[0], value: "Zone A", rowCount: half, subtotals: .empty),
                LedgerPrecomputedGroup(title: "Zone B", column: groupingColumns[0], value: "Zone B", rowCount: count - half, subtotals: .empty)
            ]
            return LedgerGroupPlan.precomputed(
                rowCount: count, groups: groups, grandSubtotals: .empty, groupingColumns: groupingColumns
            )
        }

        static func id(_ index: Int) -> UUID {
            UUID(uuid: (0x5A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        UInt8(truncatingIfNeeded: index >> 24), UInt8(truncatingIfNeeded: index >> 16),
                        UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)))
        }
    }

    @Test("IM-014: with a supplied plan, a 100 000-row rebuild reads O(visible) rows, not all of them")
    func suppliedPlanReadsNoRows() {
        let rows = 100_000
        // A source that supplies no plan used to be folded, reading every row (C-04 old
        // output: 100 000+ reads). Since the fold is gone (R-129) it is listed flat and its
        // rebuild reads only what is drawn too.
        let unsupplied = CountingSource(count: rows, suppliesPlan: false)
        let flat = LedgerTableController(rowSource: unsupplied, mode: .grouped, groupingColumns: [.projectZone])
        flat.loadViewIfNeeded()
        #expect(unsupplied.rowReads <= 200, "an unsupplied plan reads only what is drawn (\(unsupplied.rowReads))")
        #expect(flat.planOrigin == .unsupplied)
        #expect(flat.plan.groups.isEmpty)
        #expect(flat.plan.order.count == rows)

        let supplied = CountingSource(count: rows, suppliesPlan: true)
        let fast = LedgerTableController(rowSource: supplied, mode: .grouped, groupingColumns: [.projectZone])
        fast.loadViewIfNeeded()
        fast.rebuildPlan()
        #expect(supplied.rowReads <= 200, "a supplied plan reads only what is drawn (\(supplied.rowReads))")
        #expect(fast.plan.groups.map(\.rowRange) == [0..<50_000, 50_000..<100_000])

        // Selecting a row far down resolves through the source's index, not a full scan.
        let target = CountingSource.id(75_000)
        fast.applyExternalSelection([target], scrollToFirst: false)
        #expect(fast.displayPosition(of: target) == 75_000)
        #expect(supplied.rowReads <= 400, "selection does not materialise the ledger (\(supplied.rowReads))")
    }

    @Test("IM-014: the visible band is handed to the source's prefetch")
    func prefetchVisibleBand() {
        let source = CountingSource(count: 10_000, suppliesPlan: true)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        controller.prefetchVisibleBand(visible: 1_000..<1_040)
        #expect(source.prefetched.last == 968..<1_136)
        controller.prefetchVisibleBand(visible: 9_990..<10_000)
        #expect(source.prefetched.last == 9_958..<10_000)
    }

    @Test("IM-014: a precomputed outline refuses counts that do not add up")
    func precomputedPlanValidates() {
        let good = LedgerGroupPlan.precomputed(
            rowCount: 5,
            groups: [
                LedgerPrecomputedGroup(title: "A", column: .projectZone, value: "A", rowCount: 2, subtotals: .empty, children: [
                    LedgerPrecomputedGroup(title: "x", column: .trade, value: "x", rowCount: 1, subtotals: .empty),
                    LedgerPrecomputedGroup(title: "y", column: .trade, value: "y", rowCount: 1, subtotals: .empty)
                ]),
                LedgerPrecomputedGroup(title: "B", column: .projectZone, value: "B", rowCount: 3, subtotals: .empty)
            ],
            grandSubtotals: .empty,
            groupingColumns: [.projectZone, .trade]
        )
        #expect(good?.groups.map(\.rowRange) == [0..<2, 2..<5])
        #expect(good?.groups.first?.children.map(\.rowRange) == [0..<1, 1..<2])
        #expect(good?.groups.first?.children.last?.path == "A" + LedgerGroupingEngine.pathSeparator + "y")

        let bad = LedgerGroupPlan.precomputed(
            rowCount: 6,
            groups: [LedgerPrecomputedGroup(title: "A", column: .projectZone, value: "A", rowCount: 2, subtotals: .empty)],
            grandSubtotals: .empty,
            groupingColumns: [.projectZone]
        )
        #expect(bad == nil)

        let totals = LedgerTotals(rowCount: 3, quantities: [.planArea: .squareMetres(5)], incompatibleColumns: [.custom("mixedMetric")])
        let bridged = LedgerSubtotals.bridging(totals, columns: LedgerFixtures.columns)
        #expect(bridged.result(.planArea)?.quantity == .squareMetres(5))
        #expect(bridged.result(.custom("mixedMetric"))?.isMixedUnits == true)
    }
}

/// IM-200: size-to-fit from the header menu.
@MainActor
@Suite("Fix2 U1 size to fit", .ledgerTierSerialised)
struct Fix2U1SizeToFitTests {

    @Test("IM-200: Size Column to Fit widens to the long visible value and reports once")
    func sizeColumnToFit() throws {
        var rows = LedgerFixtures.rows
        let long = "A very long label that certainly does not fit in one hundred points"
        rows[2].displayValues[.label] = long
        let source = LedgerArrayRowSource(rows: rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let spy = Fix2U1TableSelectionTests.Spy()
        controller.delegate = spy
        let labelColumn = try #require(controller.column(.label))
        let textWidth = Double((long as NSString).size(withAttributes: [.font: LedgerCellView.font(for: labelColumn)]).width)

        let menu = LedgerColumnMenuBuilder.menu(for: controller)
        let item = try #require(menu.items.first { $0.title == "Size Column to Fit" }?.submenu?.items.first { $0.title == "Label" })
        controller.sizeColumnToFitFromMenu(item)

        let width = try #require(controller.column(.label)?.width)
        #expect(width >= textWidth)
        #expect(width <= 900)
        #expect(spy.columnChanges.count == 1)
        #expect(controller.mainTableViewForTesting.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label"))?.width == CGFloat(width))

        spy.columnChanges.removeAll()
        controller.sizeAllColumnsToFit()
        #expect(spy.columnChanges.count <= 1)
        #expect(controller.tableView(controller.mainTableViewForTesting, shouldShowCellExpansionFor: nil, row: 0))
    }
}
