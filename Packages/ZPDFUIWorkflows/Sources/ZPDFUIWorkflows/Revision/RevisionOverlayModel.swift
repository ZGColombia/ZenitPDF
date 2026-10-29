import Foundation
import Observation
import ZPDFUIPresentation

/// One revision drawn as a coloured layer in Revision Overlay.
public struct RevisionOverlayLayer: Hashable, Sendable, Identifiable {

    /// The revision this layer draws.
    public let id: RevisionSummary.ID
    /// The revision's name.
    public var revisionName: String
    /// The revision designation printed on the sheet.
    public var revisionLabel: String
    /// The name of the layer's colour, so the layer is identifiable without seeing it.
    public var colorName: String
    /// The layer's colour.
    public var colorRGBA: ColorRGBA
    /// How solid the layer is, `0...1`.
    public var opacity: Double
    /// Whether the layer is drawn at all.
    public var isVisible: Bool
    /// Stacking order, lowest drawn first.
    public var order: Int

    /// Creates a layer.
    public init(
        id: RevisionSummary.ID,
        revisionName: String,
        revisionLabel: String,
        colorName: String,
        colorRGBA: ColorRGBA,
        opacity: Double = 0.6,
        isVisible: Bool = true,
        order: Int = 0
    ) {
        self.id = id
        self.revisionName = revisionName
        self.revisionLabel = revisionLabel
        self.colorName = colorName
        self.colorRGBA = colorRGBA
        self.opacity = min(1, max(0, opacity))
        self.isVisible = isVisible
        self.order = order
    }

    /// A localized VoiceOver label: revision, colour name, opacity, visibility.
    public var accessibilityLabel: String {
        let format = NSLocalizedString(
            "%1$@ %2$@, %3$@ layer, %4$d percent, %5$@",
            comment: "VoiceOver label for an overlay layer: revision name, revision label, colour name, opacity, visibility"
        )
        let visibility = isVisible
            ? NSLocalizedString("visible", comment: "Overlay layer is visible")
            : NSLocalizedString("hidden", comment: "Overlay layer is hidden")
        return String(
            format: format,
            revisionName,
            revisionLabel,
            colorName,
            Int((opacity * 100).rounded()),
            visibility
        )
    }
}

/// Revision Overlay's state: which revisions are stacked, how they are drawn, and how well the
/// sheets have been brought into register.
///
/// The model owns the alignment the person builds by hand. It re-fits on every captured point,
/// reports the residual, and refuses to pretend that a fit made from the minimum number of points
/// tells anyone anything.
@MainActor
@Observable
public final class RevisionOverlayModel {

    /// The stacked layers, lowest first.
    public private(set) var layers: [RevisionOverlayLayer]
    /// How the layers are blended.
    ///
    /// A change here is a change to the picture, so it goes out through ``onLayersChange``
    /// like every other one. It did not: the compositor reads `blendMode` when it builds a
    /// request, but nothing told it to build one, so picking Multiply left the difference
    /// blend on screen until some unrelated edit — a slider, a colour, a re-fit — happened to
    /// trigger a re-composite. Finding CR-196.
    public var blendMode: RevisionOverlayBlendMode = .difference {
        didSet {
            guard blendMode != oldValue else { return }
            onLayersChange?(layers)
        }
    }
    /// Whether the overlay alternates between revisions. Never turned on under Reduce Motion.
    public private(set) var isBlinking: Bool = false

    /// Which family of transform is being fitted.
    public var alignmentMode: RevisionAlignmentMode = .twoPoint {
        didSet { if alignmentMode != oldValue { recomputeFit() } }
    }
    /// The points the person has marked on both sheets.
    public private(set) var pointPairs: [RevisionAlignmentPointPair] = []
    /// The current fit, or `nil` when there is not enough to fit.
    public private(set) var fit: RevisionAlignmentFit?
    /// Why there is no fit, or `nil` when there is one.
    public private(set) var alignmentProblem: RevisionAlignmentProblem?

