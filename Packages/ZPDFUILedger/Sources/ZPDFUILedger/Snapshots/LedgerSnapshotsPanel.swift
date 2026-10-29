import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Takeoff snapshots and the change report (NL-QTY-16): name the takeoff as it stands ("Bid 1"),
/// and later see exactly what changed since — every added, removed and changed row, field by
/// field, and each total's exact change.
@MainActor
@Observable
public final class LedgerSnapshotsModel {

    /// The project's snapshots, newest first.
    public private(set) var snapshots: [LedgerSnapshotSummary] = []
    /// The snapshot the report is against.
    public var selectedID: String?
    /// The report against ``selectedID``, once built.
    public private(set) var report: LedgerChangeReport?
    /// The name a new snapshot will take.
    public var newName: String = ""
    /// The outcome of the last action, in words.
    public private(set) var message: String?
    /// Why the report against ``selectedID`` could not be built, in words; `nil` once one is.
    public private(set) var reportFailure: String?
    /// The underlying error's own text — for the help tag, never the sentence on screen.
    public private(set) var reportFailureDetail: String?
    /// The first press of Delete Snapshot asked for the second (W-062): the panel is showing
    /// "Delete “Bid 1”? This cannot be undone." with Delete and Cancel.
    public private(set) var isConfirmingDelete = false

    @ObservationIgnored private let presenter: any LedgerSnapshotting
    /// Counts report builds, so a build that a newer one has overtaken drops its result (V-063).
    @ObservationIgnored private var reportGeneration = 0
    /// The selection the latest build was started for; `.none` before the first build.
    @ObservationIgnored private var reportRequestedFor: String??

    public init(presenter: any LedgerSnapshotting) {
        self.presenter = presenter
    }

    /// Reads the list and, when one is chosen, its report.
    public func reload() async {
        snapshots = await presenter.snapshots()
        if selectedID == nil || !snapshots.contains(where: { $0.id == selectedID }) {
            selectedID = snapshots.first?.id
        }
        await rebuildReport()
    }

    /// Builds the report against the chosen snapshot.
    ///
    /// U-065: a failure used to put the error's own English text ("ledger rebuild failed: no
    /// document") into ``message`` and leave it there beside every later, valid report. The
    /// report's failure is its own now, in the interface's words, and a report that builds
    /// clears it; ``message`` stays the outcome of the last action.
    ///
    /// V-063: the result is assigned only while this is still the latest build. A report for
    /// snapshot A that finished after the person had picked B used to land under a picker
    /// showing B.
    public func rebuildReport() async {
        reportGeneration += 1
        let generation = reportGeneration
        let selectedID = self.selectedID
        reportRequestedFor = .some(selectedID)
        guard let selectedID else {
            report = nil
            reportFailure = nil
            reportFailureDetail = nil
            return
        }
        do {
            let built = try await presenter.changeReport(since: selectedID)
            guard generation == reportGeneration else { return }
            report = built
            reportFailure = nil
            reportFailureDetail = nil
        } catch {
            guard generation == reportGeneration else { return }
            report = nil
            reportFailure = NSLocalizedString(
                "The changes since this snapshot could not be worked out. Choose it again, or take a new snapshot.",
                comment: "Snapshots panel: the change report could not be built"
            )
            reportFailureDetail = String(describing: error)
        }
    }

    /// The view's reaction to the picker (V-063): builds only when the selection is not the one
    /// the latest build was started for. ``reload()`` sets the selection and builds its report
    /// itself, so opening the panel, Take Snapshot and Delete Snapshot each built it twice at
    /// once — once there and once from the picker's change.
    public func selectionChanged() async {
        // A pending delete names the snapshot that was chosen when it was asked for; picking
        // another abandons it rather than retargeting it (W-062).
        isConfirmingDelete = false
        guard reportRequestedFor != .some(selectedID) else { return }
        await rebuildReport()
    }

