import Foundation
import ZPDFUIPresentation

// MARK: - Modifiers

/// The modifier keys the drawing flow reacts to.
///
/// Modifier keys: Shift constrains angles, Command suspends snapping while held, Option bypasses
/// the current candidate so the next Tab starts from the raw pointer position.
public struct MeasurementInputModifiers: OptionSet, Hashable, Sendable, Codable {

    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Constrain the segment to a multiple of the angle increment.
    public static let shift = MeasurementInputModifiers(rawValue: 1 << 0)
    /// Suspend snapping for as long as the key is held.
    public static let command = MeasurementInputModifiers(rawValue: 1 << 1)
    /// Bypass the acquired candidate and work from the raw pointer position.
    public static let option = MeasurementInputModifiers(rawValue: 1 << 2)
}

// MARK: - Phase

/// Where the drawing flow currently is.
public enum MeasurementInputPhase: String, Hashable, Sendable, CaseIterable {
    /// No measurement tool is armed; the pointer tool owns the canvas.
    case idle
    /// A tool is armed but no vertex has been placed yet.
    case armed
    /// At least one vertex has been placed.
    case drawing
}

// MARK: - Events

/// Everything the canvas, the menu bar and the keyboard can tell the drawing flow.
///
/// Events are values, so a test can replay a whole drawing session without a window,
/// a run loop or a presenter.
public enum MeasurementInputEvent: Hashable, Sendable {
    /// Arm a measurement tool. Re-arming the same tool restarts its geometry.
    case armTool(MeasurementKind)
    /// Disarm the tool and return to the pointer.
    case disarmTool
    /// The pointer moved to a page point. Ends keyboard-cursor placement: the pointer leads again.
    case pointerMoved(PDFPointValue)
    /// An arrow key while a tool is armed (R-137; keyboard access, `ACCESSIBILITY_PLAN.md`):
    /// the keyboard cursor moves by a page-space delta the host derived from the arrow's
    /// screen direction and step (Shift for the larger one). The keyboard cursor *is*
    /// ``MeasurementInputState/rawCursor``, so snapping, the Shift ray and the close on the first
    /// vertex apply to it exactly as to the pointer, and ``placePointAtCursor`` places there.
    /// Ignored when no tool is armed.
    case moveKeyboardCursor(dx: Double, dy: Double)
    /// Place a vertex at the effective point (snapped and/or angle-constrained).
    case placePointAtCursor
    /// Place a vertex at an explicit page point, bypassing snapping.
    case placePoint(PDFPointValue)
    /// Backspace: drop the most recent vertex.
    case removeLastVertex
    /// ⌥-click on an existing count point: remove *that* point, not the last one
    /// — a count corrects one mark without undoing later ones. Ignored by every tool that is not a point placement,
    /// and ignored when no placed point is within the hit tolerance.
    case removePoint(near: PDFPointValue)
    /// The host published the area markups a cutout could attach to on the active page.
    ///
    /// The cutout tools are the only ones that need to know about existing markups, and they
    /// need it before the first click, so the list arrives as an event rather than being
    /// fetched mid-gesture.
    case setCutoutParents([CutoutParentCandidate])
    /// Return: finish the geometry. While the keyboard cursor leads
    /// (``MeasurementInputState/returnPlacesPoint``) the host sends Return as
    /// ``placePointAtCursor`` instead, and ⌘Return as this.
    case finish
    /// Double-click: close a variable-vertex geometry at the cursor.
    ///
    /// The first click of the pair usually placed a vertex already; if it placed a duplicate,
    /// the machine drops it before committing, so a polygon area never ends on a repeated vertex.
    case doubleClick
    /// A secondary click — a two-finger trackpad tap or the right mouse button, macOS
    /// delivers both as the same event.
    ///
    /// During a variable-vertex geometry with enough points it finishes: a polygon closes
    /// at its current vertices, a polylength finishes as placed. With fewer points it does
    /// nothing at all — never a cancel, never degenerate geometry.
    case secondaryClick
    /// A press started a one-gesture drag tool at a page point (rectangle and ellipse areas).
    case dragBegan(PDFPointValue)
    /// The drag moved to a page point. The live value follows this.
    case dragMoved(PDFPointValue)
    /// The drag released at a page point. For a drag tool this places the opposite corner
    /// and commits — press, drag, release, one gesture.
    case dragEnded(PDFPointValue)
    /// ⌥-click on a tool that offers the three-point rectangle from its first two vertices
    /// (Area, `ZenitToolGesture.optionDerivesRectangle`): the two placed vertices are one
    /// *edge*, this click is the depth point, the fourth corner is derived and the shape
    /// commits — the same three-point rectangle the Rectangle tool draws.
    ///
    /// With anything other than exactly two vertices placed, or on a tool without the
    /// gesture, it is an ordinary ``placePointAtCursor``: the ⌥ only means something once
    /// there is an edge for it to complete.
    case placeRectangleDepthAtCursor
    /// Escape: cancel the geometry, then disarm the tool.
    case cancel
    /// The held modifier keys changed.
    case setModifiers(MeasurementInputModifiers)
    /// Tab / Shift-Tab: step through overlapping snap candidates.
    case cycleSnapCandidate(forward: Bool)
    /// The snap engine published a new candidate list for the current pointer position.
    case setSnapCandidates([SnapFeedbackSnapshot])
    /// The page has no usable vector content, so Vector Snap is unavailable.
    case setVectorSnapAvailable(Bool)
    /// A while drawing (NL-MEASURE-05, ADR-0030 §5.6): the next segment becomes a three-point
    /// arc — the next click is a point the arc passes through, the click after it the arc's end —
    /// or, pressed again, straight again. Ignored outside a shape in progress and for a tool
    /// whose segments cannot be arcs; the canvas keeps A as the Area tool there.
    case toggleArcSegment
}

// MARK: - Effects

/// What the host must do after an event. The state machine never touches a presenter itself.
public enum MeasurementInputEffect: Hashable, Sendable {
    /// Call `MeasurementToolPresenting.activate(kind:)`.
    case activateTool(MeasurementKind)
    /// Call `MeasurementToolPresenting.deactivate()`.
    case deactivateTool
    /// Call `MeasurementToolPresenting.placePoint(_:)`.
    case placePoint(PDFPointValue)
    /// Call `MeasurementToolPresenting.removeLastPoint()`.
    case removeLastPoint
    /// Call ``CountPointEditing/removePoint(at:)`` for a point that is not the last one.
    case removePoint(index: Int)
    /// Call `MeasurementToolPresenting.commitActiveMeasurement()`.
    case commitMeasurement
    /// Call ``CutoutCommitting/commitActiveCutout(parentMarkupID:)``.
    ///
    /// A cutout never commits through ``commitMeasurement``: that door builds `.addMarkup`,
    /// which would produce an orphan polygon that subtracts nothing. This one builds `.addCutout`,
    /// which subtracts, nests in the ledger and undoes as one step.
    case commitCutout(parentMarkupID: UUID)
    /// Call `MeasurementToolPresenting.cancelActiveMeasurement()`.
    case cancelMeasurement
    /// Speak a string that reports a state change: a vertex placed, a commit, a cancel, a
    /// tool armed. The host must never drop one of these.
    case announce(String)
    /// Speak a string that reports something transient — a snap acquisition or a Tab
    /// through candidates. The host may throttle these, keeping only the
    /// latest (IM-105).
    case announceTransient(String)
    /// Finish was refused. The message explains what is still missing.
    case rejectFinish(String)
    /// Call ``ArcSegmentDrawing/setArcNextSegment(_:)``: the next segment is an arc, or straight.
    case setArcSegment(Bool)
    /// Call ``ArcSegmentDrawing/placeArcThroughPoint(_:)``: the point the arc passes through.
    case placeArcThroughPoint(PDFPointValue)
    /// Call ``ArcSegmentDrawing/removeArcThroughPoint()``: Backspace took the through point back.
    case removeArcThroughPoint
}

// MARK: - Configuration

/// Tunables for the drawing flow.
public struct MeasurementInputConfiguration: Hashable, Sendable {

