import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Revision Overlay: two or more sheets stacked as coloured layers over one another.
///
/// Every control that changes what is on screen is next to a statement of what the picture can
/// and cannot be used for. Overlay is a way of finding a change; it is not evidence of where
/// anything is, because no two plots of the same drawing are ever quite the same size.
public struct RevisionOverlayView<Canvas: View>: View {

    private let model: RevisionOverlayModel
    private let onClose: () -> Void
    private let canvas: () -> Canvas

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - model: the layer stack and the alignment.
    ///   - onClose: leaves Revision Overlay. Required — this view must never be on screen
    ///     without a way out.
    ///   - canvas: draws the stacked sheets.
    public init(
        model: RevisionOverlayModel,
        onClose: @escaping () -> Void,
        @ViewBuilder canvas: @escaping () -> Canvas
    ) {
        self.model = model
        self.onClose = onClose
        self.canvas = canvas
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    RevisionOverlayLegend(entries: model.legendEntries)
                    ZPDFHairlineDivider()
                    compositeCanvas
                    ZPDFHairlineDivider()
                    statusStrip
                    ZPDFHairlineDivider()
                    approximateNote
                }
                ZPDFHairlineDivider(axis: .vertical)
                inspector
            }
        }
        .background(ZPDFColor.background)
        .task(id: blinkTaskID) { await runBlink() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Revision Overlay", comment: "Accessibility label for Revision Overlay")))
    }

    // MARK: - The composited sheet

    /// The stacked revisions, or the host's own placeholder until the first composite lands.
    ///
    /// The composite is a picture the compare engine produced; this view only places it and
    /// turns a click on it back into a page-space point. It is drawn `scaledToFit` so the
    /// whole sheet is visible — Revision Overlay is a "where did it change" view, and a
    /// pane that shows a corner of the sheet answers a different question.
    @ViewBuilder
    private var compositeCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                ZPDFColor.canvasBackdrop
                if let composite = model.composite {
                    Image(decorative: composite.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel(Text(compositeAccessibilityLabel(composite)))
                } else {
                    canvas()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                    handleCanvasClick(at: value.location, in: proxy.size)
                }
            )
            .overlay(alignment: .top) { captureBanner }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZPDFColor.canvasBackdrop)
    }

    /// The instruction that appears over the sheet while a point is being marked.
    @ViewBuilder
    private var captureBanner: some View {
        if let instruction = model.captureStage.instruction {
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFGlyphView(.symbol(.info), size: ZPDFSpacing.Control.iconSmall)
                    .foregroundStyle(ZPDFColor.accentBlue)
                    .accessibilityHidden(true)
                Text(instruction).zpdfText(.caption, .textPrimary)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Cancel marking an alignment point")) {
                    model.cancelPointCapture()
                }
                .controlSize(.small)
            }
            .padding(ZPDFSpacing.s)
            .background(ZPDFColor.surface)
            .padding(ZPDFSpacing.s)
            .accessibilityElement(children: .contain)
        }
    }

    /// What the canvas is doing, and — when the picture is coarser than the drawing — by
    /// how much. Both are sentences rather than a spinner alone: "why is this blurry" is a
    /// question an estimator will otherwise answer by guessing.
    @ViewBuilder
    private var statusStrip: some View {
        let message = model.compositeStatus.message
        let resolution = model.composite?.resolutionSummary
        if message != nil || resolution != nil {
            VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                if let message {
                    HStack(spacing: ZPDFSpacing.s) {
                        if model.compositeStatus.isRendering {
                            ProgressView().controlSize(.small)
                        }
                        Text(message)
                            .zpdfText(.caption, .textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if case .failed = model.compositeStatus, let retry = model.onRecomposite {
                            Button(NSLocalizedString("Try Again", comment: "Retry the overlay composite")) {
                                retry()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let resolution {
                    Text(resolution)
                        .zpdfText(.caption, .textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ZPDFSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZPDFColor.surface)
            .accessibilityElement(children: .contain)
        }
    }

    private func compositeAccessibilityLabel(_ composite: RevisionOverlayComposite) -> String {
        let format = NSLocalizedString(
            "Overlay of %@",
            comment: "Accessibility label for the composited overlay picture: the layer count as '3 revisions'"
        )
        return String(format: format, WorkflowPlurals.revisions(composite.contributingLayerIDs.count))
    }

    /// Turns a click in the pane into a page-space point on the sheet.
    ///
    /// The picture is aspect-fitted, so most of the pane is usually backdrop. A click on the
    /// backdrop is ignored rather than clamped to the nearest edge: an alignment point the
    /// person did not mean to put on the sheet border is worse than a click that did nothing.
    private func handleCanvasClick(at location: CGPoint, in size: CGSize) {
        guard model.captureStage.isCapturing, let composite = model.composite else { return }
        guard let unit = RevisionOverlayGeometry.unitPoint(
            forClickAt: location,
            in: size,
            imagePixelWidth: composite.pixelWidth,
            imagePixelHeight: composite.pixelHeight
        ) else { return }
        model.capturePoint(composite.pagePoint(atUnitPoint: unit))
    }

    // MARK: - Alternating

    /// Restarts the alternation task whenever blinking is switched, so the timer cannot
    /// outlive the setting that started it.
    private var blinkTaskID: Bool { model.isBlinking }

    private func runBlink() async {
        guard model.isBlinking else { return }
        while !Task.isCancelled, model.isBlinking {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, model.isBlinking else { return }
            model.advanceBlink()
        }
    }

    private var header: some View {
        ZPDFPanelHeader(title: NSLocalizedString("Revision Overlay", comment: "Revision Overlay header title")) {
            WorkflowPanelCloseButton(
                panelName: NSLocalizedString("Revision Overlay", comment: "Panel name"),
                action: onClose
            )
        }
    }

    private var approximateNote: some View {
        HStack(alignment: .top, spacing: ZPDFSpacing.s) {
            ZPDFGlyphView(.symbol(.info), size: ZPDFSpacing.Control.iconSmall)
                .foregroundStyle(ZPDFColor.accentBlue)
                .accessibilityHidden(true)
            Text(RevisionAlignmentDisclosure.approximate)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZPDFSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZPDFColor.surface)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            ZPDFPanelHeader(
                title: NSLocalizedString("Layers", comment: "Revision Overlay layer list heading"),
                count: model.layers.count
            )
            if model.layers.isEmpty {
                let addRevision = model.onAddRevision
                ZPDFEmptyState(
                    glyph: .symbol(.revisionOverlay),
                    title: NSLocalizedString("Nothing stacked yet", comment: "Overlay empty state"),
                    message: NSLocalizedString(
                        "Add two or more revisions of the same sheet to see them over one another.",
                        comment: "Overlay empty state message"
                    ),
                    actionTitle: addRevision == nil ? nil : NSLocalizedString("Add Revision…", comment: "Revision Overlay: choose a revised PDF to add as a layer"),
                    action: addRevision.map { hook in { hook() } }
                )
            } else {
                ScrollView {
                    VStack(spacing: ZPDFSpacing.s) {
                        ForEach(model.layers.sorted { $0.order < $1.order }) { layer in
                            layerRow(layer)
                        }
                    }
                    .padding(.horizontal, ZPDFSpacing.m)
                }
            }

            // L-57: another revision is one click away, whatever is stacked already.
            if !model.layers.isEmpty, let addRevision = model.onAddRevision {
                Button(NSLocalizedString("Add Revision…", comment: "Revision Overlay: choose a revised PDF to add as a layer")) {
                    addRevision()
                }
                .controlSize(.small)
                .padding(.horizontal, ZPDFSpacing.m)
                .help(NSLocalizedString(
                    "Choose the revised PDF of this drawing and stack it as another layer.",
                    comment: "Revision Overlay Add Revision button help"
                ))
            }

            // Not while alternating: showing one layer at a time is what alternating *is*,
            // so saying "there is nothing to compare it with" would be describing the feature
            // as a fault. Part of CR-197.
            if model.showsSingleVisibleLayerNote {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "Only one layer is visible, so there is nothing to compare it with.",
                        comment: "Overlay warning when fewer than two layers are visible"
                    )
                )
                .padding(.horizontal, ZPDFSpacing.m)
            }

            ZPDFHairlineDivider()
            blendControls
            ZPDFHairlineDivider()
            RevisionAlignmentEditor(model: model)
                .padding(.horizontal, ZPDFSpacing.m)
            Spacer(minLength: 0)
        }
        .padding(.vertical, ZPDFSpacing.s)
        .frame(width: 300)
        .background(ZPDFColor.surface)
    }

    private func layerRow(_ layer: RevisionOverlayLayer) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            HStack(spacing: ZPDFSpacing.s) {
                Toggle(isOn: Binding(
                    get: { layer.isVisible },
                    set: { model.setVisible($0, forLayer: layer.id) }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("Show %@", comment: "Accessibility label for an overlay layer visibility toggle"),
                    layer.revisionName
                )))

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(layer.colorRGBA.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(layer.revisionName).zpdfText(.control, .textPrimary).lineLimit(1)
                    Text("\(layer.revisionLabel) · \(layer.colorName)")
                        .zpdfText(.caption, .textSecondary)
                }
                Spacer(minLength: 0)
                ZPDFToolbarButton(
                    glyph: .symbol(.remove),
                    title: String(
                        format: NSLocalizedString("Remove %@", comment: "Remove an overlay layer"),
                        layer.revisionName
                    ),
                    action: { model.removeLayer(id: layer.id) }
                )
            }

            HStack(spacing: ZPDFSpacing.s) {
                Picker(selection: Binding(
                    get: { ZenitMarkupPalette.entries.first { $0.name == layer.colorName }?.id ?? "cyan" },
                    set: { model.setColor(paletteID: $0, forLayer: layer.id) }
                )) {
                    ForEach(ZenitMarkupPalette.entries) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                } label: {
                    Text(NSLocalizedString("Colour", comment: "Overlay layer colour picker"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .zpdfFont(.control)
                .frame(width: 92)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("Colour for %@", comment: "Accessibility label for an overlay layer colour picker"),
                    layer.revisionName
                )))

                Slider(
                    value: Binding(
                        get: { layer.opacity },
                        set: { model.setOpacity($0, forLayer: layer.id) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing { model.flushOpacityChange() }
                    }
                )
                .controlSize(.small)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("Opacity of %@", comment: "Accessibility label for an overlay layer opacity slider"),
                    layer.revisionName
                )))
                .accessibilityValue(Text("\(Int((layer.opacity * 100).rounded()))%"))

                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .zpdfText(.monoNumeric, .textSecondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(ZPDFSpacing.s)
        .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(layer.accessibilityLabel))
    }

    private var blendControls: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Blending", comment: "Overlay blending section")) 
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
            Picker(selection: Binding(
                get: { model.blendMode },
                set: { model.blendMode = $0 }
            )) {
                ForEach(RevisionOverlayBlendMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text(NSLocalizedString("Blending", comment: "Overlay blending section"))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .zpdfFont(.control)

            Toggle(isOn: Binding(
                get: { model.isBlinking },
                set: { model.setBlinking($0, reduceMotion: reduceMotion) }
            )) {
                Text(NSLocalizedString("Alternate between revisions", comment: "Overlay blink toggle"))
                    .zpdfText(.caption, .textSecondary)
            }
            .toggleStyle(.checkbox)
            // A control that is on must always be switchable off. Gating on `hasEnoughLayers`
            // did the opposite: alternating isolates one layer, one visible layer is not
            // "enough layers", and the checkbox greyed out with the tick still in it.
            // Finding CR-197.
            .disabled(!model.isAlternationControlEnabled(reduceMotion: reduceMotion))

            if reduceMotion {
                Text(NSLocalizedString(
                    "Alternating is off because Reduce Motion is on in System Settings. Use the opacity sliders instead.",
                    comment: "Explanation that blinking is disabled under Reduce Motion"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
    }
}

/// The manual alignment control: mark matching points, watch the error come down.
public struct RevisionAlignmentEditor: View {

    private let model: RevisionOverlayModel

    /// Creates the editor.
    public init(model: RevisionOverlayModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Alignment", comment: "Overlay alignment section"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)

            ZPDFSegmentedControl(
                selection: Binding(
                    get: { model.alignmentMode },
                    set: { model.alignmentMode = $0 }
                ),
                segments: RevisionAlignmentMode.allCases.map {
                    .init(value: $0, title: $0.displayName, helpText: $0.explanation)
                },
                accessibilityTitle: NSLocalizedString("Alignment mode", comment: "Accessibility title for the alignment mode switch")
            )

            Text(model.alignmentMode.explanation)
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.alignmentAppliesToSeveralSheets {
                ZPDFInlineWarning(
                    severity: .info,
                    message: NSLocalizedString(
                        "One set of points registers every revision above the bottom one. To align a sheet on its own, hide the others first.",
                        comment: "Note that a single manual fit is applied to every non-baseline layer"
                    )
                )
            }

            pointList
            residualReadout

            HStack(spacing: ZPDFSpacing.s) {
                // The entry route for a point. Without it the list, the residual and the
                // whole two- and three-point apparatus are a readout of something the person
                // has no way to create — a panel that can only ever be empty.
                Button(markPointTitle) {
                    if model.captureStage.isCapturing {
                        model.cancelPointCapture()
                    } else {
                        model.beginPointCapture()
                    }
                }
                .disabled(model.composite == nil)
                .help(NSLocalizedString(
                    "Click the same feature on the sheet twice: once where the first revision draws it, once where the other one does.",
                    comment: "Help text for the mark-point button"
                ))
                Button(NSLocalizedString("Start Over", comment: "Clear the alignment points")) {
                    model.clearPairs()
                }
                .disabled(model.pointPairs.isEmpty)
                Spacer(minLength: 0)
            }

            if model.composite == nil {
                Text(NSLocalizedString(
                    "Marking points needs the stacked sheet on screen. It appears as soon as two revisions have been composited.",
                    comment: "Explanation that alignment points cannot be marked before the composite exists"
                ))
                .zpdfText(.caption, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString("Alignment", comment: "Accessibility label for the alignment editor")))
    }

    @ViewBuilder
    private var pointList: some View {
        if model.pointPairs.isEmpty {
            Text(NSLocalizedString(
                "Click the same feature on both sheets to mark a point. A grid intersection or the corner of the title block works well.",
                comment: "Instruction for marking alignment points"
            ))
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 1) {
                ForEach(Array(model.pointPairs.enumerated()), id: \.element.id) { index, pair in
                    HStack(spacing: ZPDFSpacing.s) {
                        Text(String(
                            format: NSLocalizedString("Point %d", comment: "Alignment point index"),
                            index + 1
                        ))
                        .zpdfText(.control, .textPrimary)
                        .frame(width: 60, alignment: .leading)
                        Text(String(
                            format: "%.0f, %.0f → %.0f, %.0f",
                            pair.baselinePoint.x, pair.baselinePoint.y,
                            pair.comparisonPoint.x, pair.comparisonPoint.y
                        ))
                        .zpdfText(.monoNumeric, .textSecondary)
                        Spacer(minLength: 0)
                        ZPDFToolbarButton(
                            glyph: .symbol(.remove),
                            title: String(
                                format: NSLocalizedString("Remove point %d", comment: "Remove an alignment point"),
                                index + 1
                            ),
                            action: { model.removePair(id: pair.id) }
                        )
                    }
                    .frame(height: ZPDFSpacing.Control.listRow)
                }
            }
        }
    }

    @ViewBuilder
    private var residualReadout: some View {
        if let fit = model.fit {
            VStack(alignment: .leading, spacing: 2) {
                ZPDFStatusPill(
                    severity: fit.isExactlyDetermined ? .info : residualSeverity(fit.residualRMSPoints),
                    title: NSLocalizedString("Fit", comment: "Alignment residual pill title"),
                    value: fit.isExactlyDetermined
                        ? NSLocalizedString("Exact", comment: "Alignment residual value when exactly determined")
                        : String(format: "%.2f pt", fit.residualRMSPoints)
                )
                Text(fit.residualSummary)
                    .zpdfText(.caption, .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fit.transform.displaySummary)
                    .zpdfText(.code, .textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if let problem = model.alignmentProblem {
            ZPDFInlineWarning(severity: .warning, message: problem.message)
        }
    }

    private var markPointTitle: String {
        model.captureStage.isCapturing
            ? NSLocalizedString("Stop Marking", comment: "Disarm the alignment point gesture")
            : NSLocalizedString("Mark Point", comment: "Arm the alignment point gesture")
    }

    private func residualSeverity(_ residual: Double) -> ZPDFSeverity {
        switch residual {
        case ..<1.5: return .success
        case 1.5..<5: return .warning
        default: return .danger
        }
    }
}
