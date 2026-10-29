import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The rate library (NL-QTY-05): paste a supplier list, price the selected rows with an item in
/// one step, and — when the office's rates move — review exactly what "Update rates" would
/// change, row by row and in money, before applying it.
@MainActor
@Observable
public final class LedgerRateLibraryModel {

    /// The library's items.
    public private(set) var entries: [LedgerRateEntrySummary] = []
    /// The rows an item is applied to.
    public let markupIDs: Set<UUID>
    /// A supplier list being pasted.
    public var pastedList: String = ""
    /// Rows whose rate differs from the library's, when last checked.
    public private(set) var pendingUpdates: [LedgerRateUpdate] = []
    /// The outcome of the last action.
    public private(set) var message: String?
    /// Lines of the last import that were not read.
    public private(set) var rejectedLines: [String] = []
    /// The item the person just removed, held back from the office's library until the next
    /// action or until the panel closes, so Undo puts it back exactly — nothing was written
    /// (V-062). The list already hides it.
    public private(set) var pendingRemoval: LedgerRateEntrySummary?
    /// Why the last removal did not happen, when the library could not be written (V-062).
    /// It used to be discarded, so a failed removal looked like a successful one until the
    /// item reappeared.
    public private(set) var removalFailure: String?
    /// Where a removal that fails as the panel closes is reported — the pane that hosted it —
    /// since this panel's warning is no longer on screen by then (V-062 re-fix).
    @ObservationIgnored public var onRemovalFailedAfterClose: (@MainActor (String) -> Void)?

    /// The locale amounts are printed in — the ledger's, so a rate reads as the Unit Cost
    /// cell it will fill does (T-052).
    public let locale: Locale

    @ObservationIgnored private let presenter: any LedgerRateLibraryManaging

    public init(
        presenter: any LedgerRateLibraryManaging,
        markupIDs: Set<UUID>,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.presenter = presenter
        self.markupIDs = markupIDs
        self.locale = locale
    }

    /// Re-reads the library and the pending updates. An item waiting to be removed stays out
    /// of the list, and so do the rate updates only it would make.
    public func reload() async {
        let hidden = pendingRemoval
        entries = presenter.rateEntries.filter { $0.id != hidden?.id }
        pendingUpdates = await presenter.pendingRateUpdates().filter { $0.material != hidden?.name }
    }

    /// Imports the pasted list.
    public func importPasted() async {
        await commitPendingRemoval()
        let result = await presenter.importRateList(pastedList)
        rejectedLines = result.rejectedLines
        if let failure = result.failure {
            message = failure
        } else {
            message = LedgerPlurals.importOutcome(imported: result.imported, rejected: result.rejectedLines.count)
            if result.imported > 0 { pastedList = "" }
        }
        await reload()
    }

    /// Prices the selected rows with an item.
    public func apply(_ id: UUID) async {
        await commitPendingRemoval()
        let receipt = await presenter.applyRateEntry(id, to: markupIDs)
        message = receipt.failureDescription ?? LedgerPlurals.pricedRows(receipt.changedMarkupIDs.count)
        await reload()
    }

    /// Takes an item out of the list with an Undo (V-062). The office's library is written when
    /// the next action runs or the panel closes (``commitPendingRemoval()``); until then Undo
    /// brings it back. Rows priced with it keep their rates either way.
    ///
    /// It used to be one click on a borderless "−", written through at once, with no undo, no
    /// confirmation and the failure result thrown away.
    ///
    /// Removing one item writes the one removed before it. When that write fails its warning
    /// stays: it is why that item is back in the list. The first fix cleared ``removalFailure``
    /// here unconditionally, after the write, so "remove A, remove B" with A's write refused
    /// showed A back in the list, unexplained, under "Removed “B”." with an Undo — and removing
    /// several items in a row is exactly when every write but the last happens here. An older
    /// warning is cleared only when this step wrote nothing or wrote successfully.
    public func remove(_ id: UUID) async {
        let committed = await commitPendingRemoval()
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        pendingRemoval = entry
        if committed { removalFailure = nil }
        message = Self.removedMessage(entry.name)
        await reload()
    }