    /// Stores the takeoff as it is now.
    ///
    /// W-067: the name is trimmed once, here, the way the store trims it, so the confirmation
    /// names the snapshot exactly as the picker lists it. A name of only spaces used to read
    /// "Snapshot “   ” stored." while the picker said "Snapshot".
    @discardableResult
    public func takeSnapshot() async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipt = await presenter.takeSnapshot(named: name)
        if let failure = receipt.failureDescription {
            message = failure
            return false
        }
        message = String(format: NSLocalizedString(
            "Snapshot “%@” stored.", comment: "Snapshots panel: a snapshot was stored; its name"
        ), name.isEmpty ? NSLocalizedString("Snapshot", comment: "Default name of a takeoff snapshot") : name)
        newName = ""
        selectedID = nil
        await reload()
        return true
    }

    /// The chosen snapshot's name, for the delete confirmation.
    public var selectedName: String? {
        snapshots.first { $0.id == selectedID }?.name
    }

    /// The first press of Delete Snapshot: asks for the second (W-062). A snapshot is written
    /// outside the undo manager, so one click used to erase it for good.
    public func requestDelete() {
        guard selectedID != nil else { return }
        isConfirmingDelete = true
        message = nil
    }

    /// Keeps the snapshot.
    public func cancelDelete() { isConfirmingDelete = false }

    /// The second press: deletes the chosen snapshot and says whether it went.
    ///
    /// A failed delete keeps the selection and says so. It used to be thrown away: the panel
    /// cleared the selection, reloaded, picked the same snapshot again and said nothing, which
    /// read as a delete that had worked.
    @discardableResult
    public func confirmDelete() async -> Bool {
        guard isConfirmingDelete, let selectedID else {
            isConfirmingDelete = false
            return false
        }
        isConfirmingDelete = false
        let name = selectedName ?? NSLocalizedString("Snapshot", comment: "Default name of a takeoff snapshot")
        guard await presenter.deleteSnapshot(selectedID) else {
            message = String(format: NSLocalizedString(
                "“%@” could not be deleted. It is still stored.",
                comment: "Snapshots panel: deleting a snapshot failed; its name"
            ), name)
            return false
        }
        message = String(format: NSLocalizedString(
            "Snapshot “%@” deleted.", comment: "Snapshots panel: a snapshot was deleted; its name"
        ), name)
        self.selectedID = nil
        await reload()
        return true
    }

    /// Words for a change's kind.
    public static func kindTitle(_ kind: LedgerChangeReport.RowKind) -> String {
        switch kind {
        case .added: NSLocalizedString("Added", comment: "Change report: a row that was not in the snapshot")
        case .removed: NSLocalizedString("Removed", comment: "Change report: a row that is no longer in the takeoff")
        case .changed: NSLocalizedString("Changed", comment: "Change report: a row whose values changed")
        }
    }
}

/// The panel's view.
public struct LedgerSnapshotsPanel: View {

    @Bindable private var model: LedgerSnapshotsModel
    private let onDone: () -> Void

