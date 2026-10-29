import AppKit
import SwiftUI
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 1, area ui-workflows-ledger: Bulk Edit can clear a field (R-121) without the
/// focus echo of a Mixed field clearing it for the person (R-121 re-fix), the CSV
/// filter banner states numbers in the unit they were typed in (R-122), the header menu follows
/// the layout store (R-125), a column drag redraws what depends on column order (R-135), and a
/// bridged total no longer claims a contributing-row count it does not have (R-130).
@MainActor
@Suite("Ledger, loop iteration 1", .ledgerTierSerialised)
struct Iter1LedgerFixTests {

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let english = Locale(identifier: "en_US")

    private static func column(_ id: LedgerColumnID) -> LedgerColumn {
        LedgerFixtures.columns.first { $0.id == id }!
    }

    private static let unitCost = LedgerColumn(
        id: .custom("unitCost"), title: "Unit Cost", kind: .currency, dimension: .currency("SEK"),
        width: 90, alignment: .trailing, isEditable: true, displayUnitSymbol: "SEK",
        holdsUserValues: true
    )

    private static let phase = LedgerColumn(
        id: .custom("phase"), title: "Phase", kind: .choice, width: 90, alignment: .leading,
        isEditable: true, choices: LedgerFixtures.statusChoices, holdsUserValues: true
    )

    private func bulkModel(columns: [LedgerColumn] = LedgerFixtures.columns) -> LedgerBulkEditModel {
        LedgerBulkEditModel(rows: Array(LedgerFixtures.rows.prefix(2)), columns: columns)
    }

    // MARK: - R-121

    /// Old output: the text binding staged `nil` for "", so the field's getter fell back to the
    /// shared value — backspacing "Slab" away brought "Slab" back — and nothing could be blanked:
    /// the summary stayed "Nothing to change yet" and onApply never saw the field.
    @Test("Emptying a text field stages a cleared value, stays empty, and is applied")
    func emptyingATextFieldClearsIt() throws {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for index in rows.indices {
            rows[index].values[.label] = .text("Slab")
            rows[index].displayValues[.label] = "Slab"
        }
        let model = LedgerBulkEditModel(rows: rows, columns: LedgerFixtures.columns)
        let label = Self.column(.label)
        #expect(model.text(for: label) == "Slab")

        model.setText("Sla", for: label)
        #expect(model.text(for: label) == "Sla")
        model.setText("", for: label)
        #expect(model.text(for: label) == "", "the field does not snap back to the shared value")
        #expect(model.edit(for: .label) == .empty)
        #expect(model.summary.changesPerField[.label] == 2)
        #expect(model.summary.markupCount == 2)

        var applied: [LedgerColumnID: LedgerCellValue] = [:]
        model.onApply = { edits, _, _ in applied = edits }
        model.apply()
        #expect(applied[.label] == .empty)
    }

    @Test("Clearing a label that is already blank is no change")
    func clearingABlankIsNoChange() {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for index in rows.indices {
            rows[index].values[.label] = .text("")
            rows[index].displayValues[.label] = ""
        }
        let model = LedgerBulkEditModel(rows: rows, columns: LedgerFixtures.columns)
        let label = Self.column(.label)
        // The field already shows "", so writing "" is the focus echo, not an edit.
        model.setText("", for: label)
        #expect(model.edit(for: .label) == nil)
        #expect(!model.offersClear(label), "nothing to clear on a selection that is blank everywhere")
        model.setEdit(.empty, for: .label)
        #expect(model.summary.isEmpty, "a blank text cell and a cleared cell are the same nothing")
    }

