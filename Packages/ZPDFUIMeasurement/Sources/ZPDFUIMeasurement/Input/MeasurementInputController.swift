import Foundation
import Observation
import SwiftUI
import ZPDFUIPresentation

/// What ``MeasurementInputController`` applies effects to.
///
/// The six calls the drawing flow makes. A `MeasurementToolPresenting` presenter already has
/// every one of them and is wrapped by ``MeasurementInputController/init(presenter:configuration:announcementInterval:announcer:now:)``.
/// A host that must apply an effect differently from a bare presenter call adopts this
/// directly — the shipping canvas does: a commit there goes through the shell's Finish, which
/// settles in-flight snaps and honours Reuse Tool, rather than straight to the presenter
/// (IM-019). Adopting ``CountPointEditing`` and ``CutoutCommitting`` as well opts into ⌥-click
/// count removal and cutout commits, exactly as for a presenter.
@MainActor
public protocol MeasurementInputEffectApplying: AnyObject {
    /// Applies ``MeasurementInputEffect/activateTool(_:)``.
    func activate(kind: MeasurementKind)
    /// Applies ``MeasurementInputEffect/deactivateTool``.
    func deactivate()
    /// Applies ``MeasurementInputEffect/placePoint(_:)``.
    func placePoint(_ point: PDFPointValue)
    /// Applies ``MeasurementInputEffect/removeLastPoint``.
    func removeLastPoint()
    /// Applies ``MeasurementInputEffect/commitMeasurement``.
    func commitActiveMeasurement()
    /// Applies ``MeasurementInputEffect/cancelMeasurement``.
    func cancelActiveMeasurement()
}

/// Forwards the six effect calls to a `MeasurementToolPresenting` presenter.
@MainActor
private final class PresenterEffectTarget: MeasurementInputEffectApplying {
    let presenter: any MeasurementToolPresenting
    init(_ presenter: any MeasurementToolPresenting) { self.presenter = presenter }
    func activate(kind: MeasurementKind) { presenter.activate(kind: kind) }
    func deactivate() { presenter.deactivate() }
    func placePoint(_ point: PDFPointValue) { presenter.placePoint(point) }
    func removeLastPoint() { presenter.removeLastPoint() }
    func commitActiveMeasurement() { presenter.commitActiveMeasurement() }
    func cancelActiveMeasurement() { presenter.cancelActiveMeasurement() }
}

/// Binds ``MeasurementInputStateMachine`` to a `MeasurementToolPresenting`, or to any
/// ``MeasurementInputEffectApplying`` host.
///
/// The state machine stays a pure value type: this class is the only place where an effect
/// turns into a presenter call, and it is the object a SwiftUI view observes.
@MainActor
@Observable
public final class MeasurementInputController {

    /// The current drawing snapshot.
    ///
    /// Republished only when something other than the pointer position changes. Assigning the
    /// whole snapshot on every pointer move invalidated every view that reads it — the canvas
    /// accessibility value, the hint strip, the caption — at display rate while a polygon was
    /// drawn (IM-104). The pointer lives in ``cursor``; `state.rawCursor` is the cursor as of
    /// the last non-pointer change.
    public private(set) var state: MeasurementInputState
    /// The live pointer position. Only cursor-dependent overlays should read it.
    public private(set) var cursor: PDFPointValue
    /// The most recent announcement, for a VoiceOver-visible live region.
    public private(set) var lastAnnouncement: String?

    /// Tunables. Assigning also updates the machine.
    public var configuration: MeasurementInputConfiguration {
        didSet { machine.configuration = configuration }
    }

    /// The effects the most recent ``send(_:)`` applied, in order — after the cutout and
    /// count-removal reconciliation, so exactly what reached the target. Empty when the event
    /// changed nothing. A host reads it to learn what an event decided (a commit, a refusal)
    /// without re-deriving it. Not observed: it changes on every event.
    @ObservationIgnored public private(set) var lastEffects: [MeasurementInputEffect] = []

