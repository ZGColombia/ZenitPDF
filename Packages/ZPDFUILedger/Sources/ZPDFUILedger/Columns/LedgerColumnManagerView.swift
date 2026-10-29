import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Column Manager (NL-QTY-02): the project's own ledger columns — add, rename, retype,
/// reorder, show or hide, delete — each change one undo step.
///
/// Built-in columns are not listed: they are shown and hidden from the column header's menu,
/// and their meaning is fixed. What is listed is every column a person made here or a table
/// import made for them.
public struct LedgerColumnManagerView: View {

    @Bindable private var model: LedgerColumnManagerModel
    private let onDone: () -> Void

    /// Creates the view. `onDone` closes whatever presents it.
    public init(model: LedgerColumnManagerModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Ledger Columns", comment: "Title of the Column Manager"),
                subtitle: NSLocalizedString(
                    "Your own columns. Built-in columns are shown or hidden from the column header menu.",
                    comment: "Column Manager subtitle"
                ),
                count: model.columns.count
            )
            HStack(alignment: .top, spacing: 0) {
                columnList
                    .frame(minWidth: 260, idealWidth: 300)
                ZPDFHairlineDivider(axis: .vertical)
                editor
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            ZPDFHairlineDivider()
            footer
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Column Manager", comment: "Accessibility label of the Column Manager"))
    }

    // MARK: List

