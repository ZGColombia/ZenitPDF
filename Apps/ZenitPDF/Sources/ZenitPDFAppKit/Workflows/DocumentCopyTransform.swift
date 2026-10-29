import AppKit
import Foundation
import ZPDFAppCore
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFUIPresentation

/// File ▸ Export Drawing ▸ Optimize or Protect a Copy… (NL-PDF-08, NL-PDF-09).
///
/// The drawing's own file, made smaller, cleaned of what makes a PDF act on its own, with the
/// drawing's own annotations burned in, and/or locked with a password — always as a **new file**,
/// written by the vendored qpdf inside the sandboxed repair service, never inside this process
/// and never over the original.
///
/// Pictures painted above a chosen resolution are resampled inside the same service (NL-PDF-08):
/// decoded and re-encoded with ImageIO, JPEG pictures staying JPEG and lossless ones lossless,
/// and the copy is refused unless its linework matches the original page for page. JBIG2, CCITT
/// and masked pictures are never touched.
@MainActor
enum DocumentCopyTransform {

    static let panelIdentifier = "drawing.optimizeCopyPanel"
    static let resultNoteID = UUID(uuidString: "9C3E1B52-7A4D-4F18-B6E2-0D5A8C9F3E71")!

    /// What the person ticked in the save panel's accessory.
    struct Choices: Equatable, Sendable {
        var reducesSize = true
        /// Resample pictures painted above ``pictureDPI`` (only with ``reducesSize``).
        var downsamplesPictures = true
        var pictureDPI = 150
        var removesHiddenContent = false
        var flattensDrawingAnnotations = false
        var protects = false
        var openPassword = ""
        var permissionsPassword = ""
        var allowsPrinting = true
        var allowsCopying = true
    }