    /// Angle increment used while Shift is held, in degrees.
    ///
    /// 45° — Shift makes the line *straight*: horizontal, vertical or diagonal — the increment
    /// established takeoff tools use. It replaces an earlier 15° increment, which produced
    /// lines that were neither straight nor diagonal.
    public var angleIncrementDegrees: Double
    /// Whether the tool stays armed after a commit, so the estimator can keep drawing.
    public var reusesToolAfterCommit: Bool
    /// Where the keyboard cursor starts when a tool is armed without a pointer position.
    public var initialCursor: PDFPointValue
    /// How close, in page points, the cursor must be to the first vertex before a polygon
    /// tool offers to close on it. The host keeps this equivalent to a constant screen
    /// distance by updating it when the zoom changes.
    public var firstVertexCloseTolerance: Double
    /// How far, in page points, a snap candidate may sit from the Shift-constrained ray and
    /// still be used. Candidates beyond it are ignored while the constraint is active — the
    /// direction wins, a snap point off the ray never yanks the line crooked.
    public var constrainedRayTolerance: Double
    /// How close, in page points, an ⌥-click must be to a placed count point before it removes
    /// it. Like ``firstVertexCloseTolerance`` the host keeps this equivalent to a constant
    /// screen distance across zoom levels.
    public var countPointHitTolerance: Double
    /// The symbol drawn at every point of the count group being placed.
    public var countSymbol: CountSymbol
    /// Whether drag questions are answered by the canvas's gesture table
    /// (`ZenitToolMode.measure(kind).gesture`) rather than by the kind's geometry semantics.
    ///
    /// The two differ for Area only: its *geometry* is a polygon, but the canvas offers the
    /// same ring drawn as a press-drag-release rectangle too, so one Area tool covers both
    /// gestures. The shipping canvas turns this on (IM-019). It also makes a press on
    /// a click-placing tool that already has vertices a continuation rather than a fresh
    /// shape, because the canvas has already classified that press-and-release as a click.
    public var appliesCanvasGestures: Bool

    public init(
        angleIncrementDegrees: Double = 45,
        reusesToolAfterCommit: Bool = true,
        initialCursor: PDFPointValue = .zero,
        firstVertexCloseTolerance: Double = 6,
        constrainedRayTolerance: Double = 6,
        countPointHitTolerance: Double = 8,
        countSymbol: CountSymbol = .default,
        appliesCanvasGestures: Bool = false
    ) {
        self.angleIncrementDegrees = max(1, angleIncrementDegrees)
        self.reusesToolAfterCommit = reusesToolAfterCommit
        self.initialCursor = initialCursor
        self.firstVertexCloseTolerance = max(0, firstVertexCloseTolerance)
        self.constrainedRayTolerance = max(0, constrainedRayTolerance)
        self.countPointHitTolerance = max(0, countPointHitTolerance)
        self.countSymbol = countSymbol
        self.appliesCanvasGestures = appliesCanvasGestures
    }

    /// The shipped defaults.
    public static let standard = MeasurementInputConfiguration()
}

// MARK: - Shift

/// What Shift makes of one pointer position while a measurement is drawn — the answer of
/// ``MeasurementInputStateMachine/shiftConstrainedPlacement(kind:placedPoints:cursor:snap:optionHeld:incrementDegrees:rayTolerance:)``,
/// the one rule the machine's click and the canvas's feedback share (U-073).
public struct ShiftConstrainedPlacement: Hashable, Sendable {
    /// The pointer held by the constraint — to the rose ray, or to the perpendicular of a
    /// rectangle's placed edge. The rubber band runs to it, as it runs to the raw pointer when
    /// Shift is up.
    public var cursor: PDFPointValue
    /// The snap candidate held the same way, or `nil` when there is none or it lies off the
    /// rose ray and is ignored. The snap glyph is drawn here, and only when it is set.
    public var snap: PDFPointValue?
    /// The exact rose direction the segment is held to (0.0 / 45.0 / 90.0 …), or `nil` on a
    /// rectangle's depth step — held perpendicular to the edge, not to the rose — and when
    /// the pointer sits on the last placed point.
    public var roseDegrees: Double?

    /// Where a click lands: the held snap candidate when one survives, else the held pointer.
    public var point: PDFPointValue { snap ?? cursor }

    public init(cursor: PDFPointValue, snap: PDFPointValue?, roseDegrees: Double?) {
        self.cursor = cursor
        self.snap = snap
        self.roseDegrees = roseDegrees
    }
}

// MARK: - State

/// An immutable snapshot of the drawing flow, safe to hand to a view.
public struct MeasurementInputState: Hashable, Sendable {

    /// Where the flow is.
    public internal(set) var phase: MeasurementInputPhase = .idle
    /// The armed tool, or `nil` in ``MeasurementInputPhase/idle``.
    public internal(set) var kind: MeasurementKind?
    /// Vertices placed so far, in page space.
    public internal(set) var vertices: [PDFPointValue] = []
    /// The raw pointer or keyboard cursor, before snapping and constraining.
    public internal(set) var rawCursor: PDFPointValue = .zero
    /// Modifier keys held right now.
    public internal(set) var modifiers: MeasurementInputModifiers = []
    /// Overlapping snap candidates at ``rawCursor``, best first.
    public internal(set) var snapCandidates: [SnapFeedbackSnapshot] = []
    /// Index into ``snapCandidates``, or `nil` when the candidate is bypassed.
    public internal(set) var snapCandidateIndex: Int?
    /// Whether the current page exposes vector geometry to snap to.
    public internal(set) var isVectorSnapAvailable: Bool = true
    /// Whether a drag tool is being placed click by click.
    ///
    /// A press-and-release without movement on the three-point rectangle is a click that
    /// places a corner. While this is set, a fresh press continues
    /// the shape instead of restarting it, and each release places the next corner.
    public internal(set) var isClickPlacingDragTool: Bool = false
    /// The symbol the count group in progress is being drawn with.
    public internal(set) var countSymbol: CountSymbol = .default
    /// Area markups the armed cutout tool could attach to, as last published by the host.
    public internal(set) var cutoutParents: [CutoutParentCandidate] = []
    /// The parent the cutout in progress belongs to, decided by its first vertex.
    ///
    /// Once set it does not move: a cutout belongs to the area it started in, and a later
    /// vertex that leaves that area is refused rather than silently re-parenting the hole.
    public internal(set) var cutoutParent: CutoutParentCandidate?
    /// Why the last cutout point or commit was refused, or `nil` when nothing was.
    public internal(set) var cutoutRefusal: CutoutRefusalReason?
    /// The raw pointer position of the press that began the drag in progress.
    ///
    /// A release at the same raw position is a click, whatever the snap engine published in
    /// between. Comparing the snapped release with the raw press instead let a click with a
    /// live candidate 3 pt away commit a sliver (BH-260).
    public internal(set) var dragPressPoint: PDFPointValue?
    /// Whether the next segment is an arc (NL-MEASURE-05): A pressed while drawing.
    public internal(set) var isArcNextSegment: Bool = false
    /// The point the arc in progress passes through, once it has been clicked; the next click is
    /// the arc's end. Never a vertex.
    public internal(set) var arcThroughPoint: PDFPointValue?

    /// Whether the keyboard cursor leads (R-137): an arrow moved it since the pointer last did.
    /// Cleared by a pointer move or press and when the tool is put away; kept across a commit and
    /// a change of tool, because it describes the input device, not the shape.
    public internal(set) var isKeyboardCursorActive: Bool = false

    /// Whether the next click places an arc's through point rather than a vertex.
    public var awaitsArcThroughPoint: Bool { isArcNextSegment && arcThroughPoint == nil }

    /// Whether Return places a point at the keyboard cursor rather than finishing: a tool is
    /// armed and the keyboard cursor leads. ⌘Return always finishes.
    public var returnPlacesPoint: Bool { isKeyboardCursorActive && phase != .idle }

    /// Creates a snapshot. Hosts normally let ``MeasurementInputStateMachine`` own this and
    /// only build one directly to seed a preview or a test.
    public init(
        phase: MeasurementInputPhase = .idle,
        kind: MeasurementKind? = nil,
        vertices: [PDFPointValue] = [],
        rawCursor: PDFPointValue = .zero,
        modifiers: MeasurementInputModifiers = [],
        snapCandidates: [SnapFeedbackSnapshot] = [],
        snapCandidateIndex: Int? = nil,
        isVectorSnapAvailable: Bool = true
    ) {
        self.phase = phase
        self.kind = kind
        self.vertices = vertices
        self.rawCursor = rawCursor
        self.modifiers = modifiers
        self.snapCandidates = snapCandidates
        self.snapCandidateIndex = snapCandidateIndex
        self.isVectorSnapAvailable = isVectorSnapAvailable
    }

