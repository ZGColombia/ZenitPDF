import AppKit
import UniformTypeIdentifiers
import ZPDFDesignSystem
import ZPDFUIWorkflows

/// The canvas scroll view: PDFKit-free, so every scroll event reaches this class first and the
/// zoom gestures cannot be consumed underneath us.
///
/// What is intercepted here, and why:
///
/// - **`⌘` + two-finger trackpad drag zooms about the pointer.** This is the primary zoom
///   gesture. `hasPreciseScrollingDeltas` separates a trackpad from a
///   wheel, because the same numeric delta means very different things from the two devices.
///   The vertical component drives the zoom; a horizontal component during a `⌘` drag is
///   ignored, not turned into a pan.
/// - **Momentum continues the zoom.** `momentumPhase` events keep arriving after the fingers
///   lift. Whether the tail zooms is decided by what the *active* phase was doing, so releasing
///   `⌘` mid-momentum does not turn the end of a zoom into a scroll jump.
/// - **Pinch zooms about the pointer**, through the same pointer-anchored path.
/// - Plain scrolls fall through to `NSScrollView` untouched, both axes.
///
/// The view is also the canvas drop target: `.pdf` and `.zpdfproj`
/// are accepted, anything else never shows a drop indicator, and the badge says what the drop
/// will do — including the `⌥`-for-revision variant — so the behaviour is discoverable.
@MainActor
final class ZenitCanvasScrollView: NSScrollView {

