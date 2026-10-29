import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Target

/// Where a scale is applied.
public enum BulkScaleTargetKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Only the page on screen.
    case currentPage
    /// The pages selected in the page navigator.
    case selectedPages
    /// An explicit page range.
    case pageRange
    /// Every page whose media box matches the current page's.
    case matchingDimensions
    /// Every page in the document.
    case entireDocument

    public var id: String { rawValue }

    /// The radio-button label.
    public var displayName: String {
        switch self {
        case .currentPage:
            return NSLocalizedString("Current page", comment: "Bulk scale target")
        case .selectedPages:
            return NSLocalizedString("Selected pages", comment: "Bulk scale target")
        case .pageRange:
            return NSLocalizedString("Page range", comment: "Bulk scale target")
        case .matchingDimensions:
            return NSLocalizedString("Pages with the same dimensions", comment: "Bulk scale target")
        case .entireDocument:
            return NSLocalizedString("Whole document", comment: "Bulk scale target")
        }
    }

    /// One line of help under the label.
    public var explanation: String {
        switch self {
        case .currentPage:
            return NSLocalizedString("Apply the scale to this page only.", comment: "Bulk scale target help")
        case .selectedPages:
            return NSLocalizedString("Apply to the pages selected in the navigator.", comment: "Bulk scale target help")
        case .pageRange:
            return NSLocalizedString("Apply to a run of pages you type in.", comment: "Bulk scale target help")
        case .matchingDimensions:
            return NSLocalizedString(
                "Apply to every page the same size as this one, which is usually the rest of the drawing set.",
                comment: "Bulk scale target help"
            )
        case .entireDocument:
            return NSLocalizedString("Apply to every page, including title sheets and details.", comment: "Bulk scale target help")
        }
    }
}

/// The chosen target, including the typed range.
public struct BulkScaleSelection: Hashable, Sendable {

    /// Which rule picks the pages.
    public var kind: BulkScaleTargetKind
    /// First page of the range, one-based.
    public var rangeStart: Int?
    /// Last page of the range, one-based.
    public var rangeEnd: Int?

    public init(kind: BulkScaleTargetKind = .currentPage, rangeStart: Int? = nil, rangeEnd: Int? = nil) {
        self.kind = kind
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    /// Whether the typed range is usable. A reversed or empty range blocks Apply rather than
    /// being quietly reordered, because a silently swapped range is a silently wrong takeoff.
    public func isRangeValid(pageCount: Int) -> Bool {
        guard kind == .pageRange else { return true }
        guard let start = rangeStart, let end = rangeEnd else { return false }
        return start >= 1 && end >= start && end <= pageCount
    }

    /// The message shown when the range is not usable.
    public func rangeIssue(pageCount: Int) -> String? {
        guard kind == .pageRange, !isRangeValid(pageCount: pageCount) else { return nil }
        guard rangeStart != nil, rangeEnd != nil else {
            return NSLocalizedString("Type a first and a last page.", comment: "Bulk scale range error")
        }
        return String(
            format: NSLocalizedString(
                "The range must run forwards and stay inside pages 1 to %d.",
                comment: "Bulk scale range error: page count"
            ),
            pageCount
        )
    }
}

// MARK: - Impact

/// What applying the scale would touch, computed by the core and shown before anything changes.
public struct BulkScaleImpact: Hashable, Sendable {

    /// How many pages the target resolves to.
    public var pageCount: Int
    /// How many markups sit on those pages.
    public var markupCount: Int
    /// How many of those markups were measured against a different scale and would go stale.
    public var affectedMeasurementCount: Int
    /// How many of the touched pages already carry a locked scale and would be skipped.
    public var lockedPageCount: Int
    /// The page labels, for the preview list.
    public var pageLabels: [String]
    /// The target named only the page the scale was taken from, which already has it (L-69).
    public var targetIsSourcePageOnly: Bool

    public init(
        pageCount: Int,
        markupCount: Int,
        affectedMeasurementCount: Int,
        lockedPageCount: Int = 0,
        pageLabels: [String] = [],
        targetIsSourcePageOnly: Bool = false
    ) {
        self.pageCount = pageCount
        self.markupCount = markupCount
        self.affectedMeasurementCount = affectedMeasurementCount
        self.lockedPageCount = lockedPageCount
        self.pageLabels = pageLabels
        self.targetIsSourcePageOnly = targetIsSourcePageOnly
    }

