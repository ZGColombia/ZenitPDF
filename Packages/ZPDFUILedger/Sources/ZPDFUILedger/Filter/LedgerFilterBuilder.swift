import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The filter editor: rule rows inside AND / OR groups, with a live match count.
///
/// The live count is the point of the whole surface. A filter that silently removes rows
/// is how an estimator loses a quantity, so the builder always says how many rows survive
/// and offers one keystroke to clear everything.
public struct LedgerFilterBuilder: View {

    private let columns: [LedgerColumn]
    @Binding private var filter: LedgerFilterGroup
    @Binding private var savedFilters: LedgerSavedFilterStore
    @Binding private var canvasBehavior: LedgerCanvasFilterBehavior
    private let matchCount: Int
    private let totalCount: Int
    private let diagnostics: [LedgerFilterDiagnostic]

    @State private var pendingName: String = ""
    @State private var isNamingFilter = false

    /// Creates the filter builder.
    ///
    /// - Parameters:
    ///   - columns: Columns rules can be written against.
    ///   - filter: The rule tree being edited.
    ///   - savedFilters: Named filters the user can restore.
    ///   - canvasBehavior: What the canvas does with rows that fail the filter.
    ///   - matchCount: How many rows currently match.
    ///   - totalCount: How many rows there are in total.
    ///   - diagnostics: Diagnostics the host already has, shown before the ones the builder
    ///     derives from the tree itself (``LedgerFilterDiagnostic/unappliedRules(in:columns:)``).
    public init(
        columns: [LedgerColumn],
        filter: Binding<LedgerFilterGroup>,
        savedFilters: Binding<LedgerSavedFilterStore>,
        canvasBehavior: Binding<LedgerCanvasFilterBehavior>,
        matchCount: Int,
        totalCount: Int,
        diagnostics: [LedgerFilterDiagnostic] = []
    ) {
        self.columns = columns
        self._filter = filter
        self._savedFilters = savedFilters
        self._canvasBehavior = canvasBehavior
        self.matchCount = matchCount
        self.totalCount = totalCount
        self.diagnostics = diagnostics
    }

    /// The builder with its naming row already open, as after Save Current Filter…, for tests
    /// that lay the row out off screen: SwiftUI draws the row's buttons itself, so a test cannot
    /// press the one that opens it.
    init(
        columns: [LedgerColumn],
        filter: Binding<LedgerFilterGroup>,
        savedFilters: Binding<LedgerSavedFilterStore>,
        canvasBehavior: Binding<LedgerCanvasFilterBehavior>,
        matchCount: Int,
        totalCount: Int,
        namingFilter: Bool
    ) {
        self.init(
            columns: columns, filter: filter, savedFilters: savedFilters, canvasBehavior: canvasBehavior,
            matchCount: matchCount, totalCount: totalCount
        )
        _isNamingFilter = State(initialValue: namingFilter)
    }