    /// A key equivalent offered to the canvas before the menus (NL-DOCS-09: ⌘[ and ⌘]).
    var onKeyEquivalent: (@MainActor (NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Zoom callbacks

    /// Whether the last active (fingers-down) scroll sequence was a `⌘` zoom, so momentum
    /// events keep doing what the gesture was doing when the fingers lifted.
    private var activeScrollSequenceWasZoom = false

    /// Delta-to-factor exponents. A trackpad reports many small precise deltas per frame; a
    /// wheel reports a few coarse notches. The two constants make one notch feel like one
    /// short two-finger drag.
    private static let preciseDeltaExponent = 0.0035
    private static let wheelNotchExponent = 0.05

    // MARK: - Turning the page by scrolling

    /// Turns to the next or previous page. Wired by the canvas controller.
    ///
    /// Scrolling must be able to reach the next sheet of a long set. The canvas shows one page, so a scroll panned
    /// within that page and stopped dead at its edge — with no keyboard route to the next sheet
    /// either, the only way through the document was the Navigator, which can be closed.
    var onTurnPage: (@MainActor (_ forward: Bool) -> Bool)?

    /// How much overscroll past an edge, in points, turns the page.
    ///
    /// Not zero, and not small. A person panning to read the bottom of a sheet reaches the edge
    /// constantly; turning the page the instant they touch it would make the document feel like
    /// it was slipping out from under them.
    ///
    /// **Raised from 90 on 2026-08-26**, together with the began-at-the-edge rule below, because
    /// the first version turned the page when a zoomed-in reader only meant to scroll a little.
    /// Zoomed in, a sheet is many viewports tall and reaching
    /// its bottom edge is ordinary reading, not a request for the next sheet.
    static let pageTurnOverscrollThreshold: CGFloat = 160

    /// Overscroll accumulated in the current gesture, signed: positive is past the bottom.
    private var overscrollAccumulator: CGFloat = 0

    /// Whether the current gesture was **already** against the edge when the fingers went down.
    ///
    /// This is the rule that makes a page turn deliberate rather than accidental, and it matters
    /// more than any threshold. Scrolling down through a zoomed-in sheet and arriving at its
    /// bottom is one continuous gesture; under this rule that gesture can never turn the page,
    /// however far it overscrolls. The reader lifts their fingers and scrolls again — a second
    /// gesture, begun at the edge, which is a deliberate request for the next sheet.
    ///
    /// `nil` outside a gesture. A legacy wheel has no phases, so each of its events is judged on
    /// the edge state at that moment.
    private var gestureBeganAtEdge: (top: Bool, bottom: Bool)?

    /// Set once a gesture has turned a page, so one flick moves one sheet. A momentum tail
    /// carrying six hundred points of delta must not skip six sheets.
    private var gestureHasTurnedPage = false

    /// Decides whether one scroll event zooms, and what the sequence remembers.
    ///
    /// The whole fingers-down sequence is decided **at `.began`** and every later `.changed`,
    /// `.ended` and momentum event follows it. Re-deciding per event from the live `⌘` state
    /// split one gesture between the two paths: pressing `⌘` half-way handed the zoom path a
    /// sequence `NSScrollView` had seen begin but never saw end, and releasing it handed the
    /// scroll view an `.ended` with no `.began` (BH-891). A legacy wheel has no phases; the
    /// modifier decides per event.
    static func zoomDecision(
        phaseBegan: Bool,
        isGestureEvent: Bool,
        isMomentum: Bool,
        commandHeld: Bool,
        sequenceWasZoom: Bool,
        plainWheelZooms: Bool = false
    ) -> (zooming: Bool, sequenceWasZoom: Bool) {
        if isMomentum || (isGestureEvent && !phaseBegan) {
            return (sequenceWasZoom, sequenceWasZoom)
        }
        if isGestureEvent {
            return (commandHeld, commandHeld)
        }
        // A phase-less wheel: ⌘ zooms, and so does a plain notch under "Mouse wheel zooms".
        return (commandHeld || plainWheelZooms, false)
    }

    /// Whether a wheel event without ⌘ zooms under Settings ▸ Canvas ▸ "Mouse wheel zooms"
    /// (NL-UX-14): only a phase-less, coarse, vertical notch — a mouse wheel. A trackpad or a
    /// gesture mouse reports phases or precise deltas and keeps scrolling; Shift (which the
    /// system turns into a sideways notch) keeps scrolling sideways.
    static func plainWheelZooms(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        precise: Bool,
        shiftHeld: Bool,
        scrollingDeltaY: CGFloat,
        preference: Bool
    ) -> Bool {
        preference && phase == [] && momentumPhase == [] && !precise && !shiftHeld && scrollingDeltaY != 0
    }

    /// Reads the "Mouse wheel zooms" preference. Injectable so a test decides it.
    var wheelZoomsPreference: @MainActor () -> Bool = { ZenitCanvasPreferences.current.wheelZooms }

    /// Whether this event is a plain wheel notch that zooms under the preference. The
    /// preference is read only for an event that could qualify.
    func plainWheelZooms(_ event: NSEvent) -> Bool {
        guard event.phase == [], event.momentumPhase == [], !event.hasPreciseScrollingDeltas else { return false }
        return Self.plainWheelZooms(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            precise: event.hasPreciseScrollingDeltas,
            shiftHeld: event.modifierFlags.contains(.shift),
            scrollingDeltaY: event.scrollingDeltaY,
            preference: wheelZoomsPreference()
        )
    }

    /// The one delta-to-zoom-factor curve, shared by the canvas and the Split Canvas panes
    /// (IM-245) so the same gesture zooms the same amount in the same direction everywhere.
    ///
    /// Works in device direction so fingers-up means zoom-in under both settings of natural
    /// scrolling; clamps one event's factor so a wild wheel delta cannot teleport the zoom.
    /// `nil` for a zero delta.
    static func zoomFactor(scrollingDeltaY: CGFloat, precise: Bool, invertedFromDevice: Bool) -> Double? {
        var deltaY = Double(scrollingDeltaY)
        if invertedFromDevice { deltaY = -deltaY }
        guard deltaY != 0 else { return nil }
        let exponent = precise ? preciseDeltaExponent : wheelNotchExponent
        return min(2.0, max(0.5, exp(deltaY * exponent)))
    }

    /// The overscroll one event contributes to a page turn, in points, signed the way the
    /// **content** is asked to move: negative reveals what is below.
    ///
    /// `scrollingDeltaY` already carries the user's natural-scrolling preference — it is the
    /// delta `NSScrollView` itself applies — so it is used as is. Converting it to device
    /// direction (as the zoom path rightly does) inverted the page turn under Natural
    /// Scrolling, the macOS default (BH-066). A wheel reports lines, not points, so a notch
    /// is scaled by the line height, or the 160-point threshold is unreachable (BH-352).
    static func pageTurnDelta(scrollingDeltaY: CGFloat, precise: Bool, lineScroll: CGFloat) -> CGFloat {
        precise ? scrollingDeltaY : scrollingDeltaY * max(1, lineScroll)
    }

    /// How long a phase-less wheel may pause and still be one gesture.
    static let legacyWheelGestureGap: TimeInterval = 0.35

    /// The timestamp of the last phase-less wheel event.
    private var lastLegacyWheelTimestamp: TimeInterval?

    /// A phase-less wheel event: starts a new page-turn gesture only after a pause.
    ///
    /// Beginning a gesture on *every* notch zeroed the accumulator each time, so a wheel could
    /// never sum to a page turn — and reset the one-turn guard, so a single huge notch could
    /// turn page after page (BH-352). Internal for tests.
    func noteLegacyWheelEvent(at timestamp: TimeInterval, atTop: Bool, atBottom: Bool) {
        if let last = lastLegacyWheelTimestamp, timestamp - last <= Self.legacyWheelGestureGap,
           gestureBeganAtEdge != nil {
            lastLegacyWheelTimestamp = timestamp
            return
        }
        lastLegacyWheelTimestamp = timestamp
        beginScrollGesture(atTop: atTop, atBottom: atBottom)
    }

    override func scrollWheel(with event: NSEvent) {
        let isMomentum = event.momentumPhase != []
        let decision = Self.zoomDecision(
            phaseBegan: event.phase.contains(.began) || event.phase.contains(.mayBegin),
            isGestureEvent: event.phase != [] || isMomentum,
            isMomentum: isMomentum,
            commandHeld: event.modifierFlags.contains(.command),
            sequenceWasZoom: activeScrollSequenceWasZoom,
            plainWheelZooms: plainWheelZooms(event)
        )
        activeScrollSequenceWasZoom = decision.sequenceWasZoom

        guard decision.zooming else {
            let wasAtTop = isScrolledToTop
            let wasAtBottom = isScrolledToBottom

            // A new fingers-down gesture starts a fresh page-turn budget, and records whether it
            // *began* against an edge. A legacy wheel is grouped by its pauses.
            if event.phase.contains(.began) {
                beginScrollGesture(atTop: wasAtTop, atBottom: wasAtBottom)
            } else if event.phase == [], event.momentumPhase == [] {
                noteLegacyWheelEvent(at: event.timestamp, atTop: wasAtTop, atBottom: wasAtBottom)
            }

            super.scrollWheel(with: event)

            considerTurningPage(
                deltaY: Self.pageTurnDelta(
                    scrollingDeltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas,
                    lineScroll: verticalLineScroll
                ),
                wasAtTop: wasAtTop,
                wasAtBottom: wasAtBottom
            )

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                endScrollGesture()
            }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                clearPageTurnProgress()
            }
            return
        }

        // The event must not also scroll: consume it entirely.
        // Vertical component only; horizontal is deliberately ignored. A zero delta still
        // carries its phase: the momentum's end is what ends the gesture.
        let factor = Self.zoomFactor(
            scrollingDeltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            invertedFromDevice: event.isDirectionInvertedFromDevice
        ) ?? 1
        handleZoomGesture(
            factor: factor,
            windowPoint: event.locationInWindow,
            phase: Self.zoomPhase(phase: event.phase, momentumPhase: event.momentumPhase)
        )
    }

