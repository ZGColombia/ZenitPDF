import AppKit
import SwiftUI
import ZPDFDesignSystem

/// The options bar's value box as one AppKit control: the label, the editable field and the
/// unit, where a press anywhere inside the box puts the keyboard in the field (L-103).
///
/// The box used to be a SwiftUI `TextField` 56 pt wide and one text line tall, framed by a
/// 24 pt box that also held the label and the unit. Only that inner line took the keyboard, so a
/// click on the label, the unit, the padding or above and below the digits — most of what reads
/// as "the field" — gave it nothing, and the digits typed next reached the canvas, where 1–9 arm
/// Tool Library presets: "20" for a slope armed Interior Wall and the next clicks recorded a wall
/// area. Every point of this view belongs to the field; a press outside the editable text makes
/// the field first responder, a press on it is the field's own (caret placement, selection).
@MainActor
public final class MeasurementParameterBoxView: NSView, NSTextFieldDelegate {

    /// The editable field. Exposed so the window can type into it (``focusAndInsert(_:)``) and
    /// so a test can find the responder it expects.
    public let field = MeasurementParameterTextField()
    private let label = NSTextField(labelWithString: "")
    private let unit = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    /// Every edit, as the field's whole text.
    var onTextChange: (@MainActor (String) -> Void)?
    /// Whether the field holds the keyboard, for the focus ring.
    var onEditingChange: (@MainActor (Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = ZPDFTypography.nsFont(.caption)
        label.textColor = ZPDFColor.nsColor(.textSecondary)
        label.setAccessibilityElement(false)
        unit.font = ZPDFTypography.nsFont(.caption)
        unit.textColor = ZPDFColor.nsColor(.textSecondary)
        unit.setAccessibilityElement(false)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = ZPDFTypography.nsFont(.monoNumeric)
        field.textColor = ZPDFColor.nsColor(.textPrimary)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        field.box = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = ZPDFSpacing.xs
        stack.edgeInsets = NSEdgeInsets(top: 0, left: ZPDFSpacing.s, bottom: 0, right: ZPDFSpacing.s)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(unit)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    /// Applies the question the tool is asking: its name, its unit, its help and the value.
    func configure(label labelText: String, unit unitText: String, help: String, text: String) {
        if label.stringValue != labelText { label.stringValue = labelText }
        if unit.stringValue != unitText { unit.stringValue = unitText }
        toolTip = help
        field.toolTip = help
        field.setAccessibilityLabel(labelText)
        field.setAccessibilityHelp(help)
        // The field's own text wins while it is being typed into: writing the presenter's echo
        // back under the caret moves the caret to the end on every keystroke.
        if !isEditing, field.stringValue != text { field.stringValue = text }
    }

    /// Whether the field holds the keyboard.
    public var isEditing: Bool {
        guard let window, let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    // MARK: - Every point of the box is the field's

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // A press on the editable text — or on the field editor while it types — is the field's
        // own: it places the caret. Anything else inside the box comes here, to `mouseDown`.
        if hit === field || hit.isDescendant(of: field) { return hit }
        return self
    }

    public override func mouseDown(with event: NSEvent) {
        focusField()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    public override var acceptsFirstResponder: Bool { false }

    /// Puts the keyboard in the field, keeping a field already being typed into as it is.
    @discardableResult
    public func focusField() -> Bool {
        guard let window else { return false }
        if isEditing { return true }
        return window.makeFirstResponder(field)
    }

    /// Puts the keyboard in the field and types `text` there, replacing the selection — the whole
    /// value when the field has just taken the keyboard (L-103: a number typed at the canvas
    /// while the tool asks for a value is that value).
    @discardableResult
    public func focusAndInsert(_ text: String) -> Bool {
        guard focusField(), let editor = field.currentEditor() as? NSTextView else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ notification: Notification) {
        onTextChange?(field.stringValue)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        onTextChange?(field.stringValue)
        onEditingChange?(false)
    }

    fileprivate func fieldDidTakeKeyboard() {
        onEditingChange?(true)
    }
}

/// The editable text inside ``MeasurementParameterBoxView``: reports taking the keyboard, so the
/// box draws its focus ring from the first click rather than the first keystroke.
@MainActor
public final class MeasurementParameterTextField: NSTextField {

    fileprivate weak var box: MeasurementParameterBoxView?

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { box?.fieldDidTakeKeyboard() }
        return became
    }
}

/// The SwiftUI face of ``MeasurementParameterBoxView``.
struct MeasurementParameterBox: NSViewRepresentable {

    let label: String
    let unit: String
    let help: String
    let text: String
    let onTextChange: @MainActor (String) -> Void
    let onEditingChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> MeasurementParameterBoxView {
        let view = MeasurementParameterBoxView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MeasurementParameterBoxView, context: Context) {
        view.onTextChange = onTextChange
        view.onEditingChange = onEditingChange
        view.configure(label: label, unit: unit, help: help, text: text)
    }

    /// The box's own width (label, field, unit and insets) at the standard control height, so the
    /// whole drawn box is this view and takes the press.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MeasurementParameterBoxView, context: Context) -> CGSize? {
        let fitting = view.fittingSize
        return CGSize(width: fitting.width, height: max(fitting.height, ZPDFSpacing.Control.minimumHitTarget))
    }
}

extension NSView {

    /// The first options-bar value box in this view's subtree, or `nil` (L-103).
    func firstMeasurementParameterBox() -> MeasurementParameterBoxView? {
        if let box = self as? MeasurementParameterBoxView { return box }
        for subview in subviews {
            if let box = subview.firstMeasurementParameterBox() { return box }
        }
        return nil
    }
}