    /// Why there is nothing to apply, or `nil` when the target names pages.
    ///
    /// L-69: on a one-page drawing, Current page said "This target matches no pages" about the
    /// very page the scale came from. That page already has the scale, and the sheet says so.
    public var emptyTargetMessage: String? {
        guard pageCount == 0 else { return nil }
        if targetIsSourcePageOnly {
            return NSLocalizedString(
                "This page already has this scale — it is the page the scale was taken from. Choose other pages to apply it to.",
                comment: "Bulk scale: the target names only the page the scale came from"
            )
        }
        return NSLocalizedString(
            "This target matches no pages, so there is nothing to apply.",
            comment: "Bulk scale error: empty target"
        )
    }

    /// Nothing would change.
    public static let none = BulkScaleImpact(pageCount: 0, markupCount: 0, affectedMeasurementCount: 0)

    /// The one-line summary above the decision controls.
    ///
    /// Each count is its own pluralised phrase: "1 page, 1 markup, 1 measurement would be
    /// recalculated.", never "1 pages, 1 markups" (T-062).
    public var summary: String {
        String(
            format: NSLocalizedString(
                "%1$@, %2$@, %3$@ would be recalculated.",
                comment: "Bulk scale preview: '4 pages', '30 markups', '12 measurements'"
            ),
            MeasurementPlurals.pages(pageCount),
            MeasurementPlurals.markups(markupCount),
            MeasurementPlurals.measurements(affectedMeasurementCount)
        )
    }

    /// The summary for Keep existing measurements: nothing is recalculated, and saying it
    /// would be — which the Apply button's spoken value did — states the opposite (BH-750).
    public var keepValuesSummary: String {
        let flagged = LocalizedPlural.string(
            "%lld measurements keep their values and are flagged as measured against an older scale.",
            count: affectedMeasurementCount,
            one: NSLocalizedString(
                "%lld measurement keeps its value and is flagged as measured against an older scale.",
                comment: "Bulk scale preview under Keep existing: one flagged measurement"
            ),
            other: NSLocalizedString(
                "%lld measurements keep their values and are flagged as measured against an older scale.",
                comment: "Bulk scale preview under Keep existing: several flagged measurements"
            )
        )
        return String(
            format: NSLocalizedString(
                "%1$@, %2$@. %3$@",
                comment: "Bulk scale preview under Keep existing: '4 pages', '30 markups', the flagged-measurements sentence"
            ),
            MeasurementPlurals.pages(pageCount),
            MeasurementPlurals.markups(markupCount),
            flagged
        )
    }

    /// The preview's summary for the chosen decision: under Keep existing nothing is
    /// recalculated, and the preview used to say it would be (S-092).
    public func summary(for decision: BulkScaleDecision) -> String {
        decision == .keepExisting ? keepValuesSummary : summary
    }

    /// Pages the scale would actually be written to: the target minus the locked ones.
    public var changeablePageCount: Int { max(0, pageCount - lockedPageCount) }
}

// MARK: - Decision

/// What happens to measurements that were taken against the old scale.
public enum BulkScaleDecision: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Recompute every affected measurement against the new scale. Undoable.
    case recalculate
    /// Leave the stored values alone and mark them as measured against an older scale version.
    case keepExisting
    /// Change nothing.
    case cancel

    public var id: String { rawValue }

    /// The choices the decision control offers.
    ///
    /// Not ``cancel``: the sheet has a Cancel button, and a third "Cancel" segment beside it
    /// only produced a state where the primary button was dead for a reason off to the side
    /// (IM-109).
    public static let offeredChoices: [BulkScaleDecision] = [.recalculate, .keepExisting]

    public var displayName: String {
        switch self {
        case .recalculate:
            return NSLocalizedString("Recalculate", comment: "Scale change decision")
        case .keepExisting:
            return NSLocalizedString("Keep existing measurements", comment: "Scale change decision")
        case .cancel:
            return NSLocalizedString("Cancel", comment: "Scale change decision")
        }
    }

    public var explanation: String {
        switch self {
        case .recalculate:
            return NSLocalizedString(
                "Every affected measurement is measured again against the new scale. This is one undoable step.",
                comment: "Scale change decision help"
            )
        case .keepExisting:
            return NSLocalizedString(
                "Stored values stay as they are and are flagged as measured against an older scale version.",
                comment: "Scale change decision help"
            )
        case .cancel:
            return NSLocalizedString("Nothing changes.", comment: "Scale change decision help")
        }
    }
}

// MARK: - Sheet

