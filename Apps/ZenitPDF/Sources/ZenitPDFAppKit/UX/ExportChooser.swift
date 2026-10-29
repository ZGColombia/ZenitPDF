import AppKit
import ZPDFUIShell

/// The toolbar Export chip's list of every export (nl-ux).
///
/// The chip used to run the shell's `.export`, which this window services with the Quantity
/// Ledger export alone, so a person looking for the marked-up drawing behind a button labelled
/// "Export" was handed a spreadsheet dialogue. The chip now opens this list: the ledger, then
/// the four drawing exports and the snippet, each row the same command the File menu runs, with
/// the same enablement rule, title and tooltip — no second path to any export.
extension ProjectWindowController {

    /// One row of the chooser.
    struct ExportChooserRow {
        let title: String
        let toolTip: String?
        let isEnabled: Bool
        let run: @MainActor () -> Void
    }

    /// The application exports the chooser lists after the ledger, in File-menu order.
    static let exportChooserCommands: [ZenitAppCommand] = [
        .exportFlattenedPDF, .exportAnnotatedPDF, .exportCleanPDF, .exportLayeredPDF, .exportSnippet
    ]

    /// The rows for a document. `nil` entries are separators.
    func exportChooserRows(for document: ZenitPDFProjectDocument) -> [ExportChooserRow?] {
        var rows: [ExportChooserRow?] = []
        let hasLedgerRows = !(document.core?.ledger.isEmpty ?? true)
        rows.append(ExportChooserRow(
            title: NSLocalizedString("Quantity Ledger…", comment: "Export chooser row: export the Quantity Ledger"),
            toolTip: hasLedgerRows ? nil : NSLocalizedString(
                "The Quantity Ledger has no rows to export yet.",
                comment: "Export chooser: why the ledger row is off"
            ),
            isEnabled: hasLedgerRows,
            run: { [weak self, weak document] in
                guard let self, let document else { return }
                self.exportLedger(for: document)
            }
        ))
        rows.append(nil)
        let state = ZenitAppCommandWindowState(controller: self)
        for command in Self.exportChooserCommands {
            let spec = ZenitAppCommandTable.spec(for: command)
            if command == .exportSnippet { rows.append(nil) }
            rows.append(ExportChooserRow(
                title: spec.title,
                toolTip: spec.toolTip,
                isEnabled: ZenitAppCommandTable.validate(command, item: nil, state: state),
                run: { [weak self, weak document] in
                    guard let self else { return }
                    ZenitAppCommandTable.perform(command, controller: self, document: document)
                }
            ))
        }
        return rows
    }

    /// The chooser as a menu, built without showing it (tests read it; the chip pops it up).
    func makeExportChooserMenu(for document: ZenitPDFProjectDocument) -> NSMenu {
        let menu = NSMenu(title: NSLocalizedString("Export", comment: "Toolbar item"))
        menu.autoenablesItems = false
        for row in exportChooserRows(for: document) {
            guard let row else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: row.title, action: #selector(ExportChooserTarget.run(_:)), keyEquivalent: "")
            item.target = ExportChooserTarget.shared
            item.representedObject = ExportChooserTarget.Action(run: row.run)
            item.isEnabled = row.isEnabled
            item.toolTip = row.toolTip
            menu.addItem(item)
        }
        return menu
    }

    /// Pops the chooser up under the toolbar's Export chip — or under the More chip when the
    /// Export chip has moved into it — in this window.
    ///
    /// L-29: the chooser used to open at the mouse pointer, so pressed through
    /// accessibility it appeared in the middle of the canvas. Only when the band shows neither
    /// chip (the toolbar hidden) does it fall back to the pointer.
    func presentExportChooser(for document: ZenitPDFProjectDocument) {
        guard let window, let view = window.contentView else { return }
        let menu = makeExportChooserMenu(for: document)
        if let band = layoutController(for: document)?.topBand, band.popUpMenu(menu, under: .zenitExport) {
            return
        }
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}

/// The target of every chooser row: it runs the closure the row carries.
@MainActor
final class ExportChooserTarget: NSObject {
    static let shared = ExportChooserTarget()

    final class Action: NSObject {
        let run: @MainActor () -> Void
        init(run: @escaping @MainActor () -> Void) { self.run = run }
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }
}
