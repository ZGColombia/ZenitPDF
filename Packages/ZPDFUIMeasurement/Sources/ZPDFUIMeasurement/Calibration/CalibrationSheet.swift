import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The two-point calibration sheet, uniform or with separate X and Y axes.
///
/// The sheet is built around prevention. Every blocked state — identical points, a zero or
/// negative length, an unusable unit, near-parallel axes — appears the moment it becomes true,
/// beside the control that caused it, and Apply stays disabled until it is gone. An extreme
/// scale is not blocked outright but needs an explicit tick, because a 1:2000 site plan is
/// unusual and still legitimate.
public struct CalibrationSheet: View {

    @Binding private var draft: CalibrationDraft
    private let pageLabel: String
    /// Why the sheet opened, when the host has a reason to say — "This page has no scale yet"
    /// after a refused measurement (LT3-05). Shown above the mode picker.
    private let notice: String?
    private let onPickPoint: (CalibrationPickStep) -> Void
    private let onClearPoints: (CalibrationAxis) -> Void
    private let onApply: (ScaleSummary) -> Void
    private let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: Control?

    /// What the length fields are holding but have not committed yet (live finding LT-5).
    @State private var pendingPrimaryLength: String = ""
    @State private var pendingSecondaryLength: String = ""
    /// The length field to move keyboard focus to, once the last point lands (IM-102).
    @State private var lengthFocusRequest: CalibrationAxis?

    private enum Control: Hashable {
        case name
        case apply
        case cancel
    }

    /// Which calibration line a control belongs to.
    public enum CalibrationAxis: String, Hashable, Sendable, CaseIterable {
        case primary
        case secondary
    }

    /// - Parameters:
    ///   - draft: the calibration being built.
    ///   - pageLabel: the page the calibration applies to, shown in the header.
    ///   - onPickPoint: hands point picking back to the canvas for one step.
    ///   - onClearPoints: clears the picked points of one axis. Defaults to an explicit no-op
    ///     so a preview can render the sheet without a canvas behind it.
    ///   - onApply: called with the finished scale. Only ever called when the draft validates.
    ///   - onCancel: dismiss without applying.
    public init(
        draft: Binding<CalibrationDraft>,
        pageLabel: String,
        notice: String? = nil,
        onPickPoint: @escaping (CalibrationPickStep) -> Void = { _ in },
        onClearPoints: @escaping (CalibrationAxis) -> Void = { _ in },
        onApply: @escaping (ScaleSummary) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self._draft = draft
        self.pageLabel = pageLabel
        self.notice = notice
        self.onPickPoint = onPickPoint
        self.onClearPoints = onClearPoints
        self.onApply = onApply
        self.onCancel = onCancel
    }

    /// The draft as the sheet actually reads it: the bound draft with whatever the length
    /// fields are still holding folded in.
    ///
    /// Everything downstream — the readout, the issue list, whether Apply is live and what
    /// Apply commits — runs off this rather than off ``draft``. A person who typed a length
    /// and pressed Apply has told us the length; making them press twice because the text
    /// field had not written back yet is the tool failing to listen (live finding LT-5).
    private var resolvedDraft: CalibrationDraft {
        draft.resolvingPendingLengths(
            primary: pendingPrimaryLength,
            secondary: pendingSecondaryLength
        )
    }

    public var body: some View {
        // One verdict per render. `validation` used to be a computed property read at nine
        // places, each re-running the pending-text parse, the geometry and the preview's
        // number formatting on every keystroke (IM-203).
        let resolved = resolvedDraft
        let validation = CalibrationValidator.validate(resolved)
        return VStack(alignment: .leading, spacing: 0) {
            header
            ZPDFHairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: ZPDFSpacing.xl) {
                    if let notice {
                        ZPDFInlineWarning(severity: .warning, message: notice)
                    }
                    modeSection(validation)
                    if draft.mode == .drawingScale {
                        drawingScaleSection
                    } else {
                        pickSection
                        lengthSection(validation)
                    }
                    readoutSection(validation)
                    issueSection(validation)
                }
                .padding(ZPDFSpacing.xl)
            }

