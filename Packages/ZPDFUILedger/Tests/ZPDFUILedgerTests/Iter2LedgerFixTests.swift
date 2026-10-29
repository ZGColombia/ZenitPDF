import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 2, area ui-workflows-ledger. The table follows the source's columns on every
/// reload (S-075), one number grammar for every ledger field (S-076), Reset Columns goes back to
/// the default arrangement (S-080), Apply is never disabled without a visible reason (S-081), the
/// ledger reopens in its active layout (S-082), Bulk Edit edits a shared money value in place
/// (S-084), the Filter panel can name every column (S-078), money subtotal text rounds half away
/// from zero (S-079) and a column drag cannot cross the pinned band (S-087). Every controller is
/// loaded off screen and never put in a window.
@MainActor
@Suite("Ledger, loop iteration 2", .ledgerTierSerialised)
struct Iter2LedgerFixTests {

    private static let english = Locale(identifier: "en_US")
    private static let swedish = Locale(identifier: "sv_SE")
    private static let german = Locale(identifier: "de_DE")

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    /// A row source whose columns change in place, the way the application presenter's do after
    /// the Column Manager applies a change. The app never hands the table a new source.
    final class LiveColumnSource: LedgerRowProviding {
        var columns: [LedgerColumn]
        let rows: [LedgerRow]
        init(columns: [LedgerColumn], rows: [LedgerRow]) {
            self.columns = columns
            self.rows = rows
        }
        var ledgerColumns: [LedgerColumn] { columns }
        var ledgerRowCount: Int { rows.count }
        func ledgerRow(at index: Int) -> LedgerRow? { rows.indices.contains(index) ? rows[index] : nil }
    }

    private static func visibleTableIDs(_ controller: LedgerTableController) -> [LedgerColumnID] {
        controller.mainTableViewForTesting.tableColumns.map { LedgerColumnID($0.identifier.rawValue) }
    }

    private static func showColumnsTitles(_ controller: LedgerTableController) -> [String] {
        controller.headerMenu.items.first?.submenu?.items.map(\.title) ?? []
    }

    // MARK: - S-075

    /// Old output: `host.controller.columns` kept the set it was created with. The new column was
    /// in the presenter and nowhere in the table, the renamed one kept "Screed", the hidden one
    /// stayed on screen and the deleted one drew blank cells until the pane was rebuilt.
    @Test("S-075: a column added, renamed, retyped, hidden, moved or deleted at the source reaches the table on reload")
    func columnManagerChangesReachTheTable() throws {
        let source = LiveColumnSource(columns: LedgerFixtures.columns, rows: LedgerFixtures.rows)
        let host = LedgerTableHost(rowSource: source)
        host.controller.loadViewIfNeeded()
        let screed = LedgerColumnID.custom("screed")
        #expect(host.controller.column(screed) == nil)

        // Add Column… in the Column Manager, then close it: the pane calls `host.reload()`.
        source.columns.append(LedgerColumn(
            id: screed, title: "Screed", kind: .number, dimension: .area, width: 90,
            alignment: .trailing, isEditable: true, displayUnitSymbol: "m²"
        ))
        host.reload()
        #expect(host.controller.column(screed)?.visible == true)
        #expect(Self.visibleTableIDs(host.controller).contains(screed))
        #expect(host.columns.contains { $0.id == screed }, "the host's mirror follows")
        #expect(Self.showColumnsTitles(host.controller).contains("Screed"), "the header's Show Columns lists it")

        // The user widens it in the table; a rename at the source keeps that width.
        host.controller.setColumns(host.controller.columns.map { column in
            var column = column
            if column.id == screed { column.width = 222 }
            return column
        })
        let index = try #require(source.columns.firstIndex { $0.id == screed })
        source.columns[index].title = "Floor Screed"
        source.columns[index].displayUnitSymbol = "mm²"
        host.reload()
        #expect(host.controller.column(screed)?.title == "Floor Screed")
        #expect(host.controller.column(screed)?.displayUnitSymbol == "mm²")
        #expect(host.controller.column(screed)?.width == 222, "the user's width survives a rename")
        let tableColumn = host.controller.mainTableViewForTesting.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier(screed.rawValue)
        )
        #expect(tableColumn?.title == "Floor Screed", "the header shows the new title")

