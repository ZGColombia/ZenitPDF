import AppKit

/// What the ledger's row context menu can ask the host to do (NL-UX-09).
public enum LedgerRowMenuAction: Hashable, Sendable {
    case zoomTo
    case selectOnCanvas
    case setStatus(String)
    case toggleLock
    case explain
    case delete
}

/// The host's side of the row menu: the status choices to offer, whether the rows are locked
/// (which names the lock item and disables Delete and Change Status), and where a choice goes.
@MainActor
public struct LedgerRowMenuConfiguration {
    public var statuses: [(value: String, title: String)]
    public var isLocked: @MainActor (Set<UUID>) -> Bool
    public var canExplain: Bool
    public var perform: @MainActor (LedgerRowMenuAction, Set<UUID>) -> Void

    public init(
        statuses: [(value: String, title: String)],
        isLocked: @escaping @MainActor (Set<UUID>) -> Bool = { _ in false },
        canExplain: Bool = false,
        perform: @escaping @MainActor (LedgerRowMenuAction, Set<UUID>) -> Void
    ) {
        self.statuses = statuses
        self.isLocked = isLocked
        self.canExplain = canExplain
        self.perform = perform
    }
}

/// One menu item that runs a closure: no selector plumbing, and the closure holds the rows the
/// menu was opened on, so a selection change while the menu is up cannot retarget it.
@MainActor
final class LedgerRowMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, enabled: Bool = true, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { run() }
}

extension LedgerTableController: NSMenuDelegate {

    /// Gives every row-bearing table the row menu, rebuilt on each right-click.
    func installRowMenus() {
        for table in [tableViewForMenu, outlineViewForMenu, pinnedTableViewForMenu] {
            if rowMenu == nil {
                table.menu = nil
            } else {
                let menu = NSMenu(title: NSLocalizedString("Row", comment: "Ledger row context menu title"))
                menu.autoenablesItems = false
                menu.delegate = self
                table.menu = menu
            }
        }
    }

    /// The rows a right-click on visual row `row` acts on: the whole selection when the row is
    /// part of it (the Mac convention), otherwise that row alone — which it also selects.
    func rowsForContextClick(atVisualRow row: Int) -> Set<UUID> {
        guard row >= 0 else { return [] }
        // A group heading acts on every row of the group — so "Explain…" on a subtotal shows the
        // rows behind it — and selects them, as a right-click on a row selects it.
        if case let .group(path) = content(atVisualRow: row) {
            let ids = rowIDs(inGroup: path)
            guard !ids.isEmpty else { return [] }
            applyExternalSelection(ids, scrollToFirst: false)
            delegate?.ledgerTable(self, didChangeSelection: ids)
            return ids
        }
        guard case let .row(position) = content(atVisualRow: row),
              let sourceIndex = plan.sourceIndex(displayPosition: position),
              let id = rowSource.ledgerRowID(at: sourceIndex)
        else { return [] }
        if selectedRowIDs.contains(id) { return selectedRowIDs }
        applyExternalSelection([id], scrollToFirst: false)
        delegate?.ledgerTable(self, didChangeSelection: [id])
        return [id]
    }

    /// Every data row under the group at `path`, at any depth.
    func rowIDs(inGroup path: String) -> Set<UUID> {
        func find(_ slices: [LedgerGroupSlice]) -> LedgerGroupSlice? {
            for slice in slices {
                if slice.path == path { return slice }
                if let hit = find(slice.children) { return hit }
            }
            return nil
        }
        guard let slice = find(plan.groups) else { return [] }
        var ids: Set<UUID> = []
        for position in slice.rowRange {
            if let source = plan.sourceIndex(displayPosition: position), let id = rowSource.ledgerRowID(at: source) {
                ids.insert(id)
            }
        }
        return ids
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === headerMenu {
            LedgerColumnMenuBuilder.populate(menu, for: self)
            return
        }
        menu.removeAllItems()
        let table = [tableViewForMenu, outlineViewForMenu, pinnedTableViewForMenu].first { $0.menu === menu }
        guard let rowMenu, let table else { return }
        let rows = rowsForContextClick(atVisualRow: table.clickedRow)
        guard !rows.isEmpty else { return }
        populateRowMenu(menu, rows: rows, configuration: rowMenu)
    }

    /// Fills `menu` for `rows`. Separate from the right-click so a test can read the items.
    func populateRowMenu(_ menu: NSMenu, rows: Set<UUID>, configuration: LedgerRowMenuConfiguration) {
        let locked = configuration.isLocked(rows)
        let perform = configuration.perform
        func item(_ title: String, enabled: Bool = true, _ action: LedgerRowMenuAction) -> NSMenuItem {
            LedgerRowMenuItem(title: title, enabled: enabled) { perform(action, rows) }
        }
        menu.addItem(item(NSLocalizedString("Zoom To", comment: "Ledger row menu: zoom the canvas to the row's markup"), .zoomTo))
        menu.addItem(item(NSLocalizedString("Select on Canvas", comment: "Ledger row menu: select the row's markups on the canvas"), .selectOnCanvas))
        menu.addItem(.separator())
        let status = NSMenuItem(title: NSLocalizedString("Change Status", comment: "Ledger row menu: status submenu"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: status.title)
        submenu.autoenablesItems = false
        for choice in configuration.statuses {
            submenu.addItem(item(choice.title, enabled: !locked, .setStatus(choice.value)))
        }
        status.submenu = submenu
        status.isEnabled = !locked && !configuration.statuses.isEmpty
        menu.addItem(status)
        menu.addItem(item(
            locked
                ? NSLocalizedString("Unlock", comment: "Ledger row menu: unlock the row's markups")
                : NSLocalizedString("Lock", comment: "Ledger row menu: lock the row's markups"),
            .toggleLock
        ))
        if configuration.canExplain {
            menu.addItem(.separator())
            menu.addItem(item(NSLocalizedString("Explain…", comment: "Ledger row menu: show the rows, formula and scale behind the selection"), .explain))
        }
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Delete", comment: "Ledger row menu: delete the row's markups"), enabled: !locked, .delete))
    }
}