    /// Runs whenever the fit changes, so the canvas can re-register the sheets.
    public var onAlignmentChange: (@MainActor (RevisionAlignmentFit?) -> Void)?
    /// Runs whenever a layer changes, so the canvas can redraw.
    public var onLayersChange: (@MainActor ([RevisionOverlayLayer]) -> Void)?
    /// Asks for the composite to be produced again from scratch.
    ///
    /// The app tier assigns this; until it does, the overlay draws whatever placeholder its
    /// host supplies and the retry control is not offered — an inert button is worse than
    /// no button. It is separate from the two hooks above because a *failed* composite has
    /// no layer or alignment change to hang a retry off.
    public var onRecomposite: (@MainActor () -> Void)?
    /// Asks the host for a revised PDF to add as another layer (L-57). Set, the layer list
    /// offers Add Revision…; a second revision used to arrive only by an ⌥ drop from Finder,
    /// which the pane could not offer and which a person had no way to discover there.
    public var onAddRevision: (@MainActor () -> Void)?

    // MARK: - The composited picture

    /// The stacked revisions as one picture, or `nil` before the first one arrives.
    ///
    /// Produced by the compare engine from the rasters `GeometryService` returns, never in
    /// this package: a view layer that could rasterise a PDF is a view layer that parses
    /// one, and Revision Compare's whole isolation story (finding S17-02) depends on that
    /// not being true anywhere.
    public private(set) var composite: RevisionOverlayComposite?

    /// What the canvas can currently show, and why, when it cannot show a composite.
    public private(set) var compositeStatus: RevisionOverlayCompositeStatus = .idle

    /// Where the person is in the two-click gesture that marks one alignment point.
    public private(set) var captureStage: RevisionAlignmentCaptureStage = .off

    /// What the layer visibilities were before blinking took them over.
    private var blinkRestore: [RevisionSummary.ID: Bool]?

    /// Creates the model.
    public init(layers: [RevisionOverlayLayer] = []) {
        self.layers = layers.sorted { $0.order < $1.order }
        self.alignmentProblem = .notEnoughPoints(needed: 2, given: 0)
    }

    /// Builds a model over a list of revisions, giving each one a distinct named colour.
    public convenience init(revisions: [RevisionSummary]) {
        let palette = ZenitMarkupPalette.entries
        let layers = revisions.enumerated().map { index, revision in
            let entry = palette[index % palette.count]
            return RevisionOverlayLayer(
                id: revision.id,
                revisionName: revision.name,
                revisionLabel: revision.revisionLabel,
                colorName: entry.name,
                colorRGBA: entry.color,
                opacity: index == 0 ? 1 : 0.6,
                isVisible: true,
                order: index
            )
        }
        self.init(layers: layers)
    }

    // MARK: - Layers

    /// The layers that are actually drawn, lowest first.
    public var visibleLayers: [RevisionOverlayLayer] {
        layers.filter(\.isVisible).sorted { $0.order < $1.order }
    }

    /// Whether the overlay has enough layers to be worth showing.
    public var hasEnoughLayers: Bool { visibleLayers.count >= 2 }

    /// Whether there is anything to alternate between.
    ///
    /// Counts the layers in the stack, not the ones showing right now. Alternating *works* by
    /// making exactly one layer visible at a time, so gating its control on ``hasEnoughLayers``
    /// — which counts visible layers — switched the control off the instant it was switched on,
    /// and nothing else on the panel could switch it back. Finding CR-197.
    public var canAlternate: Bool { layers.count >= 2 }

    /// Whether the alternation control may be operated right now.
    ///
    /// Stated here rather than inside the view so it can be asserted without putting a panel on
    /// anybody's screen, and so there is one place to read the rule: Reduce Motion switches it
    /// off outright, and otherwise it is live whenever alternating is *either* already running
    /// or possible to start. The "already running" half is the whole of CR-197 — a control that
    /// is on must always be switchable off.
    public func isAlternationControlEnabled(reduceMotion: Bool) -> Bool {
        !reduceMotion && (isBlinking || canAlternate)
    }

    /// Adds a revision as a new top layer with the next unused colour.
    public func addLayer(for revision: RevisionSummary) {
        guard !layers.contains(where: { $0.id == revision.id }) else { return }
        let palette = ZenitMarkupPalette.entries
        let used = Set(layers.map(\.colorName))
        let entry = palette.first { !used.contains($0.name) } ?? palette[layers.count % palette.count]
        layers.append(RevisionOverlayLayer(
            id: revision.id,
            revisionName: revision.name,
            revisionLabel: revision.revisionLabel,
            colorName: entry.name,
            colorRGBA: entry.color,
            opacity: 0.6,
            isVisible: true,
            order: layers.count
        ))
        onLayersChange?(layers)
    }

