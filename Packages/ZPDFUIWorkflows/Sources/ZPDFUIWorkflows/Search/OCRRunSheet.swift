import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The sheet that reads text off scanned pages.
///
/// It says three things before it says anything else: which pages it will read, that it reads
/// them on this Mac, and that what it produces is a search aid rather than a transcription. Then
/// it gets on with it, with a Cancel button that is always live while it runs.
public struct OCRRunSheet: View {

    /// The identifier of the ``ZPDFViewMarker`` behind the footer's Close button (CR-202).
    public static let footerCloseMarkerIdentifier = "zpdf.ocr.footer-close"

    private let model: OCRRunModel
    private let onClose: () -> Void

    /// - Parameters:
    ///   - model: the run state.
    ///   - onClose: closes the sheet. Never destructive; a run in flight is cancelled first.
    public init(model: OCRRunModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                    pagesSection
                    languagesSection
                    if !model.pageResults.isEmpty { resultsSection }
                }
            }
            progressSection
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 560, height: 620)
        .background(ZPDFColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Read text from scanned pages",
            comment: "Accessibility label for the OCR sheet"
        )))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
                Text(NSLocalizedString(
                    "Read text from scanned pages",
                    comment: "Title of the OCR sheet"
                ))
                .zpdfText(.windowTitle, .textPrimary)
                Spacer(minLength: ZPDFSpacing.s)
                // The footer's Close button already owns the Escape shortcut, so this one is
                // the visible header control only — never two answers to one key.
                WorkflowPanelCloseButton(
                    panelName: NSLocalizedString("Read Text from Scanned Pages", comment: "Panel name for the OCR sheet"),
                    isEscapeRouted: false,
                    action: {
                        if model.phase.isCancellable { model.cancel() }
                        onClose()
                    }
                )
            }
            ZPDFInlineWarning(severity: .info, message: OCRDisclosure.localOnly)
            ZPDFInlineWarning(severity: .warning, message: OCRDisclosure.searchAidOnly)
        }
    }

    // MARK: - Pages

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Pages", comment: "OCR sheet section"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)

            Picker(selection: rangeKindBinding) {
                Text(OCRPageRangeSelection.currentPage.displayName).tag(RangeKind.currentPage)
                Text(OCRPageRangeSelection.allPages.displayName).tag(RangeKind.allPages)
                Text(OCRPageRangeSelection.range(lowerBound: 1, upperBound: 1).displayName).tag(RangeKind.range)
                Text(OCRPageRangeSelection.custom("").displayName).tag(RangeKind.custom)
            } label: {
                Text(NSLocalizedString("Pages to read", comment: "OCR page range picker label"))
            }
            .pickerStyle(.radioGroup)
            .zpdfFont(.control)

            if rangeKindBinding.wrappedValue == .range {
                rangeBoundsRow
            }
            if rangeKindBinding.wrappedValue == .custom {
                customRangeRow
            }

            if !model.isScopeEditable {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "The pages to read are fixed while a run is in progress. Stop the run to change them.",
                        comment: "OCR sheet: the scope controls are locked while reading"
                    )
                )
            }

            HStack(spacing: ZPDFSpacing.s) {
                ZPDFStatusPill(
                    severity: model.resolvedPageIndices.isEmpty ? .warning : .neutral,
                    title: NSLocalizedString("Selected", comment: "OCR sheet: selected page count"),
                    value: model.rangeSummary,
                    usesMonospacedValue: false
                )
                Toggle(isOn: Binding(
                    get: { model.skipsPagesWithText },
                    set: { model.skipsPagesWithText = $0 }
                )) {
                    Text(NSLocalizedString(
                        "Skip pages that already have real text",
                        comment: "OCR sheet: skip pages with embedded text"
                    ))
                    .zpdfText(.caption, .textSecondary)
                }
                .toggleStyle(.checkbox)
            }
        }
        // Every scope control at once, so a run in flight cannot have its denominator moved
        // out from under it and a person cannot be shown a bar that describes a different run
        // from the one that is happening. Finding CR-181.
        .disabled(!model.isScopeEditable)
    }

    private var rangeBoundsRow: some View {
        HStack(spacing: ZPDFSpacing.s) {
            ZPDFNumericField(
                value: Binding(
                    get: { Double(model.rangeLowerBound) },
                    set: { model.rangeLowerBound = Self.pageNumber($0, pageCount: model.pages.count) }
                ),
                accessibilityTitle: NSLocalizedString("First page", comment: "OCR page range lower bound"),
                fractionDigits: 0,
                range: 1...Double(max(1, model.pages.count))
            )
            .frame(width: 88)
            Text(NSLocalizedString("to", comment: "Between two page range bounds"))
                .zpdfText(.control, .textSecondary)
            ZPDFNumericField(
                value: Binding(
                    get: { Double(model.rangeUpperBound) },
                    set: { model.rangeUpperBound = Self.pageNumber($0, pageCount: model.pages.count) }
                ),
                accessibilityTitle: NSLocalizedString("Last page", comment: "OCR page range upper bound"),
                fractionDigits: 0,
                range: 1...Double(max(1, model.pages.count))
            )
            .frame(width: 88)
            Spacer(minLength: 0)
        }
    }

    /// A page number from whatever the field hands back.
    ///
    /// `Int(_:)` traps on a `Double` that is infinite or NaN, with the message "Double value
    /// cannot be converted to Int because it is either infinite or NaN". The field's own parser
    /// no longer produces one, and this is the second lock on the same door: a page index is
    /// not a place to find out that a clamp did not clamp. Finding CR-166.
    static func pageNumber(_ value: Double?, pageCount: Int) -> Int {
        guard let value, value.isFinite else { return 1 }
        let highest = Double(max(1, pageCount))
        return Int(min(max(value.rounded(), 1), highest))
    }

    private var customRangeRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(
                NSLocalizedString("1-4, 7, 12-14", comment: "Placeholder showing the page list format"),
                text: Binding(
                    get: { model.customRangeText },
                    set: { model.customRangeText = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .zpdfFont(.control)
            .accessibilityLabel(Text(NSLocalizedString(
                "Specific pages",
                comment: "Accessibility label for the OCR custom page list field"
            )))
            Text(NSLocalizedString(
                "Separate pages with commas and use a dash for a run. Anything outside the document is ignored.",
                comment: "Help text for the OCR custom page list field"
            ))
            .zpdfText(.caption, .textSecondary)
            // A typo used to vanish silently; now each fragment that names no page is said
            // back (IM-148).
            ForEach(model.rejectedRangeFragments, id: \.self) { fragment in
                ZPDFInlineWarning(
                    severity: .warning,
                    message: String(
                        format: NSLocalizedString(
                            "\u{201C}%@\u{201D} is not a page or range in this document — type e.g. 1-4, 7.",
                            comment: "OCR custom page list: a fragment that names no page. %@ is the fragment"
                        ),
                        fragment
                    )
                )
            }
        }
    }

    // MARK: - Languages

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("Languages", comment: "OCR sheet section"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
            Text(NSLocalizedString(
                "Choosing fewer languages makes recognition both faster and more accurate. Order matters: the first is tried first.",
                comment: "Help text for the OCR language chooser"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(model.availableLanguages) { language in
                    Toggle(isOn: languageBinding(language)) {
                        Text(language.displayName).zpdfText(.control, .textPrimary)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(Text(language.displayName))
                }
            }

            if model.selectedLanguageIDs.isEmpty {
                ZPDFInlineWarning(
                    severity: .warning,
                    message: NSLocalizedString(
                        "Pick at least one language. Recognition cannot start without one.",
                        comment: "OCR sheet: no language chosen"
                    )
                )
            }
        }
    }

    private func languageBinding(_ language: OCRLanguage) -> Binding<Bool> {
        Binding(
            get: { model.selectedLanguageIDs.contains(language.id) },
            set: { isOn in
                if isOn {
                    if !model.selectedLanguageIDs.contains(language.id) {
                        model.selectedLanguageIDs.append(language.id)
                    }
                } else {
                    model.selectedLanguageIDs.removeAll { $0 == language.id }
                }
            }
        )
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            Text(NSLocalizedString("What was read", comment: "OCR sheet section"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)

            confidenceSummary

            // Lazy, so a 500-page run builds the rows on screen rather than all 500 on every
            // reported page (IM-151).
            LazyVStack(spacing: 1) {
                ForEach(model.pageResults) { result in
                    resultRow(result)
                }
            }
        }
    }

    private var confidenceSummary: some View {
        HStack(spacing: ZPDFSpacing.s) {
            if let average = model.averageConfidence {
                ZPDFStatusPill(
                    severity: OCRConfidenceBand(confidence: average).displaySeverity,
                    title: NSLocalizedString("Average confidence", comment: "OCR results summary"),
                    value: "\(Int((average * 100).rounded()))%"
                )
            }
            ForEach(OCRConfidenceBand.allCases) { band in
                if let count = model.confidenceBandCounts[band], count > 0 {
                    ZPDFStatusPill(
                        severity: band.displaySeverity,
                        title: band.displayName,
                        value: count.formatted()
                    )
                }
            }
            if !model.pagesWithoutText.isEmpty {
                ZPDFStatusPill(
                    severity: .warning,
                    title: OCRPageStatus.noTextFound.displayName,
                    value: model.pagesWithoutText.count.formatted()
                )
            }
            if !model.pagesSkippedForText.isEmpty {
                ZPDFStatusPill(
                    severity: .neutral,
                    title: OCRPageStatus.skippedHasText.displayName,
                    value: model.pagesSkippedForText.count.formatted()
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func resultRow(_ result: OCRPageStatusSummary) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            ZPDFGlyphView(result.status.glyph, size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.color(result.status.displaySeverity.tint))
                .accessibilityHidden(true)
            Text(result.pageLabel)
                .zpdfText(.monoNumeric, .textPrimary)
                .frame(width: 72, alignment: .leading)
            Text(result.status.displayName).zpdfText(.control, .textSecondary)
                .help(result.status.explanation)
            Spacer(minLength: ZPDFSpacing.s)
            if let confidence = result.confidence {
                Text("\(Int((confidence * 100).rounded()))%")
                    .zpdfText(.monoNumeric, .textSecondary)
            }
            if result.recognizedWordCount > 0 {
                Text(WorkflowPlurals.words(result.recognizedWordCount))
                .zpdfText(.caption, .textSecondary)
            }
        }
        .padding(.horizontal, ZPDFSpacing.s)
        .frame(height: ZPDFSpacing.Control.listRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(result.accessibilityLabel))
    }

    // MARK: - Progress and footer

    @ViewBuilder
    private var progressSection: some View {
        switch model.phase {
        case .running, .cancelling:
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "Reading pages",
                        comment: "Accessibility label for the OCR progress bar"
                    )))
                    .accessibilityValue(Text("\(Int((model.progressFraction * 100).rounded()))%"))
                Text(progressCaption).zpdfText(.caption, .textSecondary)
            }
        case let .failed(error):
            ZPDFInlineWarning(
                severity: .danger,
                message: ZPDFErrorCopyTable.copy(for: error).message
            )
        case .cancelled:
            ZPDFInlineWarning(
                severity: .info,
                message: NSLocalizedString(
                    "Reading stopped. The pages that were already read stay searchable.",
                    comment: "OCR sheet: run cancelled"
                )
            )
        case .finished:
            // What the pages returned, not a fixed "searchable now" (L-20b).
            let outcome = model.finishedOutcome
            ZPDFInlineWarning(severity: outcome.displaySeverity, message: outcome.message)
        case .idle:
            EmptyView()
        }
    }

    private var progressCaption: String {
        if model.phase == .running, let estimate = model.progressEstimate {
            return estimate
        }
        if let page = model.pageBeingRead {
            return String(
                format: NSLocalizedString(
                    "Reading page %@…",
                    comment: "OCR progress caption. %@ is the page label"
                ),
                page.pageLabel
            )
        }
        if model.phase == .cancelling {
            return NSLocalizedString(
                "Finishing the current page, then stopping.",
                comment: "OCR progress caption while cancelling"
            )
        }
        return model.rangeSummary
    }

    /// The footer's buttons, in order from left to right.
    ///
    /// Close is the sheet's one dismiss action (L-30). The host's sheet chrome used to add a
    /// Done button under it that did the same thing, so the sheet offered two answers to one
    /// question; the chrome now leaves the dismissal to this footer. While a run is in flight
    /// the footer also offers Continue in Background (when the host can show progress
    /// elsewhere) and Stop Reading; otherwise Start Reading.
    public enum FooterAction: Hashable, Sendable {
        case close
        case continueInBackground
        case stopReading
        case startReading
    }

    /// The footer for a phase — see ``FooterAction``.
    public static func footerActions(phase: OCRRunPhase, offersBackground: Bool) -> [FooterAction] {
        var actions: [FooterAction] = [.close]
        if phase.isCancellable, offersBackground { actions.append(.continueInBackground) }
        actions.append(phase.isCancellable || phase == .cancelling ? .stopReading : .startReading)
        return actions
    }

    private var footer: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Spacer(minLength: 0)
            ForEach(
                Self.footerActions(phase: model.phase, offersBackground: model.onContinueInBackground != nil),
                id: \.self
            ) { action in
                footerButton(action)
            }
        }
    }

    @ViewBuilder
    private func footerButton(_ action: FooterAction) -> some View {
        switch action {
        case .close:
            Button(NSLocalizedString("Close", comment: "Close the OCR sheet")) {
                if model.phase.isCancellable { model.cancel() }
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            // Lets a test click the rendered footer button where it is drawn (CR-202).
            .zpdfMarker(Self.footerCloseMarkerIdentifier)
        case .continueInBackground:
            Button(NSLocalizedString("Continue in Background", comment: "Close the OCR sheet and let the run go on")) {
                model.continueInBackground()
                onClose()
            }
            .help(NSLocalizedString(
                "Closes this sheet and keeps reading. Progress stays in the status bar, where you can stop it.",
                comment: "Help for the OCR Continue in Background button"
            ))
        case .stopReading:
            Button(NSLocalizedString("Stop Reading", comment: "Cancel an OCR run")) {
                model.cancel()
            }
            .disabled(model.phase == .cancelling)
        case .startReading:
            Button(NSLocalizedString("Start Reading", comment: "Start an OCR run")) {
                model.start()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)
        }
    }

    /// Whether the host's sheet chrome should add its own Done button under this sheet. It
    /// should not: the footer's Close is the one dismiss action (L-30).
    public static let wantsHostDoneButton = false

    // MARK: - Range kind

    private enum RangeKind: Hashable {
        case currentPage
        case allPages
        case range
        case custom
    }

    private var rangeKindBinding: Binding<RangeKind> {
        Binding(
            get: {
                switch model.rangeSelection {
                case .currentPage: return .currentPage
                case .allPages: return .allPages
                case .range: return .range
                case .custom: return .custom
                }
            },
            set: { kind in
                switch kind {
                case .currentPage: model.rangeSelection = .currentPage
                case .allPages: model.rangeSelection = .allPages
                case .range: model.rangeSelection = .range(
                    lowerBound: model.rangeLowerBound,
                    upperBound: model.rangeUpperBound
                )
                case .custom: model.rangeSelection = .custom(model.customRangeText)
                }
            }
        )
    }
}
