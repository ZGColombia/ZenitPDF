import AppKit
import SwiftUI
import ZPDFUIShell

/// The command palette's window (NL-UX-05): a borderless panel over the project window,
/// opened by View ▸ Command Palette… (⇧⌘P).
///
/// The palette's model and view live in the shell; this file only hosts them and hands in the
/// application's own rows (its ``ZenitAppCommand``s, with their menu enablement) and the menu's
/// enablement of the shell's commands, so a row that is grey in the menu is grey here too.
extension ProjectWindowController {

    /// The palette model for a document, fully wired, without showing anything.
    func makeCommandPaletteModel(for document: ZenitPDFProjectDocument) -> CommandPaletteModel? {
        guard let shell = document.shell else { return nil }
        shell.commandPaletteValidator = { [weak self] command in
            guard let self else { return false }
            let probe = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
            probe.representedObject = command.rawValue
            return self.validateMenuItem(probe)
        }
        shell.commandPaletteExtraItems = { [weak self, weak document] in
            guard let self, let document else { return [] }
            var rows = self.applicationPaletteItems(for: document)
            if let core = document.core {
                rows += PaletteQuantities.rows(CommandPaletteHost.subjectTotals, core: core)
            }
            return rows
        }
        return CommandPaletteModel(recents: CommandPaletteHost.recents) { [weak shell] in
            shell?.commandPaletteItems() ?? []
        }
    }

    /// The application commands as palette rows, validated as their menu rows are.
    func applicationPaletteItems(for document: ZenitPDFProjectDocument) -> [CommandPaletteItem] {
        let state = ZenitAppCommandWindowState(controller: self)
        return ZenitAppCommandTable.specs.compactMap { spec in
            guard spec.command != .commandPalette else { return nil }
            let command = spec.command
            let menu = spec.slot.group?.displayName ?? NSLocalizedString("Window", comment: "Menu bar title")
            let shortcut = spec.keyEquivalent.map { ZPDFModifierFlags($0.modifiers).displayString + $0.key.uppercased() }
            return CommandPaletteItem(
                id: "app:\(command.rawValue)",
                title: ProjectShellEnvironment.paletteTitle(spec.title),
                detail: spec.slot.submenuTitle.map { "\(menu) ▸ \($0)" } ?? menu,
                category: .command,
                shortcut: shortcut,
                isEnabled: ZenitAppCommandTable.validate(command, item: nil, state: state),
                perform: { [weak self, weak document] in
                    guard let self else { return }
                    ZenitAppCommandTable.perform(command, controller: self, document: document)
                }
            )
        }
    }

    /// Shows the palette over this window. In a test process nothing is ordered on screen.
    func presentCommandPalette(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            // The subject subtotals first, so the palette opens knowing the quantities.
            if let core = document.core {
                CommandPaletteHost.subjectTotals = await PaletteQuantities.subjectTotals(core: core)
            }
            guard let window = self.window, let model = self.makeCommandPaletteModel(for: document) else { return }
            CommandPaletteHost.shared.present(model: model, over: window)
        }
    }
}

/// Owns the one palette panel.
@MainActor
final class CommandPaletteHost {
    static let shared = CommandPaletteHost()
    /// Recently used rows, in the standard defaults of the shipping app and in memory anywhere
    /// else, so a test never writes the user's preferences.
    static let recents: any CommandPaletteRecentsStore = ZenitModalPresenter.canPresentModally
        ? CommandPaletteDefaultsRecents()
        : CommandPaletteMemoryRecents()

    /// The subject subtotals read when the palette last opened.
    static var subjectTotals: [PaletteQuantities.SubjectTotal] = []

    private(set) var panel: CommandPalettePanel?
    private(set) var model: CommandPaletteModel?

    /// The panel's size and where it sits: centred on the window, a fifth of the way down.
    static let size = CGSize(width: 560, height: 420)
    static func frame(over parent: NSRect) -> NSRect {
        NSRect(
            x: parent.midX - size.width / 2,
            y: parent.maxY - parent.height / 5 - size.height,
            width: size.width,
            height: size.height
        )
    }

    func present(model: CommandPaletteModel, over parent: NSWindow) {
        dismiss()
        let panel = CommandPalettePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.setAccessibilityLabel(NSLocalizedString("Command Palette", comment: "Accessibility label of the command palette window"))
        panel.contentViewController = NSHostingController(rootView: CommandPaletteView(model: model)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
        model.onDismiss = { [weak self, weak parent] in
            self?.dismiss()
            parent?.makeKeyAndOrderFront(nil)
        }
        panel.onCancel = { [weak model] in model?.dismiss() }
        panel.onResignKey = { [weak self] in self?.dismiss() }
        self.panel = panel
        self.model = model
        guard ZenitModalPresenter.canPresentModally, parent.isVisible else { return }
        panel.setFrame(Self.frame(over: parent.frame), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        model = nil
        panel.onResignKey = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// A borderless panel that can take the keyboard, closes on Escape, and closes when it loses
/// the keyboard — a palette that lingers behind a click elsewhere is a stale one.
@MainActor
final class CommandPalettePanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?
    var onResignKey: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
