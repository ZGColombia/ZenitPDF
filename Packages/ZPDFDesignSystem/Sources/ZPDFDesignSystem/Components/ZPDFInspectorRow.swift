import SwiftUI

/// The placeholder shown when a multi-selection disagrees about a value.
///
/// A dash plus the word "Mixed": the state is legible without colour and speaks correctly.
public struct ZPDFMixedValueIndicator: View {
    private let showsLabel: Bool

    public init(showsLabel: Bool = true) {
        self.showsLabel = showsLabel
    }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            Text(verbatim: "\u{2014}")
                .zpdfText(.monoNumeric, .textSecondary)
            if showsLabel {
                Text(NSLocalizedString("Mixed", comment: "Inspector: several selected items have different values"))
                    .zpdfText(.caption, .textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString("Mixed value", comment: "Accessibility label for a mixed multi-selection value")))
    }
}

/// One inspector line: a label column and a control column.
///
/// The label column is a fixed width so controls line up down the whole inspector, which is
/// what makes a dense properties panel scannable. When `isMixed` is set, the control is
/// replaced by a mixed-value placeholder, matching how macOS inspectors behave — unless the
/// control declares it shows the mixed state itself (`showsContentWhenMixed`), in which case
/// it stays on screen so a disagreeing selection can still be given one value (BH-053).
public struct ZPDFInspectorRow<Content: View>: View {
    private let label: String
    private let helpText: String?
    private let isMixed: Bool
    private let showsContentWhenMixed: Bool
    private let labelWidth: CGFloat
    private let content: Content

    /// - Parameters:
    ///   - label: the property name.
    ///   - helpText: optional hover help for the label.
    ///   - isMixed: `true` when the current multi-selection disagrees about this property.
    ///   - labelWidth: override the shared label column width.
    ///   - showsContentWhenMixed: `true` when the control renders the mixed state itself (an em
    ///     dash, an empty field with a "Multiple values" prompt) and must stay editable.
    ///   - content: the editing control.
    public init(
        label: String,
        helpText: String? = nil,
        isMixed: Bool = false,
        labelWidth: CGFloat = ZPDFSpacing.Control.inspectorLabelWidth,
        showsContentWhenMixed: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.helpText = helpText
        self.isMixed = isMixed
        self.showsContentWhenMixed = showsContentWhenMixed
        self.labelWidth = labelWidth
        self.content = content()
    }

    /// Whether the row swaps its control for the mixed-value placeholder.
    public static func showsMixedPlaceholder(isMixed: Bool, showsContentWhenMixed: Bool) -> Bool {
        isMixed && !showsContentWhenMixed
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.m) {
            Text(label)
                .zpdfText(.control, .textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .trailing)
                .help(helpText ?? label)
                .accessibilityHidden(true)

            Group {
                if Self.showsMixedPlaceholder(isMixed: isMixed, showsContentWhenMixed: showsContentWhenMixed) {
                    ZPDFMixedValueIndicator()
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: ZPDFSpacing.Control.inspectorRow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(
            isMixed
                ? Text(NSLocalizedString("Mixed value", comment: "Accessibility label for a mixed multi-selection value"))
                : Text(verbatim: "")
        )
    }
}

#if DEBUG
struct ZPDFInspectorRow_Previews: PreviewProvider {
    private struct Demo: View {
        @State private var width: Double? = 12.5
        @State private var unit = "mm"

        var body: some View {
            ZPDFPreviewPanel("Inspector rows", width: 380) {
                VStack(spacing: ZPDFSpacing.xs) {
                    ZPDFInspectorRow(label: NSLocalizedString("Line width", comment: "Preview label")) {
                        ZPDFNumericField(
                            value: $width,
                            unit: NSLocalizedString("pt", comment: "Preview unit"),
                            accessibilityTitle: NSLocalizedString("Line width", comment: "Preview label")
                        )
                    }
                    ZPDFInspectorRow(label: NSLocalizedString("Output unit", comment: "Preview label")) {
                        ZPDFUnitPicker(
                            selection: $unit,
                            options: ZPDFUnitOption.previewLengthUnits,
                            accessibilityTitle: NSLocalizedString("Output unit", comment: "Preview label")
                        )
                    }
                    ZPDFInspectorRow(
                        label: NSLocalizedString("Layer", comment: "Preview label"),
                        isMixed: true
                    ) {
                        Text(verbatim: "Structure").zpdfText(.control)
                    }
                    ZPDFInspectorRow(label: NSLocalizedString("Locked", comment: "Preview label")) {
                        Toggle(isOn: .constant(false)) { Text(verbatim: "") }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .accessibilityLabel(NSLocalizedString("Locked", comment: "Preview label"))
                    }
                }
            }
        }
    }

    static var previews: some View {
        ZPDFAppearancePair { Demo() }
            .previewDisplayName("ZPDFInspectorRow - dark and light")
    }
}
#endif
