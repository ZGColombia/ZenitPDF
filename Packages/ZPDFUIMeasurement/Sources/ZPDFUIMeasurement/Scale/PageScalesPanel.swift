import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Rows

/// Where one sheet's scale stands (NL-MEASURE-02): set, proposed from the sheet's own text,
/// or neither. Every state is words and a glyph, never colour alone.
public enum PageScaleStatus: Hashable, Sendable {
    /// The sheet has a scale: its ratio text and where it came from.
    case set(ratio: String, source: String)
    /// No scale yet, and the sheet's text states one.
    case proposed(ratio: String, evidence: String)
    /// No scale yet, and the sheet's text, once read, states none.
    case none
    /// The sheet's text is still being read.
    case reading

    /// The status word the row shows.
    public var title: String {
        switch self {
        case .set: return NSLocalizedString("Set", comment: "Page scale status: the sheet has a scale")
        case .proposed: return NSLocalizedString("Proposed", comment: "Page scale status: the sheet's text states a scale")
        case .none: return NSLocalizedString("No scale", comment: "Page scale status: no scale and none found")
        case .reading: return NSLocalizedString("Reading…", comment: "Page scale status: the sheet's text is being read")
        }
    }

    var severity: ZPDFSeverity {
        switch self {
        case .set: return .success
        case .proposed: return .info
        case .none: return .warning
        case .reading: return .neutral
        }
    }

    /// The ratio shown beside the status, when there is one.
    var ratio: String? {
        switch self {
        case let .set(ratio, _), let .proposed(ratio, _): return ratio
        case .none, .reading: return nil
        }
    }

    /// The detail line: the source of a set scale, or the text a proposal was read from.
    var detail: String? {
        switch self {
        case let .set(_, source): return source
        case let .proposed(_, evidence):
            return String(
                format: NSLocalizedString("Read from “%@”", comment: "Page scale detail: the matched title-block text"),
                evidence
            )
        case .none, .reading: return nil
        }
    }

    /// Whether the row can be applied from its proposal.
    public var isProposed: Bool {
        if case .proposed = self { return true }
        return false
    }
}

/// One sheet in the Page Scales list.
public struct PageScaleRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let sizeText: String
    public var status: PageScaleStatus

    public init(id: UUID, label: String, sizeText: String, status: PageScaleStatus) {
        self.id = id
        self.label = label
        self.sizeText = sizeText
        self.status = status
    }
}

// MARK: - Panel

/// Every sheet of the set with its scale status, and one press to apply the proposals read
/// from the sheets' own title blocks (NL-MEASURE-02). Nothing is applied without that press.
public struct PageScalesPanel: View {

    private let rows: [PageScaleRow]
    @Binding private var selection: Set<UUID>
    private let onApplyProposals: (Set<UUID>) -> Void
    private let onApplyScaleToPages: () -> Void
    private let onClose: () -> Void

    public init(
        rows: [PageScaleRow],
        selection: Binding<Set<UUID>>,
        onApplyProposals: @escaping (Set<UUID>) -> Void = { _ in },
        onApplyScaleToPages: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self._selection = selection
        self.onApplyProposals = onApplyProposals
        self.onApplyScaleToPages = onApplyScaleToPages
        self.onClose = onClose
    }

    /// The rows an Apply Proposed Scales press writes: the selected proposed rows, or every
    /// proposed row when none is selected. Pure, for the tests.
    nonisolated public static func proposalTargets(rows: [PageScaleRow], selection: Set<UUID>) -> Set<UUID> {
        let proposed = rows.filter(\.status.isProposed).map(\.id)
        let chosen = proposed.filter { selection.contains($0) }
        return Set(chosen.isEmpty ? proposed : chosen)
    }