    public init(model: LedgerSnapshotsModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Snapshots and Changes", comment: "Title of the snapshots panel"),
                subtitle: NSLocalizedString(
                    "Store the takeoff as it stands, then see exactly what changed since.",
                    comment: "Snapshots panel subtitle"
                ),
                count: model.snapshots.count
            )
            HStack(spacing: ZPDFSpacing.s) {
                TextField(NSLocalizedString("Snapshot name, e.g. Bid 1", comment: "Snapshots panel: name field"), text: $model.newName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(NSLocalizedString("Snapshot name", comment: "Snapshots panel: name field"))
                Button(NSLocalizedString("Take Snapshot", comment: "Name of the take-snapshot action")) {
                    Task { await model.takeSnapshot() }
                }
            }
            .padding(ZPDFSpacing.m)
            HStack(spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString("Changes since", comment: "Snapshots panel: the snapshot the report compares with"))
                    .zpdfText(.caption, .textSecondary)
                Picker("", selection: $model.selectedID) {
                    ForEach(model.snapshots) { snapshot in
                        Text("\(snapshot.name) — \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .tag(Optional(snapshot.id))
                    }
                }
                .labelsHidden()
                .disabled(model.snapshots.isEmpty)
                .accessibilityLabel(NSLocalizedString("Changes since", comment: "Snapshots panel: the snapshot the report compares with"))
                if !model.isConfirmingDelete {
                    Button(NSLocalizedString("Delete Snapshot…", comment: "Snapshots panel: delete the chosen snapshot, first press")) {
                        model.requestDelete()
                    }
                    .disabled(model.selectedID == nil)
                }
                Spacer()
            }
            .padding(.horizontal, ZPDFSpacing.m)
            if model.isConfirmingDelete {
                HStack(spacing: ZPDFSpacing.s) {
                    Text(String(format: NSLocalizedString(
                        "Delete “%@”? This cannot be undone.",
                        comment: "Snapshots panel: confirm deleting a snapshot; its name"
                    ), model.selectedName ?? ""))
                    .zpdfText(.caption, .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(NSLocalizedString("Cancel", comment: "Snapshots panel: keep the snapshot")) { model.cancelDelete() }
                        .keyboardShortcut(.cancelAction)
                    Button(NSLocalizedString("Delete", comment: "Snapshots panel: delete the snapshot, second press"), role: .destructive) {
                        Task { await model.confirmDelete() }
                    }
                }
                .padding(.horizontal, ZPDFSpacing.m)
                .padding(.top, ZPDFSpacing.s)
                .accessibilityElement(children: .contain)
            }
            ZPDFHairlineDivider()
            ScrollView {
                reportBody.padding(ZPDFSpacing.m)
            }
            ZPDFHairlineDivider()
            HStack {
                if let message = model.message {
                    Text(message).zpdfText(.caption, .textSecondary).accessibilityLabel(message)
                }
                Spacer()
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(ZPDFColor.surface)
        .task { await model.reload() }
        .onChange(of: model.selectedID) { Task { await model.selectionChanged() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Snapshots and Changes", comment: "Title of the snapshots panel"))
    }

    @ViewBuilder
    private var reportBody: some View {
        if let failure = model.reportFailure {
            ZPDFInlineWarning(message: failure)
                .help(model.reportFailureDetail ?? "")
        } else if let report = model.report {
            VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                if report.rows.isEmpty {
                    Text(NSLocalizedString("Nothing has changed since this snapshot.", comment: "Change report: no changes"))
                        .zpdfText(.control, .textPrimary)
                }
                if !report.grandTotals.isEmpty || !report.subjectTotals.isEmpty {
                    Text(NSLocalizedString("Totals", comment: "Change report: the totals section")).zpdfText(.sectionHeader, .textSecondary)
                    ForEach(report.grandTotals + report.subjectTotals) { total in
                        HStack {
                            Text(total.title).zpdfText(.control, .textPrimary)
                            Spacer()
                            Text("\(total.beforeText) → \(total.afterText)").zpdfText(.monoNumeric, .textSecondary)
                            Text(total.deltaText).zpdfText(.monoNumericStrong, .textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !report.rows.isEmpty {
                    Text(LedgerPlurals.rows(report.rows.count))
                        .zpdfText(.sectionHeader, .textSecondary)
                }
                ForEach(report.rows) { row in
                    VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                        Text("\(LedgerSnapshotsModel.kindTitle(row.kind)): \(row.subject)\(row.label.isEmpty ? "" : " · \(row.label)")")
                            .zpdfText(.control, .textPrimary)
                        ForEach(row.fields, id: \.column) { field in
                            Text("\(field.column): \(field.before.isEmpty ? "—" : field.before) → \(field.after.isEmpty ? "—" : field.after)")
                                .zpdfText(.caption, .textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else if model.snapshots.isEmpty {
            Text(NSLocalizedString("No snapshots yet. Name one above and take it before the takeoff goes out.", comment: "Snapshots panel: empty"))
                .zpdfText(.caption, .textSecondary)
        }
    }
}