    /// Removes a layer.
    public func removeLayer(id: RevisionSummary.ID) {
        layers.removeAll { $0.id == id }
        renumber()
        onLayersChange?(layers)
    }

    /// Sets a layer's opacity, clamped to `0...1`.
    ///
    /// The layer changes at once, so the slider and the legend follow the pointer, but the
    /// compositor is told at most once per ``opacityNotifyInterval`` while a drag is going, and
    /// always once more with the final value. Every slider tick used to request a composite of
    /// its own, so the picture lagged behind a queue of intermediate opacities. IM-147.
    public func setOpacity(_ opacity: Double, forLayer id: RevisionSummary.ID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(1, max(0, opacity.isFinite ? opacity : layers[index].opacity))
        guard layers[index].opacity != clamped else { return }
        layers[index].opacity = clamped
        let now = ContinuousClock.now
        if let last = lastOpacityNotification, now - last < opacityNotifyInterval {
            guard pendingOpacityFlush == nil else { return }
            let wait = opacityNotifyInterval - (now - last)
            pendingOpacityFlush = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.flushOpacityChange()
            }
        } else {
            lastOpacityNotification = now
            onLayersChange?(layers)
        }
    }

    /// Delivers a throttled opacity change now — the slider calls this when the drag ends.
    public func flushOpacityChange() {
        guard let pending = pendingOpacityFlush else { return }
        pending.cancel()
        pendingOpacityFlush = nil
        lastOpacityNotification = ContinuousClock.now
        onLayersChange?(layers)
    }

    /// The shortest gap between two opacity notifications during a drag (IM-147).
    public var opacityNotifyInterval: Duration = .milliseconds(100)
    private var lastOpacityNotification: ContinuousClock.Instant?
    private var pendingOpacityFlush: Task<Void, Never>?

    /// Shows or hides a layer.
    public func setVisible(_ isVisible: Bool, forLayer id: RevisionSummary.ID) {
        update(id) { $0.isVisible = isVisible }
    }

    /// Sets a layer's colour from the named palette, so the layer keeps a spoken name.
    public func setColor(paletteID: String, forLayer id: RevisionSummary.ID) {
        guard let entry = ZenitMarkupPalette.entries.first(where: { $0.id == paletteID }) else { return }
        update(id) {
            $0.colorRGBA = entry.color
            $0.colorName = entry.name
        }
    }

    /// Turns blinking on or off. Refuses to turn it on when Reduce Motion is set, because an
    /// alternating overlay is exactly the kind of motion that setting exists to prevent.
    ///
    /// Turning it on remembers which layers were showing and isolates the bottom one;
    /// turning it off puts every one of them back exactly as the person had it. Blinking
    /// that quietly rewrote the stack would be a setting that costs the user their work.
    public func setBlinking(_ enabled: Bool, reduceMotion: Bool) {
        let wanted = enabled && !reduceMotion
        guard wanted != isBlinking else { return }
        if wanted {
            blinkRestore = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0.isVisible) })
            isBlinking = true
            isolateForBlink(at: 0)
        } else {
            isBlinking = false
            if let restore = blinkRestore {
                for index in layers.indices {
                    layers[index].isVisible = restore[layers[index].id] ?? layers[index].isVisible
                }
                blinkRestore = nil
                onLayersChange?(layers)
            }
        }
    }

    /// Shows the next revision on its own. One step of the alternating view.
    ///
    /// Each step is a whole re-composite, so this is driven by the view's timer rather than
    /// by anything faster: on a large sheet the alternation runs at the speed the compositor
    /// can keep up with, and the canvas says it is working while it does.
    public func advanceBlink() {
        guard isBlinking else { return }
        let ordered = layers.sorted { $0.order < $1.order }
        guard ordered.count > 1 else { return }
        let current = ordered.firstIndex { $0.isVisible } ?? 0
        isolateForBlink(at: (current + 1) % ordered.count)
    }

    private func isolateForBlink(at position: Int) {
        let ordered = layers.sorted { $0.order < $1.order }
        guard position < ordered.count else { return }
        let shown = ordered[position].id
        var changed = false
        for index in layers.indices where layers[index].isVisible != (layers[index].id == shown) {
            layers[index].isVisible = layers[index].id == shown
            changed = true
        }
        if changed { onLayersChange?(layers) }
    }

    /// Rebuilds the stack from a revision list, keeping every setting the person has already
    /// made on a revision that is still in it.
    ///
    /// The list arrives after the mode opens — the app has to reach the document store to
    /// discover what revisions there are — so the stack cannot simply be built once in the
    /// initialiser and left. Re-seeding it must not throw away a colour or an opacity the
    /// person chose two seconds ago, which is what the carry-over below is for.
    public func setRevisions(_ revisions: [RevisionSummary]) {
        let existing = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        let palette = ZenitMarkupPalette.entries
        var used = Set<String>()
        var rebuilt: [RevisionOverlayLayer] = []
        for (index, revision) in revisions.enumerated() {
            if var kept = existing[revision.id] {
                kept.revisionName = revision.name
                kept.revisionLabel = revision.revisionLabel
                kept.order = index
                used.insert(kept.colorName)
                rebuilt.append(kept)
                continue
            }
            let entry = palette.first { !used.contains($0.name) } ?? palette[index % palette.count]
            used.insert(entry.name)
            rebuilt.append(RevisionOverlayLayer(
                id: revision.id,
                revisionName: revision.name,
                revisionLabel: revision.revisionLabel,
                colorName: entry.name,
                colorRGBA: entry.color,
                opacity: index == 0 ? 1 : 0.6,
                isVisible: true,
                order: index
            ))
        }
        guard rebuilt != layers else { return }
        layers = rebuilt
        onLayersChange?(layers)
    }

    /// The legend, bottom layer first. One entry per *visible* layer, because a legend that
    /// names a colour nobody can see is a legend that is wrong.
    public var legendEntries: [RevisionOverlayLegendEntry] {
        visibleLayers.enumerated().map { index, layer in
            RevisionOverlayLegendEntry(
                id: layer.id,
                revisionName: layer.revisionName,
                revisionLabel: layer.revisionLabel,
                colorName: layer.colorName,
                colorRGBA: layer.colorRGBA,
                opacity: layer.opacity,
                position: index + 1
            )
        }
    }

    /// Whether the manual fit is applied to more than one sheet.
    ///
    /// One set of point pairs registers *every* revision above the bottom one onto it. With
    /// exactly two layers that is the whole truth; with three or more it is a simplification
    /// the interface has to admit to rather than let a person assume each sheet was aligned
    /// on its own.
    ///
    /// Counted over **visible** layers, like ``hasEnoughLayers`` and the legend: the note tells
    /// the person to hide the others to align one sheet on its own, and following that advice
    /// used to leave the note standing because hidden layers still counted. Finding BH-840.
    public var alignmentAppliesToSeveralSheets: Bool { visibleLayers.count > 2 }

    /// Whether the inspector should say that only one layer is visible.
    ///
    /// Exactly one, not "fewer than two": with none visible the note used to read "Only one
    /// layer is visible" beside a legend correctly saying no revision is showing. Finding
    /// BH-842. Blinking shows one layer at a time by design, so it raises no note.
    public var showsSingleVisibleLayerNote: Bool { visibleLayers.count == 1 && !isBlinking }

    /// How many screen pixels one PDF point covers where the overlay is drawn (backing scale ×
    /// zoom), so ``alignmentState`` can report its residual in the pixels it claims. The host
    /// updates it; 1 until it does. BH-835.
    public var pixelsPerPoint: Double = 1

    // MARK: - The composited picture

    /// Installs a finished composite and marks the canvas current.
    public func setComposite(_ composite: RevisionOverlayComposite) {
        self.composite = composite
        compositeStatus = .ready
    }

    /// Reports what the canvas is doing, or why it cannot show anything.
    ///
    /// A previous composite is deliberately left on screen while a new one is produced —
    /// the same rule `AppComparePresenter` follows for a running comparison — because
    /// blanking the sheet on every opacity nudge is worse than a picture that is one
    /// setting out of date for two hundred milliseconds. A composite that *failed* is
    /// cleared: leaving a stale one under an error message invites reading the wrong sheet.
    public func setCompositeStatus(_ status: RevisionOverlayCompositeStatus) {
        compositeStatus = status
        switch status {
        case .failed, .unavailable: composite = nil
        case .idle, .rendering, .ready: break
        }
    }

    /// Throws away the composite, for a mode that is being left.
    public func clearComposite() {
        composite = nil
        compositeStatus = .idle
    }

    // MARK: - Alignment

    /// Records one feature the person marked on both sheets and re-fits.
    public func capturePair(baseline: PDFPointValue, comparison: PDFPointValue) {
        pointPairs.append(RevisionAlignmentPointPair(
            baselinePoint: baseline,
            comparisonPoint: comparison
        ))
        recomputeFit()
    }

    /// Removes one marked pair and re-fits.
    public func removePair(id: RevisionAlignmentPointPair.ID) {
        pointPairs.removeAll { $0.id == id }
        recomputeFit()
    }

    /// Throws away every marked pair.
    public func clearPairs() {
        pointPairs.removeAll()
        captureStage = .off
        recomputeFit()
    }

    /// Arms the two-click gesture that marks one point.
    public func beginPointCapture() {
        captureStage = .awaitingBaseline
    }

    /// Disarms it, discarding a half-finished point.
    public func cancelPointCapture() {
        captureStage = .off
    }

    /// Takes one click on the composite, in the **baseline sheet's page space**.
    ///
    /// The first click says where the feature is on the bottom sheet. The second says where
    /// the same feature currently *appears* — which is the comparison sheet drawn through
    /// whatever alignment is in force — and is mapped back through that alignment before it
    /// is stored, so the pair stays true in the comparison sheet's own coordinates after the
    /// re-fit moves the picture. With no fit yet the two spaces are the same and the mapping
    /// is the identity.
    ///
    /// - Returns: `true` when the click completed a pair and the fit was recomputed.
    @discardableResult
    public func capturePoint(_ point: PDFPointValue) -> Bool {
        switch captureStage {
        case .off:
            return false
        case .awaitingBaseline:
            captureStage = .awaitingComparison(point)
            return false
        case let .awaitingComparison(baseline):
            // A fit whose map cannot be inverted must not turn a baseline-space click into a
            // comparison point by falling through to the raw value (BH-308).
            let comparison: PDFPointValue
            if let fit {
                guard let inverse = fit.transform.inverted() else {
                    captureStage = .off
                    return false
                }
                comparison = inverse.apply(to: point)
            } else {
                comparison = point
            }
            captureStage = .off
            capturePair(baseline: baseline, comparison: comparison)
            return true
        }
    }

    /// Re-runs the fit for the current mode and points.
    public func recomputeFit() {
        switch RevisionAlignmentSolver.fit(pairs: pointPairs, mode: alignmentMode) {
        case let .success(result):
            fit = result
            alignmentProblem = nil
        case let .failure(problem):
            fit = nil
            alignmentProblem = problem
        }
        onAlignmentChange?(fit)
    }

    /// The presentation-layer alignment state, for the parts of the app that report it.
    ///
    /// Too few points marked is *not aligned yet*, not a failure: no automatic alignment was
    /// attempted, and the state used to read "Automatic alignment failed: Mark 2 matching
    /// points…" from the moment the mode opened. Finding BH-841. Only a fit that was tried and
    /// could not be solved — coincident or collinear points — is a failure.
    public var alignmentState: RevisionAlignmentState {
        guard let fit else {
            switch alignmentProblem {
            case nil, .notEnoughPoints?:
                return .notAligned
            case let problem?:
                return .failed(reason: problem.message)
            }
        }
        return fit.alignmentState(pixelsPerPoint: pixelsPerPoint)
    }

    // MARK: - Private

    private func update(_ id: RevisionSummary.ID, _ mutate: (inout RevisionOverlayLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = layers[index]
        mutate(&layer)
        guard layer != layers[index] else { return }
        layers[index] = layer
        onLayersChange?(layers)
    }

    private func renumber() {
        let ordered = layers.sorted { $0.order < $1.order }
        layers = ordered.enumerated().map { index, layer in
            var copy = layer
            copy.order = index
            return copy
        }
    }
}