    /// Puts the item back: it was never removed from the library.
    public func undoRemove() async {
        guard pendingRemoval != nil else { return }
        pendingRemoval = nil
        message = nil
        await reload()
    }

    /// Writes a pending removal to the office's library. `false` when the write failed; the
    /// item is then back in the list and ``removalFailure`` says so.
    @discardableResult
    public func commitPendingRemoval() async -> Bool {
        guard let entry = pendingRemoval else { return true }
        pendingRemoval = nil
        let removed = await presenter.removeRateEntry(entry.id)
        if removed {
            if message == Self.removedMessage(entry.name) { message = nil }
        } else {
            message = nil
            removalFailure = String(
                format: NSLocalizedString(
                    "\u{201C}%@\u{201D} could not be removed from the rate library. It is still there.",
                    comment: "Rate library: removing an item failed; the item's name"
                ),
                entry.name
            )
        }
        await reload()
        return removed
    }

    /// The panel closed some way other than Done (Escape, the window): the pending removal is
    /// still written, and a write that fails is handed to ``onRemovalFailedAfterClose``, the
    /// only place left that a person can see it. It used to drop the `false` (V-062 re-fix).
    public func panelClosed() async {
        guard pendingRemoval != nil else { return }
        guard !(await commitPendingRemoval()), let failure = removalFailure else { return }
        onRemovalFailedAfterClose?(failure)
    }

    static func removedMessage(_ name: String) -> String {
        String(
            format: NSLocalizedString(
                "Removed \u{201C}%@\u{201D}.",
                comment: "Rate library: an item was taken out of the list, with an Undo beside it; the item's name"
            ),
            name
        )
    }

    /// Applies every pending rate update.
    public func applyAllUpdates() async {
        await commitPendingRemoval()
        let receipt = await presenter.applyRateUpdates(Set(pendingUpdates.map(\.markupID)))
        message = receipt.failureDescription ?? LedgerPlurals.updatedRates(receipt.changedMarkupIDs.count)
        await reload()
    }
}

/// The panel's view.
public struct LedgerRateLibraryPanel: View {

    @Bindable private var model: LedgerRateLibraryModel
    private let onDone: () -> Void

