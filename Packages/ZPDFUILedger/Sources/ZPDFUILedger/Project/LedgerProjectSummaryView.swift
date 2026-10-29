import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// A batch summary over closed projects (NL-QTY-15 phase 2), as the panel shows it.
public struct LedgerBatchSummary: Hashable, Sendable {
    /// A package that is not in the summary, and why.
    public struct Refusal: Hashable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }
    public let drawings: [LedgerProjectSummary.Drawing]
    public let combined: [LedgerSubjectTotal]
    public let refused: [Refusal]
    public init(drawings: [LedgerProjectSummary.Drawing], combined: [LedgerSubjectTotal], refused: [Refusal]) {
        self.drawings = drawings
        self.combined = combined
        self.refused = refused
    }
}

/// The whole-project summary (NL-QTY-15): every open drawing's subject totals and their exact
/// combination, and — phase 2 — the same over closed projects the person picks. Read-only —
/// each drawing is edited in its own ledger.
@MainActor
@Observable
public final class LedgerProjectSummaryModel {

    public private(set) var summary: LedgerProjectSummary?
    /// The last batch over closed projects, when one was run.
    public private(set) var batch: LedgerBatchSummary?
    public private(set) var isRunningBatch = false
    @ObservationIgnored private let presenter: (any LedgerProjectSummarizing)?
    /// Picks closed projects and summarises them; `nil` hides the button.
    @ObservationIgnored public var runBatch: (@MainActor () async -> LedgerBatchSummary?)?
    /// Saves a batch as a workbook; `nil` hides the button.
    @ObservationIgnored public var exportBatch: (@MainActor (LedgerBatchSummary) -> Void)?

    public init(presenter: (any LedgerProjectSummarizing)?) {
        self.presenter = presenter
    }

    public func reload() async {
        summary = await presenter?.projectSummary()
    }

    /// Runs a batch summary; a cancelled pick leaves the last one in place.
    public func summariseClosedProjects() async {
        guard let runBatch, !isRunningBatch else { return }
        isRunningBatch = true
        defer { isRunningBatch = false }
        if let result = await runBatch() { batch = result }
    }

    /// Saves the batch as one workbook.
    public func exportBatchWorkbook() {
        guard let batch, let exportBatch else { return }
        exportBatch(batch)
    }
}

public struct LedgerProjectSummaryView: View {

    @Bindable private var model: LedgerProjectSummaryModel
    private let onDone: () -> Void

    public init(model: LedgerProjectSummaryModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Whole Project", comment: "Title of the whole-project summary"),
                subtitle: NSLocalizedString(
                    "Every open drawing, subject by subject. A subject in two units stays two lines; nothing is converted by guess.",
                    comment: "Whole-project summary subtitle"
                ),
                count: model.summary?.drawings.count ?? 0
            )
            ScrollView {
                if let batch = model.batch {
                    batchSection(batch)
                }
                if let summary = model.summary {
                    VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                        Text(NSLocalizedString("All drawings", comment: "Whole-project summary: the combined section"))
                            .zpdfText(.sectionHeader, .textSecondary)
                        ForEach(Array(summary.combined.enumerated()), id: \.offset) { _, total in
                            line(total, strong: true)
                        }
                        ForEach(summary.drawings) { drawing in
                            ZPDFHairlineDivider()
                            Text(drawing.title).zpdfText(.sectionHeader, .textSecondary)
                            if drawing.totals.isEmpty {
                                Text(NSLocalizedString("No quantities yet.", comment: "Whole-project summary: a drawing without totals"))
                                    .zpdfText(.caption, .textSecondary)
                            }
                            ForEach(Array(drawing.totals.enumerated()), id: \.offset) { _, total in
                                line(total, strong: false)
                            }
                        }
                    }
                    .padding(ZPDFSpacing.l)
                }
            }
            ZPDFHairlineDivider()
            HStack {
                if model.runBatch != nil {
                    Button(NSLocalizedString("Summarise Closed Projects…", comment: "Whole-project summary: pick closed project files and total them")) {
                        Task { await model.summariseClosedProjects() }
                    }
                    .disabled(model.isRunningBatch)
                }
                if model.batch != nil, model.exportBatch != nil {
                    Button(NSLocalizedString("Export Workbook…", comment: "Whole-project summary: save the batch summary as an Excel workbook")) {
                        model.exportBatchWorkbook()
                    }
                }
                Spacer()
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 480, minHeight: 380)
        .background(ZPDFColor.surface)
        .task { await model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Whole Project", comment: "Title of the whole-project summary"))
    }

    /// The batch over closed projects: combined first, then each project, then what was left out.
    private func batchSection(_ batch: LedgerBatchSummary) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Closed projects", comment: "Whole-project summary: the batch section over closed project files"))
                .zpdfText(.sectionHeader, .textSecondary)
            ForEach(Array(batch.combined.enumerated()), id: \.offset) { _, total in
                line(total, strong: true)
            }
            ForEach(batch.drawings) { drawing in
                Text(drawing.title).zpdfText(.caption, .textSecondary)
                ForEach(Array(drawing.totals.enumerated()), id: \.offset) { _, total in
                    line(total, strong: false)
                }
            }
            if !batch.refused.isEmpty {
                Text(NSLocalizedString("Not included", comment: "Whole-project summary: packages the batch could not read"))
                    .zpdfText(.sectionHeader, .textSecondary)
                ForEach(Array(batch.refused.enumerated()), id: \.offset) { _, refusal in
                    Text("\(refusal.name): \(refusal.reason)").zpdfText(.caption, .textPrimary)
                }
            }
            ZPDFHairlineDivider()
        }
        .padding([.horizontal, .top], ZPDFSpacing.l)
    }

    private func line(_ total: LedgerSubjectTotal, strong: Bool) -> some View {
        HStack {
            Text(total.subject).zpdfText(.control, .textPrimary)
            Spacer()
            Text(LedgerPlurals.rows(total.rowCount))
                .zpdfText(.caption, .textSecondary)
            Text(total.text).zpdfText(strong ? .monoNumericStrong : .monoNumeric, .textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