    private var columnList: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            if model.columns.isEmpty {
                ZPDFEmptyState(
                    glyph: .symbol(.quantityLedger),
                    title: NSLocalizedString("No columns of your own yet", comment: "Column Manager empty state title"),
                    message: NSLocalizedString(
                        "Add a column for a rate, a cost code list or a formula such as Area × Unit Cost.",
                        comment: "Column Manager empty state message"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                        ForEach(Array(model.columns.enumerated()), id: \.element.id) { index, spec in
                            columnRow(spec, index: index)
                        }
                    }
                    .padding(ZPDFSpacing.m)
                }
            }
            HStack {
                Menu {
                    ForEach(LedgerColumnKind.allCases) { kind in
                        Button(kind.displayName) { model.beginAdd(kind: kind) }
                    }
                    Divider()
                    ForEach(LedgerColumnManagerModel.WasteBasis.allCases) { basis in
                        Button(basis.displayName) {
                            Task { await model.addWasteAndOrderColumns(basis: basis) }
                        }
                    }
                } label: {
                    Text(NSLocalizedString("Add Column", comment: "Column Manager: add a column menu"))
                }
                .fixedSize()
                .accessibilityLabel(NSLocalizedString("Add Column", comment: "Column Manager: add a column menu"))
                .disabled(model.isApplying)
                Spacer()
            }
            .padding(ZPDFSpacing.m)
        }
    }

    private func columnRow(_ spec: LedgerColumnSpec, index: Int) -> some View {
        let selected = model.draft?.id == spec.id
        return HStack(spacing: ZPDFSpacing.s) {
            Toggle(isOn: Binding(
                get: { spec.isVisible },
                set: { visible in Task { await model.setVisible(spec.id, visible) } }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(String(format: NSLocalizedString(
                    "Show %@ in the ledger", comment: "Column Manager: show/hide checkbox; the column name"
                ), spec.title))
            VStack(alignment: .leading, spacing: 0) {
                Text(spec.title).zpdfText(.control, .textPrimary).lineLimit(1)
                Text(Self.kindSummary(spec)).zpdfText(.caption, .textSecondary).lineLimit(1)
            }
            Spacer(minLength: ZPDFSpacing.s)
            Button {
                Task { await model.move(spec.id, by: -1) }
            } label: { Text("↑") }
                .buttonStyle(.borderless)
                .disabled(index == 0 || model.isApplying)
                .accessibilityLabel(String(format: NSLocalizedString(
                    "Move %@ left", comment: "Column Manager: move a column earlier; the column name"
                ), spec.title))
            Button {
                Task { await model.move(spec.id, by: 1) }
            } label: { Text("↓") }
                .buttonStyle(.borderless)
                .disabled(index == model.columns.count - 1 || model.isApplying)
                .accessibilityLabel(String(format: NSLocalizedString(
                    "Move %@ right", comment: "Column Manager: move a column later; the column name"
                ), spec.title))
            Button(NSLocalizedString("Edit", comment: "Column Manager: edit a column")) {
                model.beginEdit(spec.id)
            }
            .accessibilityLabel(String(format: NSLocalizedString(
                "Edit %@", comment: "Column Manager: edit a column; the column name"
            ), spec.title))
        }
        .padding(ZPDFSpacing.xs)
        .background(selected ? ZPDFColor.selectedFill : ZPDFColor.surface)
        .accessibilityElement(children: .contain)
    }

    /// "Number · Area", "Money · SEK", "Choice · 3 options", "Formula".
    static func kindSummary(_ spec: LedgerColumnSpec) -> String {
        var parts = [spec.kind.displayName]
        switch spec.kind {
        case .number:
            if let choice = LedgerColumnUnitChoice(dimension: spec.dimension), choice != .unspecified {
                parts.append(choice.displayName)
            }
        case .currency:
            if let code = spec.dimension?.currencyCode {
                let basis = LedgerMoneyBasis(dimension: spec.dimension)
                parts.append(basis == .amount ? code : "\(code) · \(basis.displayName)")
            }
        case .choice:
            parts.append(LedgerPlurals.options(spec.choices.filter { !$0.isRetired }.count))
        case .formula:
            if let source = spec.formulaSource, !source.isEmpty { parts.append(source) }
        default:
            break
        }
        if spec.neverSums, spec.kind == .number || spec.kind == .formula {
            parts.append(NSLocalizedString("no total", comment: "Column Manager: the column is left out of totals"))
        }
        if !spec.isVisible {
            parts.append(NSLocalizedString("hidden", comment: "Column Manager: the column is hidden in the ledger"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    Text(model.isDraftNew
                         ? NSLocalizedString("New Column", comment: "Column Manager editor heading for a new column")
                         : NSLocalizedString("Edit Column", comment: "Column Manager editor heading for an existing column"))
                        .zpdfText(.sectionHeader, .textPrimary)

                    ZPDFInspectorRow(label: NSLocalizedString("Name", comment: "Column Manager: column name field")) {
                        TextField(
                            NSLocalizedString("Column name", comment: "Column Manager: name placeholder"),
                            text: Binding(get: { model.draft?.title ?? "" }, set: { model.draft?.title = $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(NSLocalizedString("Column name", comment: "Column Manager: name placeholder"))
                    }

                    ZPDFInspectorRow(label: NSLocalizedString("Type", comment: "Column Manager: column type picker")) {
                        Picker("", selection: Binding(get: { draft.kind }, set: { model.setDraftKind($0) })) {
                            ForEach(LedgerColumnKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(NSLocalizedString("Column type", comment: "Column Manager: type picker"))
                    }

                    kindSettings(draft)

                    if !model.isDraftNew {
                        Text(NSLocalizedString(
                            "Changing the type converts the values already typed. If some cannot be converted, nothing changes and you are told how many.",
                            comment: "Column Manager: note about retyping"
                        ))
                        .zpdfText(.caption, .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: ZPDFSpacing.m) {
                        if !model.isDraftNew {
                            Button(NSLocalizedString("Delete Column", comment: "Column Manager: delete the edited column"), role: .destructive) {
                                Task {
                                    if await model.delete(draft.id) { model.cancelDraft() }
                                }
                            }
                            .disabled(model.isApplying)
                        }
                        Spacer()
                        Button(NSLocalizedString("Cancel", comment: "Column Manager: abandon the edit")) {
                            model.cancelDraft()
                        }
                        .keyboardShortcut(.cancelAction)
                        Button(model.isDraftNew
                               ? NSLocalizedString("Add", comment: "Column Manager: add the new column")
                               : NSLocalizedString("Apply", comment: "Column Manager: apply the column edit")) {
                            Task { await model.commitDraft() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canCommitDraft)
                    }
                }
                .padding(ZPDFSpacing.l)
            }
        } else {
            ZPDFEmptyState(
                glyph: .symbol(.quantityLedger),
                title: NSLocalizedString("Choose a column", comment: "Column Manager editor empty state title"),
                message: NSLocalizedString(
                    "Pick a column to edit it, or add a new one.",
                    comment: "Column Manager editor empty state message"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func kindSettings(_ draft: LedgerColumnSpec) -> some View {
        switch draft.kind {
        case .number:
            ZPDFInspectorRow(label: NSLocalizedString("Unit", comment: "Column Manager: number column unit picker")) {
                Picker("", selection: Binding(
                    get: { LedgerColumnUnitChoice(dimension: model.draft?.dimension) ?? .unspecified },
                    set: { model.draft?.dimension = $0.dimension }
                )) {
                    ForEach(LedgerColumnUnitChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Unit", comment: "Column Manager: number column unit picker"))
            }
            decimalsRow
            totalsRow
        case .currency:
            ZPDFInspectorRow(label: NSLocalizedString("Currency", comment: "Column Manager: currency code field")) {
                TextField("SEK", text: Binding(
                    get: { model.draft?.dimension?.currencyCode ?? model.defaultCurrencyCode },
                    set: { text in
                        let code = String(text.uppercased().filter { $0.isLetter && $0.isASCII }.prefix(3))
                        let basis = LedgerMoneyBasis(dimension: model.draft?.dimension)
                        model.draft?.dimension = basis.dimension(currencyCode: code)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 80)
                .accessibilityLabel(NSLocalizedString("Currency code", comment: "Column Manager: currency code field"))
            }
            ZPDFInspectorRow(label: NSLocalizedString("Holds", comment: "Column Manager: amount or rate picker")) {
                Picker("", selection: Binding(
                    get: { LedgerMoneyBasis(dimension: model.draft?.dimension) },
                    set: { basis in
                        let code = model.draft?.dimension?.currencyCode ?? model.defaultCurrencyCode
                        model.draft?.dimension = basis.dimension(currencyCode: code)
                    }
                )) {
                    ForEach(LedgerMoneyBasis.allCases) { basis in
                        Text(basis.displayName).tag(basis)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Amount or rate", comment: "Column Manager: amount or rate picker"))
            }
            Text(NSLocalizedString(
                "An amount sums into group and grand totals. A rate is money per metre, square metre or cubic metre and never sums.",
                comment: "Column Manager: explanation of amount versus rate"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        case .choice:
            choiceSettings(draft)
        case .formula:
            formulaSettings(draft)
        case .text, .date, .checkbox:
            EmptyView()
        }
    }

    /// "Leave out of totals" (ADR-0039): for a number whose values describe one row — a pack
    /// size, a spacing — which a sum would turn into a number that means nothing.
    private var totalsRow: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Toggle(NSLocalizedString("Leave out of totals", comment: "Column Manager: the column never sums into group and grand totals"), isOn: Binding(
                get: { model.draft?.neverSums ?? false },
                set: { model.draft?.neverSums = $0 }
            ))
            .toggleStyle(.checkbox)
            Text(NSLocalizedString(
                "For a value that describes one row, such as a pack size or a spacing. Its rows still count.",
                comment: "Column Manager: explanation of leaving a column out of totals"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var decimalsRow: some View {
        ZPDFInspectorRow(label: NSLocalizedString("Decimals", comment: "Column Manager: decimal places picker")) {
            Picker("", selection: Binding(
                get: { model.draft?.decimalPlaces ?? -1 },
                set: { model.draft?.decimalPlaces = $0 < 0 ? nil : $0 }
            )) {
                Text(NSLocalizedString("Ledger default", comment: "Column Manager: default decimal places")).tag(-1)
                ForEach(0..<5) { places in Text("\(places)").tag(places) }
            }
            .labelsHidden()
            .accessibilityLabel(NSLocalizedString("Decimal places", comment: "Column Manager: decimal places picker"))
        }
    }

    @ViewBuilder
    private func choiceSettings(_ draft: LedgerColumnSpec) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Options", comment: "Column Manager: choice options heading"))
                .zpdfText(.caption, .textSecondary)
            ForEach(Array(draft.choices.enumerated()), id: \.element.id) { index, option in
                HStack(spacing: ZPDFSpacing.xs) {
                    Menu {
                        ForEach(ZenitNamedPalette.entries) { entry in
                            Button(entry.name) { model.setDraftOptionColor(option.id, entry.color) }
                        }
                        Divider()
                        Button(NSLocalizedString("No Colour", comment: "Column Manager: remove an option's colour")) {
                            model.setDraftOptionColor(option.id, nil)
                        }
                    } label: {
                        Circle()
                            .fill(option.colorRGBA.alpha > 0 ? option.colorRGBA.swiftUIColor : Color.clear)
                            .overlay(Circle().stroke(ZPDFColor.border))
                            .frame(width: 14, height: 14)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(String(format: NSLocalizedString(
                        "Colour of option %@", comment: "Column Manager: option colour menu; the option name"
                    ), option.value))
                    TextField(
                        NSLocalizedString("Option", comment: "Column Manager: option name placeholder"),
                        text: Binding(get: { option.value }, set: { model.setDraftOptionValue(option.id, $0) })
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(format: NSLocalizedString(
                        "Option %d name", comment: "Column Manager: option name field; the option position"
                    ), index + 1))
                    Toggle(NSLocalizedString("Default", comment: "Column Manager: default option checkbox"), isOn: Binding(
                        get: { draft.defaultChoiceID == option.id },
                        set: { model.setDraftDefaultOption($0 ? option.id : nil) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(option.isRetired)
                    Toggle(NSLocalizedString("Retired", comment: "Column Manager: retired option checkbox"), isOn: Binding(
                        get: { option.isRetired },
                        set: { model.setDraftOptionRetired(option.id, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    Button { model.moveDraftOption(option.id, by: -1) } label: { Text("↑") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel(NSLocalizedString("Move option up", comment: "Column Manager: move option earlier"))
                    Button { model.removeDraftOption(option.id) } label: { Text("−") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(NSLocalizedString("Remove option", comment: "Column Manager: remove an option"))
                }
            }
            Button(NSLocalizedString("Add Option", comment: "Column Manager: add a choice option")) {
                model.addDraftOption()
            }
            Text(NSLocalizedString(
                "An option rows already use cannot be removed; retire it instead and it stays readable on those rows.",
                comment: "Column Manager: note about retiring options"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func formulaSettings(_ draft: LedgerColumnSpec) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack {
                Text(NSLocalizedString("Formula", comment: "Column Manager: formula field heading"))
                    .zpdfText(.caption, .textSecondary)
                Spacer()
                Menu(NSLocalizedString("Insert", comment: "Column Manager: insert a name into the formula")) {
                    ForEach(model.formulaNames, id: \.self) { name in
                        Button(name) {
                            let current = model.draft?.formulaSource ?? ""
                            model.draft?.formulaSource = current.isEmpty ? name : current + " " + name
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel(NSLocalizedString("Insert a variable or column", comment: "Column Manager: insert menu"))
            }
            TextField(
                "Area * UnitCost",
                text: Binding(get: { model.draft?.formulaSource ?? "" }, set: { model.draft?.formulaSource = $0 })
            )
            .textFieldStyle(.roundedBorder)
            .font(ZPDFTypography.font(.monoNumeric))
            .accessibilityLabel(NSLocalizedString("Formula", comment: "Column Manager: formula field heading"))
            if let problem = model.draftFormulaProblem {
                ZPDFInlineWarning(message: problem)
            } else if !(draft.formulaSource ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                Text(NSLocalizedString(
                    "The formula checks out. Units are checked: adding an area to a length is refused.",
                    comment: "Column Manager: formula is valid"
                ))
                .zpdfText(.caption, .textSecondary)
            }
            decimalsRow
            totalsRow
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.m) {
            if let message = model.message {
                Text(message)
                    .zpdfText(.caption, model.lastChangeFailed ? .textPrimary : .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            Spacer()
            Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                .keyboardShortcut(model.draft == nil ? .defaultAction : nil)
        }
        .padding(ZPDFSpacing.l)
    }
}
