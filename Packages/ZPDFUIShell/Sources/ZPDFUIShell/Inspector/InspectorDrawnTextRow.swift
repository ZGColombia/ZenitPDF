import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Markup tab's **Text** row for a Text or Callout: the words the box draws on the sheet,
/// edited apart from its Notes (NL-COLLAB-18).
///
/// Before the split the drawn words and the note were one field, so the Notes row rewrote the
/// sheet and every text box appeared on the Comments tab as a "comment".
extension InspectorPanel {

    /// The words every selected markup draws, when every one of them is a text-drawing kind.
    /// `.some(nil)` means they disagree; `nil` means the row does not apply.
    static func drawnTextState(_ summary: InspectorSelectionSummary) -> String?? {
        guard !summary.isEmpty, summary.markups.allSatisfy({ $0.drawnText != nil }) else { return nil }
        return .some(InspectorSelectionSummary.commonValue(summary.markups.compactMap(\.drawnText)))
    }

    @ViewBuilder
    func drawnTextRow(_ summary: InspectorSelectionSummary) -> some View {
        if let state = Self.drawnTextState(summary) {
            InspectorStackedRow(label: NSLocalizedString("Text", comment: "Inspector row label: the words a text box or callout draws")) {
                InspectorTextEditField(
                    current: state,
                    isEnabled: canEditText(summary),
                    accessibilityTitle: NSLocalizedString(
                        "Text drawn on the sheet",
                        comment: "Accessibility label of the inspector's text field for a text box or callout"
                    ),
                    style: .boxedMultiline
                ) { applyDrawnText($0, to: summary) }
                .id(Set(summary.markups.map(\.id)))
            }
        }
    }

    /// Sends a drawn-text edit to the app, which applies it as one undoable step. A text equal
    /// to what every selected box already draws writes nothing.
    func applyDrawnText(_ text: String, to summary: InspectorSelectionSummary) {
        guard canEditText(summary), let state = Self.drawnTextState(summary) else { return }
        if let current = state, current == text { return }
        let ids = Set(summary.markups.map(\.id))
        environment.inspectorEditing.onEditText?(ids, text)
    }
}