    /// The columns a filter rule can name, from the columns the presenter publishes: every one
    /// of them, in the default arrangement, hidden ones included.
    ///
    /// The pane used to pass only the columns on screen — the default eight and the user's —
    /// so the chip filters' rules on Status, Plan Area, Plan Length and Count were reported as
    /// naming no such column while they were in fact applied, and those columns could not be
    /// picked for a rule (S-078). The picker still leaves out the Value and Unit display
    /// columns (``LedgerFilterRuleRow/selectableColumns(_:current:)``), a new rule still starts
    /// on a visible column (``LedgerFilterRuleRow/defaultColumn(in:)``), and a rule on an
    /// identifier the presenter really lacks is still reported.
    ///
    /// Type is offered as a pick list of tools and markup kinds (U-059,
    /// ``LedgerFilterTypeColumn``), so a rule on it stores the token the cells hold and reads
    /// the name the column shows.
    public nonisolated static func filterableColumns(_ presenterColumns: [LedgerColumn]) -> [LedgerColumn] {
        LedgerDefaultColumns.arranged(presenterColumns).map(LedgerFilterTypeColumn.presented)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Filter", comment: "Title of the ledger filter panel"),
                subtitle: matchText
            ) {
                Button(NSLocalizedString("Clear All", comment: "Ledger filter action")) {
                    filter = LedgerFilterTreeEditor.cleared(filter)
                }
                // BH-710: disabled rules and empty groups are still something to clear.
                .disabled(!LedgerFilterOperandRules.hasContent(filter))
                .accessibilityHint(
                    NSLocalizedString("Removes every rule and shows all rows again.", comment: "Accessibility hint for clear all")
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    LedgerFilterGroupView(
                        group: filter,
                        columns: columns,
                        isRoot: true,
                        onChange: { filter = $0 }
                    )
                    savedFilterSection
                    canvasSection
                    // The host's diagnostics, then the rules the ledger engine does
                    // not apply at all (CR-56) — a pattern rule, a rule on a display column —
                    // so the panel never reports a filter as applied that is not.
                    ForEach(Array(shownDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        ZPDFInlineWarning(severity: .warning, message: diagnostic.message)
                    }
                }
                .padding([.top, .bottom, .leading], ZPDFSpacing.l)
                .padding(.trailing, ZPDFSpacing.l + Self.scrollerReserve)
            }
        }
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Filter builder", comment: "Accessibility label of the ledger filter panel"))
    }

    private var matchText: String {
        LedgerPlurals.rowsMatch(matchCount, of: totalCount)
    }

    /// The strip along the panel's right edge that the scroll view's vertical scroller takes when
    /// it shows, kept clear of controls.
    ///
    /// L-84: the panel sits at the window's right edge, and an overlay scroller grows under a
    /// pointer that comes near that edge and takes the click. When the content ran wider than the
    /// panel, all that showed of the naming row's Save was in that strip, so the first click went
    /// to the scroller and Save needed a second. With the rows wrapped to the panel, Cancel still
    /// reached 5 pt into it.
    static var scrollerReserve: CGFloat {
        max(
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay),
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        )
    }

    /// The supplied diagnostics, followed by one per kind of rule the engine cannot apply.
    private var shownDiagnostics: [LedgerFilterDiagnostic] {
        var shown = diagnostics
        for diagnostic in LedgerFilterDiagnostic.unappliedRules(in: filter, columns: columns)
        where !shown.contains(diagnostic) {
            shown.append(diagnostic)
        }
        return shown
    }

    @ViewBuilder
    private var savedFilterSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Saved Filters", comment: "Section title in the ledger filter panel"))
                .zpdfText(.sectionHeader, .textSecondary)

            if savedFilters.filters.isEmpty {
                Text(NSLocalizedString("No saved filters yet.", comment: "Empty state in the ledger filter panel"))
                    .zpdfText(.caption, .textSecondary)
            } else {
                ForEach(savedFilters.filters) { saved in
                    HStack(spacing: ZPDFSpacing.s) {
                        Button(saved.name) { filter = saved.filter }
                            .buttonStyle(.link)
                            .accessibilityHint(
                                NSLocalizedString("Restores this saved filter.", comment: "Accessibility hint for a saved filter")
                            )
                        Spacer()
                        Button {
                            savedFilters.remove(id: saved.id)
                        } label: {
                            ZPDFGlyphView(.symbol(.remove), size: ZPDFSpacing.Control.iconSmall)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            String(
                                format: NSLocalizedString("Delete saved filter %1$@", comment: "Accessibility label: filter name"),
                                saved.name
                            )
                        )
                    }
                }
            }

            if isNamingFilter {
                HStack(spacing: ZPDFSpacing.s) {
                    TextField(
                        NSLocalizedString("Filter name", comment: "Placeholder for the saved filter name field"),
                        text: $pendingName
                    )
                    .textFieldStyle(.roundedBorder)
                    // Return saves, as in every naming field. Not the L-84 fix: Save's second
                    // click came from the scroller's strip (`scrollerReserve`).
                    .onSubmit(saveNamedFilter)
                    Button(NSLocalizedString("Save", comment: "Ledger filter action"), action: saveNamedFilter)
                    .disabled(pendingName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(NSLocalizedString("Cancel", comment: "Ledger filter action")) {
                        pendingName = ""
                        isNamingFilter = false
                    }
                }
            } else {
                Button(NSLocalizedString("Save Current Filter…", comment: "Ledger filter action")) {
                    isNamingFilter = true
                }
                .disabled(!LedgerFilterOperandRules.hasContent(filter))
            }
        }
    }

    /// Saves the filter under the typed name and closes the naming row; nothing for a blank name.
    private func saveNamedFilter() {
        guard !pendingName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        savedFilters.save(name: pendingName, filter: filter)
        pendingName = ""
        isNamingFilter = false
    }

    /// What the canvas does with rows that fail the filter, as a column of radio buttons.
    ///
    /// L-84: three segments — "Dim Non-Matching · Hide Non-Matching · Leave Unchanged" — share
    /// the panel's width equally, and a third of it is narrower than "Leave Unchanged", which read
    /// "Leave Uncha…" and ran off the edge. One choice per line keeps every name whole at the
    /// panel's width, and a choice of three is what radio buttons are for.
    @ViewBuilder
    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Canvas", comment: "Section title in the ledger filter panel"))
                .zpdfText(.sectionHeader, .textSecondary)
            Picker("", selection: $canvasBehavior) {
                ForEach(LedgerCanvasFilterBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(NSLocalizedString(
                "What the canvas does with rows that do not match",
                comment: "Accessibility title of the canvas filter behaviour control"
            ))
        }
    }
}

