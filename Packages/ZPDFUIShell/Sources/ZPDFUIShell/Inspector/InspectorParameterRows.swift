import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One option of a choice row (NL-MEASURE-10's Display units): the id handed back on commit and
/// the words the menu shows.
public struct InspectorParameterChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One editable measurement parameter as the Inspector shows it (NL-MEASURE-07).
public struct InspectorParameterRowModel: Identifiable, Hashable, Sendable {
    /// Stable identity, handed back on commit ("depth", "slope").
    public let id: String
    /// The row's label ("Depth").
    public let title: String
    /// The value as typed or stored, in the display unit; empty when unset or mixed.
    public let text: String
    public let isMixed: Bool
    /// The unit after the field ("mm"); empty for a unitless value.
    public let unitSymbol: String
    /// The forms the field accepts, for the tooltip ("6:12, 26.57°, 50 %, 0.5").
    public let help: String
    /// The options of a choice row; empty for a typed value. A choice row shows a menu, and a
    /// pick commits the option's ``InspectorParameterChoice/id`` as the row's text.
    public let choices: [InspectorParameterChoice]

    public init(
        id: String,
        title: String,
        text: String,
        isMixed: Bool,
        unitSymbol: String,
        help: String = "",
        choices: [InspectorParameterChoice] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.isMixed = isMixed
        self.unitSymbol = unitSymbol
        self.help = help
        self.choices = choices
    }

    /// What a choice row's menu reads: the chosen option, the mixed placeholder, or "Custom" for
    /// a stored value none of the options wrote.
    public var choiceLabel: String {
        if isMixed { return InspectorSelectionSummary.mixedPlaceholder }
        return choices.first { $0.id == text }?.title
            ?? NSLocalizedString("Custom", comment: "Inspector choice row: a stored value none of the menu's options describes")
    }
}

/// The parameter rows of the Markup tab (NL-MEASURE-07): each commit is one undoable
/// `editParameters` step over the whole selection, recomputed by the engine.
extension InspectorPanel {

    @ViewBuilder
    func parameterRows(_ summary: InspectorSelectionSummary) -> some View {
        let ids = Set(summary.markups.map(\.id))
        let editing = environment.inspectorEditing
        // NL-MEASURE-03: a value kept under an older scale says so, in words, with the way out.
        if summary.markups.contains(where: { $0.warnings.contains(.staleScaleVersion) }) {
            HStack(alignment: .top, spacing: ZPDFSpacing.s) {
                ZPDFInlineWarning(severity: .warning, message: MeasurementWarningSummary.staleScaleVersion.message)
                Spacer(minLength: 0)
                if let recalculate = editing.onRecalculateStale {
                    Button(NSLocalizedString("Recalculate", comment: "Inspector: bring values kept under an older scale to the current one")) {
                        recalculate()
                    }
                    .buttonStyle(.link)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if editing.parameterRowsSelection == ids, !editing.parameterRows.isEmpty {
            ForEach(editing.parameterRows) { row in
                if !row.choices.isEmpty {
                    choiceRow(row, ids: ids, isEnabled: editing.onEditParameter != nil && summary.markups.allSatisfy { !$0.locked })
                } else {
                    InspectorInlineRow(label: row.title) {
                        HStack(spacing: ZPDFSpacing.m) {
                            InspectorTextEditField(
                                current: row.isMixed ? nil : row.text,
                                isEnabled: editing.onEditParameter != nil && summary.markups.allSatisfy { !$0.locked },
                                accessibilityTitle: row.unitSymbol.isEmpty
                                    ? row.title
                                    : String(format: NSLocalizedString("%1$@ in %2$@", comment: "Accessibility label: a parameter and its unit"), row.title, row.unitSymbol),
                                style: .boxed
                            ) { text in
                                guard text != row.text, !(row.isMixed && text.isEmpty) else { return }
                                editing.onEditParameter?(ids, row.id, text)
                            }
                            .id(ids)
                            .help(row.help)
                            if !row.unitSymbol.isEmpty {
                                Text(row.unitSymbol).zpdfText(.control, .textSecondary)
                            }
                        }
                    }
                }
            }
            if editing.parameterRows.contains(where: { $0.id == "slope" }), let pick = editing.onPickFallLine {
                InspectorInlineRow(label: NSLocalizedString("Fall line", comment: "Inspector row label: the slope's downhill-to-uphill direction")) {
                    Button(NSLocalizedString("Pick Fall Line…", comment: "Inspector button: two clicks on the sheet set the slope's direction")) {
                        pick(ids)
                    }
                    .help(NSLocalizedString(
                        "Click the low point, then the high point, on the sheet.",
                        comment: "Help for Pick Fall Line"
                    ))
                }
            }
            if let refusal = editing.parameterRefusal {
                ZPDFInlineWarning(severity: .warning, message: refusal)
            }
        }
    }
}

extension InspectorPanel {

    /// A parameter row that is a choice, not a typed value (NL-MEASURE-10's Display units): a
    /// menu whose pick is one undoable `editParameters` step over the selection.
    @ViewBuilder
    func choiceRow(_ row: InspectorParameterRowModel, ids: Set<UUID>, isEnabled: Bool) -> some View {
        let editing = environment.inspectorEditing
        InspectorInlineRow(label: row.title) {
            Menu {
                ForEach(row.choices) { choice in
                    Button {
                        guard choice.id != row.text || row.isMixed else { return }
                        editing.onEditParameter?(ids, row.id, choice.id)
                    } label: {
                        if !row.isMixed, choice.id == row.text {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                Text(row.choiceLabel).lineLimit(1).truncationMode(.tail)
            }
            .disabled(!isEnabled)
            .help(row.help)
            .accessibilityLabel(Text(row.title))
            .accessibilityValue(Text(row.choiceLabel))
        }
    }
}

/// The Caption row's state (NL-MEASURE-09): which fields the selection can show, which it shows,
/// whether it labels its segments, and whether a label was dragged.
public struct InspectorCaptionState: Hashable, Sendable {
    public let selection: Set<UUID>
    /// Fields every selected markup has, in display order.
    public let availableFields: [MeasurementField]
    /// The fields shown, in order; empty is the headline alone; `nil` when the selection disagrees.
    public let chosenFields: [MeasurementField]?
    /// The tool's headline field, which an empty choice shows.
    public let headline: MeasurementField?
    /// Whether every selected markup can label its segments.
    public let offersSegmentLengths: Bool
    /// Whether they do; `nil` when mixed.
    public let showsSegmentLengths: Bool?
    /// Whether any selected label was dragged off its automatic place.
    public let hasLabelOffset: Bool

    public init(
        selection: Set<UUID>,
        availableFields: [MeasurementField],
        chosenFields: [MeasurementField]?,
        headline: MeasurementField?,
        offersSegmentLengths: Bool,
        showsSegmentLengths: Bool?,
        hasLabelOffset: Bool
    ) {
        self.selection = selection
        self.availableFields = availableFields
        self.chosenFields = chosenFields
        self.headline = headline
        self.offersSegmentLengths = offersSegmentLengths
        self.showsSegmentLengths = showsSegmentLengths
        self.hasLabelOffset = hasLabelOffset
    }

    /// What the pill shows for a choice: the chosen fields, or the headline alone.
    public var shownFields: [MeasurementField] {
        guard let chosenFields else { return [] }
        return chosenFields.isEmpty ? headline.map { [$0] } ?? [] : chosenFields
    }

    /// The choice after toggling one field: added at the end or removed; the headline stays first
    /// when the pill would otherwise show nothing.
    public func toggling(_ field: MeasurementField) -> [MeasurementField] {
        var fields = shownFields
        if let index = fields.firstIndex(of: field) {
            fields.remove(at: index)
        } else {
            fields.append(field)
        }
        if fields.isEmpty, let headline { fields = [headline] }
        return fields == headline.map({ [$0] }) ? [] : fields
    }
}

extension InspectorPanel {

    /// The Caption row (NL-MEASURE-09): which values the pill shows, per-segment lengths, and the
    /// way back from a dragged label. Each change is one undoable style edit.
    @ViewBuilder
    func captionRows(_ summary: InspectorSelectionSummary) -> some View {
        let ids = Set(summary.markups.map(\.id))
        let editing = environment.inspectorEditing
        if let state = editing.captionState, state.selection == ids, !state.availableFields.isEmpty {
            let enabled = summary.markups.allSatisfy { !$0.locked }
            InspectorInlineRow(label: NSLocalizedString("Caption", comment: "Inspector row label: what a measurement's pill shows")) {
                Menu {
                    ForEach(state.availableFields, id: \.self) { field in
                        Button {
                            editing.onSetCaptionFields?(ids, state.toggling(field))
                        } label: {
                            if state.shownFields.contains(field) {
                                Label(field.displayName, systemImage: "checkmark")
                            } else {
                                Text(field.displayName)
                            }
                        }
                    }
                } label: {
                    Text(state.chosenFields == nil
                         ? InspectorSelectionSummary.mixedPlaceholder
                         : state.shownFields.map(\.displayName).joined(separator: ", "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .disabled(!enabled || editing.onSetCaptionFields == nil)
                .accessibilityLabel(Text(NSLocalizedString("Caption fields", comment: "Accessibility label of the Inspector caption menu")))
            }
            if state.offersSegmentLengths {
                InspectorInlineRow(label: NSLocalizedString("Segment lengths", comment: "Inspector row label: label every segment with its length")) {
                    Toggle(isOn: Binding(
                        get: { state.showsSegmentLengths ?? false },
                        set: { editing.onSetSegmentLengths?(ids, $0) }
                    )) {
                        EmptyView()
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!enabled || editing.onSetSegmentLengths == nil)
                    .accessibilityLabel(Text(NSLocalizedString("Segment lengths", comment: "Accessibility label of the segment lengths switch")))
                }
            }
            if state.hasLabelOffset, let reset = editing.onResetLabelPosition {
                InspectorInlineRow(label: NSLocalizedString("Label", comment: "Inspector row label: the caption's position")) {
                    Button(NSLocalizedString("Reset Label Position", comment: "Inspector button: put a dragged caption back")) { reset(ids) }
                        .disabled(!enabled)
                }
            }
        }
    }
}
