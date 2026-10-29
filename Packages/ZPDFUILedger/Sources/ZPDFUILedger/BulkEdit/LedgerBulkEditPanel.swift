import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Edits subject, label, status, colour and custom values across a multi-row selection.
///
/// Every field that the selection disagrees about shows the shared mixed indicator instead
/// of a value, and stays untouched until the user types into it or presses Clear. Focusing a
/// field, or tabbing through it, is not an edit. The confirmation line
/// above Apply counts the markups that will actually change, so a mis-aimed bulk edit is
/// visible before it happens rather than after.
public struct LedgerBulkEditPanel: View {

    @Bindable private var model: LedgerBulkEditModel
    /// What the last Apply did, shown above Revert and Apply, inside the fields' scroll.
    private let outcome: AnyView?

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - model: the selection and the staged edits.
    ///   - outcome: the host's line saying what the last Apply did, or `nil` for none. It sits in
    ///     the confirmation, just above the Apply button that produced it, inside the same scroll
    ///     as the fields. L-85: drawn under the panel, it took its height from the fields' scroll
    ///     after every Apply, and a short pane was squeezed back to a strip a click could miss.
    public init(model: LedgerBulkEditModel, outcome: AnyView? = nil) {
        self.model = model
        self.outcome = outcome
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Bulk Edit", comment: "Title of the bulk edit panel"),
                subtitle: selectionText,
                count: model.rows.count
            )