/// One AND / OR group of rules, drawn recursively.
struct LedgerFilterGroupView: View {

    let group: LedgerFilterGroup
    let columns: [LedgerColumn]
    let isRoot: Bool
    let onChange: (LedgerFilterGroup) -> Void
    /// Removes this group from its parent; `nil` for the root, which can never be removed.
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            header
            ForEach(group.rules) { rule in
                LedgerFilterRuleRow(
                    rule: rule,
                    columns: columns,
                    onChange: { onChange(LedgerFilterTreeEditor.updating($0, in: group)) },
                    onRemove: { onChange(LedgerFilterTreeEditor.removingRule(id: rule.id, in: group)) }
                )
            }
            ForEach(group.groups) { child in
                LedgerFilterGroupView(
                    group: child,
                    columns: columns,
                    isRoot: false,
                    onChange: { updated in
                        var parent = group
                        if let index = parent.groups.firstIndex(where: { $0.id == updated.id }) {
                            parent.groups[index] = updated
                        }
                        onChange(parent)
                    },
                    // BH-711: a nested group can be removed, not only emptied.
                    onRemove: { onChange(LedgerFilterTreeEditor.removingGroup(id: child.id, in: group)) }
                )
                .padding(.leading, ZPDFSpacing.l)
            }
            footer
        }
        .padding(ZPDFSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: ZPDFRadius.medium)
                .fill(isRoot ? Color.clear : ZPDFColor.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: ZPDFRadius.medium)
                        .strokeBorder(ZPDFColor.border, lineWidth: isRoot ? 0 : ZPDFStroke.hairline)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupAccessibilityLabel)
    }

    private var groupAccessibilityLabel: String {
        LedgerPlurals.filterGroupLabel(group.conjunction.displayName, ruleCount: group.enabledRuleCount)
    }

    private var header: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Picker("", selection: conjunctionBinding) {
                ForEach(LedgerFilterConjunction.allCases, id: \.self) { conjunction in
                    Text(conjunction.displayName).tag(conjunction)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(
                NSLocalizedString("How the rules in this group combine", comment: "Accessibility label of the conjunction picker")
            )

            Toggle(isOn: negatedBinding) {
                Text(NSLocalizedString("Invert", comment: "Ledger filter group toggle"))
                    .zpdfText(.caption)
            }
            .toggleStyle(.checkbox)

            Spacer()

            if !isRoot, let onRemove {
                Button(action: onRemove) {
                    ZPDFGlyphView(.symbol(.remove), size: ZPDFSpacing.Control.iconSmall)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Remove this group and its rules", comment: "Tooltip of the remove-group button"))
                .accessibilityLabel(NSLocalizedString("Remove this group", comment: "Accessibility label"))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.m) {
            Button {
                guard let column = LedgerFilterRuleRow.defaultColumn(in: columns) else { return }
                // U-058: a rule with nothing written in it starts off — "Page contains “”"
                // matches no row, and the builder applies changes live.
                let rule = LedgerFilterOperandRules.newRule(on: column)
                onChange(LedgerFilterTreeEditor.insertingRule(rule, intoGroup: group.id, in: group))
            } label: {
                Label(
                    NSLocalizedString("Add Rule", comment: "Ledger filter action"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderless)

            Button {
                let child = LedgerFilterGroup(id: UUID(), conjunction: group.conjunction == .all ? .any : .all)
                onChange(LedgerFilterTreeEditor.insertingGroup(child, intoGroup: group.id, in: group))
            } label: {
                Label(
                    NSLocalizedString("Add Group", comment: "Ledger filter action"),
                    systemImage: "plus.square.on.square"
                )
            }
            .buttonStyle(.borderless)
        }
    }

    private var conjunctionBinding: Binding<LedgerFilterConjunction> {
        Binding(
            get: { group.conjunction },
            set: { onChange(LedgerFilterTreeEditor.setting(conjunction: $0, forGroup: group.id, in: group)) }
        )
    }

    private var negatedBinding: Binding<Bool> {
        Binding(
            get: { group.isNegated },
            set: { onChange(LedgerFilterTreeEditor.setting(negated: $0, forGroup: group.id, in: group)) }
        )
    }
}

/// One rule row: column, operator, value.
struct LedgerFilterRuleRow: View {

    let rule: LedgerFilterRule
    let columns: [LedgerColumn]
    let onChange: (LedgerFilterRule) -> Void
    let onRemove: () -> Void

    /// Whether the rule's number fields read as numbers (T-049).
    @State private var numberFields = LedgerFilterNumberFields()
    /// Keeps the rule off while nothing is written in it (U-058).
    @State private var blankOperand = LedgerFilterBlankOperand()

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ruleControls
            // T-049: an unreadable number switches the rule off and says so, under the row.
            // U-058: so does a rule with nothing written in it.
            if let hint = numberFields.hint ?? LedgerFilterOperandRules.blankHint(for: rule) {
                ZPDFInlineWarning(severity: .warning, message: hint)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Publishes an edit to the rule, keeping a blank rule off (U-058).
    private func publish(_ proposed: LedgerFilterRule) {
        onChange(blankOperand.rule(after: proposed, replacing: rule))
    }

    /// The rule's controls on one line where they fit, else on two: the column picker on the
    /// first, the comparison and the value under it.
    ///
    /// L-84: on one line the row needs about 440 pt — the column, comparison and value
    /// minimums alone are 370 — and the ledger's side panel is 340 pt wide, so the value field
    /// and everything right of it ran off the panel's edge, docked and detached alike.
    private var ruleControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ZPDFSpacing.s) {
                enabledToggle
                columnPicker.frame(minWidth: 120)
                comparisonPicker.frame(minWidth: 130)
                operandEditor.frame(minWidth: 120)
                removeButton
            }
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                HStack(spacing: ZPDFSpacing.s) {
                    enabledToggle
                    columnPicker.frame(minWidth: 96, maxWidth: .infinity)
                    removeButton
                }
                HStack(spacing: ZPDFSpacing.s) {
                    comparisonPicker.fixedSize()
                    operandEditor.frame(minWidth: 72, maxWidth: .infinity)
                }
                .padding(.leading, Self.secondLineIndent)
            }
        }
    }

    /// The second line starts under the column picker, past the rule's check box.
    static let secondLineIndent: CGFloat = ZPDFSpacing.xl + ZPDFSpacing.s

    private var enabledToggle: some View {
        Toggle(isOn: enabledBinding) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            // While a number field does not read as a number the rule stays off: turning
            // it on would apply a value the field no longer shows. A blank rule cannot be
            // turned on either — it would match no row (U-058) — but can always be turned off.
            .disabled(numberFields.isHoldingUnreadableDraft
                || (!rule.isEnabled && LedgerFilterOperandRules.isBlank(rule)))
            .accessibilityLabel(NSLocalizedString("Rule is active", comment: "Accessibility label of the rule enable box"))
    }

    private var columnPicker: some View {
        Picker("", selection: columnBinding) {
            ForEach(Self.selectableColumns(columns, current: rule.column), id: \.id) { column in
                Text(column.title).tag(column.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel(NSLocalizedString("Column", comment: "Accessibility label of the rule column picker"))
    }

    private var comparisonPicker: some View {
        Picker("", selection: comparisonBinding) {
            ForEach(comparisons, id: \.self) { comparison in
                Text(comparison.displayName).tag(comparison)
            }
        }
        .labelsHidden()
        .accessibilityLabel(NSLocalizedString("Comparison", comment: "Accessibility label of the rule comparison picker"))
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            ZPDFGlyphView(.symbol(.remove), size: ZPDFSpacing.Control.iconSmall)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(NSLocalizedString("Remove rule", comment: "Accessibility label"))
    }

    private var column: LedgerColumn? { columns.first { $0.id == rule.column } }

    private var comparisons: [LedgerFilterComparison] {
        Self.comparisons(for: column, current: rule.comparison)
    }

    /// The comparisons the picker offers for a column.
    ///
    /// `matchesRegex` is offered to no new rule (CR-56): the ledger engine has no regex
    /// operator by design (QUALITY_BAR A23), so a pattern rule would be
    /// shown as applied and silently skipped. A rule that already carries the comparison — a
    /// saved filter from before — keeps it in its picker so the row still reads correctly,
    /// and the panel's diagnostic says it is not applied.
    nonisolated static func comparisons(
        for column: LedgerColumn?,
        current: LedgerFilterComparison
    ) -> [LedgerFilterComparison] {
        var offered: [LedgerFilterComparison]
        if let column {
            switch column.kind {
            case .text:
                offered = [.contains, .notContains, .equals, .notEquals, .beginsWith, .endsWith, .isEmpty, .isNotEmpty]
            case .number, .currency, .formula:
                offered = [.equals, .notEquals, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .between, .isEmpty, .isNotEmpty]
            case .date:
                offered = [.equals, .notEquals, .lessThan, .greaterThan, .between, .isEmpty, .isNotEmpty]
            case .checkbox:
                offered = [.isTrue, .isFalse]
            case .choice:
                offered = [.equals, .notEquals, .isAnyOf, .isEmpty, .isNotEmpty]
            }
        } else {
            offered = LedgerFilterComparison.allCases.filter { $0 != .matchesRegex }
        }
        if !offered.contains(current) { offered.append(current) }
        return offered
    }

    /// The columns the picker offers a rule.
    ///
    /// The synthesised Value and Unit display columns are not offered (CR-56): the ledger
    /// engine has no such columns and drops any rule on them. A rule that already names one
    /// keeps it in its picker, and the panel's diagnostic says it is not applied.
    nonisolated static func selectableColumns(
        _ columns: [LedgerColumn],
        current: LedgerColumnID
    ) -> [LedgerColumn] {
        columns.filter { !LedgerDefaultColumns.isDisplayColumn($0.id) || $0.id == current }
    }

    /// The column a fresh rule starts on: the first visible one the engine can filter.
    nonisolated static func defaultColumn(in columns: [LedgerColumn]) -> LedgerColumn? {
        let filterable = columns.filter { !LedgerDefaultColumns.isDisplayColumn($0.id) }
        return filterable.first(where: \.visible) ?? filterable.first ?? columns.first
    }

    @ViewBuilder
    private var operandEditor: some View {
        if rule.comparison.isUnary {
            Text(verbatim: "—")
                .zpdfText(.caption, .textSecondary)
                .accessibilityHidden(true)
        } else {
            switch rule.operand {
            case let .numberRange(lower, upper):
                HStack(spacing: ZPDFSpacing.xs) {
                    decimalField(value: lower, field: 0) { .numberRange(lower: $0, upper: upper) }
                    Text(verbatim: "–").zpdfText(.caption, .textSecondary)
                    decimalField(value: upper, field: 1) { .numberRange(lower: lower, upper: $0) }
                    unitLabel
                }
            case let .number(value):
                HStack(spacing: ZPDFSpacing.xs) {
                    decimalField(value: value, field: 0) { .number($0) }
                    unitLabel
                }
            case let .date(value):
                DatePicker("", selection: Binding(
                    get: { value },
                    set: { publish(updated(operand: .date(LedgerFilterDates.normalized($0, for: rule.comparison)))) }
                ), displayedComponents: .date)
                .labelsHidden()
                .accessibilityLabel(NSLocalizedString("Date", comment: "Accessibility label of a date filter operand"))
            case let .dateRange(start, end):
                HStack(spacing: ZPDFSpacing.xs) {
                    DatePicker("", selection: Binding(
                        get: { start },
                        set: {
                            publish(updated(operand: LedgerFilterDates.normalized(
                                .dateRange(start: $0, end: end), for: .between)))
                        }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel(NSLocalizedString("From date", comment: "Accessibility label of a date range start"))
                    DatePicker("", selection: Binding(
                        get: { end },
                        set: {
                            publish(updated(operand: LedgerFilterDates.normalized(
                                .dateRange(start: start, end: $0), for: .between)))
                        }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel(NSLocalizedString("To date", comment: "Accessibility label of a date range end"))
                }
            case let .choices(values):
                choiceMenu(selected: Set(values))
            case let .regex(pattern):
                TextField(
                    NSLocalizedString("Pattern", comment: "Placeholder for a regular expression operand"),
                    text: Binding(get: { pattern }, set: { publish(updated(operand: .regex($0))) })
                )
                .textFieldStyle(.roundedBorder)
                .font(ZPDFTypography.font(.code))
            case let .boolean(flag):
                Toggle(isOn: Binding(get: { flag }, set: { publish(updated(operand: .boolean($0))) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            // "is" / "is not" name one option. A text rule under another comparison — a saved
            // "Type contains area" from before Type was a pick list (U-059) — keeps its field.
            case let .text(value) where column?.kind == .choice && (rule.comparison == .equals || rule.comparison == .notEquals):
                singleChoicePicker(selected: value)
            case let .text(value):
                TextField(
                    NSLocalizedString("Value", comment: "Placeholder for a text operand"),
                    text: Binding(get: { value }, set: { publish(updated(operand: .text($0))) })
                )
                .textFieldStyle(.roundedBorder)
            case .none:
                TextField(
                    NSLocalizedString("Value", comment: "Placeholder for a text operand"),
                    text: Binding(get: { "" }, set: { publish(updated(operand: .text($0))) })
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// The conversion between the unit the user reads in the column and the SI operand.
    private var conversion: LedgerFilterUnitConversion { LedgerFilterUnitConversion.forColumn(column) }

    @ViewBuilder
    private var unitLabel: some View {
        if !conversion.symbol.isEmpty {
            Text(verbatim: conversion.symbol)
                .zpdfText(.caption, .textSecondary)
                .accessibilityHidden(true)
        }
    }

    /// A numeric operand field. The user types in the column's display unit (BH-039) with the
    /// locale's decimal separator (BH-040); the rule stores the SI value. `field` names the
    /// field within the rule (0, or 1 for a range's upper bound) and `operand` builds the
    /// rule's operand from the field's SI value.
    private func decimalField(
        value: Decimal,
        field: Int,
        operand: @escaping (Decimal) -> LedgerFilterOperand
    ) -> some View {
        let conversion = self.conversion
        let label = conversion.symbol.isEmpty
            ? NSLocalizedString("Value", comment: "Accessibility label of a numeric filter operand")
            : String(
                format: NSLocalizedString("Value in %1$@", comment: "Accessibility label of a numeric filter operand: unit symbol"),
                conversion.symbol
            )
        return LedgerFilterDecimalField(
            siValue: value,
            draft: numberFields.draftText(inField: field),
            conversion: conversion,
            accessibilityLabel: label,
            onType: { text in
                if let next = numberFields.rule(typing: text, inField: field, conversion: conversion, of: rule, operand: operand) {
                    publish(next)
                }
            },
            onDraftDropped: { numberFields.dropDraft(inField: field) }
        )
    }

    /// "is" / "is not" on a choice column: one option, stored by its value (BH-042).
    private func singleChoicePicker(selected: String) -> some View {
        Picker("", selection: Binding(
            get: { selected },
            set: { publish(updated(operand: .text($0))) }
        )) {
            Text(NSLocalizedString("Choose…", comment: "Placeholder for a choice operand")).tag("")
            ForEach(column?.choices ?? []) { option in
                Text(option.title).tag(option.value)
            }
        }
        .labelsHidden()
        .accessibilityLabel(NSLocalizedString("Option", comment: "Accessibility label of a single choice filter operand"))
    }

    @ViewBuilder
    private func choiceMenu(selected: Set<String>) -> some View {
        Menu {
            ForEach(column?.choices ?? []) { option in
                Button {
                    var updatedValues = selected
                    if updatedValues.contains(option.value) {
                        updatedValues.remove(option.value)
                    } else {
                        updatedValues.insert(option.value)
                    }
                    publish(updated(operand: .choices(updatedValues.sorted())))
                } label: {
                    Text(selected.contains(option.value) ? "✓ \(option.title)" : option.title)
                }
            }
        } label: {
            Text(Self.choiceMenuTitle(selected: selected, column: column))
                .zpdfText(.control)
        }
        .menuStyle(.borderlessButton)
    }

    /// The "is any of" menu's label: the picked options' titles, in the column's option
    /// order — the words the menu items show. It printed the stored keys, sorted as text:
    /// "inProgress, open" for Open and In progress (T-051). A key the column no longer offers
    /// is shown as stored, last, so a stale saved filter still says what it holds.
    nonisolated static func choiceMenuTitle(selected: Set<String>, column: LedgerColumn?) -> String {
        guard !selected.isEmpty else {
            return NSLocalizedString("Choose…", comment: "Placeholder for a choice operand")
        }
        let options = (column?.choices ?? []).sorted { $0.order < $1.order }
        let known = options.filter { selected.contains($0.value) }
        let knownValues = Set(known.map(\.value))
        let unknown = selected.subtracting(knownValues).sorted()
        return (known.map(\.title) + unknown).joined(separator: ", ")
    }

    private func updated(operand: LedgerFilterOperand) -> LedgerFilterRule {
        LedgerFilterRule(
            id: rule.id,
            column: rule.column,
            comparison: rule.comparison,
            operand: operand,
            isEnabled: rule.isEnabled
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: {
                numberFields.personToggledRule()
                onChange(
                    LedgerFilterRule(
                        id: rule.id,
                        column: rule.column,
                        comparison: rule.comparison,
                        operand: rule.operand,
                        isEnabled: $0
                    )
                )
            }
        )
    }

    private var columnBinding: Binding<LedgerColumnID> {
        Binding(
            get: { rule.column },
            set: { newID in
                guard let newColumn = columns.first(where: { $0.id == newID }) else { return }
                let isEnabled = numberFields.operandReplaced(wasEnabled: rule.isEnabled)
                publish(
                    LedgerFilterRule(
                        id: rule.id,
                        column: newID,
                        comparison: Self.defaultComparison(for: newColumn),
                        operand: Self.defaultOperand(for: newColumn),
                        isEnabled: isEnabled
                    )
                )
            }
        )
    }

    private var comparisonBinding: Binding<LedgerFilterComparison> {
        Binding(
            get: { rule.comparison },
            set: { comparison in
                let isEnabled = numberFields.operandReplaced(wasEnabled: rule.isEnabled)
                publish(
                    LedgerFilterRule(
                        id: rule.id,
                        column: rule.column,
                        comparison: comparison,
                        operand: Self.operand(for: comparison, column: column, previous: rule.operand),
                        isEnabled: isEnabled
                    )
                )
            }
        )
    }

    /// The comparison a fresh rule on a column starts with.
    static func defaultComparison(for column: LedgerColumn) -> LedgerFilterComparison {
        LedgerFilterOperandRules.defaultComparison(for: column)
    }

    /// The operand a fresh rule on a column starts with (a date is pinned to a day boundary).
    static func defaultOperand(for column: LedgerColumn) -> LedgerFilterOperand {
        LedgerFilterOperandRules.defaultOperand(for: column)
    }

    /// Keeps the operand shape in step with the comparison the user picked.
    static func operand(
        for comparison: LedgerFilterComparison,
        column: LedgerColumn?,
        previous: LedgerFilterOperand
    ) -> LedgerFilterOperand {
        LedgerFilterOperandRules.operand(for: comparison, column: column, previous: previous)
    }
}

/// A numeric operand field that keeps the user's draft text while they type.
///
/// The old field re-rendered the stored value on every keystroke, so a draft such as "12," or
/// "12.50" was reparsed, truncated and written back before the user finished (BH-040). The
/// draft is only replaced when the stored value changes from outside.
///
/// Every keystroke is reported, and the rule row reads it as a ``LedgerFilterNumberDraft`` — a
/// number (in SI), empty, or not a number — never only the ones that parse (T-049): "1,234.5"
/// parses as 1, 1.2, 1.23 and 1.234 on the way and is refused at the end, and the rule used to
/// keep filtering at 1.234 under a field that read "1,234.5".
///
/// The draft text is the rule row's (``LedgerFilterNumberFields``), not this view's (U-057):
/// a field-local `@State` survived a comparison or column change — same view, same identity —
/// so the rule came back on at 1.234 while the field went on reading "1,234.5". Rebuilding the
/// operand now clears the draft with the rest of the row's number bookkeeping.
struct LedgerFilterDecimalField: View {

    let siValue: Decimal
    /// The text typed and not yet replaced by the stored value, or `nil` to show the value.
    let draft: String?
    let conversion: LedgerFilterUnitConversion
    let accessibilityLabel: String
    /// Every keystroke's full text.
    let onType: (String) -> Void
    /// The draft was dropped because the stored value changed from outside.
    let onDraftDropped: () -> Void

    private var shownText: String {
        LedgerFilterNumberFields.shownText(draft: draft, siValue: siValue, conversion: conversion)
    }

    var body: some View {
        TextField(
            NSLocalizedString("Value", comment: "Placeholder for a numeric operand"),
            text: Binding(
                get: { shownText },
                set: { text in onType(text) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .font(ZPDFTypography.font(.monoNumeric))
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: siValue) { _, newValue in
            // Keep the draft while it still means the stored value; drop it when the value
            // was changed by something else (a restored saved filter, Clear All).
            guard let current = draft else { return }
            let typed = LedgerNumberParsing.decimal(from: current).map { conversion.siValue(fromDisplay: $0) }
            if typed != newValue {
                onDraftDropped()
            }
        }
    }
}

/// What a numeric filter field's text says (T-049).
enum LedgerFilterNumberDraft: Hashable, Sendable {
    /// A number, already converted to the rule's SI value.
    case number(Decimal)
    /// Nothing typed: no value, not the value the field held before.
    case empty
    /// Text that does not read as a number under the one grammar (`ZPDFDecimalParser`).
    case notANumber

    init(text: String, conversion: LedgerFilterUnitConversion) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else if let typed = LedgerNumberParsing.decimal(from: text) {
            self = .number(conversion.siValue(fromDisplay: typed))
        } else {
            self = .notANumber
        }
    }
}

/// The number fields of one filter rule, and whether their drafts read as numbers (T-049).
///
/// A field whose text stops reading as a number — "1,234.5", "12abc", an emptied field —
/// switches its rule off and says so, so the rows shown, the match count and the export banner
/// (which lists enabled rules only) never claim a value the field does not show. The rule comes
/// back on, with the typed value, as soon as every field reads as a number again — unless the
/// person switched it off themselves, which a draft never overrides.
struct LedgerFilterNumberFields: Hashable, Sendable {

    /// Fields (0, or 1 for a range's upper bound) whose draft is not a number, and what it is.
    private(set) var unreadable: [Int: LedgerFilterNumberDraft] = [:]
    /// The rule is off because of a draft, not because the person switched it off.
    private(set) var suspendedByDraft = false
    /// The text typed into each field and not yet replaced by the stored value (U-057).
    private(set) var drafts: [Int: String] = [:]

    /// The text a field holds: its draft, or the stored value in the column's display unit.
    static func shownText(draft: String?, siValue: Decimal, conversion: LedgerFilterUnitConversion) -> String {
        draft ?? LedgerNumberParsing.editingString(conversion.displayValue(fromSI: siValue))
    }

    /// The draft of `field`, or `nil` when it shows the stored value.
    func draftText(inField field: Int) -> String? { drafts[field] }

    /// Records what `field` now reads and returns the rule to publish, as
    /// ``rule(after:inField:of:operand:)`` does for the parsed draft.
    mutating func rule(
        typing text: String,
        inField field: Int,
        conversion: LedgerFilterUnitConversion,
        of rule: LedgerFilterRule,
        operand: (Decimal) -> LedgerFilterOperand
    ) -> LedgerFilterRule? {
        drafts[field] = text
        return self.rule(
            after: LedgerFilterNumberDraft(text: text, conversion: conversion),
            inField: field, of: rule, operand: operand
        )
    }

    /// Whether some field of the rule holds text that is not a number.
    var isHoldingUnreadableDraft: Bool { !unreadable.isEmpty }

    /// The words under the rule while it is off for an unreadable number, `nil` otherwise.
    var hint: String? {
        guard !unreadable.isEmpty else { return nil }
        if unreadable.values.contains(.notANumber) {
            return NSLocalizedString(
                "Not a number. This rule is off until the value reads as a number.",
                comment: "Ledger filter hint under a rule whose number field does not parse"
            )
        }
        return NSLocalizedString(
            "Enter a number. This rule is off until it has one.",
            comment: "Ledger filter hint under a rule whose number field is empty"
        )
    }

    /// The rule to publish after `field` reads `draft`, or `nil` when the rule does not change.
    ///
    /// - Parameter operand: builds the rule's operand from the field's SI value.
    mutating func rule(
        after draft: LedgerFilterNumberDraft,
        inField field: Int,
        of rule: LedgerFilterRule,
        operand: (Decimal) -> LedgerFilterOperand
    ) -> LedgerFilterRule? {
        switch draft {
        case let .number(value):
            unreadable[field] = nil
            var isEnabled = rule.isEnabled
            if suspendedByDraft, unreadable.isEmpty {
                isEnabled = true
                suspendedByDraft = false
            }
            return LedgerFilterRule(
                id: rule.id, column: rule.column, comparison: rule.comparison,
                operand: operand(value), isEnabled: isEnabled
            )
        case .empty, .notANumber:
            unreadable[field] = draft
            guard rule.isEnabled else { return nil }
            suspendedByDraft = true
            return LedgerFilterRule(
                id: rule.id, column: rule.column, comparison: rule.comparison,
                operand: rule.operand, isEnabled: false
            )
        }
    }

    /// A field's draft was replaced by the stored value; it no longer holds unreadable text.
    mutating func dropDraft(inField field: Int) {
        drafts[field] = nil
        unreadable[field] = nil
        if unreadable.isEmpty { suspendedByDraft = false }
    }

    /// The person switched the rule on or off: their choice stands from now on.
    mutating func personToggledRule() {
        suspendedByDraft = false
    }

    /// The operand is being rebuilt for a new column or comparison, so the fields and their
    /// drafts go — the typed text too, so the field shows the operand the rule now applies
    /// (U-057). Returns whether the rebuilt rule is enabled: as it was, or back on when only a
    /// draft had switched it off.
    mutating func operandReplaced(wasEnabled: Bool) -> Bool {
        let isEnabled = wasEnabled || suspendedByDraft
        self = LedgerFilterNumberFields()
        return isEnabled
    }
}
