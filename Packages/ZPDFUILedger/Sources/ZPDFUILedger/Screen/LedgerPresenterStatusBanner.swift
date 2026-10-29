import SwiftUI
import ZPDFDesignSystem

/// The ledger's own trouble, said above the table: a rebuild that failed (the table keeps the
/// last good result) and a sort the ledger refused.
///
/// The presenter already publishes both (`lastRebuildError`, `unappliedSortMessage`); without a
/// place to show them the table silently kept stale rows, or a header arrow for a sort that
/// never ran (IM-056 / BH-102). The pane passes the presenter's values in; nothing here reads
/// a presenter, so the view stays independent of the protocol that carries them.
public struct LedgerPresenterStatusBanner: View {

    private let rebuildError: String?
    private let unappliedSortMessage: String?
    private let onDismissRebuildError: () -> Void

    /// Creates the banner. It draws nothing when both messages are `nil`.
    public init(
        rebuildError: String?,
        unappliedSortMessage: String?,
        onDismissRebuildError: @escaping () -> Void
    ) {
        self.rebuildError = rebuildError
        self.unappliedSortMessage = unappliedSortMessage
        self.onDismissRebuildError = onDismissRebuildError
    }

    /// The sentence shown for a failed rebuild.
    public static func rebuildErrorText(_ reason: String) -> String {
        String(
            format: NSLocalizedString(
                "The ledger could not be updated: %1$@ Showing the last result.",
                comment: "Ledger banner when a rebuild failed: the reason"
            ),
            reason.hasSuffix(".") ? reason : reason + "."
        )
    }

    /// Whether the banner has anything to say.
    public var isEmpty: Bool { rebuildError == nil && unappliedSortMessage == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            if let rebuildError {
                ZPDFInlineWarning(
                    severity: .danger,
                    message: Self.rebuildErrorText(rebuildError),
                    onDismiss: onDismissRebuildError
                )
            }
            if let unappliedSortMessage {
                ZPDFInlineWarning(severity: .info, message: unappliedSortMessage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Ledger status", comment: "Accessibility label of the ledger status banner"))
    }
}