    @ObservationIgnored private var machine: MeasurementInputStateMachine
    /// Where effects are applied.
    @ObservationIgnored private let target: any MeasurementInputEffectApplying
    /// The object asked for the optional conformances: the wrapped presenter, or the target.
    @ObservationIgnored private let editingSurface: AnyObject
    @ObservationIgnored private var announcementClock: SnapAnnouncementThrottle
    @ObservationIgnored private let announcer: @MainActor (String) -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    /// - Parameters:
    ///   - presenter: the measurement presenter the effects are applied to.
    ///   - configuration: drawing tunables.
    ///   - announcementInterval: minimum seconds between two transient announcements.
    ///   - announcer: speaks one published announcement. Defaults to posting a VoiceOver
    ///     announcement; a hidden text label is not a live region on macOS and VoiceOver
    ///     does not read an unfocused element's label changes (IM-108). Injected by tests.
    ///   - now: the clock the throttle runs on. Injected by tests.
    public convenience init(
        presenter: any MeasurementToolPresenting,
        configuration: MeasurementInputConfiguration = .standard,
        announcementInterval: TimeInterval = 0.6,
        announcer: @escaping @MainActor (String) -> Void = MeasurementInputController.postVoiceOverAnnouncement,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            target: PresenterEffectTarget(presenter),
            editingSurface: presenter,
            configuration: configuration,
            announcementInterval: announcementInterval,
            announcer: announcer,
            now: now
        )
    }

    /// Binds the machine to a host that applies effects itself (IM-019).
    ///
    /// ``CountPointEditing`` and ``CutoutCommitting`` are looked up on `target`.
    public convenience init(
        target: any MeasurementInputEffectApplying,
        configuration: MeasurementInputConfiguration = .standard,
        announcementInterval: TimeInterval = 0.6,
        announcer: @escaping @MainActor (String) -> Void = MeasurementInputController.postVoiceOverAnnouncement,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            target: target,
            editingSurface: target,
            configuration: configuration,
            announcementInterval: announcementInterval,
            announcer: announcer,
            now: now
        )
    }

    private init(
        target: any MeasurementInputEffectApplying,
        editingSurface: AnyObject,
        configuration: MeasurementInputConfiguration,
        announcementInterval: TimeInterval,
        announcer: @escaping @MainActor (String) -> Void,
        now: @escaping @MainActor () -> Date
    ) {
        self.target = target
        self.editingSurface = editingSurface
        self.configuration = configuration
        self.machine = MeasurementInputStateMachine(configuration: configuration)
        self.state = machine.state
        self.cursor = machine.state.rawCursor
        self.announcementClock = SnapAnnouncementThrottle(minimumInterval: announcementInterval)
        self.announcer = announcer
        self.now = now
    }

    /// Posts `message` as a VoiceOver announcement.
    public static func postVoiceOverAnnouncement(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// The page point a click would place right now, snapped and angle-constrained.
    public var effectivePoint: PDFPointValue { machine.effectivePoint }

    /// Feeds one event through the machine and applies the resulting effects.
    public func send(_ event: MeasurementInputEvent) {
        // BH-253: a presenter that cannot remove one count mark must not have the machine
        // remove it either. The machine used to drop the mark, announce "Count point 3
        // removed", show 8 in the pill — while the presenter still held and committed 9.
        if case .removePoint = event, !(editingSurface is any CountPointEditing) {
            lastEffects = []
            publish(
                NSLocalizedString(
                    "Removing a single count point is not available here. Press Delete to remove the last one.",
                    comment: "Announced when Option-click removal of a count point is not supported by the canvas"
                )
            )
            return
        }
        // An arc toggle the host cannot carry out must not reach the machine either, or the
        // machine would take the next click as a through point the presenter never hears of —
        // on a host without arcs, or in a shape whose edges the host draws straight (a Scale
        // Region or Project Zone boundary, ADR-0030 §5.7).
        if case .toggleArcSegment = event, !surfaceDrawsArcs {
            lastEffects = []
            return
        }
        let effects = Self.reconcilingCutoutCommit(
            machine.handle(event),
            presenterCommitsCutouts: editingSurface is any CutoutCommitting
        )
        lastEffects = effects
        publishState(machine.state)
        guard !effects.isEmpty else { return }
        for effect in effects { apply(effect) }
    }

    /// Adopts the presenter's view of the drawing, with no effect applied and nothing
    /// announced. See ``MeasurementInputStateMachine/synchronize(kind:vertices:cutoutParentID:)``.
    public func synchronize(
        kind: MeasurementKind?,
        vertices: [PDFPointValue],
        cutoutParentID: UUID?,
        arcNextSegment: Bool? = nil,
        arcThroughPoint: PDFPointValue? = nil
    ) {
        machine.synchronize(
            kind: kind,
            vertices: vertices,
            cutoutParentID: cutoutParentID,
            arcNextSegment: arcNextSegment,
            arcThroughPoint: arcThroughPoint
        )
        publishState(machine.state)
    }

    /// Whether A means "arc next segment" right now (NL-MEASURE-05): a shape is in progress with a
    /// tool whose segments can be arcs, on a host that can draw them. Everywhere else the canvas
    /// keeps A as the Area tool.
    public var acceptsArcToggle: Bool {
        machine.acceptsArcToggle && surfaceDrawsArcs
    }

    /// Whether the host adopts ``ArcSegmentDrawing`` and draws arcs in the shape in progress.
    private var surfaceDrawsArcs: Bool {
        (editingSurface as? any ArcSegmentDrawing)?.drawsArcSegments ?? false
    }

    /// Republishes the snapshot only when more than the pointer changed (IM-104).
    private func publishState(_ next: MeasurementInputState) {
        if cursor != next.rawCursor { cursor = next.rawCursor }
        var masked = next
        masked.rawCursor = state.rawCursor
        if masked != state { state = next }
    }

    /// Rewrites a cutout commit the presenter cannot perform into what actually happens.
    ///
    /// Without ``CutoutCommitting`` the cutout is cancelled rather than committed as an
    /// orphan polygon. The machine still announced "Polygon Cutout finished with 4 points",
    /// so VoiceOver reported a cutout that subtracted nothing and did not exist (BH-254).
    static func reconcilingCutoutCommit(
        _ effects: [MeasurementInputEffect],
        presenterCommitsCutouts: Bool
    ) -> [MeasurementInputEffect] {
        guard !presenterCommitsCutouts,
              let index = effects.firstIndex(where: {
                  if case .commitCutout = $0 { return true }
                  return false
              })
        else { return effects }
        let message = NSLocalizedString(
            "Cutouts cannot be added here, so the cutout was discarded.",
            comment: "Announced when a cutout is finished on a canvas that cannot commit cutouts"
        )
        var rewritten = Array(effects[..<index])
        rewritten.append(.cancelMeasurement)
        rewritten.append(.rejectFinish(message))
        for effect in effects[(index + 1)...] {
            if case .announce = effect { continue }
            rewritten.append(effect)
        }
        return rewritten
    }

    /// Publishes the area markups a cutout could attach to. The canvas calls this whenever the
    /// page or its area markups change, and at the moment a cutout tool is armed.
    public func setCutoutParents(_ candidates: [CutoutParentCandidate]) {
        send(.setCutoutParents(candidates))
    }

    /// The parent the cutout in progress will subtract from, once its first vertex has chosen
    /// one. The canvas highlights it so the estimator can see what is about to change.
    public var cutoutParent: CutoutParentCandidate? { state.cutoutParent }

    /// Why the last cutout point was refused, or `nil`.
    public var cutoutRefusal: CutoutRefusalReason? { state.cutoutRefusal }

    /// Publishes a throttled transient announcement that is due, if one is waiting.
    ///
    /// Called by the trailing timer the throttle schedules; tests call it with their own
    /// clock instead of waiting.
    public func flushPendingAnnouncement() {
        if let message = announcementClock.flush(at: now()) { publish(message) }
    }

    private func publish(_ message: String) {
        lastAnnouncement = message
        announcer(message)
    }

    private func scheduleFlush() {
        guard let deadline = announcementClock.pendingDeadline else { return }
        flushTask?.cancel()
        let delay = max(0, deadline.timeIntervalSince(now()))
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingAnnouncement()
        }
    }

    private func apply(_ effect: MeasurementInputEffect) {
        switch effect {
        case let .activateTool(kind):
            target.activate(kind: kind)
        case .deactivateTool:
            target.deactivate()
        case let .placePoint(point):
            target.placePoint(point)
        case .removeLastPoint:
            target.removeLastPoint()
        case let .removePoint(index):
            // `send(_:)` never lets a removal reach the machine without a presenter that can
            // perform it, so the machine and the presenter always hold the same marks.
            (editingSurface as? any CountPointEditing)?.removePoint(at: index)
        case .commitMeasurement:
            target.commitActiveMeasurement()
        case let .commitCutout(parentMarkupID):
            // `.addCutout`, never `.addMarkup` — see ``CutoutCommitting``. A presenter without
            // the conformance never gets here: `reconcilingCutoutCommit` has already turned
            // the commit into a cancel and said so (BH-254).
            (editingSurface as? any CutoutCommitting)?.commitActiveCutout(parentMarkupID: parentMarkupID)
        case .cancelMeasurement:
            target.cancelActiveMeasurement()
        case let .announce(message):
            // A state change — placed, finished, cancelled, armed — is never throttled away.
            // It used to be dropped whenever it landed within 0.6 s of a snap announcement,
            // so a VoiceOver user lost every commit that followed a snap (BH-255, IM-105).
            announcementClock.record(message, at: now())
            publish(message)
        case let .announceTransient(message):
            if announcementClock.shouldAnnounce(message, at: now()) {
                publish(message)
            } else {
                scheduleFlush()
            }
        case let .rejectFinish(message):
            announcementClock.record(message, at: now())
            publish(message)
        case let .setArcSegment(isArc):
            (editingSurface as? any ArcSegmentDrawing)?.setArcNextSegment(isArc)
        case let .placeArcThroughPoint(point):
            (editingSurface as? any ArcSegmentDrawing)?.placeArcThroughPoint(point)
        case .removeArcThroughPoint:
            (editingSurface as? any ArcSegmentDrawing)?.removeArcThroughPoint()
        }
    }
}

