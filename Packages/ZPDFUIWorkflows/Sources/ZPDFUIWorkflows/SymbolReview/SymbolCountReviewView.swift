import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The review panel a symbol search opens before anything is counted (NL-AUTO-02, NL-AUTO-05).
///
/// Every row says in words what it is — match, near miss, already counted — so nothing relies on
/// colour, and every row can be shown on the sheet before it is ticked.
public struct SymbolCountReviewView: View {

    @Bindable private var model: SymbolCountReviewModel

    public init(model: SymbolCountReviewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            header
            if model.isSearching { progress }
            list
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 560, minHeight: 420)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Review the symbols found before counting them",
            comment: "Accessibility label for the symbol count review panel"
        )))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString(
                "Review the symbols before counting",
                comment: "Title of the symbol count review panel"
            ))
            .zpdfText(.windowTitle, .textPrimary)
            if !model.isMultiDesignation {
            HStack(spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString("Designation", comment: "Symbol review: designation field label"))
                    .zpdfText(.caption, .textSecondary)
                TextField(
                    NSLocalizedString("Designation", comment: "Symbol designation field placeholder"),
                    text: $model.designation
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Designation the counts land under",
                    comment: "Accessibility label for the symbol review designation field"
                )))
            }
            Toggle(
                NSLocalizedString("Save this symbol to the library", comment: "Symbol review: keep the exemplar in the local symbol library"),
                isOn: $model.saveToLibrary
            )
            .toggleStyle(.checkbox)
            .accessibilityHint(Text(NSLocalizedString(
                "Later sheets and other projects can then be searched for it. The library stays on this Mac.",
                comment: "Accessibility hint for the save-to-library checkbox"
            )))
            }
            Text(model.summaryText)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(model.summaryText))
        }
    }

    private var progress: some View {
        HStack(spacing: ZPDFSpacing.s) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            if case .searching(let done, let total) = model.phase {
                Text(String(
                    format: NSLocalizedString(
                        "Searching page %1$d of %2$d…",
                        comment: "Symbol review: progress while pages are searched"
                    ),
                    min(done + 1, total), total
                ))
                .zpdfText(.caption, .textSecondary)
            }
            Spacer(minLength: 0)
            Button(
                NSLocalizedString("Stop Search", comment: "Symbol review: stop searching further pages"),
                action: { model.cancelSearch() }
            )
            .accessibilityHint(Text(NSLocalizedString(
                "Keeps what was found so far; nothing is counted until you add it",
                comment: "Accessibility hint for Stop Search"
            )))
        }
    }

    private var list: some View {
        List {
            ForEach(model.pages, id: \.pageIndex) { page in
                Section {
                    ForEach(model.rows.filter { $0.pageIndex == page.pageIndex }) { row in
                        SymbolCountReviewRowView(model: model, row: row)
                    }
                    if let failure = page.failure {
                        Text(failure).zpdfText(.caption, .textSecondary)
                    }
                } header: {
                    Text(page.pageLabel).zpdfText(.caption.withWeight(.semibold), .textPrimary)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(Text(NSLocalizedString(
            "Symbols found, grouped by page",
            comment: "Accessibility label for the symbol review list"
        )))
    }

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Spacer(minLength: 0)
            Button(
                NSLocalizedString("Cancel", comment: "Close the symbol review without counting"),
                action: { model.cancel() }
            )
            .keyboardShortcut(.cancelAction)
            Button(
                WorkflowPlurals.addCounts(model.selectedRowIDs.count),
                action: { model.accept() }
            )
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canAccept)
        }
    }
}

/// One row: tick, thumbnail, status in words, detail, and a Show button.
private struct SymbolCountReviewRowView: View {
    let model: SymbolCountReviewModel
    let row: SymbolCountReviewRow
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Toggle(isOn: Binding(
                get: { model.isSelected(row) },
                set: { model.setSelected($0, for: row) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(String(
                format: NSLocalizedString(
                    "Count this place: %1$@, %2$@",
                    comment: "Accessibility label for a symbol review row checkbox; status and detail"
                ),
                row.statusText, row.detail
            )))

            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(ZPDFColor.color(.surface))
                }
            }
            .frame(width: 44, height: 44)
            .overlay(Rectangle().stroke(ZPDFColor.color(.border), lineWidth: 1))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if let designation = row.designation {
                    Text(designation).zpdfText(.caption.withWeight(.semibold), .textPrimary)
                }
                Text(row.isExemplar
                     ? String(format: NSLocalizedString("%@ · the boxed example", comment: "Symbol review: the row is the example the person boxed; the status"), row.statusText)
                     : row.statusText)
                    .zpdfText(.body, row.status == .confirmed ? .textPrimary : .textSecondary)
                Text(row.detail).zpdfText(.caption, .textSecondary)
            }
            Spacer(minLength: 0)
            Button(
                NSLocalizedString("Show", comment: "Symbol review: show this place on the sheet"),
                action: { model.reveal(row) }
            )
            .accessibilityLabel(Text(NSLocalizedString(
                "Show this place on the sheet", comment: "Accessibility label for the symbol review Show button"
            )))
        }
        .task(id: row.id) {
            thumbnail = await model.thumbnailProvider?(row)
        }
    }
}
