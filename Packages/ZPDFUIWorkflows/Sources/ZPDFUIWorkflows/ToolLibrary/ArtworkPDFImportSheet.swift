import SwiftUI
import ZPDFDesignSystem

/// The sheet a person sees between choosing a PDF and importing artwork out of it.
///
/// It exists for the two things the old flow did silently:
///
/// 1. **Which page.** A multi-page PDF used to import page 1 and say so in the button's help
///    text. The chooser is here, one-based, with the page count stated.
/// 2. **What they will get.** Imported vector artwork is single-ink (ADR-0011 §2.4), because
///    `VectorPrimitive` records paint role and stroke width and not ink. A two-colour logo
///    arrives in one colour. That is stated here, before the Import button, with the
///    alternative named — so the sheet appears for a one-page PDF too, where there is nothing
///    to choose but there is still something to know.
///
/// Everything it shows comes off ``ArtworkImportCoordinator`` and every button calls into it,
/// so the flow is asserted against the coordinator rather than by clicking this.
struct ArtworkPDFImportSheet: View {

    @Bindable var coordinator: ArtworkImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString(
                "Import PDF Artwork",
                comment: "Title of the sheet that imports stamp artwork from a PDF page"
            ))
            .zpdfText(.windowTitle, .textPrimary)

            Text(coordinator.pendingTitle)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pending = coordinator.pendingPDF, pending.offersPageChoice {
                pageChooser(pageCount: pending.summary.pageCount)
            }

            singleInkNotice

            Spacer(minLength: ZPDFSpacing.s)

            HStack(spacing: ZPDFSpacing.s) {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "Dismiss the artwork import sheet")) {
                    coordinator.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(coordinator.isBusy)

                Button(NSLocalizedString("Import", comment: "Commit the artwork import")) {
                    Task { @MainActor in await coordinator.confirm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(coordinator.isBusy)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 420)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Import PDF artwork",
            comment: "Accessibility label for the artwork import sheet"
        )))
    }

    /// One-based, because that is how a person and every other page control in this product
    /// counts pages. A stepper rather than a menu: a seal is usually on page 1, 2 or 3, and a
    /// 400-page file must not build a 400-item menu to say so.
    @ViewBuilder
    private func pageChooser(pageCount: Int) -> some View {
        ZPDFInspectorRow(label: NSLocalizedString("Page", comment: "Artwork import sheet field")) {
            HStack(spacing: ZPDFSpacing.s) {
                Stepper(
                    value: $coordinator.pageNumber,
                    in: 1...max(1, pageCount)
                ) {
                    Text(String(
                        format: NSLocalizedString(
                            "%1$lld of %2$lld",
                            comment: "Artwork import page chooser. 1: chosen page, 2: page count"
                        ),
                        Int64(coordinator.pageNumber),
                        Int64(pageCount)
                    ))
                    .zpdfText(.control, .textPrimary)
                }
                .accessibilityLabel(Text(NSLocalizedString(
                    "Page to import",
                    comment: "Accessibility label for the artwork import page chooser"
                )))
                .accessibilityValue(Text(String(
                    format: NSLocalizedString(
                        "Page %1$lld of %2$lld",
                        comment: "Accessibility value for the artwork import page chooser"
                    ),
                    Int64(coordinator.pageNumber),
                    Int64(pageCount)
                )))
            }
        }
        .zpdfFont(.control)
    }

    /// Labelled, not colour-only, and phrased as what will happen rather than as a hazard:
    /// single ink is correct for a seal and wrong for a brand mark, and only the person knows
    /// which of the two they are holding.
    private var singleInkNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.xs) {
            Image(systemName: "info.circle")
                .foregroundStyle(ZPDFColor.textSecondary)
                .accessibilityHidden(true)
            Text(ArtworkVectorLimits.singleInkNotice)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(ArtworkVectorLimits.singleInkNotice))
    }
}
