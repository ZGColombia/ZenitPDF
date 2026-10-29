import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Runs an Inspector bulk edit and keeps its refusal on screen (IM-117).
///
/// `applyStyle` used to discard the receipt, so a style edit the engine refused — a markup
/// locked by another path, a document that went read-only — simply did nothing with nothing
/// said. The refusal now lands in ``InspectorEditing/lastStyleRefusal``, which the Appearance
/// section shows as an inline warning; a successful edit clears it.
@MainActor
enum InspectorStyleEditing {

    /// The whole-markup opacity a person can pick, in percent — the Inspector's and the style
    /// strip's one limit (R-084). The floor keeps a markup from being set invisible, and so
    /// unclickable, from a field; the contract's 0…1 still admits anything the document holds.
    static let markupOpacityPercentRange: ClosedRange<Double> = 5...100

    /// A fill's own opacity, in percent. A clear fill is a real choice, so it goes to zero.
    static let fillOpacityPercentRange: ClosedRange<Double> = 0...100

    /// The line widths a person can pick, in points — the Inspector's, the style strip's and
    /// the tool style card's one limit (S-056).
    static let lineWidthRange: ClosedRange<Double> = 0.25...48

    /// The text sizes a person can pick, in points — the same three surfaces' one limit (S-056).
    static let fontSizeRange: ClosedRange<Double> = 4...288

    /// Whether "No Fill" has a fill to remove: every selected markup stores one (S-051).
    ///
    /// The Inspector and the style strip share this rule. The strip used to offer the item
    /// always, and over a markup with no stored fill the edit was a silent no-op — the bulk edit
    /// adds a change only when the style differs, and a rectangle, polygon or area keeps drawing
    /// its derived tint either way.
    static func canRemoveFill(_ markups: [MarkupSummary]) -> Bool {
        !markups.isEmpty && markups.allSatisfy { $0.fillRGBA != nil }
    }

    /// One bulk style edit over a selection: the Inspector's and the style strip's one path
    /// (R-084 — the two were line-for-line copies). Remembers the edit as the tool style when
    /// the selection is all one drawable tool's, and reports a refusal to the Inspector.
    static func apply(_ edit: MarkupStyleEdit, to summary: InspectorSelectionSummary, in environment: ProjectShellEnvironment) {
        guard !edit.isEmpty, !summary.isEmpty,
              let editor = environment.ledger as? any LedgerBulkEditPresenting
        else { return }
        if InspectorPanel.remembersToolStyle(for: summary) {
            environment.toolbar.rememberStyle(edit, kinds: Set(summary.markups.map(\.kind)))
        }
        let request = LedgerBulkEditRequest(markupIDs: Set(summary.markups.map(\.id)), style: edit)
        let editing = environment.inspectorEditing
        // The command bus publishes a new snapshot and every presenter re-adopts it, so neither
        // surface pushes a repaint. What they must not drop is a refusal (IM-117).
        Task { @MainActor in
            await apply(request, with: editor, reportingTo: editing)
        }
    }

    static func apply(
        _ request: LedgerBulkEditRequest,
        with editor: any LedgerBulkEditPresenting,
        reportingTo editing: InspectorEditing
    ) async {
        let receipt = await editor.applyBulkEdit(request)
        editing.lastStyleRefusal = refusalMessage(for: receipt)
            ?? unappliedMessage(for: request, receipt: receipt)
    }

    /// The line to show when a field edit came back changing nothing, or `nil`.
    ///
    /// The Inspector only sends a Label, Notes or Status edit that differs from what the
    /// selection holds, so a receipt that changed no markup and gave no reason means the
    /// document dropped the field. Saying so beats a field that quietly snaps back on the next
    /// selection. Appearance edits are left out: an unchanged style is legitimately no change.
    static func unappliedMessage(for request: LedgerBulkEditRequest, receipt: LedgerBulkEditReceipt) -> String? {
        guard !request.values.isEmpty, request.style.isEmpty, request.color == nil,
              !request.markupIDs.isEmpty, receipt.changedMarkupIDs.isEmpty, receipt.failureDescription == nil
        else { return nil }
        return NSLocalizedString(
            "The change was not saved: this document does not record that field.",
            comment: "Inspector warning when a label, note or status edit came back changing nothing"
        )
    }

    /// The line to show for a receipt, or `nil` when the edit landed.
    static func refusalMessage(for receipt: LedgerBulkEditReceipt) -> String? {
        guard let failure = receipt.failureDescription, !failure.isEmpty else { return nil }
        return String(
            format: NSLocalizedString(
                "The change was not applied: %@",
                comment: "Inspector warning when a style, caption or comment edit is refused; the engine's reason"
            ),
            failure
        )
    }
}

