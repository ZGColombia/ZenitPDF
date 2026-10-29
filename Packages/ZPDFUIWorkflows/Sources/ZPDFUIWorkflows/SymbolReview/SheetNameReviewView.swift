import SwiftUI
import ZPDFDesignSystem

/// The sheet-name review (NL-AUTO-04): every proposed number and title editable, weak readings
/// and duplicate numbers named in words, nothing applied until the person accepts.
public struct SheetNameReviewView: View {

    @Bindable private var model: SheetNameReviewModel

    public init(model: SheetNameReviewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Review the sheet names", comment: "Title of the sheet name review"))
                .zpdfText(.windowTitle, .textPrimary)
            Text(model.summaryText)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($model.rows) { $row in
                    SheetNameReviewRowView(model: model, row: $row)
                }
            }
            .listStyle(.inset)
            .accessibilityLabel(Text(NSLocalizedString("Proposed sheet names", comment: "Accessibility label for the sheet name list")))
            HStack(spacing: ZPDFSpacing.s) {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Close the sheet name review without naming")) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(WorkflowPlurals.nameSheets(model.includedPageIndexes.count)) { model.accept() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAccept)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 720, minHeight: 420)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
    }
}

private struct SheetNameReviewRowView: View {
    let model: SheetNameReviewModel
    @Binding var row: SheetNameReviewRow

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Toggle(isOn: Binding(
                get: { model.includedPageIndexes.contains(row.pageIndex) },
                set: { model.setIncluded($0, pageIndex: row.pageIndex) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(String(
                format: NSLocalizedString("Name %@", comment: "Accessibility label for a sheet name row checkbox; the page"),
                row.pageLabel
            )))
            Text(row.pageLabel).zpdfText(.caption, .textSecondary).frame(width: 70, alignment: .leading)
            // L-54: wide enough for the longest number read, and the title wraps onto up to
            // three lines — a reading is shown whole, and the help tag repeats it.
            TextField(NSLocalizedString("Number", comment: "Sheet number field placeholder"), text: $row.number)
                .textFieldStyle(.roundedBorder)
                .frame(width: model.numberFieldWidth)
                .help(row.number)
                .accessibilityLabel(Text(NSLocalizedString("Sheet number", comment: "Accessibility label for the sheet number field")))
            TextField(NSLocalizedString("Title", comment: "Sheet title field placeholder"), text: $row.title, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .help(row.title)
                .accessibilityLabel(Text(NSLocalizedString("Sheet title", comment: "Accessibility label for the sheet title field")))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.sourceText).zpdfText(.caption, .textSecondary)
                if model.duplicatePageIndexes.contains(row.pageIndex) {
                    Text(NSLocalizedString("Same number as another sheet", comment: "Sheet name review: duplicate flag"))
                        .zpdfText(.caption, .warning)
                } else if row.needsAttention {
                    Text(NSLocalizedString("Check this reading", comment: "Sheet name review: weak reading flag"))
                        .zpdfText(.caption, .warning)
                }
            }
            .frame(width: 150, alignment: .leading)
        }
    }
}