    /// The candidate the next click would use, or `nil` when snapping is off or bypassed.
    public var activeSnapCandidate: SnapFeedbackSnapshot? {
        guard !isSnapSuspended, let snapCandidateIndex,
              snapCandidates.indices.contains(snapCandidateIndex)
        else { return nil }
        return snapCandidates[snapCandidateIndex]
    }

    /// Whether snapping is suspended right now: Command held, or Option bypassing.
    public var isSnapSuspended: Bool {
        modifiers.contains(.command) || modifiers.contains(.option)
    }

    /// Whether the angle constraint is active for the segment being drawn.
    ///
    /// Never for Count: its marks are independent placements, not segments, so Shift held out
    /// of multi-select habit must not pull a mark onto a 45° ray from the previous one and
    /// off the item that was clicked (BH-256).
    public var isAngleConstrained: Bool {
        modifiers.contains(.shift) && !vertices.isEmpty && kind?.isPointPlacement != true
    }

    /// The first vertex, when the cursor is close enough that the next click would close the
    /// polygon on it — the close-on-first-vertex snap affordance. `nil` while the shape
    /// is still short of its minimum point count, for non-closable tools, and when the
    /// cursor is out of range.
    public func firstVertexCloseTarget(
        configuration: MeasurementInputConfiguration
    ) -> PDFPointValue? {
        guard let kind, kind.closesOnFirstVertex, phase == .drawing,
              vertices.count >= kind.minimumPointCount,
              !awaitsArcThroughPoint,
              let first = vertices.first
        else { return nil }
        let probe = activeSnapCandidate?.pagePoint ?? rawCursor
        guard probe.distance(to: first) <= configuration.firstVertexCloseTolerance else { return nil }
        return first
    }

    /// The point a click would actually place: the close target if one is offered,
    /// otherwise snapped, then angle-constrained.
    ///
    /// Snap and constraint compose: while Shift holds the segment
    /// to a ray, the snap candidate is used only if it lies on that ray (within
    /// ``MeasurementInputConfiguration/constrainedRayTolerance``), and then only its
    /// distance along the ray — the direction always wins. A candidate off the ray is
    /// ignored rather than allowed to yank the line crooked. Shift on the rectangle's depth
    /// point holds it to the perpendicular of the placed edge instead.
    ///
    /// Both halves are ``MeasurementInputStateMachine/shiftConstrainedPlacement(kind:placedPoints:cursor:snap:optionHeld:incrementDegrees:rayTolerance:)``,
    /// the one rule the canvas's rubber band, snap glyph and angle readout also read (U-073).
    public func effectivePoint(configuration: MeasurementInputConfiguration) -> PDFPointValue {
        if let closeTarget = firstVertexCloseTarget(configuration: configuration) {
            return closeTarget
        }
        let snap = activeSnapCandidate?.pagePoint
        guard isAngleConstrained,
              let held = MeasurementInputStateMachine.shiftConstrainedPlacement(
                  kind: kind,
                  placedPoints: vertices,
                  cursor: rawCursor,
                  snap: snap,
                  incrementDegrees: configuration.angleIncrementDegrees,
                  rayTolerance: configuration.constrainedRayTolerance
              )
        else { return snap ?? rawCursor }
        return held.point
    }

    /// How many points the shape in progress needs before Return may finish it.
    ///
    /// A three-point rectangle needs all three: its first two corners are one *edge*, and
    /// committing them as a rectangle is what Return used to do after the second click, with
    /// "can be finished with Return" announced first (BH-257). This used to hold only while
    /// `isClickPlacingDragTool` was set, which only a press-and-release sent as a drag sets;
    /// the canvas sends a Rectangle Area click as a click, so the shipping canvas still
    /// committed the edge's bounding box (T-055). The rule is now the kind's own minimum,
    /// the same number the presenter's `canCommit` and the Finish menu read.
    public var requiredPointCount: Int {
        guard let kind else { return 0 }
        return kind.minimumPointCount
    }

    /// How many more vertices the armed tool needs before Return would finish it.
    public var remainingVertexCount: Int {
        max(0, requiredPointCount - vertices.count)
    }

    /// Whether Return would finish the geometry.
    public var canFinish: Bool {
        guard kind != nil, phase == .drawing else { return false }
        return vertices.count >= requiredPointCount
    }


    // MARK: Count

    /// The index of the placed count point within `tolerance` of `point`, nearest first, or
    /// `nil` when the ⌥-click landed on empty page.
    public func countPointIndex(near point: PDFPointValue, tolerance: Double) -> Int? {
        guard let kind, kind.isPointPlacement else { return nil }
        var best: (index: Int, distance: Double)?
        for (index, vertex) in vertices.enumerated() {
            let distance = vertex.distance(to: point)
            guard distance <= tolerance else { continue }
            if best == nil || distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }
}

// MARK: - State machine

/// The keyboard and pointer flow for drawing a measurement, with no view layer attached.
///
/// The keyboard part of the drawing contract lives here — Backspace, Return, Escape, Shift
/// constrain, Tab candidate cycling, and the keyboard cursor that makes the
/// whole step completable without a pointer (`ACCESSIBILITY_PLAN.md`): arrows
/// move it, Return places a point at it and ⌘Return finishes — so it can be
/// exercised without a window. Space stays the canvas's temporary pan and never places.
/// The machine produces ``MeasurementInputEffect`` values; a host such as
/// ``MeasurementInputController`` is what applies them to a `MeasurementToolPresenting`.
public struct MeasurementInputStateMachine: Hashable, Sendable {

    /// The current snapshot.
    public private(set) var state: MeasurementInputState
    /// Tunables.
    public var configuration: MeasurementInputConfiguration

    /// The last snap announcement that was emitted, used to suppress repeats.
    private var lastAnnouncedSnapKey: String?

    public init(
        configuration: MeasurementInputConfiguration = .standard,
        state: MeasurementInputState = MeasurementInputState()
    ) {
        self.configuration = configuration
        self.state = state
        self.state.rawCursor = state.rawCursor == .zero ? configuration.initialCursor : state.rawCursor
    }

    /// The point a click would place right now.
    public var effectivePoint: PDFPointValue { state.effectivePoint(configuration: configuration) }

    /// Feeds one event in and returns the effects the host must apply, in order.
    @discardableResult
    public mutating func handle(_ event: MeasurementInputEvent) -> [MeasurementInputEffect] {
        switch event {
        case let .armTool(kind):
            return armTool(kind)
        case .disarmTool:
            return disarmTool()
        case let .pointerMoved(point):
            state.rawCursor = point
            state.isKeyboardCursorActive = false
            return []
        case let .moveKeyboardCursor(dx, dy):
            guard state.phase != .idle, dx.isFinite, dy.isFinite else { return [] }
            state.rawCursor = PDFPointValue(x: state.rawCursor.x + dx, y: state.rawCursor.y + dy)
            state.isKeyboardCursorActive = true
            return []
        case .placePointAtCursor:
            return placePoint(effectivePoint)
        case let .placePoint(point):
            return placePoint(point)
        case .removeLastVertex:
            return removeLastVertex()
        case let .removePoint(point):
            return removeCountPoint(near: point)
        case let .setCutoutParents(candidates):
            state.cutoutParents = candidates
            return []
        case .finish:
            return finish()
        case .doubleClick:
            return doubleClick()
        case .secondaryClick:
            return secondaryClick()
        case let .dragBegan(point):
            state.isKeyboardCursorActive = false
            return dragBegan(at: point)
        case let .dragMoved(point):
            state.rawCursor = point
            state.isKeyboardCursorActive = false
            return []
        case let .dragEnded(point):
            return dragEnded(at: point)
        case .placeRectangleDepthAtCursor:
            return placeRectangleDepth()
        case .cancel:
            return cancel()
        case let .setModifiers(modifiers):
            return setModifiers(modifiers)
        case let .cycleSnapCandidate(forward):
            return cycleSnapCandidate(forward: forward)
        case let .setSnapCandidates(candidates):
            return setSnapCandidates(candidates)
        case let .setVectorSnapAvailable(isAvailable):
            state.isVectorSnapAvailable = isAvailable
            return []
        case .toggleArcSegment:
            return toggleArcSegment()
        }
    }