    /// Where a `⌘`-scroll event sits in its zoom gesture. The fingers lifting is not the end —
    /// momentum may follow — so it is ``ZoomGesturePhase/lifted``, and only the momentum's own
    /// end (or cancellation) ends the gesture. A phase-less wheel is all ``changed``: the canvas
    /// ends it after a pause.
    static func zoomPhase(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> ZoomGesturePhase {
        if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { return .ended }
        if momentumPhase != [] { return .changed }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .lifted }
        return .changed
    }

    // MARK: - The zoom gesture (NL-PERF-01, NL-PERF-04)

    /// Where a zoom input sits in its gesture.
    enum ZoomGesturePhase: Sendable, Equatable {
        case began
        case changed
        /// The fingers left the trackpad; momentum may still follow.
        case lifted
        case ended
    }

    /// Receives every zoom input with its phase (NL-PERF-04). The canvas accumulates the
    /// steps into one GPU transform per display frame and lays the page out once, at the end.
    var onZoomGesture: (@MainActor (_ factor: Double, _ aboutWindowPoint: NSPoint, _ phase: ZoomGesturePhase) -> Void)?

    /// The one door every zoom input goes through: pinch, `⌘`+scroll and `⌘`+wheel.
    ///
    /// Internal so the gesture-replay gate (`ViewerGestureReplayTests`) can drive exactly the
    /// path a trackpad drives, without synthesising gesture `NSEvent`s, which AppKit gives no
    /// public constructor for. There is no second door: the lay-out-per-event `onZoom` fallback
    /// could never run, because the canvas always wires this one (U-004, iteration 4).
    func handleZoomGesture(factor: Double, windowPoint: NSPoint, phase: ZoomGesturePhase) {
        guard factor.isFinite, factor > 0 else { return }
        onZoomGesture?(factor, windowPoint, phase)
    }