    /// Why the choices cannot be run. Each case is a sentence a person can act on.
    enum Refusal: LocalizedError, Equatable, CustomStringConvertible {
        case nothingChosen
        case missingPermissionsPassword
        case passwordsMatch

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .nothingChosen:
                NSLocalizedString("Choose at least one thing to do to the copy.", comment: "Optimize copy refusal: nothing ticked")
            case .missingPermissionsPassword:
                NSLocalizedString(
                    "A protected copy needs a permissions password, so its restrictions cannot be lifted by anybody who opens it.",
                    comment: "Optimize copy refusal: no permissions password"
                )
            case .passwordsMatch:
                NSLocalizedString(
                    "The permissions password must differ from the open password; otherwise everyone who can open the copy can change it.",
                    comment: "Optimize copy refusal: the two passwords are the same"
                )
            }
        }
    }

    /// The service request for a set of choices. Pure.
    static func transform(for choices: Choices) throws -> RepairWireTransform {
        guard choices.reducesSize || choices.removesHiddenContent || choices.flattensDrawingAnnotations || choices.protects
        else { throw Refusal.nothingChosen }
        var protection: RepairWireTransform.Protection?
        if choices.protects {
            guard !choices.permissionsPassword.isEmpty else { throw Refusal.missingPermissionsPassword }
            guard choices.permissionsPassword != choices.openPassword else { throw Refusal.passwordsMatch }
            protection = .init(
                openPassword: choices.openPassword,
                permissionsPassword: choices.permissionsPassword,
                printing: choices.allowsPrinting ? 2 : 0,
                allowsChanges: false,
                allowsCopying: choices.allowsCopying,
                allowsAnnotating: true
            )
        }
        return RepairWireTransform(
            flattensAnnotations: choices.flattensDrawingAnnotations,
            compresses: choices.reducesSize,
            sanitizes: choices.removesHiddenContent,
            linearizes: false,
            protection: protection,
            pictureTargetDPI: choices.reducesSize && choices.downsamplesPictures ? Double(choices.pictureDPI) : nil
        )
    }

    /// The picture resolutions offered, in dots per inch.
    static let pictureResolutions = [100, 150, 200, 300]

    /// Writes the transformed copy through the repair service.
    ///
    /// The client stages the service's output in a private folder and swaps it onto `output`
    /// only after a clean reply, so a destination the save panel agreed to replace stays exactly
    /// as it was when the transform fails. Nothing else is written beside `output`: it used to be
    /// parked as a hidden sibling first, which a sandboxed save panel does not grant, so Optimize
    /// or Protect a Copy — and a burned-in Form Fill — failed on every chosen file that existed
    /// (V-051).
    static func run(
        source: URL,
        password: String?,
        output: URL,
        choices: Choices
    ) async throws -> RepairWireReply {
        let request = try transform(for: choices)
        try DerivedCopyGuard.refuseIfSource(output, source: source)
        return try await DamagedDrawingRepair.client.transform(
            input: source, output: output, password: password, transform: request
        )
    }

    /// What the person reads afterwards: the size before and after, and what was removed.
    static func resultNote(for reply: RepairWireReply, output: URL, choices: Choices, now: Date = Date()) -> AppWarning {
        var parts: [String] = []
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if let summary = reply.transformSummary, summary.inputByteCount > 0 {
            let saved = 1 - Double(reply.outputByteCount) / Double(summary.inputByteCount)
            parts.append(String(
                format: NSLocalizedString(
                    "%1$@ → %2$@ (%3$d %% smaller).",
                    comment: "Optimize copy note: size before, size after, percentage saved"
                ),
                formatter.string(fromByteCount: summary.inputByteCount),
                formatter.string(fromByteCount: reply.outputByteCount),
                Int((max(0, saved) * 100).rounded())
            ))
            if summary.flattenedAnnotationCount > 0 {
                parts.append(String(
                    format: NSLocalizedString(
                        "%d of the drawing's own annotations were burned into the pages.",
                        comment: "Optimize copy note: annotations flattened"
                    ),
                    summary.flattenedAnnotationCount
                ))
            }
            if summary.removedJavaScript || summary.removedEmbeddedFiles || summary.removedActionCount > 0 || summary.removedMetadata {
                parts.append(NSLocalizedString(
                    "Scripts, attached files, automatic actions and metadata were removed.",
                    comment: "Optimize copy note: sanitised"
                ))
            }
        }
        if choices.protects {
            parts.append(choices.openPassword.isEmpty
                ? NSLocalizedString(
                    "The copy opens without a password; printing and copying follow the permissions you chose.",
                    comment: "Optimize copy note: permissions only"
                )
                : NSLocalizedString(
                    "The copy opens only with its password.",
                    comment: "Optimize copy note: open password set"
                ))
        }
        if choices.reducesSize, choices.downsamplesPictures, let summary = reply.transformSummary {
            if summary.downsampledImageCount > 0 {
                parts.append(String(
                    format: NSLocalizedString(
                        "%1$lld pictures were reduced to %2$lld dpi; the linework was checked unchanged on every page.",
                        comment: "Optimize copy note: pictures downsampled; count, dpi"
                    ),
                    Int64(summary.downsampledImageCount), Int64(choices.pictureDPI)
                ))
            } else {
                parts.append(String(
                    format: NSLocalizedString(
                        "No picture is shown above %lld dpi, so none was reduced.",
                        comment: "Optimize copy note: nothing to downsample; dpi"
                    ),
                    Int64(choices.pictureDPI)
                ))
            }
            let left = summary.offeredImageCount - summary.downsampledImageCount
            if left > 0 {
                parts.append(String(
                    format: NSLocalizedString(
                        "%lld pictures could not be decoded here and were kept as they were.",
                        comment: "Optimize copy note: pictures left; count"
                    ),
                    Int64(left)
                ))
            }
        } else if choices.reducesSize {
            parts.append(NSLocalizedString(
                "Pictures are not re-encoded, so a scanned drawing shrinks only by what its structure allows.",
                comment: "Optimize copy note: images untouched"
            ))
        }
        return AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(
                format: NSLocalizedString("Saved “%@”", comment: "Optimize copy headline; the file name"),
                output.lastPathComponent
            ),
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }
}

/// The save panel's accessory for ``DocumentCopyTransform``: four choices and the passwords.
@MainActor
final class OptimizeCopyAccessory: NSView {

    let reduceSize = NSButton(checkboxWithTitle: NSLocalizedString("Reduce file size", comment: "Optimize copy option"), target: nil, action: nil)
    let downsample = NSButton(checkboxWithTitle: NSLocalizedString("Reduce pictures shown above", comment: "Optimize copy option: picture downsampling, followed by a resolution"), target: nil, action: nil)
    let pictureDPI = NSPopUpButton(frame: .zero, pullsDown: false)
    let removeHidden = NSButton(checkboxWithTitle: NSLocalizedString("Remove scripts, attachments and metadata", comment: "Optimize copy option"), target: nil, action: nil)
    let flatten = NSButton(checkboxWithTitle: NSLocalizedString("Burn in the drawing's own annotations and form fields", comment: "Optimize copy option"), target: nil, action: nil)
    let protect = NSButton(checkboxWithTitle: NSLocalizedString("Protect with a password", comment: "Optimize copy option"), target: nil, action: nil)
    let openPassword = NSSecureTextField()
    let permissionsPassword = NSSecureTextField()
    let allowPrinting = NSButton(checkboxWithTitle: NSLocalizedString("Allow printing", comment: "Optimize copy permission"), target: nil, action: nil)
    let allowCopying = NSButton(checkboxWithTitle: NSLocalizedString("Allow copying text", comment: "Optimize copy permission"), target: nil, action: nil)