    // MARK: Arc segments (NL-MEASURE-05, ADR-0030 §5.6)

    /// Whether A means "arc next segment" right now: a shape is in progress with a tool whose
    /// segments can be arcs. Everywhere else A is the Area tool, and mid-shape it must never be,
    /// because switching tools would throw the shape away.
    public var acceptsArcToggle: Bool {
        guard state.phase == .drawing, let kind = state.kind, kind.supportsArcSegments,
              !state.vertices.isEmpty, !state.isClickPlacingDragTool else { return false }
        return true
    }

    private mutating func toggleArcSegment() -> [MeasurementInputEffect] {
        guard acceptsArcToggle else { return [] }
        if state.isArcNextSegment {
            state.isArcNextSegment = false
            state.arcThroughPoint = nil
            return [
                .setArcSegment(false),
                .announce(NSLocalizedString("Next segment straight.", comment: "Announced when A turns the arc segment off while drawing"))
            ]
        }
        state.isArcNextSegment = true
        state.arcThroughPoint = nil
        return [
            .setArcSegment(true),
            .announce(NSLocalizedString(
                "Next segment is an arc. Click a point the arc passes through, then its end.",
                comment: "Announced when A turns the next segment into a three-point arc while drawing"
            ))
        ]
    }

    // MARK: Transitions

    /// Puts the flow back to "a tool is armed and nothing is drawn yet", after the last vertex
    /// of a shape has been taken away.
    ///
    /// Everything decided by the *first* vertex has to be undecided again, and the parent of a
    /// cutout is the whole of that. Backspacing away the first vertex used to leave
    /// `cutoutParent` standing, so the next click was not resolved against the areas under it
    /// at all — it was validated against the area the abandoned attempt had started in. Click
    /// inside A, Backspace, click inside B, and the hole was refused for being "outside A", or,
    /// where A and B overlap, quietly subtracted from A. `isClickPlacingDragTool` leaked the
    /// same way and left the three-point rectangle in click mode with no corner placed.
    /// Finding CR-198.
    ///
    /// Every road back to armed goes through here — Backspace, ⌥-click on the last count mark,
    /// Escape, a drag released without moving and a fresh press over stale geometry — and it
    /// clears the vertices too, so no road can forget a field. The drag released without
    /// moving was a fifth road that set the phase by hand and left the cutout parent pinned
    /// (BH-047, IM-106).
    private mutating func returnToArmed() {
        state.vertices = []
        state.phase = .armed
        state.isClickPlacingDragTool = false
        state.cutoutParent = nil
        state.cutoutRefusal = nil
        state.dragPressPoint = nil
        state.isArcNextSegment = false
        state.arcThroughPoint = nil
    }

    private mutating func armTool(_ kind: MeasurementKind) -> [MeasurementInputEffect] {
        // Re-arming over a shape in progress throws the shape away, and the presenter has to
        // be told: it keeps its own points and only discards them when the *kind* changes, so
        // re-arming the same tool left it holding two points against a machine holding none,
        // and three more clicks committed a five-point polygon (BH-258).
        let discardsShape = !state.vertices.isEmpty
        state.kind = kind
        returnToArmed()
        state.countSymbol = configuration.countSymbol
        if state.rawCursor == .zero { state.rawCursor = configuration.initialCursor }
        return (discardsShape ? [.cancelMeasurement] : []) + [
            .activateTool(kind),
            .announce(
                String(
                    format: NSLocalizedString(
                        "%1$@ armed. %2$@",
                        comment: "Announced when a measurement tool is armed: tool name, how to start"
                    ),
                    kind.displayName,
                    kind.shortHelp
                )
            )
        ]
    }

    private mutating func disarmTool() -> [MeasurementInputEffect] {
        guard state.phase != .idle else { return [] }
        state.kind = nil
        returnToArmed()
        state.phase = .idle
        state.isKeyboardCursorActive = false
        state.snapCandidates = []
        state.snapCandidateIndex = nil
        return [
            .deactivateTool,
            .announce(NSLocalizedString("Measurement tool off.", comment: "Announced when the pointer tool takes over"))
        ]
    }

    private mutating func placePoint(_ point: PDFPointValue) -> [MeasurementInputEffect] {
        guard state.phase != .idle, let kind = state.kind else { return [] }
        // A cutout is a hole in something. The first vertex decides *what*, so a first point
        // outside every area never becomes geometry — it would be an orphan polygon that
        // subtracts nothing. Later vertices may leave the area: the engine subtracts the part inside, and
        // refusing a cutout that overlaps nothing is the engine's call (X-cutout-ui).
        if let refusal = cutoutPointRefusal(point, kind: kind) {
            state.cutoutRefusal = refusal
            return [.rejectFinish(refusal.message), .announce(refusal.message)]
        }
        state.cutoutRefusal = nil
        // An arc segment's first click is the point it passes through, never a vertex — and
        // never the close on the first vertex, which would end the shape before the arc exists.
        if state.awaitsArcThroughPoint, state.phase == .drawing, kind.supportsArcSegments {
            state.arcThroughPoint = point
            state.rawCursor = point
            return [
                .placeArcThroughPoint(point),
                .announce(NSLocalizedString(
                    "Arc passes through this point. Click where the arc ends.",
                    comment: "Announced after the through point of an arc segment is placed"
                ))
            ]
        }
        // Clicking the first vertex again closes a polygon tool instead of stacking a
        // duplicate vertex on it. With an arc's through point placed,
        // the close makes the closing edge that arc.
        if kind.closesOnFirstVertex, state.phase == .drawing,
           state.vertices.count >= kind.minimumPointCount,
           let first = state.vertices.first,
           point.distance(to: first) <= configuration.firstVertexCloseTolerance {
            return commitGeometry()
        }
        state.vertices.append(point)
        state.rawCursor = point
        state.phase = .drawing
        // The arc's end: the presenter bends the segment through the point already placed, and
        // the next segment is straight again unless A is pressed again.
        state.isArcNextSegment = false
        state.arcThroughPoint = nil
        var effects: [MeasurementInputEffect] = [.placePoint(point)]
        // A fixed-count tool finishes the moment its last point lands: a Length is two
        // clicks and done, with no Return and no third click.
        if let completing = kind.completingPointCount, state.vertices.count >= completing {
            // The three-point rectangle closes itself: the fourth corner is derived from
            // the three placed ones before the commit.
            if kind.derivesFourthCorner, state.vertices.count == 3 {
                let fourth = Self.derivedFourthCorner(
                    state.vertices[0],
                    state.vertices[1],
                    state.vertices[2]
                )
                state.vertices.append(fourth)
                effects.append(.placePoint(fourth))
            }
            effects.append(contentsOf: commitGeometry())
        } else {
            effects.append(.announce(vertexAnnouncement()))
        }
        return effects
    }

    /// Decides whether `point` may join the cutout in progress, for any cutout tool; `nil` for a
    /// tool that is not a cutout.
    ///
    /// A polygon cutout's first vertex resolves the parent and is refused when it lies in no
    /// area. When it is allowed the parent is recorded as a side effect — the resolution has to
    /// happen exactly once, at the click that decides it, or a cutout drawn across two
    /// overlapping areas could end up subtracted from whichever one the last vertex happened to
    /// fall in.
    ///
    /// An Ellipse Cutout's two points are corners of its bounding box, not points of the hole it
    /// cuts, so its first corner decides nothing and its second resolves the parent from the
    /// box's centre (T-058). Holding each corner to the area instead refused round openings that
    /// fit and could attach the hole to a smaller area that contained a corner but not the
    /// ellipse.
    ///
    /// Nothing here holds the cutout inside its parent (X-cutout-ui). Every later polygon corner
    /// had to stay inside the area and every ellipse had to fit inside it — a rule of the
    /// interface's own, stricter than the engine's, which accepts a cutout that only partly
    /// overlaps its area and subtracts the part inside (ADR-0015). Whether a finished cutout
    /// overlaps its area at all is decided by the engine, through the application tier's
    /// measurement presenter, which refuses the commit with "A cutout must overlap the area it is
    /// subtracted from." when it does not.
    private mutating func cutoutPointRefusal(
        _ point: PDFPointValue,
        kind: MeasurementKind
    ) -> CutoutRefusalReason? {
        guard kind.requiresParentArea else { return nil }
        guard kind == .ellipseCutout else { return cutoutRefusal(for: point) }
        guard state.phase == .drawing, let corner = state.vertices.first else { return nil }
        switch CutoutParentResolver.resolveEllipse(
            corner: corner,
            opposite: point,
            candidates: state.cutoutParents
        ) {
        case let .resolved(parent):
            state.cutoutParent = parent
            return nil
        case let .refused(reason):
            state.cutoutParent = nil
            return reason
        }
    }

