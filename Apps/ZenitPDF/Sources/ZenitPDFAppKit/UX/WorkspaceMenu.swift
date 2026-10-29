import AppKit
import ZPDFUIShell
import ZPDFUIWorkflows

/// View ▸ Workspaces (NL-UX-10): Save Current Workspace…, the saved workspaces with ⌃1–⌃4 on
/// the first four, and Delete Workspace ▸.
///
/// The workspaces live beside the window layout in the process defaults
/// (`ZenitProcessDefaults.layout`: the standard defaults in the shipping app, memory elsewhere),
/// so they survive relaunch and a test never writes the user's preferences.
@MainActor
final class ZenitWorkspaceMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {

    static let shared = ZenitWorkspaceMenu()

    /// The saved workspaces. Built lazily so a test's process-defaults override applies.
    private(set) lazy var model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZenitProcessDefaults.layout))

    /// Tags of the four ⌃-number rows; the row's slot is `tag - slotTagBase`.
    static let slotTagBase = 0x5A00
    /// Tag of the rows appended beyond the four shortcut rows.
    static let extraTag = 0x5A10
    static let identifier = "workspace.saveCurrent"

    /// The Workspaces row with its submenu.
    func makeMenuItem() -> NSMenuItem {
        let title = NSLocalizedString("Workspaces", comment: "View menu submenu of saved window arrangements")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        let save = NSMenuItem(
            title: NSLocalizedString("Save Current Workspace…", comment: "Workspaces menu: save the window arrangement under a name"),
            action: #selector(saveCurrent(_:)),
            keyEquivalent: ""
        )
        save.target = self
        menu.addItem(save)
        menu.addItem(.separator())
        for slot in 0..<WorkspacesModel.shortcutSlots {
            let row = NSMenuItem(title: Self.emptySlotTitle(slot), action: #selector(recall(_:)), keyEquivalent: "\(slot + 1)")
            row.keyEquivalentModifierMask = [.control]
            row.target = self
            row.tag = Self.slotTagBase + slot
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(
            title: NSLocalizedString("Delete Workspace", comment: "Workspaces menu: submenu of workspaces to delete"),
            action: nil,
            keyEquivalent: ""
        )
        delete.submenu = NSMenu(title: delete.title)
        menu.addItem(delete)
        // A workspace can follow a canvas mode.
        let follow = NSMenuItem(
            title: NSLocalizedString("Switch Automatically", comment: "Workspaces menu: submenu choosing a workspace per canvas mode"),
            action: nil,
            keyEquivalent: ""
        )
        follow.submenu = NSMenu(title: follow.title)
        follow.tag = Self.followTag
        menu.addItem(follow)
        item.submenu = menu
        return item
    }

    static let followTag = 0x5A20

    /// Rebuilds "Switch Automatically ▸": one submenu per canvas mode, None plus each workspace.
    func refreshFollow(_ menu: NSMenu) {
        guard let follow = menu.item(withTag: Self.followTag)?.submenu else { return }
        follow.removeAllItems()
        for mode in DismissibleCanvasMode.allCases {
            let row = NSMenuItem(
                title: String(format: NSLocalizedString("When %@ Starts", comment: "Workspaces menu: which workspace a canvas mode switches to; the placeholder is the mode's name"), mode.displayName),
                action: nil,
                keyEquivalent: ""
            )
            let choices = NSMenu(title: row.title)
            let current = model.workspace(following: mode)?.id
            let none = NSMenuItem(title: NSLocalizedString("Keep the Current Layout", comment: "Workspaces menu: a canvas mode switches no workspace"), action: #selector(chooseFollow(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = FollowChoice(mode: mode, workspaceID: nil)
            none.state = current == nil ? .on : .off
            choices.addItem(none)
            for workspace in model.workspaces {
                let choice = NSMenuItem(title: workspace.name, action: #selector(chooseFollow(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = FollowChoice(mode: mode, workspaceID: workspace.id)
                choice.state = current == workspace.id ? .on : .off
                choices.addItem(choice)
            }
            row.submenu = choices
            follow.addItem(row)
        }
    }

    final class FollowChoice: NSObject {
        let mode: DismissibleCanvasMode
        let workspaceID: UUID?
        init(mode: DismissibleCanvasMode, workspaceID: UUID?) {
            self.mode = mode
            self.workspaceID = workspaceID
        }
    }

    @objc func chooseFollow(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? FollowChoice else { return }
        if let id = choice.workspaceID {
            model.setFollowsMode(choice.mode, for: id)
        } else if let current = model.workspace(following: choice.mode) {
            model.setFollowsMode(nil, for: current.id)
        }
    }

    /// One follower per window shell (C-07): each window has canvas modes of its own, so a
    /// second window on a document follows its own modes. Held with its shell weakly, so a shell
    /// allocated later at a freed one's address is followed afresh.
    private static var followers: [ObjectIdentifier: (shell: UndoToastFeed.WeakShell, follower: WorkspaceModeFollower)] = [:]

    /// Starts following canvas modes for one window of a document.
    func attachFollower(shell: ProjectShellEnvironment) {
        Self.followers = Self.followers.filter { $0.value.shell.shell != nil }
        let key = ObjectIdentifier(shell)
        guard Self.followers[key]?.shell.shell !== shell else { return }
        Self.followers[key] = (UndoToastFeed.WeakShell(shell: shell), WorkspaceModeFollower(environment: shell, model: model))
    }

    /// Stops following a window that closed.
    static func detachFollower(shell: ProjectShellEnvironment) {
        followers[ObjectIdentifier(shell)] = nil
    }

    /// The follower of a window's shell. Test affordance.
    static func follower(for shell: ProjectShellEnvironment) -> WorkspaceModeFollower? {
        guard let entry = followers[ObjectIdentifier(shell)], entry.shell.shell === shell else { return nil }
        return entry.follower
    }

    static func emptySlotTitle(_ slot: Int) -> String {
        String(format: NSLocalizedString("Workspace %ld (empty)", comment: "Workspaces menu row with nothing saved in that slot"), slot + 1)
    }

    // MARK: Menu upkeep

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(menu)
    }

    /// Titles the slot rows, appends workspaces beyond the fourth, and rebuilds Delete ▸.
    func refresh(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.extraTag { menu.removeItem(item) }
        for slot in 0..<WorkspacesModel.shortcutSlots {
            guard let row = menu.item(withTag: Self.slotTagBase + slot) else { continue }
            row.title = model.workspace(inSlot: slot)?.name ?? Self.emptySlotTitle(slot)
        }
        if model.workspaces.count > WorkspacesModel.shortcutSlots,
           let lastSlot = menu.item(withTag: Self.slotTagBase + WorkspacesModel.shortcutSlots - 1) {
            var index = menu.index(of: lastSlot) + 1
            for slot in WorkspacesModel.shortcutSlots..<model.workspaces.count {
                let row = NSMenuItem(title: model.workspaces[slot].name, action: #selector(recall(_:)), keyEquivalent: "")
                row.target = self
                row.tag = Self.extraTag
                row.representedObject = slot
                menu.insertItem(row, at: index)
                index += 1
            }
        }
        refreshFollow(menu)
        if let delete = menu.items.first(where: { $0.submenu != nil && $0.tag != Self.followTag })?.submenu {
            delete.removeAllItems()
            for workspace in model.workspaces {
                let row = NSMenuItem(title: workspace.name, action: #selector(deleteWorkspace(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = workspace.id
                delete.addItem(row)
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveCurrent(_:)) {
            return Self.frontController()?.activeDocument?.shell != nil
        }
        if item.action == #selector(recall(_:)) {
            let slot = Self.slot(of: item)
            if item.tag != Self.extraTag {
                item.title = model.workspace(inSlot: slot)?.name ?? Self.emptySlotTitle(slot)
            }
            return model.workspace(inSlot: slot) != nil && Self.frontController()?.activeDocument?.shell != nil
        }
        return true
    }

    static func slot(of item: NSMenuItem) -> Int {
        item.tag == extraTag ? (item.representedObject as? Int ?? -1) : item.tag - slotTagBase
    }

    /// The project window in front.
    static func frontController() -> ProjectWindowController? {
        NSApplication.shared.keyWindow?.windowController as? ProjectWindowController
            ?? NSApplication.shared.mainWindow?.windowController as? ProjectWindowController
    }

    // MARK: Actions

    @objc func saveCurrent(_ sender: Any?) {
        guard let controller = Self.frontController() else { return }
        promptAndSave(in: controller)
    }

    /// Asks for a name (suggesting "Workspace n") and saves the front window's arrangement.
    func promptAndSave(in controller: ProjectWindowController) {
        guard let shell = controller.activeDocument?.shell, let layout = shell.currentWorkspaceLayout() else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Save Workspace", comment: "Save workspace prompt title")
        alert.informativeText = NSLocalizedString(
            "The panes, their sizes and the pages they show are saved under this name. A name already used is replaced.",
            comment: "Save workspace prompt detail"
        )
        let field = NSTextField(string: model.suggestedName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.setAccessibilityLabel(NSLocalizedString("Workspace name", comment: "Accessibility label of the workspace name field"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Save workspace prompt: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Sheet dismissal by Escape"))
        ZenitModalPresenter.runAlert(alert, identifier: Self.identifier, sheetedOn: controller.window, answerWithoutAUser: .dismissed) { [weak self] answer in
            guard let self, answer.buttonIndex == 0 else { return }
            self.model.save(name: field.stringValue, layout: layout)
        }
    }

    @objc func recall(_ sender: NSMenuItem) {
        guard let controller = Self.frontController() else { return }
        recall(slot: Self.slot(of: sender), in: controller)
    }

    /// Re-arranges a window to the workspace in a slot. Returns whether one was there.
    @discardableResult
    func recall(slot: Int, in controller: ProjectWindowController) -> Bool {
        guard let workspace = model.workspace(inSlot: slot), let shell = controller.activeDocument?.shell else { return false }
        return shell.applyWorkspace(workspace)
    }

    @objc func deleteWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.delete(id: id)
    }
}