/// Applies one scale to more than the current page, with the impact shown first.
public struct BulkScaleSheet: View {

    private let scale: ScaleSummary
    private let pageCount: Int
    private let currentPageLabel: String
    @Binding private var selection: BulkScaleSelection
    private let impact: BulkScaleImpact
    private let onApply: (BulkScaleSelection, BulkScaleDecision) -> Void
    private let onCancel: () -> Void
    /// The decisions offered. A host that cannot keep stale values yet offers only Recalculate,
    /// and the control is replaced by a sentence saying so rather than a choice that lies.
    private let decisions: [BulkScaleDecision]

    @State private var decision: BulkScaleDecision = .recalculate
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case rangeStart
        case rangeEnd
        case apply
        case cancel
    }

    /// - Parameters:
    ///   - scale: the scale being applied.
    ///   - pageCount: pages in the document, used to validate a typed range.
    ///   - currentPageLabel: label of the page on screen.
    ///   - selection: which pages the scale goes to.
    ///   - impact: what the core says would be touched. Recomputed by the host whenever
    ///     `selection` changes.
    ///   - onApply: called with the target and the decision. Only ever called with a usable
    ///     target and a decision other than `.cancel`.
    ///   - onCancel: dismiss without applying.
    public init(
        scale: ScaleSummary,
        pageCount: Int,
        currentPageLabel: String,
        selection: Binding<BulkScaleSelection>,
        impact: BulkScaleImpact,
        onApply: @escaping (BulkScaleSelection, BulkScaleDecision) -> Void = { _, _ in },
        decisions: [BulkScaleDecision] = BulkScaleDecision.offeredChoices,
        onCancel: @escaping () -> Void = {}
    ) {
        self.scale = scale
        self.pageCount = pageCount
        self.currentPageLabel = currentPageLabel
        self._selection = selection
        self.impact = impact
        self.onApply = onApply
        self.onCancel = onCancel
        self.decisions = decisions.isEmpty ? [.recalculate] : decisions
    }

    private var rangeIssue: String? { selection.rangeIssue(pageCount: pageCount) }
    private var canApply: Bool {
        Self.canApply(selection: selection, pageCount: pageCount, impact: impact, decision: decision)
    }

    /// Whether Apply may run. Pure so the rule is testable without a sheet on screen.
    ///
    /// A target whose every page is locked changes nothing; Apply used to stay live for it and
    /// fire a no-op the person was told was an applied scale (BH-749).
    static func canApply(
        selection: BulkScaleSelection,
        pageCount: Int,
        impact: BulkScaleImpact,
        decision: BulkScaleDecision
    ) -> Bool {
        selection.isRangeValid(pageCount: pageCount)
            && impact.changeablePageCount > 0
            && decision != .cancel
    }

    /// A typed page number as the selection stores it.
    ///
    /// Carried through unclamped: the field used to clamp 25 to 20 in a 20-page set, so a
    /// mistyped range quietly retargeted instead of raising "stay inside pages 1 to 20"
    /// (BH-261). A value too large for an `Int` becomes `Int.max`, which the range check then
    /// refuses, rather than trapping.
    static func pageNumber(from value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        guard abs(value) < 1e15 else { return value < 0 ? Int.min : Int.max }
        return Int(value.rounded())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Apply Scale", comment: "Bulk scale sheet title"),
                subtitle: String(
                    format: NSLocalizedString(
                        "%1$@ · %2$@ · from page %3$@",
                        comment: "Bulk scale subtitle: scale name, ratio, source page"
                    ),
                    scale.name,
                    scale.displayString,
                    currentPageLabel
                )
            )
            .padding(.horizontal, ZPDFSpacing.xl)
            .padding(.vertical, ZPDFSpacing.m)

            ZPDFHairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.xl) {
                    targetSection
                    previewSection
                    decisionSection
                }
                .padding(ZPDFSpacing.xl)
            }

            ZPDFHairlineDivider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Apply Scale", comment: "Accessibility label")))
    }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(NSLocalizedString("Apply to", comment: "Bulk scale section title"))

            ForEach(BulkScaleTargetKind.allCases) { kind in
                targetRow(kind)
            }

            if selection.kind == .pageRange {
                HStack(spacing: ZPDFSpacing.m) {
                    ZPDFNumericField(
                        value: intBinding(\.rangeStart),
                        accessibilityTitle: NSLocalizedString("First page", comment: "Accessibility label"),
                        placeholder: NSLocalizedString("From", comment: "Range field placeholder"),
                        fractionDigits: 0
                    )
                    .frame(maxWidth: 96)
                    .focused($focusedControl, equals: .rangeStart)

                    Text(NSLocalizedString("to", comment: "Between the two page range fields"))
                        .zpdfText(.caption, .textSecondary)

                    ZPDFNumericField(
                        value: intBinding(\.rangeEnd),
                        accessibilityTitle: NSLocalizedString("Last page", comment: "Accessibility label"),
                        placeholder: NSLocalizedString("To", comment: "Range field placeholder"),
                        fractionDigits: 0
                    )
                    .frame(maxWidth: 96)
                    .focused($focusedControl, equals: .rangeEnd)

                    Spacer(minLength: 0)
                }
                .padding(.leading, ZPDFSpacing.xxl)

                if let rangeIssue {
                    ZPDFInlineWarning(severity: .danger, message: rangeIssue)
                }
            }
        }
    }

    private func targetRow(_ kind: BulkScaleTargetKind) -> some View {
        let isChosen = selection.kind == kind
        return Button {
            selection.kind = kind
        } label: {
            HStack(alignment: .top, spacing: ZPDFSpacing.m) {
                ZPDFGlyphView(
                    .symbol(isChosen ? .success : .disclosureClosed),
                    size: ZPDFSpacing.Control.iconSmall
                )
                .foregroundStyle(isChosen ? ZPDFColor.accentCyan : ZPDFColor.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName)
                        .zpdfFont(isChosen ? .control.withWeight(.semibold) : .control)
                        .foregroundStyle(ZPDFColor.textPrimary)
                    Text(kind.explanation)
                        .zpdfText(.caption, .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.displayName))
        .accessibilityHint(Text(kind.explanation))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(NSLocalizedString("Preview", comment: "Bulk scale section title"))

            HStack(spacing: ZPDFSpacing.m) {
                ZPDFStatusPill(
                    severity: .info,
                    title: NSLocalizedString("Pages", comment: "Preview counter"),
                    value: impact.pageCount.formatted()
                )
                ZPDFStatusPill(
                    severity: .info,
                    title: NSLocalizedString("Markups", comment: "Preview counter"),
                    value: impact.markupCount.formatted()
                )
                ZPDFStatusPill(
                    severity: impact.affectedMeasurementCount > 0 ? .warning : .success,
                    title: Self.affectedCounterTitle(for: decision),
                    value: impact.affectedMeasurementCount.formatted()
                )
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(NSLocalizedString("Preview", comment: "Accessibility label")))
            .accessibilityValue(Text(impact.summary(for: decision)))

            if impact.pageCount > 0, impact.changeablePageCount == 0 {
                ZPDFInlineWarning(
                    severity: .danger,
                    message: NSLocalizedString(
                        "Every page in this target has a locked scale, so nothing would change. Unlock a page's scale first.",
                        comment: "Bulk scale error: every targeted page is locked"
                    )
                )
            } else if impact.lockedPageCount > 0 {
                ZPDFInlineWarning(
                    severity: .warning,
                    message: Self.lockedPagesWarning(impact.lockedPageCount)
                )
            }

            if let empty = impact.emptyTargetMessage {
                ZPDFInlineWarning(
                    // The page that already has the scale is a fact, not a fault (L-69).
                    severity: impact.targetIsSourcePageOnly ? .info : .danger,
                    message: empty
                )
            } else if !impact.pageLabels.isEmpty {
                Text(impact.pageLabels.joined(separator: ", "))
                    .zpdfText(.caption, .textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: NSLocalizedString(
                                    "Pages: %@",
                                    comment: "Accessibility label listing affected pages"
                                ),
                                impact.pageLabels.joined(separator: ", ")
                            )
                        )
                    )
            }
        }
    }

    // MARK: Decision

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(
                NSLocalizedString("Existing measurements", comment: "Bulk scale section title")
            )
            Text(
                NSLocalizedString(
                    "Changing a scale changes what the measurements on those pages mean. Choose what happens to them.",
                    comment: "Explanation above the recalculate decision"
                )
            )
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if decisions.count > 1 {
                ZPDFSegmentedControl(
                    selection: $decision,
                    segments: decisions.map {
                        .init(value: $0, title: $0.displayName, helpText: $0.explanation)
                    },
                    accessibilityTitle: NSLocalizedString(
                        "What happens to existing measurements",
                        comment: "Accessibility label"
                    )
                )
            }

            Text(decision.explanation)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.m) {
            Spacer(minLength: 0)

            Button(action: onCancel) {
                Text(NSLocalizedString("Cancel", comment: "Button: dismiss the bulk scale sheet"))
                    .zpdfFont(.control)
                    .padding(.horizontal, ZPDFSpacing.l)
                    .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ZPDFColor.textPrimary)
            .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.small)
            .focused($focusedControl, equals: .cancel)
            .zpdfFocusRing(focusedControl == .cancel, cornerRadius: ZPDFRadius.small)
            .keyboardShortcut(.cancelAction)

            Button {
                guard canApply else { return }
                onApply(selection, decision)
            } label: {
                Text(applyTitle)
                    .zpdfFont(.control.withWeight(.semibold))
                    .padding(.horizontal, ZPDFSpacing.l)
                    .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canApply ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
            .zpdfControlBackground(fill: canApply ? .selection : .elevated, cornerRadius: ZPDFRadius.small)
            .focused($focusedControl, equals: .apply)
            .zpdfFocusRing(focusedControl == .apply, cornerRadius: ZPDFRadius.small)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
            .accessibilityLabel(Text(applyTitle))
            .accessibilityValue(Text(applyAccessibilityValue))
        }
        .padding(.horizontal, ZPDFSpacing.xl)
        .padding(.vertical, ZPDFSpacing.l)
    }

    /// The title of the preview's affected-measurement counter. It follows the decision: under
    /// Keep existing the measurements are flagged, not recalculated, and the pill used to say
    /// "Recalculated" whichever was chosen (S-092).
    static func affectedCounterTitle(for decision: BulkScaleDecision) -> String {
        decision == .keepExisting
            ? NSLocalizedString("Flagged", comment: "Preview counter: measurements kept and flagged as measured against an older scale")
            : NSLocalizedString("Recalculated", comment: "Preview counter")
    }

    /// The warning above the preview when some targeted pages have a locked scale: "1 of these
    /// pages has a locked scale", never "1 of these pages have" (T-062).
    static func lockedPagesWarning(_ lockedPageCount: Int) -> String {
        LocalizedPlural.string(
            "%lld of these pages have a locked scale and will be skipped.",
            count: lockedPageCount,
            one: NSLocalizedString(
                "%lld of these pages has a locked scale and will be skipped.",
                comment: "Bulk scale warning: one targeted page is locked"
            ),
            other: NSLocalizedString(
                "%lld of these pages have a locked scale and will be skipped.",
                comment: "Bulk scale warning: several targeted pages are locked"
            )
        )
    }

    private var applyTitle: String {
        decision == .keepExisting
            ? NSLocalizedString("Apply and Keep Values", comment: "Bulk scale primary button")
            : NSLocalizedString("Apply and Recalculate", comment: "Bulk scale primary button")
    }

    private var applyAccessibilityValue: String {
        Self.applyAccessibilityValue(selection: selection, pageCount: pageCount, impact: impact, decision: decision)
    }

    /// What VoiceOver says for the Apply button.
    static func applyAccessibilityValue(
        selection: BulkScaleSelection,
        pageCount: Int,
        impact: BulkScaleImpact,
        decision: BulkScaleDecision
    ) -> String {
        if let rangeIssue = selection.rangeIssue(pageCount: pageCount) { return rangeIssue }
        if impact.pageCount == 0 {
            return NSLocalizedString(
                "No pages match this target",
                comment: "Accessibility value when the bulk target is empty"
            )
        }
        if impact.changeablePageCount == 0 {
            return NSLocalizedString(
                "Every page in this target has a locked scale",
                comment: "Accessibility value when every targeted page is locked"
            )
        }
        switch decision {
        case .cancel:
            return NSLocalizedString(
                "Choose Recalculate or Keep existing measurements",
                comment: "Accessibility value when the decision is Cancel"
            )
        case .keepExisting, .recalculate:
            return impact.summary(for: decision)
        }
    }

    // MARK: Shared

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .zpdfText(.sectionHeader, .textSecondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    /// Bridges the sheet's `Int?` page numbers to the numeric field's `Double?`.
    private func intBinding(_ keyPath: WritableKeyPath<BulkScaleSelection, Int?>) -> Binding<Double?> {
        Binding(
            get: { selection[keyPath: keyPath].map(Double.init) },
            set: { selection[keyPath: keyPath] = Self.pageNumber(from: $0) }
        )
    }
}