    private mutating func cutoutRefusal(for point: PDFPointValue) -> CutoutRefusalReason? {
        guard state.cutoutParent == nil else { return nil }
        switch CutoutParentResolver.resolve(firstPoint: point, candidates: state.cutoutParents) {
        case let .resolved(parent):
            state.cutoutParent = parent
            return nil
        case let .refused(reason):
            return reason
        }
    }

    /// ⌥-click on a placed count point removes that point.
    ///
    /// A miss is silent about geometry and loud about nothing: it never places a point, because
    /// the estimator's intent — "take that one away" — cannot be reinterpreted as "add another".
    private mutating func removeCountPoint(near point: PDFPointValue) -> [MeasurementInputEffect] {
        guard let kind = state.kind, kind.isPointPlacement, state.phase == .drawing else { return [] }
        guard let index = state.countPointIndex(
            near: point,
            tolerance: configuration.countPointHitTolerance
        ) else {
            return [
                .announce(
                    NSLocalizedString(
                        "No count point here to remove.",
                        comment: "Announced when an Option-click during counting hits no placed point"
                    )
                )
            ]
        }
        state.vertices.remove(at: index)
        if state.vertices.isEmpty { returnToArmed() }
        let total = CountRunningTotal(points: state.vertices.count, symbol: state.countSymbol)
        return [
            .removePoint(index: index),
            .announce(
                String(
                    format: NSLocalizedString(
                        "Count point %1$d removed. %2$@",
                        comment: "Announced after Option-click removes a count point: its 1-based position, new total"
                    ),
                    index + 1,
                    total.accessibilityLabel
                )
            )
        ]
    }

    private mutating func dragBegan(at point: PDFPointValue) -> [MeasurementInputEffect] {
        guard state.phase != .idle, let kind = state.kind else { return [] }
        state.rawCursor = point
        guard usesDragGesture(kind) else { return [] }
        // Click-by-click placement in progress (three-point rectangle): the press continues
        // the shape — the corner lands on the release, never on the press.
        if state.isClickPlacingDragTool, !state.vertices.isEmpty { return [] }
        // On the canvas a shape a click-placing tool is already drawing — an Area polygon two
        // vertices in, a three-point rectangle one corner in — is continued by a press, never
        // restarted by it; the canvas routes the release through the click path (IM-019).
        if configuration.appliesCanvasGestures, dragAlsoPlacesClicks(kind), !state.vertices.isEmpty {
            return []
        }
        var effects: [MeasurementInputEffect] = []
        // A fresh press always starts a fresh shape; stale geometry from an interrupted
        // drag is thrown away first so the presenter stays in step. This has to happen
        // *before* the cutout check: the stale shape's parent is part of what is thrown away,
        // and checking first validated a press inside area B against area A (BH-259).
        if !state.vertices.isEmpty {
            returnToArmed()
            effects.append(.cancelMeasurement)
        }
        // The press snaps exactly as the release does. A raw anchor and a snapped release
        // turned a click beside a live candidate into a sliver, and the first corner of every
        // drag never snapped while the second did (BH-260).
        let anchor = state.activeSnapCandidate?.pagePoint ?? point
        if let refusal = cutoutPointRefusal(anchor, kind: kind) {
            state.cutoutRefusal = refusal
            return effects + [.rejectFinish(refusal.message), .announce(refusal.message)]
        }
        state.vertices.append(anchor)
        state.dragPressPoint = point
        state.phase = .drawing
        effects.append(.placePoint(anchor))
        return effects
    }

    private mutating func dragEnded(at point: PDFPointValue) -> [MeasurementInputEffect] {
        guard let kind = state.kind, usesDragGesture(kind), state.phase == .drawing else { return [] }
        // A release with no press behind it is not the end of a drag. On the canvas that is the
        // release of a press that continued a click-placed shape, which the canvas has already
        // routed as a click.
        if configuration.appliesCanvasGestures, state.dragPressPoint == nil, !state.isClickPlacingDragTool {
            return []
        }
        state.rawCursor = point
        // Click mode: the release places the next corner through the click path, which
        // derives the fourth corner and commits on the third.
        if state.isClickPlacingDragTool {
            return placePoint(effectivePoint)
        }
        let placed = state.activeSnapCandidate?.pagePoint ?? point
        let releasedWhereItWasPressed = state.dragPressPoint.map { point.distance(to: $0) < 1e-9 } ?? false
        if let anchor = state.vertices.first,
           releasedWhereItWasPressed || placed.distance(to: anchor) < 1e-9 {
            if kind.derivesFourthCorner {
                // The press never moved: it was a *click*, and a click on the three-point
                // rectangle places its first corner. The anchor the
                // press placed stays; the tool switches to click-by-click placement.
                state.isClickPlacingDragTool = true
                return [.announce(vertexAnnouncement())]
            }
            // A pure drag tool released without moving: no shape exists. Back to armed, through
            // the one reset that also forgets the cutout parent the press resolved (BH-047).
            returnToArmed()
            return [
                .cancelMeasurement,
                .announce(
                    String(
                        format: NSLocalizedString(
                            "%@ needs a drag. Press and drag to the opposite corner.",
                            comment: "Announced when a drag tool is released without moving: tool name"
                        ),
                        kind.displayName
                    )
                )
            ]
        }
        // A real drag: the release places the opposite corner and always commits — press,
        // drag, release, one gesture. The host expands the two
        // corners to the full outline, so the commit does not wait for a point count.
        if let refusal = cutoutPointRefusal(placed, kind: kind) {
            state.cutoutRefusal = refusal
            return [.rejectFinish(refusal.message), .announce(refusal.message)]
        }
        var effects: [MeasurementInputEffect]
        if kind.derivesFourthCorner, !configuration.appliesCanvasGestures, let anchor = state.vertices.first {
            // A host that applies effects straight to a presenter gets the dragged box's whole
            // outline, in drawing order. Two opposite corners alone are what two clicks along
            // an edge look like, and a Rectangle Area commits from three corners or more
            // (T-055). The canvas keeps receiving the release alone: its driver derives the
            // three remaining corners from the settled anchor.
            let corners = Array(ZenitMarkupGeometry.rectangleCorners(anchor, placed).dropFirst())
            state.vertices.append(contentsOf: corners)
            effects = corners.map(MeasurementInputEffect.placePoint)
        } else {
            state.vertices.append(placed)
            effects = [.placePoint(placed)]
        }
        effects.append(contentsOf: commitGeometry())
        return effects
    }

    /// ⌥-click with an edge placed: the depth point of a three-point rectangle (IM-019).
    private mutating func placeRectangleDepth() -> [MeasurementInputEffect] {
        guard let kind = state.kind, state.phase == .drawing, state.vertices.count == 2,
              ZenitToolMode.measure(kind).gesture.optionDerivesRectangle
        else { return placePoint(effectivePoint) }
        let edgeStart = state.vertices[0]
        let edgeEnd = state.vertices[1]
        let snap = state.activeSnapCandidate?.pagePoint
        // Shift holds the depth point to the perpendicular of the edge, so the derived
        // quadrilateral is a true rectangle — the same rule, with `⌥`
        // held, that the canvas's preview and snap glyph read (U-073).
        let held = state.modifiers.contains(.shift)
            ? Self.shiftConstrainedPlacement(
                kind: kind,
                placedPoints: state.vertices,
                cursor: state.rawCursor,
                snap: snap,
                optionHeld: true,
                incrementDegrees: configuration.angleIncrementDegrees,
                rayTolerance: configuration.constrainedRayTolerance
            )
            : nil
        let depth = held?.point ?? snap ?? state.rawCursor
        let fourth = Self.derivedFourthCorner(edgeStart, edgeEnd, depth)
        state.cutoutRefusal = nil
        state.vertices.append(contentsOf: [depth, fourth])
        state.rawCursor = depth
        return [.placePoint(depth), .placePoint(fourth)] + commitGeometry()
    }