/// What a text field last committed or was seeded with, so one edit is committed once (R-080).
///
/// `ZPDFNumericField` and `InspectorNumberControl` already kept this; the text rows did not, and
/// Return followed by focus loss — before the async bulk edit had landed and re-rendered the
/// summary the commit compares against — sent a second, identical request.
struct InspectorCommitGate: Equatable, Sendable {
    private(set) var committedText: String?

    /// The field shows a stored value now; committing it untouched is not an edit.
    mutating func reseed(_ text: String) {
        committedText = text
    }

    /// Whether `draft` is a new commit, recording it when it is.
    mutating func commit(_ draft: String) -> Bool {
        guard draft != committedText else { return false }
        committedText = draft
        return true
    }
}

/// A single-line text row that commits on Return or on focus loss: the Inspector's Caption and
/// Comment (IM-118).
///
/// The same three rules as the Subject combo: the draft follows the stored value while nobody
/// is typing (so an undone edit is never re-committed, CR-109); a mixed selection opens empty
/// with a "Multiple values" prompt; and committing untouched text — including an empty mixed
/// field — writes nothing.
struct InspectorTextEditField: View {

    /// The value every selected markup shares, or `nil` when they disagree.
    let current: String?
    let isEnabled: Bool
    let accessibilityTitle: String
    /// How the field is drawn: bare and trailing-aligned inside a row, or boxed as the
    /// 2026-09-23 mockup draws Label (one line) and Notes (several lines).
    var style: Style = .inline
    /// Set to `true` to put the caret in the field once it is on screen — the Comments tab's
    /// "Write a Note" does this. The field clears it when it takes focus.
    var wantsFocus: Binding<Bool>? = nil
    let onCommit: (String) -> Void

    /// The field's look. Behaviour — commit on Return or focus loss, mixed prompt, draft
    /// re-seeding — is the same for all three.
    enum Style: Equatable {
        case inline
        case boxed
        case boxedMultiline
    }

    @State private var draft: String = ""
    @State private var gate = InspectorCommitGate()
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        styledField
        .focused($isFocused)
        .disabled(!isEnabled)
        .onAppear {
            draft = current ?? ""
            gate.reseed(draft)
            takeFocusIfWanted()
        }
        .onChange(of: wantsFocus?.wrappedValue ?? false) { _, wanted in if wanted { takeFocusIfWanted() } }
        .onChange(of: current) { _, new in
            guard !isFocused else { return }
            draft = new ?? ""
            gate.reseed(draft)
        }
        .onSubmit { commit() }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .accessibilityLabel(Text(accessibilityTitle))
        .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
    }

    /// Return, then focus leaving before the edit's refresh lands, used to send the same edit
    /// twice; the second changed nothing and raised "The change was not saved" (R-080).
    private func commit() {
        guard gate.commit(draft) else { return }
        onCommit(draft)
    }

    private func takeFocusIfWanted() {
        guard let wantsFocus, wantsFocus.wrappedValue, isEnabled else { return }
        wantsFocus.wrappedValue = false
        // One turn later, so the field is in the responder chain when it is asked.
        Task { @MainActor in isFocused = true }
    }

    private var prompt: String {
        current == nil ? InspectorSelectionSummary.mixedPlaceholder : ""
    }

    @ViewBuilder
    private var styledField: some View {
        switch style {
        case .inline:
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .zpdfText(.control, .textPrimary)
        case .boxed:
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain)
                .zpdfText(InspectorTypography.fieldValue, .textPrimary)
                .inspectorFieldBox(isFocused: isFocused, isHovering: isHovering, isEnabled: isEnabled)
                .onHover { isHovering = $0 }
        case .boxedMultiline:
            TextField(prompt, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .zpdfText(InspectorTypography.fieldValue, .textPrimary)
                .padding(.vertical, ZPDFSpacing.s)
                .inspectorFieldBox(
                    isFocused: isFocused, isHovering: isHovering, isEnabled: isEnabled,
                    minHeight: InspectorMetrics.fieldHeight * 2,
                    alignment: .topLeading
                )
                .onHover { isHovering = $0 }
        }
    }

    /// The bulk edit a commit issues, or `nil` when it would change nothing.
    ///
    /// Value-only so the rule is testable without a view tree.
    static func request(
        text: String,
        current: String?,
        column: LedgerColumnID,
        markupIDs: Set<UUID>
    ) -> LedgerBulkEditRequest? {
        guard !markupIDs.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current {
            // A selection that agrees: unchanged text is not an edit; clearing is.
            guard trimmed != current else { return nil }
        } else {
            // A mixed selection: an untouched (empty) field never blanks every markup.
            guard !trimmed.isEmpty else { return nil }
        }
        return LedgerBulkEditRequest(
            markupIDs: markupIDs,
            values: [column: trimmed.isEmpty ? .empty : .text(trimmed)]
        )
    }
}