    /// With the focus echo ignored, emptying a Mixed field cannot mean "blank it" — the untouched
    /// field is already empty. Clear is the deliberate way, for text and number fields alike.
    @Test("Clear blanks a mixed text or number field on purpose, and survives the focus echo")
    func clearBlanksAMixedField() {
        let model = mixedModel()
        let label = Self.column(.label)
        #expect(model.offersClear(label))
        #expect(model.offersClear(Self.unitCost))
        #expect(!model.offersClear(Self.column(.subject)), "Subject has no cleared form")

        model.clearField(label)
        model.clearField(Self.unitCost)
        #expect(model.text(for: label) == "")
        #expect(model.numberText(for: Self.unitCost, locale: Self.posix) == "")
        #expect(!model.offersClear(label), "already staged to be blanked")

        // The field loses focus and writes its "" back: the Clear stays.
        model.setText("", for: label)
        model.setNumberText("", for: Self.unitCost, locale: Self.posix)
        #expect(model.edits == [.label: .empty, Self.unitCost.id: .empty])
        #expect(model.summary.changesPerField == [.label: 2, Self.unitCost.id: 2])

        var applied: [LedgerColumnID: LedgerCellValue] = [:]
        model.onApply = { edits, _, _ in applied = edits }
        model.apply()
        #expect(applied == [.label: .empty, Self.unitCost.id: .empty])
    }

    @Test("Typing into a mixed field and deleting it again leaves the field unchanged")
    func typedThenDeletedInAMixedFieldIsUnchanged() {
        let model = mixedModel()
        let label = Self.column(.label)
        model.setText("X", for: label)
        #expect(model.edit(for: .label) == .text("X"))
        model.setText("", for: label)
        #expect(model.edit(for: .label) == nil)
        #expect(model.showsMixedPlaceholder(.label))

        model.setNumberText("7", for: Self.unitCost, locale: Self.posix)
        #expect(model.edit(for: Self.unitCost.id) == .currency(amount: 7, code: "SEK"))
        model.setNumberText("", for: Self.unitCost, locale: Self.posix)
        #expect(model.edit(for: Self.unitCost.id) == nil)
        #expect(model.summary.isEmpty)
        #expect(model.refusedBlankColumns.isEmpty)
    }

    /// Old output: `setNumberText("")` dropped the draft and unstaged, and `numberText` then
    /// showed the shared value again, so a Unit Cost could never be blanked.
    @Test("Emptying a number field clears it and the field stays empty")
    func emptyingANumberFieldClearsIt() {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for index in rows.indices {
            rows[index].values[Self.unitCost.id] = .currency(amount: 95, code: "SEK")
            rows[index].displayValues[Self.unitCost.id] = "95"
        }
        let model = LedgerBulkEditModel(rows: rows, columns: LedgerFixtures.columns + [Self.unitCost])
        model.setNumberText("9", for: Self.unitCost, locale: Self.posix)
        model.setNumberText("", for: Self.unitCost, locale: Self.posix)
        #expect(model.numberText(for: Self.unitCost, locale: Self.posix) == "")
        #expect(model.edit(for: Self.unitCost.id) == .empty)
        #expect(model.summary.changesPerField[Self.unitCost.id] == 2)
    }

    @Test("A choice column can be cleared from its menu, and Leave Unchanged takes it back")
    func choiceClearAndLeaveUnchanged() {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for index in rows.indices { rows[index].values[Self.phase.id] = .choice("draft") }
        let model = LedgerBulkEditModel(rows: rows, columns: LedgerFixtures.columns + [Self.phase])
        #expect(model.canClear(Self.phase))
        model.clearField(Self.phase)
        #expect(model.edit(for: Self.phase.id) == .empty)
        #expect(model.summary.changesPerField[Self.phase.id] == 2)
        model.leaveUnchanged(Self.phase.id)
        #expect(model.edit(for: Self.phase.id) == nil)
        #expect(model.summary.isEmpty)
    }

    /// Subject and Status have no cleared form in the application's apply path, so an emptied
    /// Subject must neither stage a `.empty` the app would silently ignore nor snap back.
    @Test("Subject and Status cannot be blanked, and an emptied Subject says so")
    func subjectAndStatusRefuseBlank() {
        let model = bulkModel()
        let subject = Self.column(.subject)
        #expect(!model.canClear(subject))
        #expect(!model.canClear(Self.column(.status)))
        model.setText("", for: subject)
        #expect(model.text(for: subject) == "")
        #expect(model.edit(for: .subject) == nil)
        #expect(model.refusedBlankColumns.contains(.subject))
        model.clearField(Self.column(.status))
        #expect(model.edit(for: .status) == nil)
        model.setText("Slab", for: subject)
        #expect(!model.refusedBlankColumns.contains(.subject))
        #expect(model.edit(for: .subject) == .text("Slab"))
        model.clearEdits()
        #expect(model.refusedBlankColumns.isEmpty && model.textDrafts.isEmpty)
    }