    // MARK: Gesture questions

    /// Whether `kind` is drawn with one press-drag-release gesture, as the host collects it.
    private func usesDragGesture(_ kind: MeasurementKind) -> Bool {
        configuration.appliesCanvasGestures
            ? ZenitToolMode.measure(kind).gesture.usesDragGesture
            : kind.usesDragGesture
    }

    /// Whether a press-and-release without movement on `kind` is a click that places a point.
    private func dragAlsoPlacesClicks(_ kind: MeasurementKind) -> Bool {
        configuration.appliesCanvasGestures
            ? ZenitToolMode.measure(kind).gesture.dragAlsoPlacesClicks
            : kind.derivesFourthCorner
    }

    // MARK: Synchronising with the presenter

    /// Adopts the presenter's view of the drawing without producing a single effect.
    ///
    /// The presenter is the source of truth for the placed points: it snaps each one on the
    /// session actor, drops a coincident duplicate, and is also changed by paths that never
    /// pass through this machine — the menu bar's Finish, a toolbar chip, a Tool Library arm,
    /// a refused commit that keeps its points. A host that drives a real presenter calls this
    /// before each event, whenever no placement of its own is still in flight, so every
    /// transition is decided against what is actually drawn (IM-019).
    ///
    /// - Parameters:
    ///   - kind: the presenter's armed tool, or `nil` when none is armed.
    ///   - vertices: the presenter's placed points.
    ///   - cutoutParentID: the parent area the presenter will commit a cutout into, if any.
    ///
    /// Fields a click decides and the presenter does not hold — the press point of a drag in
    /// progress, click-by-click rectangle placement — survive while the shape does. A change
    /// of tool, or a shape the presenter no longer holds, clears them through the same reset
    /// every other road back to armed takes.
    public mutating func synchronize(
        kind: MeasurementKind?,
        vertices: [PDFPointValue],
        cutoutParentID: UUID?,
        arcNextSegment: Bool? = nil,
        arcThroughPoint: PDFPointValue? = nil
    ) {
        defer {
            // The presenter holds the arc in progress too (NL-MEASURE-05); a host that passes it
            // keeps the two in step, as it does the vertices.
            if let arcNextSegment, state.phase == .drawing, state.kind?.supportsArcSegments == true {
                state.isArcNextSegment = arcNextSegment
                state.arcThroughPoint = arcNextSegment ? arcThroughPoint : nil
            }
        }
        guard let kind else {
            if state.phase != .idle || state.kind != nil {
                state.kind = nil
                returnToArmed()
                state.phase = .idle
            }
            state.isKeyboardCursorActive = false
            return
        }
        if state.kind != kind || state.phase == .idle {
            state.kind = kind
            returnToArmed()
            state.countSymbol = configuration.countSymbol
        }
        if state.vertices != vertices {
            if vertices.isEmpty {
                returnToArmed()
            } else {
                state.vertices = vertices
                state.phase = .drawing
            }
        }
        guard kind.requiresParentArea else { return }
        if let cutoutParentID {
            if state.cutoutParent?.markupID != cutoutParentID,
               let parent = state.cutoutParents.first(where: { $0.markupID == cutoutParentID }) {
                state.cutoutParent = parent
            }
        } else if state.vertices.isEmpty {
            state.cutoutParent = nil
        }
    }

    private mutating func secondaryClick() -> [MeasurementInputEffect] {
        // A two-finger tap or right click finishes a variable-vertex geometry that has
        // enough input; anything less does nothing at all — it never cancels work and never
        // commits degenerate geometry.
        guard let kind = state.kind, state.phase == .drawing,
              kind.completingPointCount == nil,
              state.canFinish
        else { return [] }
        return commitGeometry()
    }

    private mutating func doubleClick() -> [MeasurementInputEffect] {
        guard let kind = state.kind, state.phase == .drawing,
              kind.completingPointCount == nil
        else { return [] }
        // A double-click is a *path* gesture: it says "the polyline or polygon ends here".
        // Count has no path — each click is its own mark — so the gesture means nothing to it
        // and must do nothing to it. It used to do two things: two count marks placed quickly
        // 4 pt apart arrive as a double-click, the second was thrown away as a duplicate
        // vertex, and the discard then closed the whole group. An estimator counting sockets
        // along a wall lost a mark and the group with it. Finding CR-177.
        guard !kind.isPointPlacement else { return [] }

        var effects: [MeasurementInputEffect] = []
        // The first click of the pair may have already placed a vertex on top of the previous
        // one. A coincident pair is never geometry — it is the same corner twice — so it goes,
        // whatever the count. The old guard was `count > minimumPointCount`, which spared the
        // duplicate at *exactly* the minimum: a polygon area whose third click landed on its
        // second committed a triangle with two vertices in the same place and an area of zero,
        // straight into the ledger. Finding CR-176.
        if let last = state.vertices.last,
           let previous = state.vertices.dropLast().last,
           last.distance(to: previous) <= configuration.firstVertexCloseTolerance {
            state.vertices.removeLast()
            effects.append(.removeLastPoint)
        }
        guard state.canFinish else {
            let message = refusalMessage(kind)
            effects.append(contentsOf: [.rejectFinish(message), .announce(message)])
            return effects
        }
        effects.append(contentsOf: commitGeometry())
        return effects
    }

    private mutating func removeLastVertex() -> [MeasurementInputEffect] {
        // Backspace takes back the most recent input: an arc's through point before the vertex
        // it hangs from. The arc stays armed, waiting for a new through point.
        if state.arcThroughPoint != nil {
            state.arcThroughPoint = nil
            return [
                .removeArcThroughPoint,
                .announce(NSLocalizedString(
                    "Arc point removed. Click a point the arc passes through.",
                    comment: "Announced when Backspace removes the through point of an arc segment"
                ))
            ]
        }
        guard !state.vertices.isEmpty else {
            return [
                .announce(
                    NSLocalizedString(
                        "No vertex to remove.",
                        comment: "Announced when Backspace is pressed with no placed vertices"
                    )
                )
            ]
        }
        state.vertices.removeLast()
        if state.vertices.isEmpty { returnToArmed() }
        return [
            .removeLastPoint,
            .announce(
                String(
                    format: NSLocalizedString(
                        "Vertex removed. %@",
                        comment: "Announced after Backspace removes a vertex"
                    ),
                    vertexCountDescription()
                )
            )
        ]
    }

    private mutating func finish() -> [MeasurementInputEffect] {
        guard let kind = state.kind, state.phase == .drawing else { return [] }
        guard state.canFinish else {
            let message = refusalMessage(kind)
            return [.rejectFinish(message), .announce(message)]
        }
        return commitGeometry()
    }

    /// Commits the drawn geometry: shared by Return, the last click of a fixed-count tool,
    /// the release of a drag tool, a double-click, and a click on the first vertex.
    /// The Reuse setting decides whether the tool stays armed or hands back to Select.
    private mutating func commitGeometry() -> [MeasurementInputEffect] {
        guard let kind = state.kind else { return [] }
        // A cutout with no parent must not reach the commit door at all. Reaching it is what
        // would produce an orphan polygon that subtracts nothing, so the refusal is stated here as
        // well as at the first click — the two guards fail closed independently.
        if kind.requiresParentArea, state.cutoutParent == nil {
            let reason = CutoutRefusalReason.noAreaUnderPoint
            state.cutoutRefusal = reason
            return [.rejectFinish(reason.message), .announce(reason.message)]
        }
        let finishedCount = state.vertices.count
        let parentMarkupID = state.cutoutParent?.markupID
        returnToArmed()
        state.phase = configuration.reusesToolAfterCommit ? .armed : .idle
        var effects: [MeasurementInputEffect] = [
            parentMarkupID.map { MeasurementInputEffect.commitCutout(parentMarkupID: $0) }
                ?? .commitMeasurement
        ]
        if !configuration.reusesToolAfterCommit {
            state.kind = nil
            effects.append(.deactivateTool)
        }
        effects.append(
            .announce(
                String(
                    format: NSLocalizedString(
                        "%1$@ finished with %2$@.",
                        comment: "Announced after a measurement commits: tool name, '3 points' (T-062: a Count with one mark says '1 point')"
                    ),
                    kind.displayName,
                    MeasurementPlurals.points(finishedCount)
                )
            )
        )
        return effects
    }

