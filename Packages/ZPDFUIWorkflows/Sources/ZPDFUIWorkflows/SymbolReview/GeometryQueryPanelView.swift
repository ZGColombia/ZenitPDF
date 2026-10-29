import SwiftUI
import ZPDFDesignSystem

/// The geometry query panel (NL-AUTO-24): a question, its highlights, and a commit only where a
/// quantity is honest.
public struct GeometryQueryPanelView: View {

    @Bindable private var model: GeometryQueryPanelModel

    public init(model: GeometryQueryPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Find Geometry", comment: "Title of the geometry query panel"))
                .zpdfText(.windowTitle, .textPrimary)
            Picker(NSLocalizedString("Find", comment: "Geometry query kind picker label"), selection: $model.kind) {
                ForEach(GeometryQueryKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityLabel(Text(NSLocalizedString("What to find", comment: "Accessibility label for the geometry query kind picker")))
            HStack(spacing: ZPDFSpacing.s) {
                TextField(NSLocalizedString("Value", comment: "Geometry query value placeholder"), text: $model.valueText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString("Value in %@", comment: "Accessibility label for the geometry query value; the unit"),
                        model.unitLabel
                    )))
                Text("±").zpdfText(.body, .textSecondary).accessibilityHidden(true)
                TextField(NSLocalizedString("2 %", comment: "Geometry query tolerance placeholder: two percent by default"), text: $model.toleranceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString("Tolerance in %@", comment: "Accessibility label for the geometry query tolerance; the unit"),
                        model.unitLabel
                    )))
                Text(model.unitLabel).zpdfText(.body, .textSecondary)
                Button(NSLocalizedString("Find", comment: "Run the geometry query")) {
                    Task { await model.run() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
            }
            if let text = model.resultText {
                Text(text).zpdfText(.caption, .textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ZPDFSpacing.s) {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Close", comment: "Close the geometry query panel")) { model.close() }
                    .keyboardShortcut(.cancelAction)
                if model.kind.canCount || model.kind.canMeasure {
                    Button(
                        model.kind.canCount
                            ? String(format: NSLocalizedString("Count These (%d)", comment: "Commit circle matches as one count; the number"), model.matchCount)
                            : String(format: NSLocalizedString("Measure These (%d)", comment: "Commit line matches as lengths; the number"), model.matchCount)
                    ) { model.commit() }
                    .disabled(!model.canCommit)
                }
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 460)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
    }
}
