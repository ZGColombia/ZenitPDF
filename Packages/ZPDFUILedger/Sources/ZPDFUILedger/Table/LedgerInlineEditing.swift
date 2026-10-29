import AppKit
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The cell an inline edit is open on.
public struct LedgerCellAddress: Hashable, Sendable {

    /// Display position of the row in ``LedgerGroupPlan/order``.
    public let displayPosition: Int
    /// The column being edited.
    public let columnID: LedgerColumnID

    /// Creates an address.
    public init(displayPosition: Int, columnID: LedgerColumnID) {
        self.displayPosition = displayPosition
        self.columnID = columnID
    }
}

/// What a key press inside an inline editor asks the table to do.
public enum LedgerInlineEditCommand: Hashable, Sendable {
    /// Return: keep the value and close the editor.
    case commit
    /// Tab: keep the value and open the next editable cell.
    case next
    /// Shift-Tab: keep the value and open the previous editable cell.
    case previous
    /// Escape: restore the value and close the editor.
    case cancel
}

/// Localised copy for inline editing, in one place so every editor says the same thing.
enum LedgerInlineEditStrings {

    static func editorLabel(columnTitle: String) -> String {
        String(
            format: NSLocalizedString(
                "Edit %1$@",
                comment: "VoiceOver label of the inline editor in a ledger cell: column title"
            ),
            columnTitle
        )
    }

    static var editorHelp: String {
        NSLocalizedString(
            "Return saves, Escape cancels, Tab moves to the next editable cell.",
            comment: "VoiceOver help of the inline editor in a ledger cell"
        )
    }

    static var emptyChoice: String {
        NSLocalizedString("No value", comment: "Inline choice editor entry that clears the cell")
    }
}

/// The text field laid over a cell while it is edited in place.
@MainActor
final class LedgerInlineTextField: NSTextField {

    /// The cell being edited.
    let address: LedgerCellAddress
    /// The text the cell held when editing began, restored by Escape.
    let originalText: String
    /// The column being edited: a number or money column parses what was typed (NL-QTY-04).
    let column: LedgerColumn

    init(address: LedgerCellAddress, text: String, column: LedgerColumn) {
        self.address = address
        self.originalText = text
        self.column = column
        super.init(frame: .zero)
        stringValue = text
        isEditable = true
        isSelectable = true
        isBordered = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = ZPDFColor.nsColor(.surface)
        textColor = ZPDFColor.nsColor(.textPrimary)
        font = LedgerCellView.font(for: column)
        alignment = LedgerCellView.nsAlignment(column.alignment)
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        focusRingType = .exterior
        setAccessibilityLabel(LedgerInlineEditStrings.editorLabel(columnTitle: column.title))
        setAccessibilityHelp(LedgerInlineEditStrings.editorHelp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Built in code only.
        return nil
    }
}

/// The pop-up laid over a choice cell while it is edited in place.
@MainActor
final class LedgerInlinePopUpButton: NSPopUpButton {

    /// The cell being edited.
    let address: LedgerCellAddress
    /// The stored value the cell held when editing began, `nil` for an empty cell.
    let originalValue: String?
    /// Receives Tab, Shift-Tab, Return and Escape.
    var onCommand: ((LedgerInlineEditCommand) -> Void)?

    /// Stored choice values in item order; `nil` is the "no value" entry.
    private(set) var values: [String?] = []

    init(address: LedgerCellAddress, column: LedgerColumn, current: String?) {
        self.address = address
        self.originalValue = current
        super.init(frame: .zero, pullsDown: false)
        font = ZPDFTypography.nsFont(.body)
        (cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        bezelStyle = .flexiblePush
        setAccessibilityLabel(LedgerInlineEditStrings.editorLabel(columnTitle: column.title))
        setAccessibilityHelp(LedgerInlineEditStrings.editorHelp)

        // T-050: Status cannot be cleared — the application writes it only from a choice, and
        // it has a real "No status" option — so its pop-up offers no empty entry that would
        // close the editor and change nothing. A cell that is empty right now keeps the entry,
        // so opening and committing it never writes an option nobody picked.
        if Self.offersEmptyChoice(column: column, current: current) {
            addItem(withTitle: LedgerInlineEditStrings.emptyChoice)
            values.append(nil)
        }
        let options = column.choices
            .filter { !$0.isRetired || $0.value == current }
            .sorted { $0.order < $1.order }
        for option in options {
            addItem(withTitle: option.title)
            values.append(option.value)
        }
        if let index = values.firstIndex(of: current) { selectItem(at: index) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Built in code only.
        return nil
    }

    /// Whether the pop-up lists the "No value" entry: for every column a bulk edit may clear
    /// (``LedgerBulkEditModel/unclearableColumns``), and for any cell that holds no value yet.
    static func offersEmptyChoice(column: LedgerColumn, current: String?) -> Bool {
        current == nil || !LedgerBulkEditModel.unclearableColumns.contains(column.id)
    }

    /// The stored value of the selected item, `nil` for "no value".
    var selectedValue: String? {
        let index = indexOfSelectedItem
        return values.indices.contains(index) ? values[index] : nil
    }

    /// Selects the item for a stored value, for keyboard-free tests.
    func select(value: String?) {
        if let index = values.firstIndex(of: value) { selectItem(at: index) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            onCommand?(event.modifierFlags.contains(.shift) ? .previous : .next)
        case 36, 76:
            onCommand?(.commit)
        case 53:
            onCommand?(.cancel)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCommand?(.cancel)
    }
}