    private mutating func cancel() -> [MeasurementInputEffect] {
        // Escape is two-stage: the first press throws away the geometry, the second gives the
        // canvas back to the pointer. One press never does both, so an accidental Escape
        // mid-polygon does not also disarm the tool.
        switch state.phase {
        case .idle:
            return []
        case .drawing:
            // Escape *ends* a count group; it does not throw it away. The estimator has
            // placed the marks they wanted and pressed the key that means "done here".
            // Discarding them — which is what shipped —
            // destroys real work with no undo, because nothing was ever committed.
            if let kind = state.kind, kind.endsGroupOnEscape, state.canFinish {
                return commitGeometry()
            }
            returnToArmed()
            return [
                .cancelMeasurement,
                .announce(
                    NSLocalizedString(
                        "Measurement cancelled. Tool still armed.",
                        comment: "Announced after the first Escape press while drawing"
                    )
                )
            ]
        case .armed:
            return disarmTool()
        }
    }

    private mutating func setModifiers(_ modifiers: MeasurementInputModifiers) -> [MeasurementInputEffect] {
        let previous = state.modifiers
        guard previous != modifiers else { return [] }
        state.modifiers = modifiers
        // Option bypasses the acquired candidate; releasing it re-acquires the best one.
        if modifiers.contains(.option) {
            state.snapCandidateIndex = nil
        } else if !state.snapCandidates.isEmpty, state.snapCandidateIndex == nil {
            state.snapCandidateIndex = 0
        }
        guard previous.contains(.shift) != modifiers.contains(.shift) else { return [] }
        let message = modifiers.contains(.shift)
            ? String(
                format: NSLocalizedString(
                    "Angle constrained to %d degree steps.",
                    comment: "Announced when Shift starts constraining the drawing angle"
                ),
                Int(configuration.angleIncrementDegrees.rounded())
            )
            : NSLocalizedString(
                "Angle constraint off.",
                comment: "Announced when Shift is released"
            )
        return [.announce(message)]
    }

    private mutating func cycleSnapCandidate(forward: Bool) -> [MeasurementInputEffect] {
        // Option or Command suspends snapping, so a candidate chosen now is one the next
        // placement will not use. Announcing "candidate 1 of 3" and then placing the raw
        // cursor told the person something untrue (BH-746).
        guard !state.isSnapSuspended else {
            return [
                .announceTransient(
                    NSLocalizedString(
                        "Snapping is off while Option or Command is held.",
                        comment: "Announced when Tab is pressed while snapping is suspended"
                    )
                )
            ]
        }
        guard !state.snapCandidates.isEmpty else {
            return [
                .announceTransient(
                    state.isVectorSnapAvailable
                        ? NSLocalizedString(
                            "No snap candidate here.",
                            comment: "Announced when Tab finds no snap candidate"
                        )
                        : NSLocalizedString(
                            "Vector Snap unavailable on this page.",
                            comment: "Announced when Tab is pressed on a scanned page"
                        )
                )
            ]
        }
        let count = state.snapCandidates.count
        let current = state.snapCandidateIndex ?? (forward ? -1 : 0)
        let next = ((current + (forward ? 1 : -1)) % count + count) % count
        state.snapCandidateIndex = next
        let candidate = state.snapCandidates[next]
        return [
            .announceTransient(
                String(
                    format: NSLocalizedString(
                        "%1$@, candidate %2$d of %3$d.",
                        comment: "Announced when Tab moves to another snap candidate"
                    ),
                    candidate.accessibilityAnnouncement,
                    next + 1,
                    count
                )
            )
        ]
    }

    private mutating func setSnapCandidates(
        _ candidates: [SnapFeedbackSnapshot]
    ) -> [MeasurementInputEffect] {
        state.snapCandidates = candidates
        state.snapCandidateIndex = candidates.isEmpty ? nil : 0
        guard let best = candidates.first, !state.isSnapSuspended else {
            lastAnnouncedSnapKey = nil
            return []
        }
        // Throttle by identity, not by clock: the same candidate acquired twice in a row is
        // silent, so VoiceOver does not chatter while the pointer sits still.
        let key = "\(best.kind.rawValue)|\(best.sourceLabel)|\(best.pagePoint.x),\(best.pagePoint.y)"
        guard key != lastAnnouncedSnapKey else { return [] }
        lastAnnouncedSnapKey = key
        return [.announceTransient(best.accessibilityAnnouncement)]
    }

    // MARK: Descriptions

    /// "Polygon Area needs 1 more point before it can be finished." — the sentence Finish says
    /// for the same condition (W-074). Return used to say "Polygon Area: 1 more point needed."
    private func refusalMessage(_ kind: MeasurementKind) -> String {
        MeasurementPointPhrases.finishRefusal(kind, remaining: state.remainingVertexCount)
    }

    private func vertexAnnouncement() -> String {
        guard let kind = state.kind else { return vertexCountDescription() }
        if state.remainingVertexCount == 0 {
            return String(
                format: NSLocalizedString(
                    "Point %1$d placed. %2$@ can be finished with Return.",
                    comment: "Announced when enough points exist: point index, tool name"
                ),
                state.vertices.count,
                kind.displayName
            )
        }
        return String(
            format: NSLocalizedString(
                "Point %1$d placed. %2$@ needed.",
                comment: "Announced after placing a point: point index, how many more points are needed ('1 more point')"
            ),
            state.vertices.count,
            MeasurementPointPhrases.morePoints(state.remainingVertexCount)
        )
    }

    private func vertexCountDescription() -> String {
        LocalizedPlural.string(
            "%lld points placed.",
            count: state.vertices.count,
            one: NSLocalizedString("%lld point placed.", comment: "Announced count of placed vertices, singular"),
            other: NSLocalizedString("%lld points placed.", comment: "Announced count of placed vertices")
        )
    }

    /// A spoken coordinate pair, rounded to one decimal so VoiceOver stays readable.
    public static func coordinateDescription(_ point: PDFPointValue) -> String {
        String(
            format: NSLocalizedString(
                "x %1$.1f, y %2$.1f page points",
                comment: "Spoken page-space coordinates"
            ),
            point.x,
            point.y
        )
    }

    // MARK: Geometry

    /// Whether the next placement is a rectangle's depth point: the dedicated Rectangle Area
    /// tool with its edge placed, or Area with its first two vertices placed while `⌥` turns
    /// the click into the three-point rectangle (``ZenitToolGesture/optionDerivesRectangle``).
    /// Shift holds that point to the perpendicular of the edge, never to the angle rose.
    public static func isRectangleDepthStep(
        kind: MeasurementKind,
        placedPointCount: Int,
        optionHeld: Bool
    ) -> Bool {
        guard placedPointCount == 2 else { return false }
        let gesture = ZenitToolMode.measure(kind).gesture
        return gesture.derivesFourthCorner || (optionHeld && gesture.optionDerivesRectangle)
    }

