import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The contextual style strip (NL-MARKUP-03, round 2): "change it where I'm looking".
///
/// It lives in the tool options slot above the canvas and keeps that slot's rule — it is there
/// only when it has something to say. With markups selected it edits the selection (one bulk
/// edit per change, exactly the Inspector's path, so undo names and audit are shared); with a
/// markup tool armed and nothing selected it edits the tool's style, so the next markup takes it.
/// A measurement-only selection has no strip: its look is the Inspector's business.
///
/// Every control is one the Inspector already uses, so the mixed-value rules live in one place.
public struct MarkupStyleStrip: View {

    let environment: ProjectShellEnvironment

    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    /// What the strip is editing.
    public enum Target: Equatable {
        /// The selected markups.
        case selection(InspectorSelectionSummary.IDs)
        /// The armed markup tool's style.
        case tool(MarkupKind)
    }

    /// The strip's target, or `nil` when it has nothing to show.
    @MainActor
    public static func target(in environment: ProjectShellEnvironment) -> Target? {
        target(selected: environment.canvas.resolvedSelectedMarkups, armed: environment.toolbar.activeSelection.mode)
    }

    /// The rule, value-only: a selection of markups a tool draws, else an armed markup tool.
    public static func target(selected: [MarkupSummary], armed: ZenitToolMode) -> Target? {
        if !selected.isEmpty {
            // A selection of markups a tool draws (at least one, and no measurement): a
            // measured area's look is a statement about the area, edited in the Inspector.
            guard selected.allSatisfy({ $0.measurementKind == nil }),
                  selected.contains(where: { ZenitToolMode.isDrawable($0.kind) })
            else { return nil }
            return .selection(InspectorSelectionSummary.IDs(selected.map(\.id)))
        }
        if let kind = armed.markupKind, ZenitToolMode.isDrawable(kind) {
            return .tool(kind)
        }
        return nil
    }

    @MainActor
    public static func shows(in environment: ProjectShellEnvironment) -> Bool {
        target(in: environment) != nil
    }