    public init(model: LedgerRateLibraryModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Rate Library", comment: "Title of the rate library"),
                subtitle: NSLocalizedString(
                    "Your office's rates. A project keeps the rates it was priced with until you update them here.",
                    comment: "Rate library subtitle"
                ),
                count: model.entries.count
            )
            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    if model.entries.isEmpty {
                        Text(NSLocalizedString(
                            "No items yet. Paste a supplier list below: a first line naming Name, Unit and Rate, then one item per line.",
                            comment: "Rate library: empty"
                        ))
                        .zpdfText(.caption, .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.entries) { entry in
                        HStack(spacing: ZPDFSpacing.s) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.name).zpdfText(.control, .textPrimary)
                                Text(Self.summary(entry, locale: model.locale)).zpdfText(.caption, .textSecondary)
                            }
                            Spacer()
                            Button(LedgerPlurals.priceRows(model.markupIDs.count)) {
                                Task { await model.apply(entry.id) }
                            }
                            .disabled(model.markupIDs.isEmpty)
                            .accessibilityLabel(String(format: NSLocalizedString(
                                "Price the selected rows with %@", comment: "Rate library: apply button label; the item"
                            ), entry.name))
                            Button { Task { await model.remove(entry.id) } } label: { Text("−") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(format: NSLocalizedString(
                                    "Remove %@ from the library", comment: "Rate library: remove button; the item"
                                ), entry.name))
                        }
                        .accessibilityElement(children: .contain)
                    }
                    ZPDFHairlineDivider()
                    Text(NSLocalizedString("Paste a supplier list", comment: "Rate library: import heading"))
                        .zpdfText(.sectionHeader, .textSecondary)
                    TextEditor(text: $model.pastedList)
                        .font(ZPDFTypography.font(.monoNumeric))
                        .frame(minHeight: 90)
                        .accessibilityLabel(NSLocalizedString("Supplier list", comment: "Rate library: paste area"))
                    HStack {
                        Button(NSLocalizedString("Import", comment: "Rate library: import the pasted list")) {
                            Task { await model.importPasted() }
                        }
                        .disabled(model.pastedList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                    }
                    ForEach(model.rejectedLines, id: \.self) { line in
                        Text(line).zpdfText(.caption, .textSecondary)
                    }
                    if !model.pendingUpdates.isEmpty {
                        ZPDFHairlineDivider()
                        Text(LedgerPlurals.staleRates(model.pendingUpdates.count))
                        .zpdfText(.sectionHeader, .textSecondary)
                        ForEach(model.pendingUpdates) { update in
                            HStack {
                                Text("\(update.subject) · \(update.material)").zpdfText(.control, .textPrimary)
                                Spacer()
                                Text("\(Self.money(update.before, update.currencyCode, locale: model.locale)) → \(Self.money(update.after, update.currencyCode, locale: model.locale))")
                                    .zpdfText(.monoNumeric, .textSecondary)
                                Text((update.moneyDelta > 0 ? "+" : "") + Self.money(update.moneyDelta, update.currencyCode, locale: model.locale))
                                    .zpdfText(.monoNumericStrong, .textPrimary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button(NSLocalizedString("Update Rates", comment: "Undo action name: rates updated from the library")) {
                            Task { await model.applyAllUpdates() }
                        }
                    }
                }
                .padding(ZPDFSpacing.l)
            }
            ZPDFHairlineDivider()
            if let failure = model.removalFailure {
                ZPDFInlineWarning(severity: .warning, message: failure)
                    .padding(.horizontal, ZPDFSpacing.l)
                    .padding(.top, ZPDFSpacing.s)
            }
            HStack {
                if let message = model.message {
                    Text(message).zpdfText(.caption, .textSecondary).accessibilityLabel(message)
                }
                if model.pendingRemoval != nil {
                    Button(NSLocalizedString("Undo", comment: "Rate library: put back the item just removed")) {
                        Task { await model.undoRemove() }
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(String(
                        format: NSLocalizedString(
                            "Undo removing %@", comment: "Rate library: undo button label; the item's name"
                        ),
                        model.pendingRemoval?.name ?? ""
                    ))
                }
                Spacer()
                Button(NSLocalizedString("Done", comment: "Column Manager: close")) {
                    // A removal that cannot be written keeps the panel open, saying so.
                    Task { if await model.commitPendingRemoval() { onDone() } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(ZPDFSpacing.l)
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(ZPDFColor.surface)
        .task { await model.reload() }
        // Closed some other way (Escape, the window): the removal still happens, and a refusal
        // is reported to the host.
        .onDisappear { Task { await model.panelClosed() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Rate Library", comment: "Title of the rate library"))
    }

    /// An amount as the Unit Cost cell prints it: the shared money formatter, half away from
    /// zero at the currency's minor digits. It rounded half-even (ICU's default) in the
    /// process locale, so a rate of 45.125 SEK read "45,12 kr" here and "45,13 kr" in the
    /// cell it priced (T-052).
    static func money(_ amount: Decimal, _ code: String, locale: Locale) -> String {
        LedgerMoneyFormatting.text(amount, currencyCode: code, locale: locale)
    }

    static func summary(_ entry: LedgerRateEntrySummary, locale: Locale) -> String {
        var parts = ["\(money(entry.rate, entry.currencyCode, locale: locale)) / \(entry.basis.unitSymbol)"]
        if let waste = entry.waste {
            parts.append(String(format: NSLocalizedString("waste %@", comment: "Rate library: an item's waste"),
                                (waste * 100).formatted() + " %"))
        }
        if !entry.costCode.isEmpty { parts.append(entry.costCode) }
        if !entry.trade.isEmpty { parts.append(entry.trade) }
        return parts.joined(separator: " · ")
    }
}