    /// The one-line count above the list.
    ///
    /// Only a sheet whose text has been read and states no scale is "without a scale". A sheet
    /// still being read is counted as such: the panel opens with every unscaled sheet reading,
    /// and the summary used to report the whole set as unscaled until each proposal landed
    /// (S-093).
    nonisolated public static func summary(of rows: [PageScaleRow]) -> String {
        var set = 0, proposed = 0, missing = 0, reading = 0
        for row in rows {
            switch row.status {
            case .set: set += 1
            case .proposed: proposed += 1
            case .none: missing += 1
            case .reading: reading += 1
            }
        }
        // The sheet count is its own pluralised phrase: "1 sheet: …", never "1 sheets" (T-062).
        let sheets = MeasurementPlurals.sheets(rows.count)
        guard reading > 0 else {
            return String(
                format: NSLocalizedString(
                    "%1$@: %2$d set, %3$d proposed, %4$d without a scale.",
                    comment: "Page scales summary: '4 sheets', set, proposed, none"
                ),
                sheets, set, proposed, missing
            )
        }
        return String(
            format: NSLocalizedString(
                "%1$@: %2$d set, %3$d proposed, %4$d without a scale, %5$d still being read.",
                comment: "Page scales summary while sheets are being read: '4 sheets', set, proposed, none, reading"
            ),
            sheets, set, proposed, missing, reading
        )
    }

    /// The title of the button that applies the proposals: "Apply 1 Proposed Scale" /
    /// "Apply 3 Proposed Scales" (T-062).
    nonisolated static func applyProposalsTitle(_ count: Int) -> String {
        LocalizedPlural.string(
            "Apply %lld Proposed Scales",
            count: count,
            one: NSLocalizedString("Apply %lld Proposed Scale", comment: "Page scales button: apply one proposal"),
            other: NSLocalizedString("Apply %lld Proposed Scales", comment: "Page scales button: number of proposals to apply")
        )
    }

    public var body: some View {
        let targets = Self.proposalTargets(rows: rows, selection: selection)
        return VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Page Scales", comment: "Page scales sheet title"),
                subtitle: Self.summary(of: rows)
            )
            .padding(.horizontal, ZPDFSpacing.xl)
            .padding(.vertical, ZPDFSpacing.m)
            ZPDFHairlineDivider()

            List(rows, selection: $selection) { row in
                rowView(row)
            }
            .accessibilityLabel(Text(NSLocalizedString("Sheets and their scales", comment: "Accessibility label of the page scales list")))

            ZPDFHairlineDivider()
            HStack(spacing: ZPDFSpacing.m) {
                Button(NSLocalizedString("Apply Scale to Pages…", comment: "Page scales button: open the bulk apply sheet"), action: onApplyScaleToPages)
                    .accessibilityHint(Text(NSLocalizedString(
                        "Applies the scale of the page on screen to other pages.",
                        comment: "Accessibility hint of Apply Scale to Pages"
                    )))
                Spacer(minLength: 0)
                Button(NSLocalizedString("Close", comment: "Button: close the page scales sheet"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(Self.applyProposalsTitle(targets.count)) {
                    onApplyProposals(targets)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty)
                .accessibilityHint(Text(NSLocalizedString(
                    "Sets each chosen sheet to the scale printed on it. One undo takes them all back.",
                    comment: "Accessibility hint of Apply Proposed Scales"
                )))
            }
            .zpdfFont(.control)
            .padding(.horizontal, ZPDFSpacing.xl)
            .padding(.vertical, ZPDFSpacing.l)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Page Scales", comment: "Accessibility label of the page scales sheet")))
    }

    private func rowView(_ row: PageScaleRow) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.label).zpdfText(.control, .textPrimary).lineLimit(1)
                Text(row.sizeText).zpdfText(.caption, .textSecondary).lineLimit(1)
            }
            Spacer(minLength: ZPDFSpacing.m)
            VStack(alignment: .trailing, spacing: 1) {
                ZPDFStatusPill(severity: row.status.severity, title: row.status.title, value: row.status.ratio)
                if let detail = row.status.detail {
                    Text(detail).zpdfText(.caption, .textSecondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, ZPDFSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.label))
        .accessibilityValue(Text([row.status.title, row.status.ratio, row.status.detail].compactMap { $0 }.joined(separator: ", ")))
    }
}