            ZPDFHairlineDivider()
            footer(validation)
        }
        .onChange(of: resolved.scaleInputs) { previous, _ in
            // A tick confirms one scale. Change what decides the scale and it is a different
            // scale, so the tick goes (BH-251).
            draft.clearConfirmationsIfScaleChanged(from: previous)
        }
        .onChange(of: draft.nextPickStep) { previous, next in
            lengthFocusRequest = Self.lengthFieldToFocus(from: previous, to: next, draft: draft)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 480)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(NSLocalizedString("Calibrate Scale", comment: "Accessibility label for the calibration sheet"))
        )
    }

    // MARK: Header

    private var header: some View {
        ZPDFPanelHeader(
            title: NSLocalizedString("Calibrate Scale", comment: "Calibration sheet title"),
            subtitle: String(
                format: NSLocalizedString("Page %@", comment: "Calibration sheet subtitle: page label"),
                pageLabel
            )
        )
        .padding(.horizontal, ZPDFSpacing.xl)
        .padding(.vertical, ZPDFSpacing.m)
    }

    // MARK: Mode

    private func modeSection(_ validation: CalibrationValidation) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            ZPDFSegmentedControl(
                selection: $draft.mode,
                segments: CalibrationMode.allCases.map {
                    .init(value: $0, title: $0.displayName, helpText: $0.explanation)
                },
                accessibilityTitle: NSLocalizedString("Calibration mode", comment: "Accessibility label")
            )
            Text(draft.mode.explanation)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZPDFInspectorRow(
                label: NSLocalizedString("Name", comment: "Field label: the scale's name")
            ) {
                TextField(namePlaceholder(validation), text: $draft.name)
                .textFieldStyle(.plain)
                .zpdfFont(.control)
                .foregroundStyle(ZPDFColor.textPrimary)
                .focused($focusedControl, equals: .name)
                .padding(.horizontal, ZPDFSpacing.s)
                .frame(minHeight: ZPDFSpacing.Control.inspectorControl)
                .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.small)
                .zpdfFocusRing(focusedControl == .name, cornerRadius: ZPDFRadius.small)
                .accessibilityLabel(NSLocalizedString("Scale name", comment: "Accessibility label"))
            }
        }
    }

    /// The name the scale will get if Name stays empty, so the placeholder is the real
    /// default rather than an example (IM-204).
    private func namePlaceholder(_ validation: CalibrationValidation) -> String {
        guard let preview = validation.preview else {
            return NSLocalizedString("Plan 1:50", comment: "Placeholder for the scale name")
        }
        return CalibrationValidator.generatedName(for: preview)
    }

    /// Which length field should take focus when the pick step moves from `previous` to `next`.
    ///
    /// When the last point lands the person's next act is typing the length, so the field
    /// takes focus instead of waiting for a pointer trip. Separate X/Y focuses the first
    /// field still empty. Pure, so the rule is testable without a sheet on screen.
    static func lengthFieldToFocus(
        from previous: CalibrationPickStep,
        to next: CalibrationPickStep,
        draft: CalibrationDraft
    ) -> CalibrationAxis? {
        guard next == .done, previous != .done else { return nil }
        if draft.primary.knownLength == nil { return .primary }
        if draft.mode == .separateAxes, draft.secondary.knownLength == nil { return .secondary }
        return .primary
    }

    // MARK: Drawing scale

    /// The ratio from the title block, chosen from the common ones or typed as the `n` of
    /// `1:n` through the shared numeric field (IM-016).
    private var drawingScaleSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(NSLocalizedString("Drawing scale", comment: "Calibration section title"))

            ZPDFInspectorRow(label: NSLocalizedString("Scale", comment: "Field label: the drawing scale")) {
                HStack(spacing: ZPDFSpacing.m) {
                    Menu {
                        Section(NSLocalizedString("Metric", comment: "Drawing scale menu section")) {
                            ForEach(DrawingScalePreset.metric) { preset in
                                Button(preset.title) { draft.drawingScaleDenominator = preset.denominator }
                            }
                        }
                        Section(NSLocalizedString("Imperial", comment: "Drawing scale menu section")) {
                            ForEach(DrawingScalePreset.imperial) { preset in
                                Button(preset.title) { draft.drawingScaleDenominator = preset.denominator }
                            }
                        }
                    } label: {
                        Text(drawingScaleTitle).zpdfFont(.control)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 160, alignment: .leading)
                    .accessibilityLabel(NSLocalizedString("Drawing scale", comment: "Accessibility label"))
                    .accessibilityValue(Text(drawingScaleTitle))

                    Text("1:").zpdfText(.monoNumeric, .textSecondary).accessibilityHidden(true)
                    ZPDFNumericField(
                        value: $draft.drawingScaleDenominator,
                        accessibilityTitle: NSLocalizedString(
                            "Scale denominator, the n of 1 to n",
                            comment: "Accessibility label for the typed drawing scale"
                        ),
                        placeholder: "50",
                        fractionDigits: 2
                    )
                    .frame(maxWidth: 96)
                    Spacer(minLength: 0)
                }
            }

            ZPDFInspectorRow(
                label: NSLocalizedString("Unit", comment: "Field label: the calibration unit")
            ) {
                ZPDFUnitPicker(
                    selection: $draft.unitIdentifier,
                    options: MeasurementUnitCatalog.lengthOptions,
                    accessibilityTitle: NSLocalizedString("Calibration unit", comment: "Accessibility label")
                )
            }
        }
    }

    private var drawingScaleTitle: String {
        guard let denominator = draft.drawingScaleDenominator else {
            return NSLocalizedString("Choose a scale", comment: "Drawing scale menu with nothing chosen")
        }
        let preset = (DrawingScalePreset.metric + DrawingScalePreset.imperial)
            .first { abs($0.denominator - denominator) < 1e-9 }
        return preset?.title ?? "1:\(denominator.formatted(.number.precision(.fractionLength(0...2))))"
    }

    // MARK: Point picking

    private var pickSection: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(NSLocalizedString("Picked points", comment: "Calibration section title"))

            ZPDFStatusPill(
                severity: draft.nextPickStep == .done ? .success : .info,
                title: draft.nextPickStep.instruction,
                usesMonospacedValue: false
            )
            .accessibilityLabel(
                Text(
                    String(
                        format: NSLocalizedString("Next step: %@", comment: "Accessibility label for the pick step"),
                        draft.nextPickStep.instruction
                    )
                )
            )

            axisRow(
                axis: .primary,
                title: draft.mode == .uniform
                    ? NSLocalizedString("Calibration line", comment: "Row label for the single calibration line")
                    : NSLocalizedString("X line", comment: "Row label for the horizontal calibration line"),
                input: draft.primary,
                startStep: draft.mode == .uniform ? .primaryStart : .xAxisStart
            )

            if draft.mode == .separateAxes {
                axisRow(
                    axis: .secondary,
                    title: NSLocalizedString("Y line", comment: "Row label for the vertical calibration line"),
                    input: draft.secondary,
                    startStep: .yAxisStart
                )
            }
        }
    }

    private func axisRow(
        axis: CalibrationAxis,
        title: String,
        input: CalibrationAxisInput,
        startStep: CalibrationPickStep
    ) -> some View {
        ZPDFInspectorRow(label: title) {
            HStack(spacing: ZPDFSpacing.m) {
                Text(pointDescription(input))
                    .zpdfText(.monoNumeric.withSize(11), .textPrimary)
                    .lineLimit(1)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: NSLocalizedString("%1$@: %2$@", comment: "Accessibility: axis name, picked points"),
                                title,
                                pointDescription(input)
                            )
                        )
                    )
                Spacer(minLength: ZPDFSpacing.s)
                ZPDFToolbarButton(
                    glyph: .measurement(.calibrate),
                    title: NSLocalizedString("Pick points", comment: "Button: hand picking back to the canvas"),
                    helpText: startStep.instruction
                ) {
                    onPickPoint(startStep)
                }
                ZPDFToolbarButton(
                    glyph: .symbol(.remove),
                    title: NSLocalizedString("Clear points", comment: "Button: forget the picked points"),
                    prominence: .destructive
                ) {
                    switch axis {
                    case .primary: draft.primary = CalibrationAxisInput(knownLength: draft.primary.knownLength)
                    case .secondary: draft.secondary = CalibrationAxisInput(knownLength: draft.secondary.knownLength)
                    }
                    onClearPoints(axis)
                }
                .disabled(input.pickedPointCount == 0)
            }
        }
    }

    private func pointDescription(_ input: CalibrationAxisInput) -> String {
        guard let start = input.start else {
            return NSLocalizedString("No points picked", comment: "Placeholder when nothing is picked")
        }
        guard let end = input.end else {
            return String(
                format: NSLocalizedString("%@ — waiting for the second point", comment: "One point picked"),
                MeasurementInputStateMachine.coordinateDescription(start)
            )
        }
        return String(
            format: NSLocalizedString(
                "%1$.1f pt apart",
                comment: "Distance in PDF page points between the two picked points"
            ),
            start.distance(to: end)
        )
    }

    // MARK: Lengths

    private func lengthSection(_ validation: CalibrationValidation) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            sectionTitle(NSLocalizedString("Known length", comment: "Calibration section title"))

            ZPDFInspectorRow(
                label: NSLocalizedString("Unit", comment: "Field label: the calibration unit")
            ) {
                HStack(spacing: ZPDFSpacing.m) {
                    ZPDFUnitPicker(
                        selection: $draft.unitIdentifier,
                        options: MeasurementUnitCatalog.lengthOptions,
                        accessibilityTitle: NSLocalizedString("Calibration unit", comment: "Accessibility label")
                    )
                    if draft.showsImperialPrecision {
                        precisionPicker
                    }
                    Spacer(minLength: 0)
                }
            }

            ZPDFInspectorRow(
                label: draft.mode == .uniform
                    ? NSLocalizedString("Length", comment: "Field label: the known real-world length")
                    : NSLocalizedString("X length", comment: "Field label: known horizontal length"),
                isMixed: false
            ) {
                CalibrationLengthField(
                    length: $draft.primary.knownLength,
                    unit: draft.resolvedUnit,
                    precision: draft.imperialPrecision,
                    title: NSLocalizedString("Known length", comment: "Accessibility label"),
                    isInvalid: !Set(validation.issues).isDisjoint(
                        with: [.nonPositivePrimaryLength, .outOfRangePrimaryLength, .unparseablePrimaryLength]
                    ),
                    pendingText: $pendingPrimaryLength,
                    requestsFocus: lengthFocusRequest == .primary
                )
            }

            if draft.mode == .separateAxes {
                ZPDFInspectorRow(
                    label: NSLocalizedString("Y length", comment: "Field label: known vertical length")
                ) {
                    CalibrationLengthField(
                        length: $draft.secondary.knownLength,
                        unit: draft.resolvedUnit,
                        precision: draft.imperialPrecision,
                        title: NSLocalizedString("Known vertical length", comment: "Accessibility label"),
                        isInvalid: !Set(validation.issues).isDisjoint(
                            with: [.nonPositiveSecondaryLength, .outOfRangeSecondaryLength, .unparseableSecondaryLength]
                        ),
                        pendingText: $pendingSecondaryLength,
                        requestsFocus: lengthFocusRequest == .secondary
                    )
                }
            }
        }
    }

    private var precisionPicker: some View {
        Picker(selection: $draft.imperialPrecision) {
            ForEach(ImperialPrecision.allCases) { precision in
                Text(precision.displayName).tag(precision)
            }
        } label: {
            Text(NSLocalizedString("Fraction", comment: "Picker label for imperial fraction precision"))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .zpdfFont(.control)
        .frame(maxWidth: 96)
        .help(
            NSLocalizedString(
                "Fraction precision used for display only. The stored value keeps full accuracy.",
                comment: "Help tag for the imperial fraction picker"
            )
        )
        .accessibilityLabel(
            NSLocalizedString("Imperial fraction precision", comment: "Accessibility label")
        )
        .accessibilityValue(Text(draft.imperialPrecision.displayName))
    }

    // MARK: Readout

    @ViewBuilder
    private func readoutSection(_ validation: CalibrationValidation) -> some View {
        if let preview = validation.preview {
            VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                sectionTitle(NSLocalizedString("Result", comment: "Calibration section title"))

                ZPDFInspectorRow(label: Self.primaryReadoutLabel(preview)) {
                    readoutValue(preview.ratioString)
                }
                if let secondary = preview.secondaryRatioString, !preview.isUniform {
                    ZPDFInspectorRow(label: NSLocalizedString("Y scale", comment: "Readout label")) {
                        readoutValue(secondary)
                    }
                }
                if let angle = preview.axisAngleString {
                    ZPDFInspectorRow(
                        label: NSLocalizedString("Axis angle", comment: "Readout label"),
                        helpText: NSLocalizedString(
                            "The angle between the two calibration lines. Near zero means the axes cannot be separated.",
                            comment: "Help tag for the axis angle readout"
                        )
                    ) {
                        readoutValue(angle)
                    }
                }
                if let residual = preview.residualPercentString {
                    ZPDFInspectorRow(
                        label: NSLocalizedString("Residual", comment: "Readout label"),
                        helpText: NSLocalizedString(
                            "How much the two axis scales differ. Zero means the drawing is not stretched.",
                            comment: "Help tag for the residual readout"
                        )
                    ) {
                        readoutValue(residual)
                    }
                }
            }
        }
    }

    /// The first result row's label: "X scale" beside a "Y scale" row, "Scale" when the result
    /// is one scale (L-37 — the X value was labelled "Scale" next to "Y scale").
    static func primaryReadoutLabel(_ preview: CalibrationPreview) -> String {
        preview.isUniform || preview.secondaryRatioString == nil
            ? NSLocalizedString("Scale", comment: "Readout label")
            : NSLocalizedString("X scale", comment: "Readout label: the horizontal scale of a separate X/Y calibration")
    }

    private func readoutValue(_ text: String) -> some View {
        Text(text)
            .zpdfText(.monoNumericStrong, .textPrimary)
            .accessibilityLabel(Text(text))
    }

    // MARK: Issues

    /// The issues the sheet lists: every problem, but of the inputs still missing only the next
    /// one (L-37). Separate X / Y with nothing picked listed "pick two points", "pick the
    /// vertical points", "enter the length" and "enter the vertical length" at once — a stack of
    /// boxes whose last was cut off by the footer, all saying "not yet". The next step is the
    /// one worth reading; the others appear as each is reached, and Apply stays disabled for
    /// all of them.
    static func displayedIssues(_ issues: [CalibrationIssue]) -> [CalibrationIssue] {
        var shownMissingInput = false
        return issues.filter { issue in
            guard issue.isMissingInput else { return true }
            defer { shownMissingInput = true }
            return !shownMissingInput
        }
    }

    @ViewBuilder
    private func issueSection(_ validation: CalibrationValidation) -> some View {
        let issues = Self.displayedIssues(validation.issues)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                        ZPDFInlineWarning(severity: issue.displaySeverity, message: issue.message)
                        if let confirmation = issue.confirmationTitle {
                            // The issue stays listed once ticked, so this checkbox stays on
                            // screen and the tick can be taken back (BH-251).
                            Toggle(isOn: binding(for: issue)) {
                                Text(confirmation).zpdfText(.control, .textPrimary)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(Text(confirmation))
                            .accessibilityValue(
                                Text(
                                    validation.isConfirmed(issue)
                                        ? NSLocalizedString("Confirmed", comment: "Calibration confirmation ticked")
                                        : NSLocalizedString("Not confirmed", comment: "Calibration confirmation not ticked")
                                )
                            )
                        }
                    }
                }
            }
            .zpdfAnimation(.quick, value: issues)
        }
    }

    private func binding(for issue: CalibrationIssue) -> Binding<Bool> {
        switch issue {
        case .extremeScale:
            return $draft.confirmsExtremeScale
        case .obliqueAxes:
            return $draft.confirmsNearParallelAxes
        default:
            // No other issue is confirmable. A constant binding keeps the control inert
            // rather than silently toggling something unrelated.
            return .constant(false)
        }
    }

    // MARK: Footer

    private func footer(_ validation: CalibrationValidation) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            Spacer(minLength: 0)

            Button(action: onCancel) {
                Text(NSLocalizedString("Cancel", comment: "Button: dismiss the calibration sheet"))
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

            Button(action: apply) {
                Text(NSLocalizedString("Apply Scale", comment: "Button: commit the calibration"))
                    .zpdfFont(.control.withWeight(.semibold))
                    .padding(.horizontal, ZPDFSpacing.l)
                    .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(validation.canApply ? ZPDFColor.textPrimary : ZPDFColor.textSecondary)
            .zpdfControlBackground(
                fill: validation.canApply ? .selection : .elevated,
                cornerRadius: ZPDFRadius.small
            )
            .focused($focusedControl, equals: .apply)
            .zpdfFocusRing(focusedControl == .apply, cornerRadius: ZPDFRadius.small)
            .keyboardShortcut(.defaultAction)
            .disabled(!validation.canApply)
            .help(validation.applyAccessibilityValue)
            .accessibilityLabel(NSLocalizedString("Apply Scale", comment: "Accessibility label"))
            .accessibilityValue(Text(validation.applyAccessibilityValue))
        }
        .padding(.horizontal, ZPDFSpacing.xl)
        .padding(.vertical, ZPDFSpacing.l)
        .background(ZPDFColor.surface)
    }

    private func apply() {
        // Belt and braces: the button is disabled when the draft is invalid, and the factory
        // returns nil for an invalid draft, so a broken scale cannot leave this sheet.
        let resolved = resolvedDraft
        guard let scale = CalibrationValidator.makeScaleSummary(from: resolved) else { return }
        // Fold the fields' uncommitted text into the draft the caller holds, so the sheet's
        // own state agrees with the scale that just left it.
        draft = resolved
        pendingPrimaryLength = ""
        pendingSecondaryLength = ""
        onApply(scale)
    }

    // MARK: Shared

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .zpdfText(.sectionHeader, .textSecondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

extension CalibrationIssue {

    /// Whether the issue is an input not given yet rather than a problem with one given (L-37).
    var isMissingInput: Bool {
        switch self {
        case .missingPrimaryPoints, .missingSecondaryPoints, .missingPrimaryLength,
             .missingSecondaryLength, .missingDrawingScale:
            return true
        default:
            return false
        }
    }
}