    // MARK: - R-121 re-fix: the focus echo

    /// The checker's probe: Label S-01/S-02 and Subject Slab A/Slab B disagree, and so do Unit
    /// Cost (95/120 SEK) and Waste Factor (0.05/0.10).
    private static func mixedRows() -> [LedgerRow] {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for (index, subject) in ["Slab A", "Slab B"].enumerated() {
            rows[index].values[.subject] = .text(subject)
            rows[index].displayValues[.subject] = subject
        }
        for (index, amount) in [Decimal(95), Decimal(120)].enumerated() {
            rows[index].values[unitCost.id] = .currency(amount: amount, code: "SEK")
            rows[index].displayValues[unitCost.id] = "\(amount)"
        }
        return rows
    }

    private func mixedModel() -> LedgerBulkEditModel {
        LedgerBulkEditModel(rows: Self.mixedRows(), columns: LedgerFixtures.columns + [Self.unitCost])
    }

    /// Old output (first R-121 fix): a TextField writes its unchanged text back whenever it gains
    /// or loses focus, and in a Mixed field that text is "". `setText("")` staged `.empty` for it:
    /// `edits == [label: .empty]`, `refusedBlankColumns == [subject]`, "Applies 1 changed field(s)
    /// to 2 markup(s)", and Apply would have wiped both labels.
    @Test("Writing back the empty text a mixed field shows stages nothing")
    func mixedFieldEchoStagesNothing() {
        let model = mixedModel()
        let subject = Self.column(.subject)
        let label = Self.column(.label)
        let waste = Self.column(LedgerFixtures.wasteFactor)
        #expect(model.text(for: label) == "")
        #expect(model.numberText(for: Self.unitCost, locale: Self.posix) == "")

        model.setText("", for: subject)
        model.setText("", for: label)
        model.setNumberText("", for: Self.unitCost, locale: Self.posix)
        model.setNumberText("", for: waste, locale: Self.posix)

        #expect(model.edits.isEmpty, "\(model.edits)")
        #expect(model.summary.isEmpty, "\(model.summary.message)")
        #expect(model.refusedBlankColumns.isEmpty, "no false \"Subject cannot be blank\" hint")
        #expect(model.showsMixedPlaceholder(.label))
        #expect(model.showsMixedPlaceholder(Self.unitCost.id))
    }

    @Test("Writing back the shared value a uniform field shows stages nothing")
    func uniformFieldEchoStagesNothing() {
        let model = bulkModel()
        let subject = Self.column(.subject)
        #expect(model.text(for: subject) == "Concrete Slab")
        model.setText("Concrete Slab", for: subject)
        #expect(model.edits.isEmpty)
        #expect(model.textDrafts.isEmpty)
    }

    /// Hosts the real panel in a window that is never ordered in, moves the keyboard into each
    /// field and out again without typing, and checks the model. This is the path the model
    /// tests above cannot see: SwiftUI, not the test, decides what the binding receives.
    @Test("Focusing and leaving every field of the hosted panel stages nothing")
    func hostedPanelFocusStagesNothing() throws {
        let model = mixedModel()
        let hosting = NSHostingView(rootView: LedgerBulkEditPanel(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()

        let fields = Self.editableTextFields(in: hosting)
        // Subject, Label, Waste Factor and Unit Cost.
        #expect(fields.count == 4)
        for field in fields {
            #expect(window.makeFirstResponder(field))
            Self.spinRunLoop()
            #expect(window.makeFirstResponder(nil))
            Self.spinRunLoop()
        }
        #expect(model.edits.isEmpty, "\(model.edits)")
        #expect(model.summary.isEmpty, "\(model.summary.message)")
        #expect(model.refusedBlankColumns.isEmpty)

        // The same round trip after a deliberate edit keeps exactly that edit.
        model.clearField(Self.column(.label))
        hosting.layoutSubtreeIfNeeded()
        for field in Self.editableTextFields(in: hosting) {
            #expect(window.makeFirstResponder(field))
            Self.spinRunLoop()
            #expect(window.makeFirstResponder(nil))
            Self.spinRunLoop()
        }
        #expect(model.edits == [.label: .empty], "\(model.edits)")
    }

    private static func editableTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { result.append(field) }
            result.append(contentsOf: editableTextFields(in: subview))
        }
        return result
    }

