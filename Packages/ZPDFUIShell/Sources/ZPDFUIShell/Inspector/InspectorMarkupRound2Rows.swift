import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector rows round 2 adds to the Markup tab (r2-markup, ADR-0029): bold, italic, text
/// colour and box border (NL-MARKUP-08), arc size (NL-MARKUP-16), rotation (NL-MARKUP-18), the
/// hyperlink's destination (NL-MARKUP-17) and the group (NL-MARKUP-11).
///
/// Same rules as every other Markup-tab row: one bulk edit per change, a mixed selection shows
/// "Mixed" and writes nothing until a value is chosen, a locked markup disables the row, and a
/// row appears only where every selected markup can take its value.
extension InspectorPanel {

    /// Whether a markup draws words: a Text, a Callout, or a clouded callout.
    public static func holdsTextFormatting(_ markup: MarkupSummary) -> Bool {
        holdsTextFormatting(markup.kind) || (markup.kind == .cloud && markup.drawnText != nil)
    }

    /// Whether a markup's outline scallops (a Cloud, or a closed shape in the Cloud style), so an
    /// arc size means something.
    public static func holdsArcSize(_ markup: MarkupSummary) -> Bool {
        markup.kind == .cloud || markup.kind == .revisionCloud
            || (drawsCloudStyle(markup.kind) && markup.lineStyle == .cloud)
    }

    /// Whether a markup turns by the Rotation row: text boxes and shapes, never a measurement or
    /// a stamp (a stamp has its own knob).
    public static func holdsRotation(_ markup: MarkupSummary) -> Bool {
        guard markup.measurementKind == nil else { return false }
        switch markup.kind {
        case .text, .callout, .line, .arrow, .polyline, .rectangle, .ellipse, .polygon, .cloud,
             .freehand, .hyperlink, .note, .image:
            return true
        default:
            return false
        }
    }

    /// Every round-2 row the selection can take, in form order.
    @ViewBuilder
    func round2Rows(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        textStyleRows(summary, enabled: enabled)
        arcSizeRow(summary, enabled: enabled)
        rotationRow(summary, enabled: enabled)
        linkRow(summary)
        groupRow(summary)
    }

    // MARK: Text style (NL-MARKUP-08)

    @ViewBuilder
    private func textStyleRows(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        if !summary.isEmpty, summary.markups.allSatisfy(Self.holdsTextFormatting) {
            let bold = InspectorSelectionSummary.commonValue(summary.markups.map { $0.bold ?? false })
            let italic = InspectorSelectionSummary.commonValue(summary.markups.map { $0.italic ?? false })
            InspectorInlineRow(label: NSLocalizedString("Text style", comment: "Inspector row label: bold and italic")) {
                HStack(spacing: ZPDFSpacing.xs) {
                    InspectorTraitToggle(
                        symbol: "bold",
                        title: NSLocalizedString("Bold", comment: "Inspector: bold text toggle"),
                        value: bold,
                        isEnabled: enabled
                    ) { applyStyle(Self.styleEdit(bold: $0), to: summary) }
                    InspectorTraitToggle(
                        symbol: "italic",
                        title: NSLocalizedString("Italic", comment: "Inspector: italic text toggle"),
                        value: italic,
                        isEnabled: enabled
                    ) { applyStyle(Self.styleEdit(italic: $0), to: summary) }
                }
            }
            let colours = summary.markups.map { $0.textColorRGBA }
            let shared = InspectorSelectionSummary.commonValue(colours)
            InspectorInlineRow(label: NSLocalizedString("Text colour", comment: "Inspector row label: the colour of the words, apart from the border")) {
                InspectorColourControl(
                    value: (shared ?? nil) ?? summary.common(\.colorRGBA),
                    isMixed: shared == nil,
                    isEnabled: enabled,
                    showsHex: false,
                    accessibilityTitle: NSLocalizedString("Text colour", comment: "Accessibility label of the inspector's text colour well"),
                    role: "text",
                    noneChoice: colours.contains { $0 != nil }
                        ? (
                            title: NSLocalizedString("Same as Border", comment: "Colour palette: the text follows the border colour again"),
                            action: { applyStyle(Self.styleEdit(removesTextColor: true), to: summary) }
                        )
                        : nil,
                    services: InspectorColourServices(environment: environment)
                ) { applyStyle(Self.styleEdit(textColor: $0), to: summary) }
                .id(Set(summary.markups.map(\.id)))
            }
            if summary.markups.allSatisfy({ $0.kind == .text }) {
                let border = InspectorSelectionSummary.commonValue(summary.markups.map { $0.boxBorder ?? false })
                InspectorInlineRow(label: NSLocalizedString("Box border", comment: "Inspector row label: whether a text box draws a frame")) {
                    InspectorTraitToggle(
                        symbol: "square",
                        title: NSLocalizedString("Draw a border round the text box", comment: "Inspector: text box border toggle"),
                        value: border,
                        isEnabled: enabled
                    ) { applyStyle(Self.styleEdit(boxBorder: $0), to: summary) }
                }
            }
        }
    }