    init(choices: DocumentCopyTransform.Choices = .init()) {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 258))
        reduceSize.state = choices.reducesSize ? .on : .off
        downsample.state = choices.downsamplesPictures ? .on : .off
        for dpi in DocumentCopyTransform.pictureResolutions {
            pictureDPI.addItem(withTitle: String(format: NSLocalizedString("%lld dpi", comment: "Picture resolution menu item; dots per inch"), Int64(dpi)))
            pictureDPI.lastItem?.tag = dpi
        }
        pictureDPI.selectItem(withTag: DocumentCopyTransform.pictureResolutions.contains(choices.pictureDPI) ? choices.pictureDPI : 150)
        pictureDPI.setAccessibilityLabel(NSLocalizedString("Picture resolution", comment: "Accessibility label: optimize copy picture resolution"))
        removeHidden.state = choices.removesHiddenContent ? .on : .off
        flatten.state = choices.flattensDrawingAnnotations ? .on : .off
        protect.state = choices.protects ? .on : .off
        allowPrinting.state = choices.allowsPrinting ? .on : .off
        allowCopying.state = choices.allowsCopying ? .on : .off
        openPassword.stringValue = choices.openPassword
        permissionsPassword.stringValue = choices.permissionsPassword
        openPassword.placeholderString = NSLocalizedString("Open password (optional)", comment: "Optimize copy field placeholder")
        permissionsPassword.placeholderString = NSLocalizedString("Permissions password", comment: "Optimize copy field placeholder")
        openPassword.setAccessibilityLabel(NSLocalizedString("Open password", comment: "Accessibility label: optimize copy open password"))
        permissionsPassword.setAccessibilityLabel(NSLocalizedString("Permissions password", comment: "Accessibility label: optimize copy permissions password"))
        for button in [reduceSize, downsample, removeHidden, flatten, protect, allowPrinting, allowCopying] {
            button.setAccessibilityLabel(button.title)
        }
        protect.target = self
        protect.action = #selector(protectionChanged)
        reduceSize.target = self
        reduceSize.action = #selector(sizeChanged)

        let passwords = NSStackView(views: [openPassword, permissionsPassword])
        passwords.spacing = 8
        passwords.distribution = .fillEqually
        let permissions = NSStackView(views: [allowPrinting, allowCopying])
        permissions.spacing = 16
        let pictures = NSStackView(views: [downsample, pictureDPI])
        pictures.spacing = 6
        let indented = NSStackView(views: [pictures])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        let stack = NSStackView(views: [reduceSize, indented, removeHidden, flatten, protect, passwords, permissions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            passwords.widthAnchor.constraint(equalToConstant: 400)
        ])
        protectionChanged()
        sizeChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func sizeChanged() {
        let on = reduceSize.state == .on
        downsample.isEnabled = on
        pictureDPI.isEnabled = on
    }

    @objc private func protectionChanged() {
        let on = protect.state == .on
        for control in [openPassword, permissionsPassword] as [NSControl] { control.isEnabled = on }
        allowPrinting.isEnabled = on
        allowCopying.isEnabled = on
    }

    var choices: DocumentCopyTransform.Choices {
        DocumentCopyTransform.Choices(
            reducesSize: reduceSize.state == .on,
            downsamplesPictures: downsample.state == .on,
            pictureDPI: pictureDPI.selectedTag() > 0 ? pictureDPI.selectedTag() : 150,
            removesHiddenContent: removeHidden.state == .on,
            flattensDrawingAnnotations: flatten.state == .on,
            protects: protect.state == .on,
            openPassword: openPassword.stringValue,
            permissionsPassword: permissionsPassword.stringValue,
            allowsPrinting: allowPrinting.state == .on,
            allowsCopying: allowCopying.state == .on
        )
    }
}

extension ProjectWindowController {

    /// File ▸ Export Drawing ▸ Optimize or Protect a Copy….
    func optimizeCopy(for document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = NSLocalizedString(
            "Save a smaller, cleaned or password-protected copy of the drawing. The drawing itself is not changed.",
            comment: "Optimize copy save panel message"
        )
        panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent
            + " — " + NSLocalizedString("Optimized", comment: "Optimize copy file-name suffix") + ".pdf"
        let accessory = OptimizeCopyAccessory()
        panel.accessoryView = accessory
        ZenitModalPresenter.runSavePanel(panel, identifier: DocumentCopyTransform.panelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            let choices = accessory.choices
            Task { @MainActor in
                do {
                    // Nothing the document is made of, not only the drawing (V-021).
                    try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
                    let reply = try await DocumentCopyTransform.run(
                        source: drawing.url, password: document.drawingPassword, output: url, choices: choices
                    )
                    document.core?.document.post(DocumentCopyTransform.resultNote(for: reply, output: url, choices: choices))
                    ExportCompletion.remember(url, document: document)
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }
}
