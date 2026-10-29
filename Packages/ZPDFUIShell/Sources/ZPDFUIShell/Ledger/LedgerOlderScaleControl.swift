import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The ledger bar's "Older scale" control (NL-MEASURE-03, r2-layers follow-up): a count of the
/// rows whose value was kept under an older scale, in words and a glyph — never colour alone —
/// and a toggle that narrows the ledger to exactly those rows.
struct LedgerOlderScaleControl: View {

    let filtering: any LedgerOlderScaleFiltering

    var body: some View {
        let on = filtering.showsOnlyOlderScaleValues
        ZPDFToolbarButton(
            glyph: .symbol(.warning),
            title: Self.title(count: filtering.olderScaleRowCount),
            showsTitle: true,
            isSelected: on,
            helpText: on
                ? NSLocalizedString("Show every row again", comment: "Help on the ledger's Older scale control while it filters")
                : NSLocalizedString(
                    "These values were kept under an older scale. Show only them, then recalculate or check them before relying on a total.",
                    comment: "Help on the ledger's Older scale control"
                )
        ) {
            filtering.setShowsOnlyOlderScaleValues(!on)
        }
        .accessibilityValue(Text(on
            ? NSLocalizedString("Showing only these", comment: "Accessibility value of the Older scale control while it filters")
            : ""))
    }

    /// "Older scale (3)".
    static func title(count: Int) -> String {
        String(format: NSLocalizedString("Older scale (%d)", comment: "Ledger bar control: rows whose value was kept under an older scale; count"), count)
    }
}