    /// What Shift makes of one pointer position — and of the snap candidate under it — while
    /// a measurement is drawn, or `nil` when Shift holds nothing: no tool, a count mark (never
    /// constrained, BH-256), or nothing placed yet.
    ///
    /// The one Shift rule (U-073). The machine's click (``MeasurementInputState/effectivePoint(configuration:)``
    /// and the `⌥` rectangle) reads ``ShiftConstrainedPlacement/point``; the canvas draws the
    /// rubber band to ``ShiftConstrainedPlacement/cursor``, the snap glyph at
    /// ``ShiftConstrainedPlacement/snap`` and the angle readout from
    /// ``ShiftConstrainedPlacement/roseDegrees``. The canvas used to carry its own copies:
    /// its glyph filter projected the candidate onto a rose ray on the rectangle's depth step
    /// too, so with an edge at 30° — perpendicular at 120°, rose rays at 90° and 135° — the
    /// glyph vanished while the click still snapped square to the edge.
    ///
    /// - On a rectangle's depth step (``isRectangleDepthStep(kind:placedPointCount:optionHeld:)``)
    ///   the pointer and the candidate are both held to the perpendicular of the placed edge
    ///   through its end (``rectangleDepthPoint(from:edgeStart:edgeEnd:)``), and the
    ///   candidate is always kept.
    /// - Otherwise the pointer is held to the nearest rose ray from the last placed point
    ///   (``constrain(_:to:incrementDegrees:)``), and the candidate contributes its distance
    ///   along that ray only when it lies within `rayTolerance` of it
    ///   (``projectOntoConstrainedRay(_:anchor:rayPoint:tolerance:)``).
    public static func shiftConstrainedPlacement(
        kind: MeasurementKind?,
        placedPoints: [PDFPointValue],
        cursor: PDFPointValue,
        snap: PDFPointValue?,
        optionHeld: Bool = false,
        incrementDegrees: Double,
        rayTolerance: Double
    ) -> ShiftConstrainedPlacement? {
        guard let kind, !kind.isPointPlacement, let anchor = placedPoints.last else { return nil }
        if isRectangleDepthStep(kind: kind, placedPointCount: placedPoints.count, optionHeld: optionHeld) {
            let edgeStart = placedPoints[0]
            return ShiftConstrainedPlacement(
                cursor: rectangleDepthPoint(from: cursor, edgeStart: edgeStart, edgeEnd: anchor),
                snap: snap.map { rectangleDepthPoint(from: $0, edgeStart: edgeStart, edgeEnd: anchor) },
                roseDegrees: nil
            )
        }
        let heldCursor = constrain(cursor, to: anchor, incrementDegrees: incrementDegrees)
        return ShiftConstrainedPlacement(
            cursor: heldCursor,
            snap: snap.flatMap {
                projectOntoConstrainedRay($0, anchor: anchor, rayPoint: heldCursor, tolerance: rayTolerance)
            },
            roseDegrees: constrainedDirectionDegrees(from: anchor, toward: cursor, incrementDegrees: incrementDegrees)
        )
    }

    /// The angle the on-canvas indicator reads while Shift constrains the segment being drawn,
    /// or `nil` when nothing is held to the angle rose: the
    /// ``ShiftConstrainedPlacement/roseDegrees`` of the one Shift rule
    /// (``shiftConstrainedPlacement(kind:placedPoints:cursor:snap:optionHeld:incrementDegrees:rayTolerance:)``).
    ///
    /// `nil` for no tool, for a count mark, before the first point, and on a rectangle's depth
    /// point, which Shift holds perpendicular to the placed edge rather than to the rose.
    /// Computed from the snapped increment itself, never back through `atan2`, so the readout
    /// is *exactly* 0.0 / 45.0 / 90.0.
    public static func constraintIndicatorDegrees(
        kind: MeasurementKind?,
        placedPoints: [PDFPointValue],
        cursor: PDFPointValue,
        optionHeld: Bool = false,
        incrementDegrees: Double
    ) -> Double? {
        shiftConstrainedPlacement(
            kind: kind,
            placedPoints: placedPoints,
            cursor: cursor,
            snap: nil,
            optionHeld: optionHeld,
            incrementDegrees: incrementDegrees,
            rayTolerance: 0
        )?.roseDegrees
    }

    /// The constrained direction from `anchor` toward `point`, as an exact whole multiple of
    /// `incrementDegrees` in `[0, 360)`.
    ///
    /// Horizontal and vertical are dominant: when the raw direction
    /// sits exactly between two rays and one of them is an axis, the axis wins. The result
    /// is computed as `multiple × increment` — never back through `atan2` — so the caption
    /// can show 0.0 / 45.0 / 90.0 *exactly*.
    public static func constrainedDirectionDegrees(
        from anchor: PDFPointValue,
        toward point: PDFPointValue,
        incrementDegrees: Double
    ) -> Double? {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard (dx != 0 || dy != 0), incrementDegrees > 0 else { return nil }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let steps = degrees / incrementDegrees
        var index = steps.rounded()
        // Exactly halfway between two rays: prefer the neighbour that is an axis, so
        // horizontal and vertical dominate the diagonals.
        if abs(steps - steps.rounded(.down) - 0.5) < 1e-12 {
            let lower = steps.rounded(.down)
            let upper = steps.rounded(.up)
            let lowerDegrees = (lower * incrementDegrees).truncatingRemainder(dividingBy: 360)
            let upperDegrees = (upper * incrementDegrees).truncatingRemainder(dividingBy: 360)
            let lowerIsAxis = lowerDegrees.truncatingRemainder(dividingBy: 90) == 0
            let upperIsAxis = upperDegrees.truncatingRemainder(dividingBy: 90) == 0
            if lowerIsAxis, !upperIsAxis {
                index = lower
            } else if upperIsAxis, !lowerIsAxis {
                index = upper
            }
        }
        var snapped = (index * incrementDegrees).truncatingRemainder(dividingBy: 360)
        if snapped < 0 { snapped += 360 }
        return snapped
    }

    /// Projects `point` onto the nearest ray from `anchor` whose direction is a whole multiple
    /// of `incrementDegrees`, preserving the distance from the anchor.
    ///
    /// Axis-aligned rays come out exact: a horizontal constraint yields `dy == 0` to the
    /// last bit, not to within a rounding error, so the committed segment is *straight*.
    public static func constrain(
        _ point: PDFPointValue,
        to anchor: PDFPointValue,
        incrementDegrees: Double
    ) -> PDFPointValue {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0, incrementDegrees > 0,
              let degrees = constrainedDirectionDegrees(
                  from: anchor,
                  toward: point,
                  incrementDegrees: incrementDegrees
              )
        else { return point }
        let (ux, uy) = Self.unitVector(degrees: degrees)
        return PDFPointValue(
            x: anchor.x + ux * distance,
            y: anchor.y + uy * distance
        )
    }

    /// A unit vector for a direction in degrees, exact on the axes.
    private static func unitVector(degrees: Double) -> (Double, Double) {
        switch degrees.truncatingRemainder(dividingBy: 360) {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default:
            let radians = degrees * .pi / 180
            return (cos(radians), sin(radians))
        }
    }

    /// Projects a snap candidate onto the Shift-constrained ray, or `nil` when the candidate
    /// is too far off the ray (or behind the anchor) to be meant for it.
    ///
    /// This is the snap-and-constraint composition rule: the candidate contributes its
    /// *distance along the ray* only, so snapping while constrained never bends the line.
    public static func projectOntoConstrainedRay(
        _ candidate: PDFPointValue,
        anchor: PDFPointValue,
        rayPoint: PDFPointValue,
        tolerance: Double
    ) -> PDFPointValue? {
        let rx = rayPoint.x - anchor.x
        let ry = rayPoint.y - anchor.y
        let length = (rx * rx + ry * ry).squareRoot()
        guard length > 0 else { return nil }
        let ux = rx / length
        let uy = ry / length
        let cx = candidate.x - anchor.x
        let cy = candidate.y - anchor.y
        let along = cx * ux + cy * uy
        guard along > 0 else { return nil }
        let offRay = abs(cx * uy - cy * ux)
        guard offRay <= tolerance else { return nil }
        return PDFPointValue(x: anchor.x + ux * along, y: anchor.y + uy * along)
    }

    /// The derived corner of the three-point rectangle: `P4 = P1 + P3 − P2`.
    public static func derivedFourthCorner(
        _ first: PDFPointValue,
        _ second: PDFPointValue,
        _ third: PDFPointValue
    ) -> PDFPointValue {
        PDFPointValue(x: first.x + third.x - second.x, y: first.y + third.y - second.y)
    }

    /// The rectangle's depth point under Shift: the cursor held to the perpendicular of the
    /// placed edge through its end, so the inferred quadrilateral is a true rectangle.
    public static func rectangleDepthPoint(
        from cursor: PDFPointValue,
        edgeStart: PDFPointValue,
        edgeEnd: PDFPointValue
    ) -> PDFPointValue {
        let ex = edgeEnd.x - edgeStart.x
        let ey = edgeEnd.y - edgeStart.y
        let length = (ex * ex + ey * ey).squareRoot()
        guard length > 0 else { return cursor }
        // Unit perpendicular of the edge.
        let px = -ey / length
        let py = ex / length
        let dx = cursor.x - edgeEnd.x
        let dy = cursor.y - edgeEnd.y
        let depth = dx * px + dy * py
        return PDFPointValue(x: edgeEnd.x + px * depth, y: edgeEnd.y + py * depth)
    }
}
