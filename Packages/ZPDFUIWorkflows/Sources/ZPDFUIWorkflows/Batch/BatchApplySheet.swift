import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The scoped batch apply sheet: choose a scope, choose a position, see
/// the count, apply.
///
/// The layout follows the order of the decision rather than the order of the data model —
/// *which pages*, *where on them*, *what will happen* — because the third of those is the
/// one the person has to read before pressing the button, and a preview under the fold is a
/// preview nobody sees.
public struct BatchApplySheet: View {

    @Bindable private var model: BatchApplyModel
    private let title: String

    /// Whether the host's sheet chrome should add its own Done button under this panel. It
    /// should not: the footer's Close (Cancel while running) is the sheet's one dismiss action.
    /// L-58/L-60: Batch Stamp and Header, Footer or Sheet Number showed Close and Apply and a
    /// separate Done bar under them, the doubled dismiss L-30 removed from the OCR sheet.
    public static let wantsHostDoneButton = false

    /// - Parameters:
    ///   - model: the sheet's state.
    ///   - title: what is being placed, for example "Batch Stamp: Reviewed".
    public init(model: BatchApplyModel, title: String) {
        self.model = model
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(title).zpdfText(.windowTitle, .textPrimary)

            scopeSection
            ZPDFHairlineDivider()
            positionSection
            ZPDFHairlineDivider()
            if let prompt = model.placementPrompt {
                promptSection(prompt)
                ZPDFHairlineDivider()
            }
            previewSection

            Spacer(minLength: ZPDFSpacing.s)
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 460)
        .background(ZPDFColor.background)
        .onAppear { model.preview() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Batch apply", comment: "Accessibility label for the scoped batch apply sheet"
        )))
    }

    // MARK: Scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Pages", comment: "Batch apply sheet section header"))
                .zpdfText(.sectionHeader, .textSecondary)

            ZPDFInspectorRow(label: NSLocalizedString("Scope", comment: "Batch apply field")) {
                Picker("", selection: $model.scopeChoice) {
                    ForEach(BatchApplyModel.ScopeChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .labelsHidden()
                .zpdfFont(.control)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Page scope", comment: "Accessibility label for the batch scope picker"
                )))
            }

            switch model.scopeChoice {
            case .pageRange:
                ZPDFInspectorRow(label: NSLocalizedString("From", comment: "Batch apply field")) {
                    pageField($model.rangeFrom, label: NSLocalizedString(
                        "First page", comment: "Accessibility label for the batch range start"
                    ))
                }
                ZPDFInspectorRow(label: NSLocalizedString("Through", comment: "Batch apply field")) {
                    pageField($model.rangeThrough, label: NSLocalizedString(
                        "Last page", comment: "Accessibility label for the batch range end"
                    ))
                }
            case .matchingSize:
                ZPDFInspectorRow(label: NSLocalizedString("Width (pt)", comment: "Batch apply field")) {
                    decimalField($model.sizeWidthPoints, range: 1...14_400, label: NSLocalizedString(
                        "Page width in points", comment: "Accessibility label for the batch size width"
                    ))
                }
                ZPDFInspectorRow(label: NSLocalizedString("Height (pt)", comment: "Batch apply field")) {
                    decimalField($model.sizeHeightPoints, range: 1...14_400, label: NSLocalizedString(
                        "Page height in points", comment: "Accessibility label for the batch size height"
                    ))
                }
            case .matchingSearchTerm:
                ZPDFInspectorRow(label: NSLocalizedString("Contains", comment: "Batch apply field")) {
                    TextField("", text: $model.searchTerm)
                        .textFieldStyle(.roundedBorder)
                        .zpdfFont(.control)
                        .accessibilityLabel(Text(NSLocalizedString(
                            "Search term", comment: "Accessibility label for the batch search term"
                        )))
                }
            case .navigatorSelection:
                // The scope reads a real multi-selection now, so it has to say what it
                // read — an empty selection is a legitimate answer and the person needs to
                // know that is what the sheet is working from.
                Text(navigatorSelectionSentence)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .allPages:
                EmptyView()
            }

            Toggle(isOn: $model.skipPagesAlreadyCarrying) {
                Text(NSLocalizedString(
                    "Skip pages that already carry it",
                    comment: "Batch apply option: the skip rule"
                ))
                .zpdfText(.control, .textPrimary)
            }
            .toggleStyle(.checkbox)
        }
        // No per-field `onChange` here any more: every choice re-previews itself through the
        // model (IM-144, BH-830).
    }

    /// What the navigator-selection scope is working from, in words.
    private var navigatorSelectionSentence: String {
        Self.navigatorSelectionSentence(count: model.navigatorSelection.count)
    }

    /// "1 page selected in the Navigator." — it said "1 page(s)" (V-075).
    static func navigatorSelectionSentence(count: Int) -> String {
        guard count > 0 else {
            return NSLocalizedString(
                "No page is selected in the Navigator. Command-click or Shift-click page thumbnails to select more than one.",
                comment: "Batch apply, navigator-selection scope with an empty selection"
            )
        }
        return LocalizedPlural.string(
            "%lld pages selected in the Navigator.",
            count: count,
            one: NSLocalizedString(
                "%lld page selected in the Navigator.",
                comment: "Batch apply, navigator-selection scope with one page selected"
            ),
            other: NSLocalizedString(
                "%lld pages selected in the Navigator.",
                comment: "Batch apply, navigator-selection scope. %lld is the selected page count"
            )
        )
    }

    // MARK: Position

    /// The anchor, and the sentence explaining why it is an anchor and not a point.
    private var positionSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Position", comment: "Batch apply sheet section header"))
                .zpdfText(.sectionHeader, .textSecondary)

            ZPDFInspectorRow(label: NSLocalizedString("Anchor", comment: "Batch apply field")) {
                Picker("", selection: $model.anchorCorner) {
                    Text(NSLocalizedString("Centred", comment: "Batch apply anchor"))
                        .tag(BatchAnchorCorner?.none)
                    ForEach(BatchAnchorCorner.allCases) { corner in
                        Text(corner.displayName).tag(BatchAnchorCorner?.some(corner))
                    }
                }
                .labelsHidden()
                .zpdfFont(.control)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Anchor position", comment: "Accessibility label for the batch anchor picker"
                )))
            }
            if model.anchorCorner != nil {
                ZPDFInspectorRow(label: NSLocalizedString("Inset X (pt)", comment: "Batch apply field")) {
                    decimalField($model.insetX, range: 0...model.maximumInsetPoints, label: NSLocalizedString(
                        "Horizontal inset in points", comment: "Accessibility label for the batch inset X"
                    ))
                }
                ZPDFInspectorRow(label: NSLocalizedString("Inset Y (pt)", comment: "Batch apply field")) {
                    decimalField($model.insetY, range: 0...model.maximumInsetPoints, label: NSLocalizedString(
                        "Vertical inset in points", comment: "Accessibility label for the batch inset Y"
                    ))
                }
                if let issue = model.insetIssue {
                    ZPDFInlineWarning(severity: .warning, message: issue)
                }
            }
            Text(NSLocalizedString(
                "The anchor is measured on each page's own box, so sheets of different sizes each get it in the same corner.",
                comment: "Batch apply explanation of per-page anchoring"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the placement question sits: beside its field when it fits the label column,
    /// above a full-width field when it does not.
    public enum PromptPlacement: Hashable, Sendable {
        case beside
        case above
    }

    /// L-60: the header and footer question — a whole sentence naming the template fields —
    /// went into the 92 pt label column and read "Text for each…". A question that does not fit
    /// the column now sits above the field, wrapped, whole.
    public static func promptPlacement(for prompt: String) -> PromptPlacement {
        let width = (prompt as NSString).size(withAttributes: [.font: ZPDFTypography.nsFont(.control)]).width
        return Double(width) <= Double(ZPDFSpacing.Control.inspectorLabelWidth) ? .beside : .above
    }

    @ViewBuilder
    private func promptSection(_ prompt: String) -> some View {
        switch Self.promptPlacement(for: prompt) {
        case .beside:
            ZPDFInspectorRow(label: prompt) {
                promptField(prompt)
            }
        case .above:
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                Text(prompt)
                    .zpdfText(.control, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                promptField(prompt)
            }
        }
    }

    private func promptField(_ prompt: String) -> some View {
        TextField("", text: $model.promptedText)
            .textFieldStyle(.roundedBorder)
            .zpdfFont(.control)
            .accessibilityLabel(Text(prompt))
    }

    // MARK: Preview

    /// The count, before anything happens. The reason this sheet exists.
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            // The scope in words, above the count. The count on its own is a number the
            // person has to take on trust; the pair is something they can check against
            // what they believe they chose.
            if let scope = model.scopeSentence {
                Text(scope)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(scope))
            }
            if let caution = model.scopeCautionSentence {
                Text(caution)
                    .zpdfText(.caption, .warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.previewSentence)
                .zpdfText(.control, .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(model.previewSentence))
            if let skip = model.skipSentence {
                Text(skip)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isRunning {
                ProgressView(value: model.progressFraction ?? 0)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Batch progress", comment: "Accessibility label for the batch progress bar"
                    )))
                    .accessibilityValue(Text(model.progressDetail))
                Text(model.progressDetail).zpdfText(.caption, .textSecondary)
            }
            // After the run: the short-run or cancel sentence (W-072). It used to live only in
            // the `isRunning` block above, which the model has left by the time it is written.
            if let result = model.resultSentence {
                Text(result)
                    .zpdfText(.caption, model.resultIsShortfall ? .warning : .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(result))
            }
            if let failure = model.resultFailure {
                Text(failure).zpdfText(.caption, .warning).fixedSize(horizontal: false, vertical: true)
            }
            Text(NSLocalizedString(
                "One Undo takes the whole batch back.",
                comment: "Batch apply reassurance about undo"
            ))
            .zpdfText(.caption, .textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(model.isRunning
                ? NSLocalizedString("Cancel", comment: "Batch apply, stop the running batch")
                : NSLocalizedString("Close", comment: "Batch apply, dismiss the sheet")
            ) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)

            if model.needsFreshPreview {
                Button(NSLocalizedString(
                    "Preview Again", comment: "Batch apply, count the pages again after a short or failed run"
                )) {
                    model.preview()
                }
            }

            Button(NSLocalizedString("Apply", comment: "Batch apply, run the batch")) {
                Task { await model.run() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply)
        }
    }

    // MARK: Fields

    /// A page number, through the shared numeric field and its one grammar (IM-145), bounded
    /// to the drawing set. The old value-formatted `TextField` was locale-strict and
    /// silently reverted anything it could not read.
    private func pageField(_ binding: Binding<Int>, label: String) -> some View {
        ZPDFNumericField(
            value: Binding(
                get: { Double(binding.wrappedValue) },
                set: { binding.wrappedValue = Int(($0 ?? 1).rounded()) }
            ),
            accessibilityTitle: label,
            fractionDigits: 0,
            range: model.pageCount.map { 1...Double($0) } ?? 1...Double(Int32.max)
        )
        .frame(width: 80)
    }

    /// A length in points, through the shared numeric field (IM-145). `36,5` and `36.5` are the
    /// same inset whichever locale the estimator works in.
    private func decimalField(_ binding: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        ZPDFNumericField(
            value: Binding(
                get: { binding.wrappedValue },
                set: { if let value = $0 { binding.wrappedValue = value } }
            ),
            unit: "pt",
            accessibilityTitle: label,
            fractionDigits: 2,
            range: range
        )
        .frame(width: 110)
    }
}
