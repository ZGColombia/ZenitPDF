import AppKit
import ZPDFAppCore
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Tools ▸ Fill Form Fields… (NL-PDF-17).
///
/// The drawing's own form fields — an RFI, a transmittal, a daily report — listed with a native
/// control each (text field, check box, pop-up), filled, and written to a **new file** with
/// appearances generated, optionally with the fields burned into the pages (qpdf, in the repair
/// service, as Optimize or Protect a Copy does). The drawing itself is never written; field
/// values are never part of the ledger. An XFA form is refused with the reason.
@MainActor
enum FormFill {

    static let sheetIdentifier = "forms.fillSheet"
    static let panelIdentifier = "forms.savePanel"
    static let refusalIdentifier = "forms.refused"
    static let resultNoteID = UUID(uuidString: "1D5C7B38-2E9A-4F61-8B04-3C6A9E7D5F12")!

    /// Writes the filled copy; `flatten` burns the fields in. The half of the command worth
    /// asserting.
    static func write(
        source: URL,
        password: String?,
        values: [String: PDFFormFields.Value],
        flatten: Bool,
        to output: URL
    ) async throws -> Int {
        // Both branches: the burned-in copy is written from a temporary filled file, so the
        // flattening writer's own guard never sees the drawing (R-103).
        try StagedFileReplacement.refuseOverwriting([source], with: output, refusal: PDFFormFields.Refusal.destinationIsSource)
        guard flatten else {
            return try await Task.detached(priority: .userInitiated) {
                try PDFFormFields.fill(source: source, password: password, values: values, to: output)
            }.value
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let filled = folder.appendingPathComponent("filled.pdf")
        let changed = try await Task.detached(priority: .userInitiated) {
            try PDFFormFields.fill(source: source, password: password, values: values, to: filled)
        }.value
        _ = try await DocumentCopyTransform.run(
            source: filled, password: nil, output: output,
            choices: .init(reducesSize: false, downsamplesPictures: false, flattensDrawingAnnotations: true)
        )
        return changed
    }

    static func resultNote(changed: Int, flattened: Bool, output: URL, now: Date = Date()) -> AppWarning {
        AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(format: NSLocalizedString("Filled form saved as “%@”", comment: "Form fill result headline; the file name"), output.lastPathComponent),
            message: (flattened
                ? String(format: NSLocalizedString("%lld fields filled and burned into the pages; the copy has no fields left to change.", comment: "Form fill result: flattened; count"), Int64(changed))
                : String(format: NSLocalizedString("%lld fields filled; the copy can still be edited in any PDF reader.", comment: "Form fill result; count"), Int64(changed)))
                + " " + NSLocalizedString("The drawing itself was not changed.", comment: "Form fill result: original untouched"),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// A field's name as its label: the last part of a fully qualified name, its words split
    /// at underscores, hyphens and lower-to-upper case changes, and the first letter capitalised
    /// — "project" is "Project", "form.approvedBy" is "Approved by", "RFI_no" is "RFI no". An
    /// all-capitals word keeps its capitals. L-65: the sheet showed the internal names in lower
    /// case ("project", "inspector", "date", "approved").
    static func displayLabel(forFieldNamed name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in last {
            if character == "_" || character == "-" || character.isWhitespace {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                if !current.isEmpty { words.append(current) }
                current = String(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return name }
        let shaped = words.enumerated().map { index, word -> String in
            let isAcronym = word.count > 1 && word == word.uppercased() && word != word.lowercased()
            if isAcronym { return word }
            if index == 0 { return word.prefix(1).uppercased() + word.dropFirst().lowercased() }
            return word.lowercased()
        }
        return shaped.joined(separator: " ")
    }

    /// Tools ▸ Fill Form Fields….
    static func present(document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let drawing = document.drawing else { return }
        let fields: [PDFFormFields.Field]
        do {
            fields = try PDFFormFields.fields(ofFileAt: drawing.url, password: document.drawingPassword)
            guard !fields.isEmpty else { throw PDFFormFields.Refusal.noFields }
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("This drawing's form cannot be filled here.", comment: "Form fill refusal title")
            alert.informativeText = (error as? PDFFormFields.Refusal)?.description ?? error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismissal"))
            ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window) { _ in }
            return
        }
        let controller = FormFillController(fields: fields)
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = NSLocalizedString("Fill Form Fields", comment: "Form fill sheet title")
        controller.onCancel = { [weak sheet, weak window] in
            if let sheet { window?.endSheet(sheet) }
        }
        controller.onSave = { [weak sheet, weak window] values, flatten in
            if let sheet { window?.endSheet(sheet) }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent + " — "
                + NSLocalizedString("Filled", comment: "Filled form file-name suffix") + ".pdf"
            ZenitModalPresenter.runSavePanel(panel, identifier: panelIdentifier, sheetedOn: window) { answer in
                guard let url = answer.firstURL else { return }
                Task { @MainActor in
                    do {
                        // Nothing the document is made of, not only the drawing (V-021).
                        try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
                        let changed = try await write(source: drawing.url, password: document.drawingPassword, values: values, flatten: flatten, to: url)
                        document.core?.document.post(resultNote(changed: changed, flattened: flatten, output: url))
                        ExportCompletion.remember(url, document: document)
                    } catch {
                        ZenitErrorPresenter.present(error, in: window)
                    }
                }
            }
        }
        guard let window else { return }
        ZenitModalPresenter.beginSheet(sheet, on: window, identifier: sheetIdentifier) {}
    }
}

/// The fields, one native control each.
@MainActor
final class FormFillController: NSViewController {

    let fields: [PDFFormFields.Field]
    private(set) var controls: [String: NSControl] = [:]
    /// Each field's label, keyed by the field's name.
    private(set) var labels: [String: NSTextField] = [:]
    /// The sentence under the fields: where the values go. L-65: it was a wrapping label with
    /// no preferred width, so Auto Layout sized it for one line and it was cut — "…never enter
    /// the led…".
    let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString(
        "The values are written into a new PDF. The drawing itself is not changed, and field values never enter the ledger.",
        comment: "Form fill sheet explanation"
    ))
    /// The width of the sheet's content column, in points.
    static let contentWidth: CGFloat = 440
    let flattenBox = NSButton(checkboxWithTitle: NSLocalizedString("Burn the filled fields into the pages", comment: "Form fill option: flatten"), target: nil, action: nil)
    var onSave: ((_ values: [String: PDFFormFields.Value], _ flatten: Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(fields: [PDFFormFields.Field]) {
        self.fields = fields
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        var rows: [[NSView]] = []
        for field in fields {
            // L-65: the label is the field's name as a person reads it — "Inspector", not the
            // internal "inspector"; the internal name stays in the help tag.
            let label = NSTextField(labelWithString: FormFill.displayLabel(forFieldNamed: field.name))
            label.alignment = .right
            label.toolTip = field.name
            labels[field.name] = label
            let control: NSControl
            switch field.kind {
            case let .text(multiline):
                let text = NSTextField(string: field.value ?? "")
                text.usesSingleLineMode = !multiline
                text.cell?.wraps = multiline
                text.widthAnchor.constraint(equalToConstant: 260).isActive = true
                control = text
            case .checkBox:
                let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                box.state = field.isOn ? .on : .off
                control = box
            case let .radio(options), let .choice(options, _):
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItem(withTitle: NSLocalizedString("None", comment: "Form fill: no option chosen"))
                popup.addItems(withTitles: options)
                if let value = field.value, options.contains(value) { popup.selectItem(withTitle: value) }
                control = popup
            }
            control.isEnabled = !field.isReadOnly
            control.setAccessibilityLabel(FormFill.displayLabel(forFieldNamed: field.name))
            controls[field.name] = control
            rows.append([label, control])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        grid.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: NSLocalizedString("Save Filled Copy…", comment: "Form fill: save"), target: self, action: #selector(saveCopy))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: "Button: cancel"), target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        flattenBox.setAccessibilityLabel(flattenBox.title)
        let note = explanation
        note.textColor = .secondaryLabelColor
        // Sized for the wrapped text at the column's width, never squeezed to one line (L-65).
        note.preferredMaxLayoutWidth = Self.contentWidth
        note.maximumNumberOfLines = 0
        note.setContentCompressionResistancePriority(.required, for: .vertical)
        let buttons = NSStackView(views: [flattenBox, NSView(), cancel, save])
        let stack = NSStackView(views: [scroll, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scroll.heightAnchor.constraint(equalToConstant: min(420, CGFloat(max(1, fields.count)) * 30 + 12)),
            note.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            buttons.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        view = stack
    }

    /// What the controls say now.
    var values: [String: PDFFormFields.Value] {
        var out: [String: PDFFormFields.Value] = [:]
        for field in fields where !field.isReadOnly {
            guard let control = controls[field.name] else { continue }
            switch field.kind {
            case .text:
                out[field.name] = .text((control as? NSTextField)?.stringValue ?? "")
            case .checkBox:
                out[field.name] = .checked((control as? NSButton)?.state == .on)
            case .radio, .choice:
                guard let popup = control as? NSPopUpButton, popup.indexOfSelectedItem > 0, let title = popup.titleOfSelectedItem else { continue }
                out[field.name] = .option(title)
            }
        }
        return out
    }

    @objc func saveCopy() { onSave?(values, flattenBox.state == .on) }
    @objc func cancelSheet() { onCancel?() }
}
