import AppKit
import ZPDFUIPresentation

/// Builds the ledger's header context menu.
///
/// Everything the menu offers is also reachable from the Columns panel and from the
/// keyboard, so the menu is a shortcut rather than the only path to a setting.
@MainActor
public enum LedgerColumnMenuBuilder {

    /// Builds the menu for a controller's current column set.
    public static func menu(for controller: LedgerTableController) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Columns", comment: "Ledger header context menu title"))
        menu.autoenablesItems = false
        populate(menu, for: controller)
        return menu
    }

    /// Replaces a menu's items with the ones for the controller's current state: columns,
    /// saved layouts and host hooks. The controller's shared header menu is refilled through
    /// this every time it opens and every time the layout store changes (R-125).
    public static func populate(_ menu: NSMenu, for controller: LedgerTableController) {
        menu.removeAllItems()

        let showHide = NSMenuItem(
            title: NSLocalizedString("Show Columns", comment: "Ledger header context menu section"),
            action: nil,
            keyEquivalent: ""
        )
        let showHideSubmenu = NSMenu()
        showHideSubmenu.autoenablesItems = false
        for column in controller.columns {
            let item = NSMenuItem(
                title: column.title,
                action: #selector(LedgerTableController.toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = column.id.rawValue
            item.state = column.visible ? .on : .off
            item.toolTip = column.accessibilityLabel
            showHideSubmenu.addItem(item)
        }
        showHide.submenu = showHideSubmenu
        menu.addItem(showHide)

        let pin = NSMenuItem(
            title: NSLocalizedString("Pin to Left", comment: "Ledger header context menu section"),
            action: nil,
            keyEquivalent: ""
        )
        let pinSubmenu = NSMenu()
        pinSubmenu.autoenablesItems = false
        for column in controller.columns where column.visible {
            let item = NSMenuItem(
                title: column.title,
                action: #selector(LedgerTableController.toggleColumnPinned(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = column.id.rawValue
            item.state = column.pinned ? .on : .off
            pinSubmenu.addItem(item)
        }
        pin.submenu = pinSubmenu
        menu.addItem(pin)

        let alignment = NSMenuItem(
            title: NSLocalizedString("Alignment", comment: "Ledger header context menu section"),
            action: nil,
            keyEquivalent: ""
        )
        let alignmentSubmenu = NSMenu()
        alignmentSubmenu.autoenablesItems = false
        for column in controller.columns where column.visible {
            let columnItem = NSMenuItem(title: column.title, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.autoenablesItems = false
            for option in LedgerColumnAlignment.allCases {
                let item = NSMenuItem(
                    title: title(for: option),
                    action: #selector(LedgerTableController.setColumnAlignmentFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                // Two separate strings, not "id|alignment": a column key may itself contain
                // a pipe, and splitting on the first one made the choice a no-op (BH-704).
                item.representedObject = [column.id.rawValue, option.rawValue]
                item.state = column.alignment == option ? .on : .off
                choices.addItem(item)
            }
            columnItem.submenu = choices
            alignmentSubmenu.addItem(columnItem)
        }
        alignment.submenu = alignmentSubmenu
        menu.addItem(alignment)

        // Auto-width (IM-200): one column, or every visible column at once.
        let sizeToFit = NSMenuItem(
            title: NSLocalizedString("Size Column to Fit", comment: "Ledger header context menu section"),
            action: nil,
            keyEquivalent: ""
        )
        let sizeSubmenu = NSMenu()
        sizeSubmenu.autoenablesItems = false
        for column in controller.columns where column.visible {
            let item = NSMenuItem(
                title: column.title,
                action: #selector(LedgerTableController.sizeColumnToFitFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = column.id.rawValue
            item.toolTip = column.accessibilityLabel
            sizeSubmenu.addItem(item)
        }
        sizeToFit.submenu = sizeSubmenu
        menu.addItem(sizeToFit)

        let sizeAll = NSMenuItem(
            title: NSLocalizedString("Size All Columns to Fit", comment: "Ledger header context menu action"),
            action: #selector(LedgerTableController.sizeAllColumnsToFitFromMenu(_:)),
            keyEquivalent: ""
        )
        sizeAll.target = controller
        menu.addItem(sizeAll)

        menu.addItem(.separator())

        let layouts = NSMenuItem(
            title: NSLocalizedString("Saved Layouts", comment: "Ledger header context menu section"),
            action: nil,
            keyEquivalent: ""
        )
        let layoutsSubmenu = NSMenu()
        layoutsSubmenu.autoenablesItems = false
        if controller.layoutStore.layouts.isEmpty {
            let empty = NSMenuItem(
                title: NSLocalizedString("No saved layouts", comment: "Ledger header context menu placeholder"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            layoutsSubmenu.addItem(empty)
        } else {
            for layout in controller.layoutStore.layouts {
                let item = NSMenuItem(
                    title: layout.name,
                    action: #selector(LedgerTableController.applyLayoutFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = layout.id.uuidString
                item.state = controller.layoutStore.activeLayoutID == layout.id ? .on : .off
                layoutsSubmenu.addItem(item)
            }
        }
        layoutsSubmenu.addItem(.separator())
        let save = NSMenuItem(
            title: NSLocalizedString("Save Layout…", comment: "Ledger header context menu action"),
            action: #selector(LedgerTableController.requestSaveLayout(_:)),
            keyEquivalent: ""
        )
        save.target = controller
        layoutsSubmenu.addItem(save)
        layouts.submenu = layoutsSubmenu
        menu.addItem(layouts)

        if controller.onManageColumnsRequested != nil {
            menu.addItem(.separator())
            let add = NSMenuItem(
                title: NSLocalizedString("Add Column…", comment: "Ledger header context menu action: open the Column Manager on a new column"),
                action: #selector(LedgerTableController.requestAddColumn(_:)),
                keyEquivalent: ""
            )
            add.target = controller
            menu.addItem(add)
            let manage = NSMenuItem(
                title: NSLocalizedString("Manage Columns…", comment: "Ledger header context menu action: open the Column Manager"),
                action: #selector(LedgerTableController.requestManageColumns(_:)),
                keyEquivalent: ""
            )
            manage.target = controller
            menu.addItem(manage)
        }

        let reset = NSMenuItem(
            title: NSLocalizedString("Reset Columns", comment: "Ledger header context menu action"),
            action: #selector(LedgerTableController.resetColumnsFromMenu(_:)),
            keyEquivalent: ""
        )
        reset.target = controller
        menu.addItem(reset)
    }

    /// A localized name for an alignment option.
    public static func title(for alignment: LedgerColumnAlignment) -> String {
        switch alignment {
        case .leading: return NSLocalizedString("Leading", comment: "Ledger column alignment")
        case .center: return NSLocalizedString("Centered", comment: "Ledger column alignment")
        case .trailing: return NSLocalizedString("Trailing", comment: "Ledger column alignment")
        }
    }
}

public extension LedgerTableController {

    /// Toggles a column's visibility from the header menu.
    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let columnID = LedgerColumnID(raw)
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        setColumn(columnID, visible: !column.visible)
    }

    /// Pins or unpins a column from the header menu.
    @objc func toggleColumnPinned(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let columnID = LedgerColumnID(raw)
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        setColumn(columnID, pinned: !column.pinned)
    }

    /// Sets a column's alignment from the header menu.
    @objc func setColumnAlignmentFromMenu(_ sender: NSMenuItem) {
        let columnRaw: String
        let alignmentRaw: String
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            columnRaw = pair[0]
            alignmentRaw = pair[1]
        } else if let raw = sender.representedObject as? String, let separator = raw.lastIndex(of: "|") {
            // The older encoding, split at the *last* pipe: the alignment never contains one.
            columnRaw = String(raw[..<separator])
            alignmentRaw = String(raw[raw.index(after: separator)...])
        } else {
            return
        }
        guard let alignment = LedgerColumnAlignment(rawValue: alignmentRaw) else { return }
        setColumn(LedgerColumnID(columnRaw), alignment: alignment)
    }

    /// Applies a saved layout from the header menu and makes it the active one.
    ///
    /// The store's active layout — the menu's check mark and the "reopen in this layout"
    /// preference — used to stay on whichever layout was saved last (BH-705).
    @objc func applyLayoutFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let layout = layoutStore.layout(id: id) else { return }
        layoutStore.activeLayoutID = id
        apply(layout: layout)
        onLayoutStoreChange?(layoutStore)
    }

    /// Sizes one column to its content from the header menu.
    @objc func sizeColumnToFitFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        sizeColumnToFit(LedgerColumnID(raw))
    }

    /// Sizes every visible column to its content from the header menu.
    @objc func sizeAllColumnsToFitFromMenu(_ sender: NSMenuItem) {
        sizeAllColumnsToFit()
    }

    /// Asks the host to present the "name this layout" sheet.
    @objc func requestSaveLayout(_ sender: NSMenuItem) {
        onSaveLayoutRequested?()
    }

    /// Asks the host to open the Column Manager on a new column (NL-QTY-02).
    @objc func requestAddColumn(_ sender: NSMenuItem) {
        onManageColumnsRequested?(true)
    }

    /// Asks the host to open the Column Manager (NL-QTY-02).
    @objc func requestManageColumns(_ sender: NSMenuItem) {
        onManageColumnsRequested?(false)
    }

    /// Restores the default arrangement from the header menu (``resetColumns()``).
    @objc func resetColumnsFromMenu(_ sender: NSMenuItem) {
        resetColumns()
    }
}