    // MARK: Arc size (NL-MARKUP-16)

    @ViewBuilder
    private func arcSizeRow(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        if !summary.isEmpty, summary.markups.allSatisfy(Self.holdsArcSize) {
            let sizes = summary.markups.map(\.cloudArcSize)
            let shared = InspectorSelectionSummary.commonValue(sizes)
            InspectorInlineRow(label: NSLocalizedString("Arc size", comment: "Inspector row label: the size of a cloud's scallops")) {
                HStack(spacing: ZPDFSpacing.m) {
                    InspectorNumberControl(
                        value: shared ?? nil,
                        isMixed: shared == nil,
                        isEnabled: enabled,
                        range: 2...72,
                        step: 1,
                        suffix: NSLocalizedString("pt", comment: "Points, the PDF unit"),
                        accessibilityLabel: NSLocalizedString("Cloud arc size in points", comment: "Accessibility label")
                    ) { applyStyle(Self.styleEdit(cloudArcSize: $0), to: summary) }
                    Button(NSLocalizedString("Auto", comment: "Inspector: cloud arc size back to automatic")) {
                        applyStyle(Self.styleEdit(resetsCloudArcSize: true), to: summary)
                    }
                    .buttonStyle(.link)
                    .disabled(!enabled || sizes.allSatisfy { $0 == nil })
                    .help(NSLocalizedString("Scallops sized to the cloud, 8 to 18 pt.", comment: "Inspector: automatic arc size help"))
                }
            }
        }
    }

    // MARK: Rotation (NL-MARKUP-18)

    @ViewBuilder
    private func rotationRow(_ summary: InspectorSelectionSummary, enabled: Bool) -> some View {
        if !summary.isEmpty, summary.markups.allSatisfy(Self.holdsRotation) {
            let angles = summary.markups.map { $0.rotationDegrees ?? 0 }
            let shared = InspectorSelectionSummary.commonValue(angles)
            InspectorInlineRow(label: NSLocalizedString("Rotation", comment: "Inspector row label: the markup's angle")) {
                InspectorNumberControl(
                    value: shared,
                    isMixed: shared == nil,
                    isEnabled: enabled,
                    range: 0...359,
                    step: 15,
                    suffix: "°",
                    accessibilityLabel: NSLocalizedString("Rotation in degrees", comment: "Accessibility label")
                ) { applyStyle(Self.styleEdit(rotationDegrees: $0), to: summary) }
                .help(NSLocalizedString(
                    "Or drag the knob above the selected markup; hold Shift for 15° steps.",
                    comment: "Inspector rotation help"
                ))
            }
        }
    }

    // MARK: Link (NL-MARKUP-17)

