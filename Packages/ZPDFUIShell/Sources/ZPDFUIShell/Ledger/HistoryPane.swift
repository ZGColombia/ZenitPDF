import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The History tab of the bottom pane: the project's append-only audit trail
/// (ADR-0007 §2, §3), filterable by page, markup and action, with a jump-to-markup on
/// every row that concerns one.
///
/// The trail answers the question undo cannot: "why does this say 21.34 m², who made it
/// say that, and did it change after the revision came in". Rows are shown newest first —
/// the way the question is asked — while exports keep trail order.
struct HistoryPaneContent: View {

    let environment: ProjectShellEnvironment

    @State private var filter = LedgerAuditFilter()

    private var audit: (any LedgerAuditPresenting)? {
        environment.ledger as? LedgerAuditPresenting
    }

    var body: some View {
        if let audit {
            content(audit)
        } else {
            ZPDFEmptyState(
                glyph: .symbol(.quantityLedger),
                title: NSLocalizedString("No history", comment: "History pane title when the trail is unavailable"),
                message: NSLocalizedString(
                    "This project has no audit trail to show.",
                    comment: "History pane message when the trail is unavailable"
                )
            )
        }
    }

    private func content(_ audit: any LedgerAuditPresenting) -> some View {
        let events = cachedEvents(audit)
        return VStack(spacing: 0) {
            filterBar(audit, resultCount: events.count)
            ZPDFHairlineDivider(axis: .horizontal)
            if events.isEmpty {
                emptyTrail
            } else {
                eventList(events)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "History",
            comment: "Accessibility label for the History pane"
        )))
    }

    /// The trail can be empty two ways: nothing recorded yet, or a filter that matches
    /// nothing. Both are stated; neither renders as a blank body.
    private var emptyTrail: some View {
        VStack {
            Text(followsSelection && selectedMarkupID == nil
                ? NSLocalizedString(
                    "Select exactly one markup to see its changes.",
                    comment: "History pane hint while Selected Markup is on and zero or several markups are selected"
                )
                : effectiveFilter.isEmpty
                ? NSLocalizedString(
                    "No changes recorded yet. Measure or edit something and it appears here.",
                    comment: "History pane hint when the project has no audit entries"
                )
                : NSLocalizedString(
                    "No changes match the current filter.",
                    comment: "History pane hint when the filter excludes every entry"
                ))
                .zpdfText(.caption, .textSecondary)
                .padding(ZPDFSpacing.m)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filter bar

    private func filterBar(_ audit: any LedgerAuditPresenting, resultCount: Int) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            pageFilterMenu(audit)
            actionFilterMenu(audit)
            // Its own view (R-096): only the toggle reads the canvas selection, for its disabled
            // state, so a canvas click with "Selected Markup" off re-runs the toggle and not the
            // pane's body and its trail.
            HistorySelectionFilterToggle(environment: environment, followsSelection: $followsSelection)
            if !effectiveFilter.isEmpty || followsSelection {
                Button(NSLocalizedString("Clear Filter", comment: "History pane action")) {
                    filter = LedgerAuditFilter()
                    followsSelection = false
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
            Text(entryCountText(resultCount))
                .zpdfText(.caption, .textSecondary)
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(minHeight: ZPDFSpacing.Control.panelHeader)
    }

    private func pageFilterMenu(_ audit: any LedgerAuditPresenting) -> some View {
        Menu {
            Button(NSLocalizedString("All Pages", comment: "History page filter option")) {
                filter.pageLabel = nil
            }
            ForEach(audit.auditPageLabels, id: \.self) { label in
                Button(label) { filter.pageLabel = label }
            }
        } label: {
            Text(filter.pageLabel
                ?? NSLocalizedString("All Pages", comment: "History page filter option"))
                .zpdfText(.control, .textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Show changes on one page only", comment: "History page filter help"))
        .accessibilityLabel(Text(NSLocalizedString("Filter by page", comment: "History page filter accessibility label")))
    }

    private func actionFilterMenu(_ audit: any LedgerAuditPresenting) -> some View {
        Menu {
            Button(NSLocalizedString("All Actions", comment: "History action filter option")) {
                filter.action = nil
            }
            ForEach(audit.auditActions, id: \.self) { action in
                Button(Self.displayName(forAction: action)) { filter.action = action }
            }
        } label: {
            Text(filter.action.map(Self.displayName(forAction:))
                ?? NSLocalizedString("All Actions", comment: "History action filter option"))
                .zpdfText(.control, .textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Show one kind of change only", comment: "History action filter help"))
        .accessibilityLabel(Text(NSLocalizedString("Filter by action", comment: "History action filter accessibility label")))
    }

    /// Whether the trail is in "follow the selection" mode.
    ///
    /// A mode, not a snapshot. `filter.markupID` used to be *written* the moment the box was
    /// ticked and never looked at again, so clicking the next markup left the trail showing
    /// the previous one's changes under a checkbox that still said "Selected Markup"
    /// (CR-115). Now nothing is written: the id is derived from the live canvas selection on
    /// every pass, by ``effectiveFilter(base:followsSelection:selection:)``.
    @State private var followsSelection = false

    /// The filter actually applied: the three menus, plus the live selection when the trail
    /// is following it.
    private var effectiveFilter: LedgerAuditFilter {
        Self.effectiveFilter(
            base: filter,
            followsSelection: followsSelection,
            // IM-213: the selection is read only while the trail follows it, so a canvas
            // click with the toggle off does not touch the History body at all.
            selection: followsSelection ? environment.canvas.selectedMarkupIDs : []
        )
    }

    /// The identity no markup has: a filter on it matches nothing.
    static let noMarkup = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    /// The whole selection-following rule, as a function of its three inputs.
    ///
    /// Static and value-only so the rule is testable without a view tree.
    ///
    /// BH-293: a multi-selection or an empty selection shows an EMPTY trail while the mode is
    /// on. It used to resolve to `markupID = nil`, which `LedgerAuditFilter.matches` reads as
    /// "no markup filter" — the pane listed every change in the project under the ticked
    /// "Selected Markup" checkbox. It now filters on ``noMarkup``, which nothing matches.
    static func effectiveFilter(
        base: LedgerAuditFilter,
        followsSelection: Bool,
        selection: Set<UUID>
    ) -> LedgerAuditFilter {
        var effective = base
        guard followsSelection else {
            effective.markupID = nil
            return effective
        }
        effective.markupID = selection.count == 1 ? selection.first : noMarkup
        return effective
    }

    /// IM-213: the query runs once per distinct effective filter and trail revision, not on
    /// every body pass.
    @State private var eventCache = HistoryEventCache()

    private func cachedEvents(_ audit: any LedgerAuditPresenting) -> [LedgerAuditEvent] {
        Self.events(matching: effectiveFilter, audit: audit, ledgerRevision: environment.ledger.contentRevision, cache: eventCache)
    }

    /// The trail through the memo, keyed on the ledger's revision **and the trail's own**
    /// (V-042). Keyed on the ledger alone, a trail write that rebuilt nothing — Verify Scale, or
    /// an append that published after the ledger adopted — was never re-read, and the list and
    /// its "n entries" stayed stale while the filter menus beside them updated.
    static func events(
        matching filter: LedgerAuditFilter,
        audit: any LedgerAuditPresenting,
        ledgerRevision: Int,
        cache: HistoryEventCache
    ) -> [LedgerAuditEvent] {
        cache.events(for: filter, revision: .init(ledger: ledgerRevision, trail: audit.auditRevision)) {
            audit.auditEvents(matching: $0)
        }
    }

    /// The markup the canvas has selected, or `nil` for none and for a multi-selection.
    private var selectedMarkupID: UUID? {
        let selected = environment.canvas.selectedMarkupIDs
        return selected.count == 1 ? selected.first : nil
    }


    /// BH-810: "1 entries".
    static func entryCountText(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld entries",
            count: count,
            one: NSLocalizedString("%lld entry", comment: "History pane count: one audit entry shown"),
            other: NSLocalizedString("%lld entries", comment: "History pane count of audit entries shown")
        )
    }

    private func entryCountText(_ count: Int) -> String { Self.entryCountText(count) }

    // MARK: - Rows

    private func eventList(_ events: [LedgerAuditEvent]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Newest first: the question is almost always about the latest change.
                ForEach(events.reversed()) { event in
                    eventRow(event)
                    ZPDFHairlineDivider(axis: .horizontal)
                }
            }
        }
    }

    private func eventRow(_ event: LedgerAuditEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.m) {
            Text(Self.timestampFormatter.string(from: event.occurredAt))
                .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                .frame(width: 110, alignment: .leading)
            Text(event.actionDisplayName)
                .zpdfText(.control.withWeight(.semibold), .textPrimary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: ZPDFSpacing.s) {
                    if let title = Self.markupTitle(event) {
                        Text(title).zpdfText(.control, .textPrimary).lineLimit(1)
                    }
                    if let page = Self.pageText(event) {
                        Text(page).zpdfText(.caption, .textSecondary)
                    }
                }
                if let detail = Self.detailText(event) {
                    Text(detail)
                        .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(event.actor)
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
            // BH-811: a deleted markup has nothing to reveal; offering the action selected a
            // row that no longer exists.
            if let markupID = Self.revealableMarkupID(event, exists: { environment.ledger.index(of: $0) != nil }) {
                ZPDFToolbarButton(
                    glyph: .symbol(.select),
                    title: NSLocalizedString("Reveal Markup", comment: "History row action: select and zoom to the markup")
                ) {
                    Self.reveal(markupID: markupID, environment: environment)
                }
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .padding(.vertical, ZPDFSpacing.xs)
        .frame(minHeight: ZPDFSpacing.Control.listRow)
        .accessibilityElement(children: .combine)
    }

    /// The row's Reveal Markup: selects the ledger row, then pages the canvas to the markup
    /// through the page-turning reveal, so the page-scoped panels follow a markup on another
    /// sheet (R-078).
    static func reveal(markupID: UUID, environment: ProjectShellEnvironment) {
        environment.ledger.select(rowIDs: [markupID], additive: false)
        environment.reveal(markupID: markupID, selecting: false)
    }

    // MARK: - Formatting

    /// Which markup a row is about: what it is ("Area R-1", "Text", "Image") and its subject when
    /// it has one, or `nil` for a project-level entry such as a scale change.
    ///
    /// L-79: a row printed the subject alone, and a text box, a note or an image has none, so
    /// every such row read only its page ("1") and an "Edited" could not be told from a "Deleted".
    static func markupTitle(_ event: LedgerAuditEvent) -> String? {
        let name = event.markupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subject = event.markupSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [name, subject == name ? "" : subject].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The page a row's markup is on, said as a page rather than a bare number (L-79).
    static func pageText(_ event: LedgerAuditEvent) -> String? {
        guard let page = event.pageLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty else {
            return nil
        }
        return String(format: NSLocalizedString("Page %@", comment: "History row: the page a markup is on"), page)
    }

    /// What changed: the values that moved, or — for a step that moved none, a move, Group, Align,
    /// Send to Back — the command's own name (``LedgerAuditEvent/historyDetail``). Those rows read
    /// "Edited" with nothing beside them, and on an area, a length or a count they listed every
    /// unchanged value instead of the command (L-79).
    static func detailText(_ event: LedgerAuditEvent) -> String? {
        event.historyDetail
    }

    /// The markup a row's Reveal action targets, or `nil` when there is nothing to reveal:
    /// no markup, a deletion event, or a markup the ledger no longer has.
    static func revealableMarkupID(_ event: LedgerAuditEvent, exists: (UUID) -> Bool) -> UUID? {
        guard let markupID = event.markupID else { return nil }
        if event.action == "markup_deleted" { return nil }
        return exists(markupID) ? markupID : nil
    }

    static func displayName(forAction action: String) -> String {
        LedgerAuditEvent(
            sequence: 0, occurredAt: .distantPast, action: action, actor: ""
        ).actionDisplayName
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A one-entry memo of the History query (IM-213): the last effective filter and revision,
/// and the events they produced. A reference type so a body pass can update it without a state
/// write.
@MainActor
final class HistoryEventCache {

    /// What the memo is keyed on: the ledger's revision and the trail's own (V-042).
    struct Revision: Hashable {
        var ledger: Int
        var trail: Int
    }

    private var lastFilter: LedgerAuditFilter?
    private var lastRevision: Revision?
    private var events: [LedgerAuditEvent] = []
    private(set) var queryCount = 0

    func events(
        for filter: LedgerAuditFilter,
        revision: Revision,
        query: (LedgerAuditFilter) -> [LedgerAuditEvent]
    ) -> [LedgerAuditEvent] {
        if lastFilter == filter, lastRevision == revision { return events }
        events = query(filter)
        queryCount += 1
        lastFilter = filter
        lastRevision = revision
        return events
    }
}

/// The History filter bar's "Selected Markup" checkbox: on, the trail shows the selected
/// markup's changes. Off while nothing single is selected, unless it is already on.
///
/// A child view so that it alone observes the canvas selection (R-096). As a property of
/// ``HistoryPaneContent`` its disabled state was computed in the pane's body, so every canvas
/// click re-ran that body and re-diffed the whole audit trail — contrary to IM-213.
struct HistorySelectionFilterToggle: View {

    let environment: ProjectShellEnvironment
    @Binding var followsSelection: Bool

    var body: some View {
        Toggle(
            NSLocalizedString("Selected Markup", comment: "History filter: only the selected markup's changes"),
            isOn: $followsSelection
        )
        .toggleStyle(.checkbox)
        .disabled(environment.canvas.selectedMarkupIDs.count != 1 && !followsSelection)
        .help(NSLocalizedString(
            "Show only the selected markup's changes",
            comment: "History selection filter help"
        ))
    }
}
