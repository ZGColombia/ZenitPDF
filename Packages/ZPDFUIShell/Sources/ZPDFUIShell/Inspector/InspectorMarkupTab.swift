import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Markup tab: the mockup's form, top to bottom — Label, the measured quantities, colour
/// and opacity, border, style, notes, layer, review status, author, created and modified.
///
/// Every value comes from the selection and every edit goes through the same bulk-edit path
/// the ledger uses, so one change over a multi-selection is one undo step and a field the
/// selection disagrees about stays mixed until somebody deliberately sets it.
extension InspectorPanel {

    @ViewBuilder
    func markupTab(_ summary: InspectorSelectionSummary) -> some View {
        let ids = Set(summary.markups.map(\.id))
        InspectorCard {
            InspectorStackedRow(label: NSLocalizedString("Label", comment: "Inspector row label: the markup's short instance label")) {
                InspectorTextEditField(
                    current: summary.common(\.label),
                    isEnabled: canEditText(summary),
                    accessibilityTitle: NSLocalizedString("Label", comment: "Accessibility label of the inspector's label field"),
                    style: .boxed
                ) { applyText($0, column: .label, to: summary) }
                .id(ids)
            }

            quantityRows(summary)

            // r2-measure (NL-MEASURE-07): depth, heights and slope, edited in place.
            parameterRows(summary)
            // r2-measure (NL-MEASURE-09): what the pill shows and where.
            captionRows(summary)

            appearanceForm(summary)

            // NL-COLLAB-18: a text box's drawn words, apart from its Notes.
            drawnTextRow(summary)

            InspectorStackedRow(label: NSLocalizedString("Notes", comment: "Inspector row label: the markup's free-text comment")) {
                InspectorTextEditField(
                    current: summary.common(\.comment),
                    isEnabled: canEditText(summary),
                    accessibilityTitle: NSLocalizedString("Notes", comment: "Accessibility label of the inspector's notes field"),
                    style: .boxedMultiline,
                    wantsFocus: notesFocusRequest
                ) { applyText($0, column: .comment, to: summary) }
                .id(ids)
            }

            InspectorInlineRow(label: NSLocalizedString("Layer", comment: "Inspector row label")) {
                layerValue(summary)
            }

            InspectorInlineRow(label: NSLocalizedString("Status", comment: "Inspector row label: review status")) {
                statusMenu(summary)
            }

            InspectorInlineRow(label: NSLocalizedString("Author", comment: "Inspector row label")) {
                if let author = summary.common(\.author) {
                    HStack(spacing: ZPDFSpacing.m) {
                        InspectorAvatar(author: author)
                        Text(author.isEmpty ? InspectorAppearanceText.none : author)
                            .zpdfText(.control, .textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(NSLocalizedString("Author", comment: "Inspector row label")))
                    .accessibilityValue(Text(author))
                } else {
                    Text(InspectorSelectionSummary.mixedPlaceholder).zpdfText(.control, .textSecondary)
                }
            }

            timestampRow(
                label: NSLocalizedString("Created", comment: "Inspector row label: creation time"),
                value: summary.common(\.created)
            )
            timestampRow(
                label: NSLocalizedString("Modified", comment: "Inspector row label"),
                value: summary.common(\.modified)
            )
        }
    }

    // MARK: - Quantities

    /// One row per measured field the whole selection shares, with the value restated in the
    /// other unit system beneath the display unit — "620.0 ft²  57.6 m²".
    @ViewBuilder
    private func quantityRows(_ summary: InspectorSelectionSummary) -> some View {
        let model = InspectorMeasurementModel(environment: environment, selection: summary)
        let rows = model.valueRows
        if model.hasAnyQuantities {
            if rows.isEmpty {
                // BH-287: a length and an area share no field.
                Text(NSLocalizedString(
                    "The selected markups measure different quantities.",
                    comment: "Inspector measurement section when a mixed-kind selection shares no field"
                ))
                .zpdfText(.caption, .textSecondary)
            } else {
                InspectorRowDivider()
                ForEach(rows) { row in
                    InspectorQuantityRow(
                        label: Self.quantityLabel(for: row),
                        primary: row.text,
                        secondary: InspectorMarkupFormatting.secondaryText(
                            for: row.id, isTotal: row.isTotal, in: summary
                        ),
                        repetition: row.repetition
                    )
                    InspectorRowDivider()
                }
            }
        }
    }

    /// The quantity row's label: the field's own name ("Plan Area", "Perimeter"), prefixed
    /// "Total" when several markups are summed.
    static func quantityLabel(for row: InspectorMeasurementModel.ValueRow) -> String {
        guard row.isTotal else { return row.id.displayName }
        return String(
            format: NSLocalizedString(
                "Total %@", comment: "Inspector row label: the sum of one measured field over the selection"
            ),
            row.id.displayName
        )
    }

    // MARK: - Appearance

    @ViewBuilder
    private func appearanceForm(_ summary: InspectorSelectionSummary) -> some View {
        let enabled = canEditAppearance(summary)
        let fills = summary.markups.allSatisfy(InspectorMarkupFormatting.acceptsFill)
        // Fill Colour: the swatch and the fill's own opacity, as the mockup's first swatch
        // line. Only where every selected markup has an interior to fill.
        if fills {
            fillRow(summary, enabled: enabled)
        }

        // Border: the markup's colour — its stroke — and width.
        InspectorInlineRow(label: NSLocalizedString("Border", comment: "Inspector row label: the stroke colour and width")) {
            HStack(spacing: ZPDFSpacing.l) {
                colourWell(summary, enabled: enabled)
                InspectorNumberControl(
                    value: summary.common(\.lineWidth),
                    isMixed: summary.isMixed(\.lineWidth),
                    isEnabled: enabled,
                    range: InspectorStyleEditing.lineWidthRange,
                    step: 0.25,
                    suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
                    accessibilityLabel: NSLocalizedString("Line width in points", comment: "Accessibility label")
                ) { applyStyle(MarkupStyleEdit(lineWidth: $0), to: summary) }
            }
        }

        // The markup's own opacity (`MarkupStyle.opacity`) multiplies stroke and fill alike —
        // the canvas calls it the ink opacity. Beside a Fill Colour row that has an Opacity
        // of its own, the row says which one it is, on one line.
        InspectorInlineRow(label: fills
            ? NSLocalizedString("Ink opacity", comment: "Inspector row label: the opacity of the whole markup, stroke and fill, beside a fill opacity")
            : NSLocalizedString("Opacity", comment: "Inspector row label")
        ) {
            opacityControl(summary, enabled: enabled)
                .help(NSLocalizedString(
                    "The opacity of the whole markup, stroke and fill together.",
                    comment: "Inspector ink opacity help"
                ))
        }

        InspectorInlineRow(label: NSLocalizedString("Style", comment: "Inspector row label: solid, dashed, dotted…")) {
            InspectorLineStyleControl(
                value: summary.common(\.lineStyle),
                isMixed: summary.isMixed(\.lineStyle),
                isEnabled: enabled,
                isBoxed: true,
                offersCloud: summary.markups.allSatisfy { Self.drawsCloudStyle($0.kind) }
            ) { applyStyle(MarkupStyleEdit(lineStyle: $0), to: summary) }
        }

        // nl-markup: line ends for open markups (NL-MARKUP-07).
        lineEndsRow(summary, enabled: enabled)

        // Text size, only for the kinds that carry text: a font size on an arrow is a
        // control that does nothing.
        if summary.markups.contains(where: { Self.carriesText($0.kind) }) {
            InspectorInlineRow(label: NSLocalizedString("Text size", comment: "Inspector row label")) {
                InspectorNumberControl(
                    value: summary.common(\.fontSize),
                    isMixed: summary.isMixed(\.fontSize),
                    isEnabled: enabled,
                    range: InspectorStyleEditing.fontSizeRange,
                    step: 1,
                    suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
                    accessibilityLabel: NSLocalizedString("Text size in points", comment: "Accessibility label")
                ) { applyStyle(MarkupStyleEdit(fontSize: $0), to: summary) }
            }
        }

        // nl-markup: font family and alignment for text and callouts (NL-MARKUP-08).
        textFormattingRows(summary, enabled: enabled)
        // r2-markup (ADR-0029): text style, arc size, rotation, link, group.
        round2Rows(summary, enabled: enabled)
        setAsDefaultRow(summary)

        // IM-117: a refused edit says so, next to the controls that asked for it.
        if let refusal = environment.inspectorEditing.lastStyleRefusal {
            HStack(alignment: .top, spacing: ZPDFSpacing.s) {
                ZPDFInlineWarning(severity: .warning, message: refusal)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Dismiss", comment: "Clears the Inspector's style edit refusal")) {
                    environment.inspectorEditing.lastStyleRefusal = nil
                }
                .buttonStyle(.link)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func colourWell(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        InspectorColourControl(
            value: summary.common(\.colorRGBA),
            isMixed: summary.isMixed(\.colorRGBA),
            isEnabled: enabled,
            showsHex: false,
            accessibilityTitle: NSLocalizedString("Border colour", comment: "Accessibility label of the inspector's stroke colour well"),
            role: "border",
            services: InspectorColourServices(environment: environment)
        ) { applyStyle(MarkupStyleEdit(color: $0), to: summary) }
        // A new selection is a new swatch: a colour panel left open for the old one is closed
        // rather than retargeted, so it can never write the old pick onto the new selection.
        .id(Set(summary.markups.map(\.id)))
    }

    /// The Fill Colour row. The swatch and the percentage show the fill the canvas draws — the
    /// stored fill, or the 20 % stroke tint a closed area gets without one — so what the row says
    /// is what the page shows. A picked colour keeps the current fill opacity; the percentage
    /// rewrites only the fill's alpha, and needs one shared fill colour to do that.
    @ViewBuilder
    private func fillRow(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        let effective = InspectorSelectionSummary.commonValue(summary.markups.map(InspectorMarkupFormatting.effectiveFill))
        // `commonValue` answers `nil` only when the markups disagree; `.some(nil)` is a
        // selection that agrees on having no fill.
        let isMixed = effective == nil
        let shared: ColorRGBA? = effective ?? nil
        let alpha = shared?.alpha
        let removable = InspectorStyleEditing.canRemoveFill(summary.markups)
        let well = InspectorColourControl(
            value: shared,
            isMixed: isMixed,
            isEnabled: enabled,
            showsHex: false,
            accessibilityTitle: NSLocalizedString("Fill colour", comment: "Accessibility label of the inspector's fill colour well"),
            role: "fill",
            noneChoice: removable
                ? (
                    title: NSLocalizedString("No Fill", comment: "Colour palette: removes the markup's fill"),
                    action: { applyStyle(MarkupStyleEdit(removesFill: true), to: summary) }
                )
                : nil,
            services: InspectorColourServices(environment: environment)
        ) { picked in
            var fill = picked
            fill.alpha = alpha ?? InspectorMarkupFormatting.derivedFillAlpha
            applyStyle(MarkupStyleEdit(fill: fill), to: summary)
        }
        .id(Set(summary.markups.map(\.id)))
        let opacity = InspectorNumberControl(
            value: alpha.map { $0 * 100 },
            isMixed: alpha == nil,
            isEnabled: enabled && shared != nil,
            range: InspectorStyleEditing.fillOpacityPercentRange,
            step: 5,
            suffix: "%",
            accessibilityLabel: NSLocalizedString("Fill opacity percentage", comment: "Accessibility label")
        ) { percent in
            guard var fill = shared else { return }
            fill.alpha = percent / 100
            applyStyle(MarkupStyleEdit(fill: fill), to: summary)
        }
        let fillLabel = NSLocalizedString("Fill Colour", comment: "Inspector row label: the markup's interior colour")
        // The mockup's one line when it fits; the swatch and the percentage on two rows in a
        // narrow panel.
        ViewThatFits(in: .horizontal) {
            InspectorInlineRow(label: fillLabel) {
                HStack(spacing: ZPDFSpacing.xs) {
                    well
                    if removable { removeFillButton(summary, enabled: enabled) }
                    Spacer(minLength: 0)
                    Text(NSLocalizedString("Opacity", comment: "Inspector row label"))
                        .zpdfText(.control, .textSecondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                    opacity
                }
            }
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorInlineRow(label: fillLabel) {
                    HStack(spacing: ZPDFSpacing.m) {
                        well
                        if removable { removeFillButton(summary, enabled: enabled) }
                    }
                }
                InspectorInlineRow(label: NSLocalizedString("Fill opacity", comment: "Inspector row label: the fill's own opacity")) {
                    opacity
                }
            }
        }
    }

    private func opacityControl(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        InspectorNumberControl(
            value: summary.common(\.opacity).map { $0 * 100 },
            isMixed: summary.isMixed(\.opacity),
            isEnabled: enabled,
            // R-084: the style strip's limit; this field went to 0 % and the strip stopped at 5.
            range: InspectorStyleEditing.markupOpacityPercentRange,
            step: 5,
            suffix: "%",
            accessibilityLabel: NSLocalizedString("Opacity percentage", comment: "Accessibility label")
        ) { applyStyle(MarkupStyleEdit(opacity: $0 / 100), to: summary) }
    }

    /// The Remove Fill button's marker, which the hit-target probe checks the fill swatch
    /// against: the old hosted well overhung it by 8 pt.
    static let removeFillMarker = "zpdf.inspector.remove-fill"

    private func removeFillButton(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        Button {
            applyStyle(MarkupStyleEdit(removesFill: true), to: summary)
        } label: {
            ZPDFGlyphView(.symbol(.close), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.textSecondary)
                .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zpdfMarker(Self.removeFillMarker)
        .disabled(!enabled)
        .help(NSLocalizedString(
            "Remove the fill. A closed area goes back to its standard tint.",
            comment: "Inspector: remove fill button help"
        ))
        .accessibilityLabel(Text(NSLocalizedString("Remove Fill", comment: "Inspector: remove fill button")))
    }

    // MARK: - Status

    /// The review status as a popup with its tint dot. The dot is a redundant cue: the name is
    /// always written beside it.
    @ViewBuilder
    private func statusMenu(_ summary: InspectorSelectionSummary) -> some View {
        let current = summary.common(\.status)
        let enabled = canEditText(summary)
        InspectorPopup(
            title: current?.displayName ?? InspectorSelectionSummary.mixedPlaceholder,
            dot: current.map { InspectorMarkupFormatting.severity(for: $0).tint },
            isEnabled: enabled
        ) {
            ForEach(MarkupStatus.allCases) { status in
                Button {
                    applyStatus(status, to: summary)
                } label: {
                    if status == current {
                        Label(status.displayName, systemImage: "checkmark")
                    } else {
                        Text(status.displayName)
                    }
                }
            }
            // NL-COLLAB-03: a status change that says why — "Rejected, see RFI 12" — as a note
            // on every selected markup's thread.
            if environment.inspectorEditing.onRequestStatusNote != nil {
                Divider()
                Button(NSLocalizedString("Set Status with Note…", comment: "Inspector status popup: set a status and write why")) {
                    environment.inspectorEditing.onRequestStatusNote?(Set(summary.markups.map(\.id)))
                }
            }
        }
        .help(InspectorAppearanceText.helpText(isEnabled: enabled))
        .accessibilityLabel(Text(NSLocalizedString("Review status", comment: "Accessibility label of the inspector's status popup")))
        .accessibilityValue(Text(current?.displayName ?? InspectorSelectionSummary.mixedPlaceholder))
    }

    // MARK: - Timestamps

    @ViewBuilder
    private func timestampRow(label: String, value: Date?) -> some View {
        InspectorInlineRow(label: label) {
            if let value {
                let parts = InspectorMarkupFormatting.dateAndTime(value)
                // Date and time side by side while they fit, else the time under the date — never
                // "27 Sep 20…" with the time gone (L-14).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ZPDFSpacing.l) {
                        Text(parts.date).zpdfText(.monoNumeric, .textPrimary).lineLimit(1).fixedSize()
                        Text(parts.time).zpdfText(.monoNumeric, .textPrimary).lineLimit(1).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(parts.date).zpdfText(.monoNumeric, .textPrimary).lineLimit(1)
                        Text(parts.time).zpdfText(.monoNumeric, .textPrimary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(verbatim: "\(parts.date) \(parts.time)"))
            } else {
                Text(InspectorSelectionSummary.mixedPlaceholder).zpdfText(.control, .textSecondary)
            }
        }
    }
}
