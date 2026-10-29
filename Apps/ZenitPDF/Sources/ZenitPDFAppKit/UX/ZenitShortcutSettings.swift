import AppKit
import SwiftUI
import ZPDFUIShell

/// Customisable shortcuts, the application half (NL-UX-11).
///
/// The shell owns the rules (`ZPDFCommandTable.validate`) and the settings model; this file
/// knows what only the application can: the chords its own commands and hand-built menu rows
/// hold, where the overrides live, and how to edit the menu bar once a shortcut changes.
@MainActor
enum ZenitShortcutSettings {

    /// The overrides store: the standard defaults in the shipping app, memory only in any
    /// other process (tests never write the user's preferences).
    static var store: ZPDFShortcutOverrideStore = ZenitModalPresenter.canPresentModally
        ? ZPDFShortcutOverrideStore()
        : ZPDFShortcutOverrideStore(defaults: nil)

    /// Reads the stored overrides into ``ZPDFCommandTable/effective``. Launch calls it before
    /// the menu bar is built.
    static func installStoredOverrides() {
        ZPDFCommandTable.effective = ZPDFCommandTable.standard.applying(store.overrides)
    }

    /// Chords the application holds outside the shell's table, keyed by chord, with the
    /// holder's title: every application command's key equivalents and the hand-built rows.
    static var reservedChords: [String: String] {
        var chords: [String: String] = [:]
        func chord(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
            ZPDFKeyBinding(key: key.lowercased(), modifiers: ZPDFModifierFlags(modifiers), displayKey: key, spokenKey: key).chord
        }
        for spec in ZenitAppCommandTable.specs {
            for equivalent in [spec.keyEquivalent].compactMap({ $0 }) + spec.hiddenKeyEquivalents {
                chords[chord(equivalent.key, equivalent.modifiers)] = spec.title
            }
        }
        chords[chord("f", [.command, .control])] = NSLocalizedString("Enter Full Screen", comment: "View menu command")
        chords[chord("h", [.command, .option])] = NSLocalizedString("Hide Others", comment: "Application menu item")
        // ⌘[ and ⌘] are the canvas's sheet history, taken before the menu bar sees them in every
        // project window (S-004). A command rebound to either was saved and then never fired.
        for equivalent in PDFCanvasViewController.navigationChords {
            chords[chord(equivalent.key, equivalent.modifiers)] = equivalent.key == "["
                ? NSLocalizedString("Go Back", comment: "Sheet history: the previous view (⌘[), named when a shortcut is refused")
                : NSLocalizedString("Go Forward", comment: "Sheet history: the next view (⌘]), named when a shortcut is refused")
        }
        return chords
    }

    /// Installs a changed table: the effective table, then the key equivalents of the menu bar
    /// already installed, edited in place.
    ///
    /// Never a rebuilt bar: AppKit inserts Open Recent, Duplicate, Rename…, Move To…, Share and
    /// Revert To into a document application's File menu once, at launch, and a replaced bar
    /// lost all of them after one rebound-and-restored shortcut (L-44).
    ///
    /// - Parameter installedBar: the bar to edit. The application's own in the shipping app; a
    ///   test process has none of its own, so it passes the bar it built.
    static func apply(_ table: ZPDFCommandTable, installedBar: NSMenu? = installedMenuBar) {
        let previous = ZPDFCommandTable.effective
        ZPDFCommandTable.effective = table
        guard let installedBar else { return }
        ZenitMenuBar.applyKeyEquivalents(of: table, replacing: previous, in: installedBar)
    }

    /// The menu bar a shortcut change edits: the application's, in the shipping app only.
    static var installedMenuBar: NSMenu? {
        ZenitModalPresenter.canPresentModally ? NSApplication.shared.mainMenu : nil
    }

    /// A settings model wired to the store and to ``apply(_:)``.
    static func makeModel() -> ShortcutSettingsModel {
        let model = ShortcutSettingsModel(store: store, reservedChords: reservedChords)
        model.onApply = { apply($0) }
        return model
    }
}

/// Help ▸ Customize Keyboard Shortcuts…, and the button in Settings.
@MainActor
final class ZenitShortcutSettingsWindowController: NSWindowController {

    static let shared = ZenitShortcutSettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = NSLocalizedString("Keyboard Shortcuts", comment: "Shortcut settings window title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc func showShortcutSettings(_ sender: Any?) {
        guard ZenitModalPresenter.canPresentModally else { return }
        window?.contentViewController = NSHostingController(rootView: ShortcutSettingsView(model: ZenitShortcutSettings.makeModel()))
        window?.center()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