    private static func spinRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - R-122

    private static let millimetre = LedgerColumn(
        id: .planLength, title: "Plan Length", kind: .number, dimension: .length,
        width: 90, aggregate: .sum, displayUnitSymbol: "mm"
    )

    /// Old output: "Plan Length is at least 0.5" — the operand as stored, in metres, with no
    /// unit — for a rule the person typed as 500 in a millimetre column.
    @Test("The filter banner states a number in the column's display unit, with the unit")
    func bannerUsesTheDisplayUnit() {
        let filter = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.planLength, .greaterThanOrEqual, .number(Decimal(string: "0.5")!), index: 0)
        ])
        let text = LedgerExportWriter.describe(filter: filter, columns: [Self.millimetre], locale: Self.english)
        #expect(text.hasSuffix(" 500 mm"), "\(text)")
        #expect(!text.contains("0.5"))
    }

    @Test("A range reads in the display unit at both ends; unitless columns stay bare")
    func rangeAndUnitless() {
        let range = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(
                .planLength, .between,
                .numberRange(lower: Decimal(string: "1.2")!, upper: Decimal(string: "2.4")!), index: 0
            )
        ])
        let text = LedgerExportWriter.describe(filter: range, columns: [Self.millimetre], locale: Self.english)
        #expect(text.hasSuffix(" 1,200–2,400 mm"), "\(text)")

        let count = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.count, .greaterThan, .number(3), index: 0)
        ])
        let countText = LedgerExportWriter.describe(filter: count, columns: LedgerFixtures.columns, locale: Self.english)
        #expect(countText.hasSuffix(" 3"), "\(countText)")

        let cost = LedgerFixtures.group(.all, rules: [
            LedgerFixtures.rule(.totalCost, .greaterThan, .number(1500), index: 0)
        ])
        let costText = LedgerExportWriter.describe(filter: cost, columns: LedgerFixtures.columns, locale: Self.english)
        #expect(costText.hasSuffix(" 1,500 SEK"), "\(costText)")
    }

    // MARK: - R-125

    private func menuItem(_ menu: NSMenu?, path: [String]) -> NSMenuItem? {
        var current = menu
        var found: NSMenuItem?
        for title in path {
            found = current?.items.first { $0.title == title }
            current = found?.submenu
        }
        return found
    }

    /// Old output: the header menu was built in `rebuildColumns()` only, so after the host
    /// assigned a store with a new layout the submenu still read "No saved layouts".
    @Test("The header menu shows a layout saved after the columns were built, and drops a deleted one")
    func headerMenuFollowsTheLayoutStore() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let header = try #require(controller.mainTableViewForTesting.headerView?.menu)
        #expect(menuItem(header, path: ["Saved Layouts", "No saved layouts"]) != nil)

        var store = controller.layoutStore
        let savedLayout = store.save(controller.columns, name: "Review")
        let saved = try #require(savedLayout)
        controller.layoutStore = store
        let live = controller.mainTableViewForTesting.headerView?.menu
        #expect(menuItem(live, path: ["Saved Layouts", "Review"])?.state == .on)
        #expect(menuItem(live, path: ["Saved Layouts", "No saved layouts"]) == nil)
        #expect(controller.pinnedTableViewForTesting.headerView?.menu === live)
        #expect(controller.outlineViewForTesting.headerView?.menu === live)

        store.remove(id: saved.id)
        controller.layoutStore = store
        #expect(menuItem(controller.mainTableViewForTesting.headerView?.menu, path: ["Saved Layouts", "Review"]) == nil)
    }

    @Test("The header menu is refilled when it opens, so a hook set later appears")
    func headerMenuRefillsOnOpen() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let header = try #require(controller.mainTableViewForTesting.headerView?.menu)
        #expect(!header.items.contains { $0.title == "Manage Columns…" })
        controller.onManageColumnsRequested = { _ in }
        header.removeAllItems()
        header.delegate?.menuNeedsUpdate?(header)
        #expect(header.items.contains { $0.title == "Manage Columns…" })
    }

    // MARK: - R-135

    /// Old output: after moving the first column the outline's disclosure stayed on the column
    /// that was first before the drag and no row was redrawn (`rowReloadCount` unchanged), so
    /// rows on screen drew swatches and headings in the old column.
    @Test("Moving the first column re-points the disclosure and redraws the rows")
    func movingTheFirstColumnRedraws() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        controller.loadViewIfNeeded()
        let outline = controller.outlineViewForTesting
        let reloadsBefore = controller.rowReloadCount
        let firstBefore = try #require(controller.columns.first(where: \.visible)?.id)
        #expect(outline.outlineTableColumn?.identifier.rawValue == firstBefore.rawValue)

        outline.moveColumn(0, toColumn: 2)

        let firstAfter = try #require(controller.columns.first(where: \.visible)?.id)
        #expect(firstAfter != firstBefore)
        #expect(outline.outlineTableColumn?.identifier.rawValue == firstAfter.rawValue)
        #expect(controller.rowReloadCount == reloadsBefore + 1)
    }

    @Test("Moving a later column, or resizing without crossing the heading rule, does not redraw")
    func unrelatedChangesDoNotRedraw() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        controller.loadViewIfNeeded()
        let outline = controller.outlineViewForTesting
        let reloads = controller.rowReloadCount
        #expect(controller.columns.filter(\.visible).count >= 5)
        outline.moveColumn(3, toColumn: 4)
        #expect(controller.rowReloadCount == reloads, "neither the first nor the heading column moved")

        // The heading sits in the first visible column at least 90 pt wide.
        let heading = try #require(controller.groupHeadingColumnID)
        #expect(heading == controller.columns.first(where: \.visible)?.id)
        let headingColumn = try #require(outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(heading.rawValue)))
        headingColumn.width = 100
        #expect(controller.groupHeadingColumnID == heading, "100 pt is still past the 90 pt rule")
        #expect(controller.rowReloadCount == reloads, "a live resize that moves nothing does not reload")

        // Below 90 pt the headings move to the next wide column: that redraws, once.
        headingColumn.width = 60
        #expect(controller.groupHeadingColumnID != heading)
        #expect(controller.rowReloadCount == reloads + 1)
    }

    // MARK: - R-130

    /// Old output: `contributingRowCount == 7` — the bridge stored the group's row count, which
    /// the core's totals carry, as if every row had contributed a value. W-069 removed the
    /// field (it was `nil` in every shipping result), so the claim cannot be made at all; the
    /// group's row count stays where it belongs, on the subtotal record.
    @Test("A total bridged from the core does not claim a contributing-row count")
    func bridgedTotalHasNoContributingCount() {
        let totals = LedgerTotals(
            rowCount: 7,
            quantities: [.planArea: DecimalQuantity(value: 40, dimension: .area)],
            displayValues: [.planArea: "40 m²"]
        )
        let subtotals = LedgerSubtotals.bridging(totals, columns: LedgerFixtures.columns)
        #expect(subtotals.rowCount == 7)
        #expect(subtotals.result(.planArea)?.quantity?.value == 40)
        #expect(subtotals.result(.planArea) == LedgerAggregateResult(
            column: .planArea, aggregate: .sum, value: .quantity(DecimalQuantity(value: 40, dimension: .area))
        ))
    }
}