    /// Whether the document is scrolled hard against its top edge.
    ///
    /// A tolerance of half a point, not equality: `NSScrollView` lands on values such as
    /// `-0.4999` after a fit, and an exact comparison makes the page turn work sometimes.
    var isScrolledToTop: Bool {
        contentView.bounds.origin.y <= contentView.documentRect.origin.y + 0.5
    }

    /// Whether the document is scrolled hard against its bottom edge.
    var isScrolledToBottom: Bool {
        let visible = contentView.bounds
        let document = contentView.documentRect
        // A page shorter than the viewport is at both edges at once; that is correct, and the
        // caller's direction test is what separates the two.
        guard document.height > visible.height else { return true }
        return visible.maxY >= document.maxY - 0.5
    }

    /// Accumulates overscroll and turns the page once the gesture has clearly asked for it.
    ///
    /// The `was…` flags are read *before* `super.scrollWheel` so that the frame in which the
    /// content reaches the edge is the frame the accumulator starts in. Reading them afterwards
    /// loses one event's delta and, on a short page, every event's delta.
    /// Starts a scroll gesture: resets the page-turn budget and records whether the document was
    /// already against an edge. Internal so a test can begin a gesture without an `NSEvent`.
    func beginScrollGesture(atTop: Bool, atBottom: Bool) {
        overscrollAccumulator = 0
        gestureHasTurnedPage = false
        gestureBeganAtEdge = (top: atTop, bottom: atBottom)
        clearPageTurnProgress()
    }

    /// Ends the current gesture, so the next overscroll needs a fresh one.
    func endScrollGesture() {
        gestureBeganAtEdge = nil
        clearPageTurnProgress()
    }

    // MARK: - Page-turn progress (IM-246)

    /// How far the current overscroll has gone towards a page turn, 0…1, and which way.
    /// `nil` while nothing is accumulating. Internal for tests.
    private(set) var pageTurnProgress: (fraction: CGFloat, forward: Bool)?

    /// The fraction below which the hint stays hidden: brushing an edge while reading is not
    /// a page-turn request, and a flickering label would be noise.
    static let pageTurnHintThreshold: CGFloat = 0.25

