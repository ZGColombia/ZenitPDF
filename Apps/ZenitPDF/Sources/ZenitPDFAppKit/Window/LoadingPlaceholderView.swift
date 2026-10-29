import AppKit
import ZPDFDesignSystem

/// What a window says while its drawing opens (IM-050): the file's name, "Opening…", an
/// indeterminate progress indicator — a still label under Reduce Motion — and Cancel, which
/// closes the tab and so aborts the load through the document's own close path.
@MainActor
final class LoadingPlaceholderView: NSStackView {

    let nameLabel: NSTextField
    let statusLabel: NSTextField
    let progress: NSProgressIndicator
    let cancelButton: NSButton
    private let onCancel: @MainActor () -> Void

    init(fileName: String, onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        nameLabel = NSTextField(labelWithString: fileName)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .labelColor
        statusLabel = NSTextField(labelWithString: NSLocalizedString(
            "Opening…", comment: "Placeholder status while a drawing is being opened"
        ))
        statusLabel.textColor = .secondaryLabelColor
        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(NSLocalizedString(
            "Opening the drawing", comment: "Accessibility label for the opening progress indicator"
        ))
        cancelButton = NSButton(
            title: NSLocalizedString("Cancel", comment: "Button that stops opening a drawing"),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 10
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.toolTip = (NSLocalizedString(
            "Stops opening this drawing and closes its tab",
            comment: "Accessibility hint for the Cancel button while a drawing opens"
        ))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        progress.isHidden = reduceMotion
        if !reduceMotion { progress.startAnimation(nil) }
        addArrangedSubview(progress)
        addArrangedSubview(nameLabel)
        addArrangedSubview(statusLabel)
        addArrangedSubview(cancelButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(
            format: NSLocalizedString("Opening %@", comment: "Accessibility label while a drawing opens; the file name"),
            fileName
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
    }
}