    /// Whether the fill palette offers "No Fill": only when there is a stored fill to remove,
    /// the Inspector's rule (S-051). It used to be offered always, and did nothing over a
    /// markup with no stored fill.
    @MainActor
    static func offersNoFill(_ summary: InspectorSelectionSummary) -> Bool {
        InspectorStyleEditing.canRemoveFill(summary.markups)
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.m) {
            switch Self.target(in: environment) {
            case .selection?:
                selectionControls(InspectorSelectionSummary(markups: environment.canvas.resolvedSelectedMarkups))
            case let .tool(kind)?:
                toolControls(kind: kind, style: environment.toolbar.activeSelection.style)
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Markup style", comment: "Accessibility label of the style strip")))
    }

    // MARK: Selection

    @ViewBuilder
    private func selectionControls(_ summary: InspectorSelectionSummary) -> some View {
        let enabled = !summary.markups.contains(where: \.locked) && environment.ledger is any LedgerBulkEditPresenting
        let label = summary.count == 1
            ? (summary.markups.first?.kind.displayName ?? "")
            : String(format: NSLocalizedString("%ld markups", comment: "Style strip: how many markups it edits"), summary.count)
        Text(label).zpdfText(.caption, .textSecondary).lineLimit(1)
        ZPDFHairlineDivider(axis: .vertical)
        InspectorColourControl(
            value: summary.common(\.colorRGBA),
            isMixed: summary.isMixed(\.colorRGBA),
            isEnabled: enabled,
            showsHex: false,
            accessibilityTitle: NSLocalizedString("Colour", comment: "Style strip: the markup colour"),
            role: "strip.colour",
            services: InspectorColourServices(environment: environment)
        ) { apply(MarkupStyleEdit(color: $0), to: summary) }
        .id(summary.markups.map(\.id))
        if summary.markups.allSatisfy(InspectorMarkupFormatting.acceptsFill) {
            let fill = InspectorSelectionSummary.commonValue(summary.markups.map(InspectorMarkupFormatting.effectiveFill))
            InspectorColourControl(
                value: fill ?? nil,
                isMixed: fill == nil,
                isEnabled: enabled,
                showsHex: false,
                accessibilityTitle: NSLocalizedString("Fill", comment: "Style strip: the fill colour"),
                role: "strip.fill",
                noneChoice: Self.offersNoFill(summary)
                    ? (
                        title: NSLocalizedString("No Fill", comment: "Colour palette: removes the markup's fill"),
                        action: { apply(MarkupStyleEdit(removesFill: true), to: summary) }
                    )
                    : nil,
                services: InspectorColourServices(environment: environment)
            ) { picked in
                var colour = picked
                colour.alpha = (fill ?? nil)?.alpha ?? InspectorMarkupFormatting.derivedFillAlpha
                apply(MarkupStyleEdit(fill: colour), to: summary)
            }
            .id(summary.markups.map(\.id))
        }
        widthField(value: summary.common(\.lineWidth), mixed: summary.isMixed(\.lineWidth), enabled: enabled) {
            apply(MarkupStyleEdit(lineWidth: $0), to: summary)
        }
        InspectorLineStyleControl(
            value: summary.common(\.lineStyle),
            isMixed: summary.isMixed(\.lineStyle),
            isEnabled: enabled,
            offersCloud: summary.markups.allSatisfy { InspectorPanel.drawsCloudStyle($0.kind) }
        ) { apply(MarkupStyleEdit(lineStyle: $0), to: summary) }
        if summary.markups.allSatisfy({ InspectorPanel.holdsLineEnds($0.kind) }) {
            endsMenus(
                start: InspectorSelectionSummary.commonValue(summary.markups.map { $0.startCap ?? .none }),
                end: InspectorSelectionSummary.commonValue(summary.markups.map { $0.endCap ?? .none }),
                enabled: enabled,
                onStart: { apply(MarkupStyleEdit(startCap: $0), to: summary) },
                onEnd: { apply(MarkupStyleEdit(endCap: $0), to: summary) }
            )
        }
        opacityField(value: summary.common(\.opacity), mixed: summary.isMixed(\.opacity), enabled: enabled) {
            apply(MarkupStyleEdit(opacity: $0), to: summary)
        }
        if summary.markups.allSatisfy(InspectorPanel.holdsTextFormatting) {
            textSizeField(value: summary.common(\.fontSize), mixed: summary.isMixed(\.fontSize), enabled: enabled) {
                apply(MarkupStyleEdit(fontSize: $0), to: summary)
            }
        }
    }

    // MARK: Armed tool

    @ViewBuilder
    private func toolControls(kind: MarkupKind, style: ToolStyleSelection) -> some View {
        Text(String(format: NSLocalizedString("Next %@", comment: "Style strip: it edits the armed tool's next markup; the kind"), kind.displayName))
            .zpdfText(.caption, .textSecondary)
            .lineLimit(1)
        ZPDFHairlineDivider(axis: .vertical)
        InspectorColourControl(
            value: style.stroke,
            isMixed: false,
            isEnabled: true,
            showsHex: false,
            accessibilityTitle: NSLocalizedString("Colour", comment: "Style strip: the markup colour"),
            role: "strip.tool.colour",
            services: InspectorColourServices(environment: environment)
        ) { applyToTool(MarkupStyleEdit(color: $0)) }
        widthField(value: style.lineWidth, mixed: false, enabled: true) { applyToTool(MarkupStyleEdit(lineWidth: $0)) }
        InspectorLineStyleControl(
            value: style.lineStyle ?? (kind == .cloud ? .cloud : .solid),
            isMixed: false,
            isEnabled: true,
            offersCloud: InspectorPanel.drawsCloudStyle(kind)
        ) { applyToTool(MarkupStyleEdit(lineStyle: $0)) }
        if InspectorPanel.holdsLineEnds(kind) {
            endsMenus(
                start: style.startCap ?? .none,
                end: style.endCap ?? (kind == .arrow ? .closedArrow : (kind == .callout ? .openArrow : .none)),
                enabled: true,
                onStart: { applyToTool(MarkupStyleEdit(startCap: $0)) },
                onEnd: { applyToTool(MarkupStyleEdit(endCap: $0)) }
            )
        }
        opacityField(value: style.opacity, mixed: false, enabled: true) { applyToTool(MarkupStyleEdit(opacity: $0)) }
        if InspectorPanel.holdsTextFormatting(kind) {
            textSizeField(value: style.fontSize, mixed: false, enabled: true) { applyToTool(MarkupStyleEdit(fontSize: $0)) }
        }
    }

    // MARK: Controls

    private func widthField(value: Double?, mixed: Bool, enabled: Bool, onChange: @escaping (Double) -> Void) -> some View {
        InspectorNumberControl(
            value: value, isMixed: mixed, isEnabled: enabled, range: InspectorStyleEditing.lineWidthRange, step: 0.25,
            suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
            accessibilityLabel: NSLocalizedString("Line width in points", comment: "Accessibility label"),
            onChange: onChange
        )
        .frame(maxWidth: 88)
    }

    private func opacityField(value: Double?, mixed: Bool, enabled: Bool, onChange: @escaping (Double) -> Void) -> some View {
        InspectorNumberControl(
            value: value.map { $0 * 100 }, isMixed: mixed, isEnabled: enabled,
            range: InspectorStyleEditing.markupOpacityPercentRange, step: 5, suffix: "%",
            accessibilityLabel: NSLocalizedString("Opacity percentage", comment: "Accessibility label"),
            onChange: { onChange($0 / 100) }
        )
        .frame(maxWidth: 80)
    }

    private func textSizeField(value: Double?, mixed: Bool, enabled: Bool, onChange: @escaping (Double) -> Void) -> some View {
        InspectorNumberControl(
            value: value, isMixed: mixed, isEnabled: enabled, range: InspectorStyleEditing.fontSizeRange, step: 1,
            suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
            accessibilityLabel: NSLocalizedString("Text size in points", comment: "Accessibility label"),
            onChange: onChange
        )
        .frame(maxWidth: 80)
    }

    private func endsMenus(
        start: MarkupLineCap?,
        end: MarkupLineCap?,
        enabled: Bool,
        onStart: @escaping (MarkupLineCap) -> Void,
        onEnd: @escaping (MarkupLineCap) -> Void
    ) -> some View {
        HStack(spacing: ZPDFSpacing.xs) {
            InspectorChoiceControl(
                choices: MarkupLineCap.offered, value: start, isEnabled: enabled,
                accessibilityLabel: NSLocalizedString("Start of line", comment: "Accessibility label of the line start decoration menu"),
                name: { $0.displayName }, onChange: onStart
            )
            InspectorChoiceControl(
                choices: MarkupLineCap.offered, value: end, isEnabled: enabled,
                accessibilityLabel: NSLocalizedString("End of line", comment: "Accessibility label of the line end decoration menu"),
                name: { $0.displayName }, onChange: onEnd
            )
        }
    }

    // MARK: Writing

    /// One bulk edit over the selection, the Inspector's own path.
    @MainActor
    func apply(_ edit: MarkupStyleEdit, to summary: InspectorSelectionSummary) {
        InspectorStyleEditing.apply(edit, to: summary, in: environment)
    }

    /// The armed tool's next markup takes the edit.
    @MainActor
    func applyToTool(_ edit: MarkupStyleEdit) {
        let toolbar = environment.toolbar
        toolbar.setStyle(ZenitToolbarModel.style(toolbar.activeSelection.style, applying: edit))
    }
}

extension InspectorSelectionSummary {
    /// A selection's identity, for the strip's target.
    public struct IDs: Hashable, Sendable {
        public let ids: [UUID]
        public init(_ ids: [UUID]) { self.ids = ids }
    }
}