    /// The small edge label that makes the deliberate second-gesture page turn discoverable.
    private(set) lazy var pageTurnHintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
        label.alignment = .center
        label.isHidden = true
        label.setAccessibilityRole(.staticText)
        return label
    }()

    /// The hint text for a progress, or `nil` when it should be hidden. Pure for tests.
    static func pageTurnHintText(fraction: CGFloat, forward: Bool) -> String? {
        guard fraction >= pageTurnHintThreshold, fraction < 1 else { return nil }
        let percent = Int((min(1, fraction) * 100).rounded())
        let format = forward
            ? NSLocalizedString(
                "Keep scrolling for the next page (%d %%)",
                comment: "Canvas edge hint while an overscroll accumulates towards the next page"
            )
            : NSLocalizedString(
                "Keep scrolling for the previous page (%d %%)",
                comment: "Canvas edge hint while an overscroll accumulates towards the previous page"
            )
        return String(format: format, percent)
    }

    private func updatePageTurnProgress() {
        let fraction = min(1, abs(overscrollAccumulator) / Self.pageTurnOverscrollThreshold)
        guard fraction > 0 else {
            clearPageTurnProgress()
            return
        }
        let forward = overscrollAccumulator > 0
        pageTurnProgress = (fraction, forward)
        guard let text = Self.pageTurnHintText(fraction: fraction, forward: forward) else {
            pageTurnHintLabel.isHidden = true
            return
        }
        let label = pageTurnHintLabel
        if label.superview == nil { addSubview(label) }
        label.stringValue = text
        label.setAccessibilityLabel(text)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 16, height: label.frame.height + 6)
        // `NSScrollView` is not flipped: y = 0 is the bottom edge.
        let y = forward ? 12 : bounds.height - size.height - 12
        label.frame = CGRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
        label.isHidden = false
    }

    private func clearPageTurnProgress() {
        pageTurnProgress = nil
        if pageTurnHintLabel.superview != nil { pageTurnHintLabel.isHidden = true }
    }

    /// Internal rather than private so the threshold, the direction reversal and the
    /// one-turn-per-gesture rule can be asserted without synthesising `NSEvent`s — the three
    /// things most likely to be wrong, and the three a screenshot cannot show.
    func considerTurningPage(deltaY: CGFloat, wasAtTop: Bool, wasAtBottom: Bool) {
        guard onTurnPage != nil, !gestureHasTurnedPage, deltaY != 0 else { return }

        // Scrolling content up (fingers up, deltaY negative) reveals what is below: forward.
        let goingForward = deltaY < 0
        guard goingForward ? wasAtBottom : wasAtTop else {
            overscrollAccumulator = 0
            clearPageTurnProgress()
            return
        }
        // The gesture must have *begun* at the edge it is now pushing against. Arriving at the
        // edge part-way through a scroll is reading, not a page turn.
        guard let began = gestureBeganAtEdge, goingForward ? began.bottom : began.top else {
            overscrollAccumulator = 0
            clearPageTurnProgress()
            return
        }

        // Reset when the direction reverses, so a wobble at the edge never sums to a turn.
        if (overscrollAccumulator > 0) != goingForward { overscrollAccumulator = 0 }
        overscrollAccumulator += goingForward ? abs(deltaY) : -abs(deltaY)

        guard abs(overscrollAccumulator) >= Self.pageTurnOverscrollThreshold else {
            updatePageTurnProgress()
            return
        }
        overscrollAccumulator = 0
        clearPageTurnProgress()
        if onTurnPage?(goingForward) == true {
            gestureHasTurnedPage = true
        }
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0 else { return }
        let phase: ZoomGesturePhase
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            phase = .ended
        } else if event.phase.contains(.began) {
            phase = .began
        } else {
            phase = .changed
        }
        handleZoomGesture(factor: Double(factor), windowPoint: event.locationInWindow, phase: phase)
    }

    // MARK: - Drag and drop

    /// What a drop of files would do right now, given the `⌥` state. Decides the badge text.
    var dropBehaviorProvider: (@MainActor (_ optionHeld: Bool) -> CanvasDropBehavior)?
    /// Performs the drop. URLs arrive in the order Finder supplies.
    var onDropFiles: (@MainActor (_ urls: [URL], _ behavior: CanvasDropBehavior) -> Bool)?
    /// r2-markup (NL-UX-15): a behaviour decided by what is dropped — image files onto a
    /// project's drawing become image markups. `nil` defers to ``dropBehaviorProvider``.
    var contentDropBehavior: (@MainActor (_ urls: [URL], _ optionHeld: Bool) -> CanvasDropBehavior?)?
    /// Where the last drop landed, in window coordinates, for a drop that places something.
    private(set) var lastDropLocationInWindow: NSPoint?

    private var dropIndicator: CanvasDropIndicatorView?

    /// The behaviour for these files now: the content's, else the modifier's.
    private func behavior(for urls: [URL]) -> CanvasDropBehavior? {
        contentDropBehavior?(urls, optionIsHeld) ?? dropBehaviorProvider?(optionIsHeld)
    }

    /// The types this application can open: projects, PDFs, and scans or photos of sheets
    /// (NL-PLAT-04). Everything else is rejected *during* the drag: the indicator never appears
    /// for a file we cannot open.
    static let acceptedTypes: [UTType] = ZenitDocumentController.openPanelContentTypes

    /// Registers the drag types. Called from the canvas controller once the callbacks exist.
    func enableFileDrops() {
        // r2-markup (NL-UX-15): a Tool Library row, dragged out as its JSON payload, too.
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(UTType.json.identifier)])
    }

    /// r2-markup (NL-UX-15): places a Tool Library preset dragged onto the sheet, at the drop
    /// point in window coordinates. `nil` refuses preset drags.
    var onDropPreset: (@MainActor (_ presetID: UUID, _ windowPoint: NSPoint) -> Bool)?

    /// The preset a drag carries, when it is a Tool Library row.
    private func draggedPresetID(from info: NSDraggingInfo) -> UUID? {
        guard onDropPreset != nil,
              let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(UTType.json.identifier)),
              let payload = try? JSONDecoder().decode(ToolPresetDragPayload.self, from: data) else { return nil }
        return payload.presetID
    }

    private func droppableURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else { return [] }
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                return false
            }
            return Self.acceptedTypes.contains { type.conforms(to: $0) }
                || url.pathExtension.lowercased() == ZenitAppInfo.projectExtension
        }
    }

    private var optionIsHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPresetID(from: sender) != nil { return .copy }
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty, dropBehaviorProvider != nil else { return [] }
        showDropIndicator()
        return updateDropIndicator(urls: urls)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if draggedPresetID(from: sender) != nil { return .copy }
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty, dropIndicator != nil else { return [] }
        return updateDropIndicator(urls: urls)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()
        if let presetID = draggedPresetID(from: sender), let onDropPreset {
            return onDropPreset(presetID, sender.draggingLocation)
        }
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty,
              let behavior = behavior(for: urls),
              let onDropFiles else { return false }
        lastDropLocationInWindow = sender.draggingLocation
        return onDropFiles(urls, behavior)
    }

    private func showDropIndicator() {
        guard dropIndicator == nil else { return }
        let indicator = CanvasDropIndicatorView(frame: bounds)
        indicator.autoresizingMask = [.width, .height]
        addSubview(indicator, positioned: .above, relativeTo: nil)
        dropIndicator = indicator
    }

    private func updateDropIndicator(urls: [URL]) -> NSDragOperation {
        guard let behavior = behavior(for: urls) else { return [] }
        dropIndicator?.badgeText = behavior.badgeText(fileCount: urls.count)
        return behavior == .addAsRevision ? .link : .copy
    }

    private func hideDropIndicator() {
        dropIndicator?.removeFromSuperview()
        dropIndicator = nil
    }
}

