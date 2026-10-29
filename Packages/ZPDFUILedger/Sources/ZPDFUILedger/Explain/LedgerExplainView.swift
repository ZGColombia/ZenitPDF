import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// "Explain a number": the rows behind a total — a group's
/// subtotal or the selection — each with its value and how it was made (measured on which sheet
/// at which scale, by whom; or the formula of a derived row), the exact sum per unit, and a way
/// to the markup on the canvas.
@MainActor
@Observable
public final class LedgerExplainModel {

    /// What is being explained, in words: "3 selected rows", "Group: Slab".
    public let title: String
    public let markupIDs: Set<UUID>
    public private(set) var explanation: LedgerExplanation?
    @ObservationIgnored private let presenter: any LedgerExplaining
    @ObservationIgnored private let onShow: (@MainActor (UUID) -> Void)?

    public init(title: String, markupIDs: Set<UUID>, presenter: any LedgerExplaining, onShow: (@MainActor (UUID) -> Void)? = nil) {
        self.title = title
        self.markupIDs = markupIDs
        self.presenter = presenter
        self.onShow = onShow
    }

    public func reload() async {
        explanation = await presenter.explain(markupIDs)
    }

    /// Whether a row can be shown on the canvas from here.
    public var canShow: Bool { onShow != nil }

    /// Selects and reveals one row's markup on the canvas.
    public func show(_ markupID: UUID) { onShow?(markupID) }
}

public struct LedgerExplainView: View {

    @Bindable private var model: LedgerExplainModel
    private let onDone: () -> Void

    public init(model: LedgerExplainModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Explain", comment: "Title of the explain-a-number panel"),
                subtitle: model.title,
                count: model.explanation?.rows.count ?? 0
            )
            ScrollView {
                if let explanation = model.explanation {
                    VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                        Text(NSLocalizedString("Total", comment: "Explain panel: the exact sum, one line per unit"))
                            .zpdfText(.sectionHeader, .textSecondary)
                        if explanation.totals.isEmpty {
                            Text(NSLocalizedString("No quantity to add up.", comment: "Explain panel: rows without a quantity"))
                                .zpdfText(.caption, .textSecondary)
                        }
                        ForEach(Array(explanation.totals.enumerated()), id: \.offset) { _, total in
                            Text(total).zpdfText(.monoNumericStrong, .textPrimary)
                        }
                        ZPDFHairlineDivider()
                        Text(NSLocalizedString("Rows", comment: "Explain panel: the rows behind the total"))
                            .zpdfText(.sectionHeader, .textSecondary)
                        ForEach(explanation.rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(ZPDFSpacing.l)
                }
            }
            ZPDFHairlineDivider()
            HStack {
                Spacer()
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(ZPDFColor.surface)
        .task { await model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Explain", comment: "Title of the explain-a-number panel"))
    }

    private func rowView(_ row: LedgerExplanation.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.m) {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text([row.subject, row.label].filter { !$0.isEmpty }.joined(separator: " · "))
                    .zpdfText(.control, .textPrimary)
                if !row.provenance.isEmpty {
                    Text(row.provenance).zpdfText(.caption, .textSecondary)
                }
            }
            Spacer()
            Text(row.valueText).zpdfText(.monoNumeric, .textPrimary)
            if model.canShow {
                Button(NSLocalizedString("Show", comment: "Explain panel: select and reveal the row's markup on the canvas")) {
                    model.show(row.markupID)
                }
                .accessibilityLabel(String(
                    format: NSLocalizedString("Show %@ on the canvas", comment: "Accessibility label: reveal a row's markup; the subject"),
                    row.subject
                ))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