            if model.rows.isEmpty {
                ZPDFEmptyState(
                    glyph: .symbol(.quantityLedger),
                    title: NSLocalizedString("No rows selected", comment: "Bulk edit empty state title"),
                    message: NSLocalizedString(
                        "Select rows in the ledger to change their subject, label, status, colour or custom values together.",
                        comment: "Bulk edit empty state message"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let outcome {
                    // An Apply whose rows then left the selection (a filter on the field it set)
                    // still says what it did.
                    outcome.padding(ZPDFSpacing.l)
                }
            } else {
                // L-85: one scroll for the fields and the confirmation under them. The
                // confirmation and the buttons used to sit below the scroll at their full height,
                // so a short pane — the detached ledger opened 200 pt tall — left the fields a
                // 22 pt strip: a click on a field outside it landed on the panel behind, the
                // keyboard stayed in the field typed into before, and only a double click (the
                // first one scrolling) reached the field.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
                            ForEach(model.editableColumns, id: \.id) { column in
                                field(for: column)
                            }
                            colorField
                        }
                        .padding(ZPDFSpacing.l)

                        ZPDFHairlineDivider()

                        confirmation
                    }
                }
            }
        }
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Bulk edit", comment: "Accessibility label of the bulk edit panel"))
    }

    /// The count of what Apply will change, per field, what the last Apply did, and the Revert and
    /// Apply buttons.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(model.summary.message)
                .zpdfText(.caption, model.summary.isEmpty ? .textSecondary : .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(model.summary.message)

            if !model.summary.isEmpty {
                ForEach(perFieldLines, id: \.self) { line in
                    Text(line)
                        .zpdfText(.caption, .textSecondary)
                }
            }

            if let outcome {
                outcome
            }

            HStack(spacing: ZPDFSpacing.m) {
                Spacer()
                Button(NSLocalizedString("Revert", comment: "Bulk edit action")) {
                    model.clearEdits()
                }
                .disabled(model.summary.isEmpty)
                Button(NSLocalizedString("Apply", comment: "Bulk edit action")) {
                    model.apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.summary.isEmpty)
            }
        }
        .padding(ZPDFSpacing.l)
    }

    private var selectionText: String {
        LedgerPlurals.markupsSelected(model.rows.count)
    }

    private var perFieldLines: [String] {
        model.summary.changesPerField
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { columnID, count in
                let title = model.columns.first { $0.id == columnID }?.title ?? columnID.rawValue
                return LedgerPlurals.markupsPerField(title, count: count)
            }
    }

    /// One field's row. The row is never told `isMixed`, so it never swaps its editor for the
    /// inert "Mixed" indicator. It used to be told exactly while no edit was staged, which hid
    /// the only control that could stage one — so a disagreeing selection could never be
    /// unified, the panel's primary job (BH-036). Each editor now shows "Mixed" itself, as a
    /// placeholder, a menu title, or a caption beside the control.
    @ViewBuilder
    private func field(for column: LedgerColumn) -> some View {
        let state = model.displayState(column.id)
        ZPDFInspectorRow(
            label: column.title,
            helpText: column.accessibilityLabel
        ) {
            switch column.kind {
            case .checkbox:
                checkboxEditor(for: column, state: model.valueState(column.id))
            case .choice:
                choiceEditor(for: column, state: state)
            case .date:
                dateEditor(for: column, state: model.valueState(column.id))
            case .number, .currency:
                numberEditor(for: column, state: state)
            case .text, .formula:
                textEditor(for: column, state: state)
            }
        }
    }

    @ViewBuilder
    private func textEditor(for column: LedgerColumn, state: LedgerMixedValue<String>) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.s) {
                // "Not edited" and "edited to empty" are two states in the model, so emptying
                // a shared value blanks it across the selection instead of putting it back
                // (R-121). The setter also receives the field's unchanged text whenever the
                // field gains or loses focus; the model ignores that write, so tabbing through
                // a Mixed field stages nothing. A Mixed field is blanked with Clear.
                TextField(
                    placeholder(for: column, state: state),
                    text: Binding(
                        get: { model.text(for: column) },
                        set: { model.setText($0, for: column) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(column.title)
                .accessibilityValue(accessibilityValue(for: column, state: state))
                clearButton(for: column)
                leaveUnchangedButton(for: column)
            }
            blankRefusal(for: column)
        }
    }

    /// Blanks the field on every selected markup, on purpose (R-121 re-fix). Emptying a Mixed
    /// field cannot do it — an untouched Mixed field is already empty — so this is the way.
    @ViewBuilder
    private func clearButton(for column: LedgerColumn) -> some View {
        if model.offersClear(column) {
            Button(NSLocalizedString("Clear", comment: "Bulk edit action: blank this field on every selected markup")) {
                model.clearField(column)
            }
            .buttonStyle(.link)
            .zpdfFont(.caption)
            .accessibilityLabel(String(
                format: NSLocalizedString(
                    "Clear %@",
                    comment: "Accessibility label of the bulk edit Clear action; the placeholder is the column title"
                ),
                column.title
            ))
        }
    }

    /// Takes back a staged edit, shown only while the field has one (R-121).
    @ViewBuilder
    private func leaveUnchangedButton(for column: LedgerColumn) -> some View {
        if model.edit(for: column.id) != nil || model.refusedBlankColumns.contains(column.id) {
            Button(NSLocalizedString("Leave Unchanged", comment: "Bulk edit action: take back the edit staged for one field")) {
                model.leaveUnchanged(column.id)
            }
            .buttonStyle(.link)
            .zpdfFont(.caption)
        }
    }

    /// Says why an emptied Subject or Status changes nothing (R-121).
    @ViewBuilder
    private func blankRefusal(for column: LedgerColumn) -> some View {
        if model.refusedBlankColumns.contains(column.id) {
            let message = String(
                format: NSLocalizedString(
                    "%@ cannot be blank. Nothing will change in this field.",
                    comment: "Bulk edit hint under an emptied field that cannot be cleared; the placeholder is the column title"
                ),
                column.title
            )
            Text(message)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)
        }
    }

    @ViewBuilder
    private func numberEditor(for column: LedgerColumn, state: LedgerMixedValue<String>) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.s) {
                TextField(
                    placeholder(for: column, state: state),
                    text: Binding(
                        get: { model.numberText(for: column) },
                        set: { model.setNumberText($0, for: column) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(ZPDFTypography.font(.monoNumeric))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(column.title)
                .accessibilityValue(accessibilityValue(for: column, state: state))
                clearButton(for: column)
                leaveUnchangedButton(for: column)
            }
            blankRefusal(for: column)

            if model.invalidNumberColumns.contains(column.id) {
                Text(invalidNumberMessage(for: column))
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(invalidNumberMessage(for: column))
            }
        }
    }

    private func invalidNumberMessage(for column: LedgerColumn) -> String {
        if column.kind == .currency, column.dimension?.currencyCode == nil {
            return NSLocalizedString(
                "This column has no currency, so the amount cannot be applied.",
                comment: "Bulk edit hint under a currency field whose column declares no currency"
            )
        }
        return NSLocalizedString(
            "Not a number. Nothing will change in this field.",
            comment: "Bulk edit hint under a number field whose text does not parse"
        )
    }

    @ViewBuilder
    private func choiceEditor(for column: LedgerColumn, state: LedgerMixedValue<String>) -> some View {
        Menu {
            ForEach(column.choices.filter { !$0.isRetired }) { option in
                Button(option.title) { model.setEdit(.choice(option.value), for: column.id) }
            }
            Divider()
            if model.canClear(column) {
                Button(NSLocalizedString("Clear", comment: "Bulk edit choice action: blank this field on every selected markup")) {
                    model.clearField(column)
                }
            }
            Button(NSLocalizedString("Leave Unchanged", comment: "Bulk edit choice action")) {
                model.setEdit(nil, for: column.id)
            }
        } label: {
            Text(currentChoiceTitle(for: column, state: state))
                .zpdfText(.control)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(column.title)
        .accessibilityValue(accessibilityValue(for: column, state: state))
    }

    @ViewBuilder
    private func checkboxEditor(for column: LedgerColumn, state: LedgerMixedValue<LedgerCellValue>) -> some View {
        let staged = model.edit(for: column.id)
        let current: Bool = {
            if case let .checkbox(flag)? = staged { return flag }
            if case let .checkbox(flag)? = state.uniformValue { return flag }
            return false
        }()
        Toggle(isOn: Binding(
            get: { current },
            set: { model.setEdit(.checkbox($0), for: column.id) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .accessibilityLabel(column.title)
        .accessibilityValue(state.isMixed && staged == nil
            ? NSLocalizedString("Mixed", comment: "Accessibility value for a mixed bulk edit field")
            : (current
               ? NSLocalizedString("Checked", comment: "Accessibility value for a ticked check box")
               : NSLocalizedString("Not checked", comment: "Accessibility value for a clear check box")))
    }

    @ViewBuilder
    private func dateEditor(for column: LedgerColumn, state: LedgerMixedValue<LedgerCellValue>) -> some View {
        let staged = model.edit(for: column.id)
        let current: Date = {
            if case let .date(value)? = staged { return value }
            if case let .date(value)? = state.uniformValue { return value }
            return Date()
        }()
        HStack(spacing: ZPDFSpacing.s) {
            DatePicker(
                "",
                selection: Binding(get: { current }, set: { model.setEdit(.date($0), for: column.id) }),
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityLabel(column.title)
            .accessibilityValue(state.isMixed && staged == nil ? mixedText : "")

            if state.isMixed && staged == nil {
                ZPDFMixedValueIndicator()
            }
            if staged == .empty {
                Text(clearedText).zpdfText(.caption, .textSecondary)
            }
            if model.canClear(column), staged != .empty {
                Button(NSLocalizedString("Clear", comment: "Bulk edit action: blank a date on every selected markup")) {
                    model.clearField(column)
                }
                .buttonStyle(.link)
                .zpdfFont(.caption)
            }
            leaveUnchangedButton(for: column)
        }
    }

    private var clearedText: String {
        NSLocalizedString("Cleared", comment: "Bulk edit: a field staged to be blanked on every selected markup")
    }

    private var mixedText: String {
        NSLocalizedString("Mixed", comment: "Accessibility value for a mixed bulk edit field")
    }

    @ViewBuilder
    private var colorField: some View {
        let state = model.colorState
        ZPDFInspectorRow(
            label: NSLocalizedString("Color", comment: "Bulk edit field label"),
            helpText: NSLocalizedString(
                "Colour is a cue only. Subject and label carry the meaning.",
                comment: "Help text for the bulk edit colour field"
            )
        ) {
            HStack(spacing: ZPDFSpacing.s) {
                ColorPicker(
                    "",
                    selection: Binding(
                        get: {
                            let rgba = model.colorEdit ?? state.uniformValue ?? ColorRGBA.Zenit.Dark.cyan
                            return rgba.swiftUIColor
                        },
                        set: { color in
                            model.colorEdit = ColorRGBA(swiftUIColor: color)
                        }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Markup colour", comment: "Accessibility label of the bulk edit colour well"))
                .accessibilityValue(state.isMixed && model.colorEdit == nil ? mixedText : "")

                if state.isMixed && model.colorEdit == nil {
                    ZPDFMixedValueIndicator()
                }

                if model.colorEdit != nil {
                    Button(NSLocalizedString("Leave Unchanged", comment: "Bulk edit colour action")) {
                        model.colorEdit = nil
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func placeholder(for column: LedgerColumn, state: LedgerMixedValue<String>) -> String {
        if model.edit(for: column.id) == .empty { return clearedText }
        return state.isMixed
            ? NSLocalizedString("Mixed", comment: "Placeholder for a bulk edit field whose rows disagree")
            : NSLocalizedString("Value", comment: "Placeholder for an empty bulk edit field")
    }

    private func currentChoiceTitle(for column: LedgerColumn, state: LedgerMixedValue<String>) -> String {
        if case let .choice(value)? = model.edit(for: column.id) {
            return column.choices.first { $0.value == value }?.title ?? value
        }
        if model.edit(for: column.id) == .empty { return clearedText }
        if state.isMixed { return NSLocalizedString("Mixed", comment: "Bulk edit choice showing disagreeing rows") }
        return state.uniformValue ?? NSLocalizedString("Choose…", comment: "Bulk edit choice placeholder")
    }

    private func accessibilityValue(for column: LedgerColumn, state: LedgerMixedValue<String>) -> String {
        if let staged = model.edit(for: column.id) {
            if staged == .empty { return clearedText }
            return staged.asText ?? NSLocalizedString("Changed", comment: "Accessibility value for a staged bulk edit")
        }
        if state.isMixed {
            return NSLocalizedString("Mixed", comment: "Accessibility value for a mixed bulk edit field")
        }
        return state.uniformValue ?? NSLocalizedString("Empty", comment: "Accessibility value for an empty bulk edit field")
    }
}