        // A retype, which the old id-only comparison could never see.
        source.columns[index].kind = .text
        source.columns[index].dimension = nil
        host.reload()
        #expect(host.controller.column(screed)?.kind == .text)

        // Hidden in the Column Manager: hidden in the table.
        source.columns[index].visible = false
        host.reload()
        #expect(host.controller.column(screed)?.visible == false)
        #expect(!Self.visibleTableIDs(host.controller).contains(screed))
        source.columns[index].visible = true
        host.reload()
        #expect(Self.visibleTableIDs(host.controller).contains(screed))

        // Moved in the Column Manager: the user columns take the new order in their own slots.
        let userOrder = { host.controller.columns.filter(\.isUserDefined).map(\.id) }
        #expect(userOrder() == [LedgerFixtures.wasteFactor, LedgerFixtures.mixed, screed])
        let moved = source.columns.remove(at: index)
        source.columns.insert(moved, at: 0)
        host.reload()
        #expect(userOrder() == [screed, LedgerFixtures.wasteFactor, LedgerFixtures.mixed])

        // Deleted: gone from the columns, the table and the header menu.
        source.columns.removeAll { $0.id == screed }
        host.reload()
        #expect(host.controller.column(screed) == nil)
        #expect(!Self.visibleTableIDs(host.controller).contains(screed))
        #expect(!Self.showColumnsTitles(host.controller).contains("Floor Screed"))
    }

    @Test("S-075: an unchanged source changes no columns and keeps the user's arrangement")
    func unchangedSourceKeepsTheArrangement() {
        let source = LiveColumnSource(columns: LedgerFixtures.columns, rows: LedgerFixtures.rows)
        let host = LedgerTableHost(rowSource: source)
        host.controller.loadViewIfNeeded()
        host.controller.setColumn(.trade, visible: true)
        host.controller.moveColumn(.trade, to: 0)
        let arranged = host.controller.columns
        host.reload()
        host.reload()
        #expect(host.controller.columns == arranged)
    }

    // MARK: - S-080

    /// Every built-in the core publishes is visible in the projection, as `LedgerColumnSet
    /// .standard()` creates them.
    private static let publishedColumns: [LedgerColumn] = [
        LedgerColumn(id: .pageLabel, title: "Page", kind: .text, width: 60),
        LedgerColumn(id: .icon, title: "Type", kind: .text, width: 60),
        LedgerColumn(id: .label, title: "Label", kind: .text, width: 100, isEditable: true),
        LedgerColumn(id: .subject, title: "Subject", kind: .text, width: 160, isEditable: true),
        LedgerColumn(id: .comment, title: "Comment", kind: .text, width: 120, isEditable: true),
        LedgerColumn(id: .status, title: "Status", kind: .choice, width: 96, choices: LedgerFixtures.statusChoices),
        LedgerColumn(id: .trade, title: "Trade", kind: .text, width: 100),
        LedgerColumn(id: .planArea, title: "Plan Area", kind: .number, dimension: .area, width: 90,
                     alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m²"),
        LedgerColumn(id: .planLength, title: "Plan Length", kind: .number, dimension: .length, width: 90,
                     alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m"),
        LedgerColumn(id: .count, title: "Count", kind: .number, dimension: .count, width: 60,
                     alignment: .trailing, aggregate: .sum),
        LedgerColumn(id: .perimeter, title: "Perimeter", kind: .number, dimension: .length, width: 90,
                     alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m")
    ]

    private static let defaultVisible: [LedgerColumnID] = [
        .pageLabel, .icon, .label, .subject, .comment,
        LedgerDefaultColumns.valueColumnID, LedgerDefaultColumns.unitColumnID, .perimeter
    ]

    /// Old output: every column visible — Status, Trade, Plan Area, Plan Length and Count too —
    /// with Subject still first, Label still pinned and the widened column still wide.
    @Test("S-080: Reset Columns restores the default set, order, widths and pins, and clears the active layout")
    func resetRestoresTheDefault() {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: Self.publishedColumns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        #expect(controller.columns.filter(\.visible).map(\.id) == Self.defaultVisible)
        let defaults = controller.columns

        var store = LedgerColumnLayoutStore()
        store.save(controller.columns, name: "Mine")
        controller.layoutStore = store
        var persisted: [LedgerColumnLayoutStore] = []
        controller.onLayoutStoreChange = { persisted.append($0) }

        controller.setColumn(.status, visible: true)
        controller.setColumn(.trade, visible: true)
        controller.moveColumn(.subject, to: 0)
        controller.setColumn(.label, pinned: true)
        controller.setColumn(.comment, alignment: .trailing)
        controller.setColumns(controller.columns.map { column in
            var column = column
            if column.id == .icon { column.width = 300 }
            return column
        })
        #expect(controller.columns.filter(\.visible).count == 10)

        controller.resetColumns()
        #expect(controller.columns.filter(\.visible).map(\.id) == Self.defaultVisible)
        #expect(controller.columns == defaults, "order, widths, alignment and pins are the default again")
        let anyPinned = controller.columns.contains { $0.pinned }
        #expect(!anyPinned)
        #expect(Self.visibleTableIDs(controller) == Self.defaultVisible)
        #expect(controller.layoutStore.activeLayoutID == nil, "the menu no longer ticks a layout")
        #expect(persisted.last?.activeLayoutID == nil, "and the host persists that")
    }

    // MARK: - S-082

    /// Old output: the store was installed and the menu ticked "Estimating", while the table
    /// showed the default arrangement — Status hidden, Label shown.
    @Test("S-082: restoring the store reopens the ledger in its active layout")
    func restoredStoreAppliesTheActiveLayout() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: Self.publishedColumns)
        let author = LedgerTableController(rowSource: source)
        author.loadViewIfNeeded()
        author.setColumn(.status, visible: true)
        author.setColumn(.label, visible: false)
        author.moveColumn(.status, to: 0)
        var store = LedgerColumnLayoutStore()
        let savedLayout = store.save(author.columns, name: "Estimating")
        let saved = try #require(savedLayout)
        #expect(store.activeLayoutID == saved.id)

        // The next session: a fresh controller, the store restored before the view loads.
        let controller = LedgerTableController(rowSource: source)
        var persisted: [LedgerColumnLayoutStore] = []
        controller.onLayoutStoreChange = { persisted.append($0) }
        controller.restoreLayoutStore(store)
        controller.loadViewIfNeeded()
        #expect(controller.columns.filter(\.visible).map(\.id).first == .status)
        #expect(controller.column(.label)?.visible == false)
        #expect(Self.visibleTableIDs(controller).first == .status)
        #expect(controller.layoutStore.activeLayoutID == saved.id)
        #expect(persisted.isEmpty, "applying the stored layout changes nothing to persist")
        let layoutItems = controller.headerMenu.items.compactMap(\.submenu).flatMap(\.items)
        let estimating = try #require(layoutItems.first { item in item.title == "Estimating" })
        #expect(estimating.state == .on, "the menu ticks the layout the table is in")

        // An active layout the store no longer holds is cleared, not claimed.
        let orphan = LedgerColumnLayoutStore(layouts: store.layouts, activeLayoutID: UUID())
        let other = LedgerTableController(rowSource: source)
        other.onLayoutStoreChange = { persisted.append($0) }
        other.restoreLayoutStore(orphan)
        #expect(other.layoutStore.activeLayoutID == nil)
        #expect(persisted.last?.activeLayoutID == nil)
        #expect(other.columns.filter(\.visible).map(\.id) == Self.defaultVisible)
    }

    // MARK: - S-087

    /// Old output: the main table's order became [Plan Area, Subject, …] while `columns` said
    /// [Subject, Plan Area, …], so the pinned overlay covered Plan Area's slot and Subject showed
    /// a second time beside it; and nothing refused the drag.
    @Test("S-087: a column move across the pinned band is refused, and a programmatic one is put back")
    func reorderStaysInsideItsBand() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        controller.setColumn(.subject, pinned: true)
        let table = controller.mainTableViewForTesting
        #expect(Self.visibleTableIDs(controller).first == .subject)
        let pinnedCount = controller.columns.filter { $0.visible && $0.pinned }.count
        #expect(pinnedCount == 1)

        // What AppKit asks while a person drags.
        #expect(controller.tableView(table, shouldReorderColumn: 2, toColumn: -1), "a drag may begin")
        #expect(!controller.tableView(table, shouldReorderColumn: 2, toColumn: 0), "an unpinned column cannot land in the pinned band")
        #expect(!controller.tableView(table, shouldReorderColumn: 0, toColumn: 2), "the pinned column cannot leave it")
        #expect(controller.tableView(table, shouldReorderColumn: 2, toColumn: 3), "a move inside the scrolling band is fine")
        #expect(!controller.tableView(controller.pinnedTableViewForTesting, shouldReorderColumn: 0, toColumn: 0))
        controller.setGrouping([.projectZone])
        #expect(controller.mode == .grouped)
        let outline = controller.outlineViewForTesting
        #expect(!controller.outlineView(outline, shouldReorderColumn: 2, toColumn: 0))
        #expect(controller.outlineView(outline, shouldReorderColumn: 2, toColumn: 3))
        controller.setGrouping([])

        // A programmatic move across the band: the table is put back in step with `columns`.
        table.moveColumn(2, toColumn: 0)
        #expect(Self.visibleTableIDs(controller) == controller.columns.filter(\.visible).map(\.id))
        #expect(Self.visibleTableIDs(controller).first == .subject)

        // A move inside the band still reorders.
        let before = Self.visibleTableIDs(controller)
        table.moveColumn(1, toColumn: 3)
        let after = Self.visibleTableIDs(controller)
        #expect(after != before)
        #expect(after == controller.columns.filter(\.visible).map(\.id))
    }

    // MARK: - S-076

    /// The same text typed into the preset editor's Assembly row
    /// (`ToolPresetAssembly.quantity`: `ZPDFDecimalParser.decimal(text, allowingExponent: true)`,
    /// in metres) and into Apply Assembly. Hand-derived values; `nil` is a refusal.
    static let parameterTable: [(text: String, value: Decimal?)] = [
        ("0,6", decimal("0.6")), ("0.6", decimal("0.6")), ("45,50", decimal("45.5")),
        ("45.50", decimal("45.5")), ("1 200", 1200), ("6e-1", decimal("0.6")),
        ("1,234.5", nil), ("1,200,300", nil), ("12abc", nil), ("0.6m", nil)
    ]

    /// Old output under en-US: "0,6" was 6 (the grouping comma skipped), so the stud formula
    /// FLOOR(10 / 0.6) + 1 = 17 became FLOOR(10 / 6) + 1 = 2; "45,50" was 4550.
    @Test("S-076: Apply Assembly reads a parameter exactly as the preset editor does, in every locale")
    func assemblyParameterMatchesThePresetEditor() async throws {
        for (text, value) in Self.parameterTable {
            #expect(LedgerAssemblyPanelModel.parameterValue(text) == value, "\(text)")
            #expect(ZPDFDecimalParser.decimal(text, allowingExponent: true) == value, "the preset row: \(text)")
        }
        for locale in [Self.english, Self.swedish, Self.german] {
            let presenter = MockLedgerPresenter()
            let model = LedgerAssemblyPanelModel(presenter: presenter, markupIDs: [UUID()], locale: locale)
            model.parameterTexts["Spacing"] = "0,6"
            #expect(model.canApply, "\(locale.identifier)")
            #expect(await model.apply())
            #expect(presenter.appliedAssemblies.last?.parameters["Spacing"]
                == DecimalQuantity(value: Self.decimal("0.6"), dimension: .length), "\(locale.identifier)")
        }
    }

    /// Old output: en-US read "0,6" as 6 and "45,50" as 4550; de-DE read "45.50" as 4550.
    @Test("S-076: a cell, Bulk Edit and the filter read typed numbers with the one grammar")
    func ledgerFieldsShareTheGrammar() {
        #expect(LedgerNumberParsing.decimal(from: "0,6") == Self.decimal("0.6"))
        #expect(LedgerNumberParsing.decimal(from: "45,50") == Self.decimal("45.5"))
        #expect(LedgerNumberParsing.decimal(from: "45.50") == Self.decimal("45.5"))
        #expect(LedgerNumberParsing.decimal(from: "1 234,5") == Self.decimal("1234.5"))
        #expect(LedgerNumberParsing.decimal(from: "1,234") == Self.decimal("1.234"), "a single comma is the decimal mark")
        #expect(LedgerNumberParsing.decimal(from: "1e5") == nil, "no exponent in a ledger cell")
        #expect(LedgerBulkEditModel.parseDecimal("45,50") == Self.decimal("45.5"))

        let waste = LedgerFixtures.columns.first { $0.id == LedgerFixtures.wasteFactor }!
        for locale in [Self.english, Self.german] {
            let model = LedgerBulkEditModel(rows: Array(LedgerFixtures.rows.prefix(2)), columns: LedgerFixtures.columns)
            model.setNumberText("0,6", for: waste, locale: locale)
            #expect(model.edit(for: waste.id) == .number(Self.decimal("0.6")), "\(locale.identifier)")
            model.setNumberText("45.50", for: waste, locale: locale)
            #expect(model.edit(for: waste.id) == .number(Self.decimal("45.5")), "\(locale.identifier)")
        }
    }

    // MARK: - S-081

    /// Old output: `invalidInputs == ["Depth"]` and `canApply == false`, with no hint on screen —
    /// the "Not a number" line is drawn only under the chosen recipe's own inputs.
    @Test("S-081: text left in a field of a recipe chosen earlier does not disable Apply")
    func staleFieldDoesNotBlockApply() {
        let model = LedgerAssemblyPanelModel(presenter: MockLedgerPresenter(), markupIDs: [UUID()])
        model.parameterTexts["Depth"] = "0.6m"     // typed while another recipe was chosen
        model.parameterTexts["Spacing"] = "0.6"
        #expect(model.invalidInputs.isEmpty)
        #expect(model.canApply)
        model.parameterTexts["Spacing"] = "0.6m"
        #expect(model.invalidInputs == ["Spacing"], "the chosen recipe's own field is still checked")
        #expect(!model.canApply)
    }

    // MARK: - S-084

    private static let unitCost = LedgerColumn(
        id: .custom("unitCost"), title: "Unit Cost", kind: .currency, dimension: .currency("SEK"),
        width: 90, alignment: .trailing, isEditable: true, displayUnitSymbol: "SEK", holdsUserValues: true
    )
    private static let depth = LedgerColumn(
        id: .custom("depth"), title: "Depth", kind: .number, dimension: .length,
        width: 90, alignment: .trailing, isEditable: true, displayUnitSymbol: "mm", holdsUserValues: true
    )

    /// Old output: the field showed "45,50 kr"; changing one digit sent "46,50 kr" to the parser,
    /// which refused the currency symbol, so the column was marked "Not a number" and nothing
    /// was staged.
    @Test("S-084: a shared money or length value opens as a bare number that edits in place")
    func sharedMoneyValueEditsInPlace() {
        var rows = Array(LedgerFixtures.rows.prefix(2))
        for index in rows.indices {
            rows[index].values[Self.unitCost.id] = .currency(amount: Self.decimal("45.50"), code: "SEK")
            rows[index].displayValues[Self.unitCost.id] = "45,50 kr"
            rows[index].values[Self.depth.id] = .quantity(.metres(Self.decimal("0.5")))
            rows[index].displayValues[Self.depth.id] = "500 mm"
        }
        let columns = LedgerFixtures.columns + [Self.unitCost, Self.depth]
        let model = LedgerBulkEditModel(rows: rows, columns: columns)

        #expect(model.numberText(for: Self.unitCost, locale: Self.english) == "45.5")
        #expect(model.numberText(for: Self.unitCost, locale: Self.swedish) == "45,5")
        #expect(model.numberText(for: Self.depth, locale: Self.english) == "500", "in the unit the column displays")

        // The focus echo of the shown text stages nothing (R-121).
        model.setNumberText("45.5", for: Self.unitCost, locale: Self.english)
        #expect(model.edit(for: Self.unitCost.id) == nil)

        model.setNumberText("46.5", for: Self.unitCost, locale: Self.english)
        #expect(model.edit(for: Self.unitCost.id) == .currency(amount: Self.decimal("46.5"), code: "SEK"))
        #expect(!model.invalidNumberColumns.contains(Self.unitCost.id))

        model.setNumberText("450", for: Self.depth, locale: Self.english)
        #expect(model.edit(for: Self.depth.id) == .quantity(.metres(Self.decimal("0.45"))))
        #expect(model.invalidNumberColumns.isEmpty)

        // The inline cell editor opens with the same text (one conversion for both).
        let controller = LedgerTableController(rowSource: LedgerArrayRowSource(rows: rows, columns: columns))
        controller.locale = Self.swedish
        #expect(controller.inlineEditingText(row: rows[0], column: Self.unitCost) == "45,5")
        #expect(controller.inlineEditingText(row: rows[0], column: Self.depth) == "500")
    }

    // MARK: - S-078

    /// Old output: the builder was given `arranged(visibleColumns).filter(\.visible)`, so both
    /// chip rules were reported as `unknownColumnNotApplied` ("status", "planArea") while the
    /// presenter applied them, and neither column could be picked for a rule.
    @Test("S-078: the Filter panel is given every column, so chip rules are not reported as unknown")
    func filterPanelNamesEveryColumn() {
        let chipRules = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .status, comparison: .isAnyOf, operand: .choices(["approved"])),
            LedgerFilterRule(id: UUID(), column: .planArea, comparison: .isNotEmpty, operand: .none),
            LedgerFilterRule(id: UUID(), column: .count, comparison: .isNotEmpty, operand: .none)
        ])
        let onScreenOnly = LedgerDefaultColumns.arranged(Self.publishedColumns).filter(\.visible)
        #expect(LedgerFilterDiagnostic.unappliedRules(in: chipRules, columns: onScreenOnly).count == 3, "the old input")

        let filterable = LedgerFilterBuilder.filterableColumns(Self.publishedColumns)
        #expect(LedgerFilterDiagnostic.unappliedRules(in: chipRules, columns: filterable).isEmpty)
        let offered = LedgerFilterRuleRow.selectableColumns(filterable, current: .status).map(\.id)
        #expect(offered.contains(.status) && offered.contains(.planArea) && offered.contains(.trade))
        #expect(!offered.contains(LedgerDefaultColumns.valueColumnID) && !offered.contains(LedgerDefaultColumns.unitColumnID))
        #expect(LedgerFilterRuleRow.defaultColumn(in: filterable)?.id == .pageLabel, "a new rule still starts on a visible column")

        let unknown = LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .custom("gone"), comparison: .isNotEmpty, operand: .none)
        ])
        #expect(LedgerFilterDiagnostic.unappliedRules(in: unknown, columns: filterable)
            == [.unknownColumnNotApplied(columnName: "custom.gone")], "a column the presenter lacks is still reported")
    }

    // MARK: - S-079

    @Test("S-079: a money subtotal heading rounds a .xx5 amount half away from zero")
    func moneyHeadingRoundsAwayFromZero() {
        // 17 × 45.125 = 767.125 → 767.13; the cell text now agrees (ZPDFAppCore
        // Iter2LedgerMoneyRoundingTests), and this is the heading side of the comparison.
        let total = DecimalQuantity.money(Decimal(17) * Self.decimal("45.125"), code: "SEK")
        #expect(LedgerNumberFormatting.displayParts(total, rounding: .twoDigits, locale: Self.swedish).numberText == "767,13")
        let negative = DecimalQuantity.money(Self.decimal("-30.625"), code: "SEK")
        #expect(LedgerNumberFormatting.displayParts(negative, rounding: .twoDigits, locale: Self.english).numberText == "-30.63")
    }
}