/// Rate-limits VoiceOver announcements so a moving pointer does not talk over itself.
///
/// The snap type is announced to VoiceOver with throttling. Two rules: never repeat
/// the same string twice in a row, and never speak more often than ``minimumInterval``.
///
/// A message refused for arriving too soon is not thrown away: the latest one is kept as
/// ``pendingMessage`` and ``flush(at:)`` speaks it once the interval has passed. Dropping it
/// left the live region saying "Snapped to Endpoint" while the acquired candidate was a
/// midpoint (BH-745), and a quick run of Tab presses spoke the first candidate and never the
/// resting one (IM-105).
public struct SnapAnnouncementThrottle: Hashable, Sendable {

    /// Minimum seconds between two announcements.
    public var minimumInterval: TimeInterval

    private var lastMessage: String?
    private var lastDate: Date?
    /// The latest message refused for arriving inside the interval, waiting to be flushed.
    public private(set) var pendingMessage: String?

    public init(minimumInterval: TimeInterval = 0.6) {
        self.minimumInterval = max(0, minimumInterval)
    }

    /// When ``pendingMessage`` becomes due, or `nil` when nothing is waiting.
    public var pendingDeadline: Date? {
        guard pendingMessage != nil else { return nil }
        return (lastDate ?? .distantPast).addingTimeInterval(minimumInterval)
    }

    /// Returns `true` when `message` should be spoken at `date`, and records it if so.
    ///
    /// A different message refused for arriving too soon becomes ``pendingMessage``.
    public mutating func shouldAnnounce(_ message: String, at date: Date) -> Bool {
        if message == lastMessage {
            pendingMessage = nil
            return false
        }
        if let lastDate, date.timeIntervalSince(lastDate) < minimumInterval {
            pendingMessage = message
            return false
        }
        record(message, at: date)
        return true
    }

    /// Records a message that was spoken without asking, so the next transient one is timed
    /// and de-duplicated against it.
    public mutating func record(_ message: String, at date: Date) {
        lastMessage = message
        lastDate = date
        pendingMessage = nil
    }

    /// The pending message, when it is due at `date`; it is recorded as spoken.
    public mutating func flush(at date: Date) -> String? {
        guard let pendingMessage, let deadline = pendingDeadline, date >= deadline else { return nil }
        record(pendingMessage, at: date)
        return pendingMessage
    }

    /// Forgets the history, so the next message is always spoken.
    public mutating func reset() {
        lastMessage = nil
        lastDate = nil
        pendingMessage = nil
    }
}