    @ViewBuilder
    private func linkRow(_ summary: InspectorSelectionSummary) -> some View {
        if let markup = summary.single, markup.kind == .hyperlink {
            InspectorInlineRow(label: NSLocalizedString("Link", comment: "Inspector row label: where a hyperlink markup leads")) {
                HStack(spacing: ZPDFSpacing.m) {
                    Text(Self.linkDescription(markup, pages: environment.document.pages))
                        .zpdfText(.control, markup.linkURL == nil && markup.linkPageID == nil ? .textSecondary : .textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let onEditLink = environment.inspectorEditing.onEditLink {
                        Button(NSLocalizedString("Edit…", comment: "Inspector: edit the link's destination")) { onEditLink(markup.id) }
                            .buttonStyle(.link)
                            .disabled(markup.locked)
                    }
                }
            }
        }
    }

    /// What the Link row says: the address, "Sheet A-2", or that there is none yet.
    static func linkDescription(_ markup: MarkupSummary, pages: [PageDescriptor]) -> String {
        if let url = markup.linkURL { return url }
        if let pageID = markup.linkPageID {
            let label = pages.first { $0.id == pageID }?.label ?? ""
            return String(format: NSLocalizedString("Sheet %@", comment: "Inspector link row: a link to a sheet; its label"), label)
        }
        return NSLocalizedString("No destination yet", comment: "Inspector link row: a link that leads nowhere")
    }

    // MARK: Group (NL-MARKUP-11)

    @ViewBuilder
    private func groupRow(_ summary: InspectorSelectionSummary) -> some View {
        let groups = Set(summary.markups.compactMap(\.groupID))
        if !groups.isEmpty, let onUngroup = environment.inspectorEditing.onUngroup {
            InspectorInlineRow(label: NSLocalizedString("Group", comment: "Inspector row label: the markup group")) {
                HStack(spacing: ZPDFSpacing.m) {
                    Text(String(
                        format: NSLocalizedString("%ld markups", comment: "Inspector group row: how many markups the group holds"),
                        summary.count
                    ))
                    .zpdfText(.control, .textPrimary)
                    Spacer(minLength: 0)
                    Button(NSLocalizedString("Ungroup", comment: "Inspector: ungroup the selection")) {
                        onUngroup(Set(summary.markups.map(\.id)))
                    }
                    .buttonStyle(.link)
                }
            }
        } else if summary.count >= 2, let onGroup = environment.inspectorEditing.onGroup {
            HStack {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Group", comment: "Inspector: group the selection")) {
                    onGroup(Set(summary.markups.map(\.id)))
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: Edits

    static func styleEdit(
        bold: Bool? = nil,
        italic: Bool? = nil,
        textColor: ColorRGBA? = nil,
        removesTextColor: Bool = false,
        boxBorder: Bool? = nil,
        cloudArcSize: Double? = nil,
        resetsCloudArcSize: Bool = false,
        rotationDegrees: Double? = nil
    ) -> MarkupStyleEdit {
        var edit = MarkupStyleEdit()
        edit.bold = bold
        edit.italic = italic
        edit.textColor = textColor
        edit.removesTextColor = removesTextColor
        edit.boxBorder = boxBorder
        edit.cloudArcSize = cloudArcSize
        edit.resetsCloudArcSize = resetsCloudArcSize
        edit.rotationDegrees = rotationDegrees
        return edit
    }
}

/// A two-state trait button — bold, italic, border — marked by shape and weight as well as
/// colour, showing mixed as a dash.
struct InspectorTraitToggle: View {
    let symbol: String
    let title: String
    /// `nil` when the selection disagrees.
    let value: Bool?
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!(value ?? false))
        } label: {
            Image(systemName: value == nil ? "minus" : symbol)
                .font(.system(size: 12, weight: value == true ? .bold : .regular))
                .frame(width: ZPDFSpacing.Control.minimumHitTarget, height: ZPDFSpacing.Control.minimumHitTarget)
                .foregroundStyle(ZPDFColor.color(value == true ? .accentBlue : .textSecondary))
                .background(
                    RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                        .strokeBorder(ZPDFColor.color(value == true ? .accentBlue : .borderStrong), lineWidth: ZPDFStroke.regular)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value == nil
            ? InspectorAppearanceText.mixed
            : (value == true
                ? NSLocalizedString("On", comment: "Accessibility value of a toggle that is on")
                : NSLocalizedString("Off", comment: "Accessibility value of a toggle that is off"))))
        .accessibilityAddTraits(value == true ? .isSelected : [])
    }
}