/// What dropping drawings on the canvas will do. The badge states it in words, so the
/// `⌥` behaviour is discoverable instead of secret.
public enum CanvasDropBehavior: Equatable, Sendable {
    /// Open the files as documents.
    case open
    /// Add the drawing as a new revision of the current document, for Revision Compare.
    case addAsRevision
    /// Place the images on the sheet as image markups (r2-markup, NL-UX-15 / NL-MARKUP-17).
    case placeImages

    func badgeText(fileCount: Int) -> String {
        switch self {
        case .placeImages:
            return fileCount > 1
                ? String(format: NSLocalizedString("Place %d images on the sheet", comment: "Drop badge: several images become image markups"), fileCount)
                : NSLocalizedString("Place the image on the sheet", comment: "Drop badge: an image becomes an image markup")
        case .open:
            if fileCount > 1 {
                return String(
                    format: NSLocalizedString(
                        "Open %d drawings",
                        comment: "Drop badge for several files"
                    ),
                    fileCount
                )
            }
            return NSLocalizedString("Open", comment: "Drop badge: the file opens as a document")
        case .addAsRevision:
            return NSLocalizedString(
                "Add as revision",
                comment: "Drop badge: the file becomes a revision of the current drawing"
            )
        }
    }
}

/// The drop highlight: a border around the target region and a badge saying what will happen.
final class CanvasDropIndicatorView: NSView {

    var badgeText: String = "" {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    // The indicator must never eat the drag events of the scroll view under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = ZPDFColor.nsColor(.accentCyan)
        accent.withAlphaComponent(0.08).setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 3
        accent.setStroke()
        border.stroke()

        guard !badgeText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: badgeText, attributes: attributes)
        let size = string.size()
        let badge = CGRect(
            x: bounds.midX - size.width / 2 - 14,
            y: bounds.midY - size.height / 2 - 8,
            width: size.width + 28,
            height: size.height + 16
        )
        let pill = NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8)
        ZPDFColor.nsColor(.elevated).withAlphaComponent(0.95).setFill()
        pill.fill()
        accent.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        string.draw(at: CGPoint(x: badge.minX + 14, y: badge.minY + 8))
    }
}

/// The drop target for the window's empty state: before a drawing has loaded, dropping a
/// PDF or a project anywhere in the window opens it.
@MainActor
final class ZenitEmptyWindowDropView: NSView {

    /// Opens the dropped files. Set by the window controller.
    var onDropFiles: (@MainActor ([URL]) -> Bool)?

    private var dropIndicator: CanvasDropIndicatorView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func droppableURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] else { return [] }
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                return false
            }
            return ZenitCanvasScrollView.acceptedTypes.contains { type.conforms(to: $0) }
                || url.pathExtension.lowercased() == ZenitAppInfo.projectExtension
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty else { return [] }
        if dropIndicator == nil {
            let indicator = CanvasDropIndicatorView(frame: bounds)
            indicator.autoresizingMask = [.width, .height]
            addSubview(indicator)
            dropIndicator = indicator
        }
        dropIndicator?.badgeText = CanvasDropBehavior.open.badgeText(fileCount: urls.count)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator?.removeFromSuperview()
        dropIndicator = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropIndicator?.removeFromSuperview()
        dropIndicator = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty, let onDropFiles else { return false }
        return onDropFiles(urls)
    }
}
