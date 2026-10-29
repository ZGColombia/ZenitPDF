import CoreGraphics
import Foundation
import Observation
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation

/// `MeasurementToolPresenting` driving the measurement engine and the snap engine.
///
/// Every placed point goes through the snap engine before it is stored, and every stored
/// point produces a live preview through the measurement engine. Both run on the session
/// actor; the presenter holds the points and the last preview it received.
///
/// The rule that matters for correctness: a point is stored **snapped**. Storing the raw
/// cursor and snapping it again at commit time would mean the number the user watched
/// while drawing is not the number that lands in the ledger.
@MainActor
@Observable
public final class AppMeasurementToolPresenter: MeasurementToolPresenting {

    // MARK: Published state

    public private(set) var availableKinds: [Shown.Kind] = Shown.Kind.allCases
    public private(set) var activeKind: Shown.Kind?
    public private(set) var lastUsedKinds: [Shown.Kind] = []
    public private(set) var activeScale: ScaleSummary?
    public private(set) var lengthUnit: ZPDFUIPresentation.LengthUnit
    public private(set) var areaUnit: ZPDFUIPresentation.AreaUnit
    public private(set) var volumeUnit: ZPDFUIPresentation.VolumeUnit
    public private(set) var slopeDisplayMode: SlopeDisplayMode
    public private(set) var imperialPrecision: ImperialPrecision
    public private(set) var liveFields: [MeasurementFieldSummary] = []
    public private(set) var liveWarnings: [MeasurementWarningSummary] = []
    public private(set) var snapFeedback: SnapFeedbackSnapshot?
    public private(set) var placedPoints: [PDFPointValue] = []
    /// The pointer, in page space, while a tool is armed and at least one vertex is placed.
    ///
    /// The running value follows the cursor *between* clicks — a length must read live from
    /// the first click on, not only once the second point lands.
    /// The cursor participates in the preview only; committed geometry never includes it.
    public private(set) var liveCursorPoint: PDFPointValue?
    /// Arc segments of the shape in progress (NL-MEASURE-05, ADR-0030 §5.6): the bulge of the
    /// edge from placed point `i` to point `i + 1`, keyed by `i`. Absent is straight.
    public private(set) var placedArcBulges: [Int: Double] = [:]
    /// Whether the next segment is an arc (A while drawing).
    public private(set) var isArcNextSegment: Bool = false
    /// The through point of the arc in progress, once it has landed.
    public private(set) var arcThroughPoint: PDFPointValue?
    /// The live length of the arc segment in progress — through point placed, end at the
    /// pointer — for the pill, or `nil` when no arc is being drawn.
    public private(set) var liveArcSegmentField: MeasurementFieldSummary?
    public private(set) var isTemporaryMeasurement: Bool = false
    public private(set) var temporaryMeasurements: [MarkupSummary] = []

    /// The records behind the summaries, read-only, for the canvas.
    ///
    /// A summary carries bounds but no stroke geometry, so a canvas drawing the tape overlay
    /// from summaries alone would draw boxes. Until 2026-08-27 nothing read either list and a
    /// committed Temporary Measure simply vanished from screen — kept faithfully in a list no
    /// view rendered, which made the tool look broken the moment the second click landed.
    public var temporaryOverlayRecords: [MarkupRecord] { temporaryRecords }
    /// What the estimator has typed into the tool options bar's parameter field.
    public private(set) var parameterText: String = ""
    /// ``parameterText`` parsed, in the requirement's entry unit. `nil` until something
    /// usable is typed, which is what keeps ``canCommit`` false for the five tools that
    /// cannot produce a number without it.
    public private(set) var parameterValue: Decimal?

    /// Whether the measurement in progress could be committed right now.
    ///
    /// Three conditions, all of them necessary: a tool is armed, it has the points it
    /// needs, and nothing blocking is wrong with the geometry. A self-intersecting polygon
    /// has a shoelace area that is not its visible area (spec 12.3), so committing it
    /// would write a number the drawing does not support.
    public var canCommit: Bool {
        guard let activeKind else { return false }
        guard placedPoints.count >= activeKind.minimumPointCount else { return false }
        // A boundary is not a quantity: a Project Zone or Scale Region outline needs a
        // closed polygon, nothing more. Judging it by the measurement rules made
        // `missingScale` block the finish, so on an uncalibrated sheet Return silently
        // refused to close the polygon and neither panel could ever create anything
        // (LT-35/LT-36, 2026-08-29). Only a shape with no extent is refused.
        if boundaryPurpose != nil {
            return !liveWarnings.contains(.degenerateGeometry)
        }
        // A tool that needs a depth, a height or a slope cannot be finished before it has
        // one. Before this line the commit went ahead, the calculator threw
        // `missingParameter`, and a `try?` dropped it: the estimator watched a live
        // preview, pressed Return, and nothing appeared with nothing said. Refusing here is
        // what turns that silence into a disabled Finish button and a sentence naming the
        // value.
        guard !isMissingRequiredParameter else { return false }
        return !hasBlockingWarning
    }

    /// Called when a measurement is committed, with the record to add. The environment
    /// routes it through the command bus so it lands on the undo stack.
    public var onCommit: (@MainActor (MarkupRecord) -> Void)?

    // MARK: Missing scale (LT3-05)

    /// Called with the page when a point was refused because the page has no scale, so the
    /// host can open the scale sheet for it — the visible call to action LT3-05 asked for.
    public var onScaleRequired: (@MainActor (PageID) -> Void)?
    /// How many points were refused for a missing scale. Test affordance.
    public private(set) var scaleRequiredRefusals = 0

    /// Whether the armed tool needs a scale to produce its number.
    ///
    /// A count is a number of things, not of metres, and a Scale Region or
    /// Project Zone boundary is an outline, not a quantity (LT-35/LT-36). Everything else —
    /// Temporary Measure included, whose whole purpose is a number — needs one.
    public var armedToolNeedsScale: Bool {
        guard let activeKind, boundaryPurpose == nil else { return false }
        return activeKind != .count
    }

    /// LT3-05: on a sheet with no scale a measurement is refused **up front**, at its first
    /// point, rather than drawn in full and then silently not committed.
    ///
    /// Old behaviour: every vertex landed, the fill showed, and Return or a click on the first
    /// vertex committed nothing because `.missingScale` blocks the finish — the shape sat in
    /// limbo until Escape, explained only by a sentence in the status strip. The canvas asks
    /// this before routing a click or a press to the tool: when it answers `true` the point is
    /// not placed, the live warning names the missing scale, and ``onScaleRequired`` asks the
    /// host to open the scale sheet. The presenter's own `placePoint` stays scale-agnostic, so
    /// its mechanics (snap, fences, counts) are the same with or without a scale.
    ///
    /// - Parameter point: where the first point would land. A circle tool is refused by the
    ///   scale that applies **there** — a Scale Region's, inside one — so the canvas passes the
    ///   click (L-102). Without it only a sheet on which no circle can be measured anywhere refuses.
    public func refusesForMissingScale(at point: PDFPointValue? = nil) -> Bool {
        // L-102: a circle tool where the scale has separate X and Y can never commit — the
        // engine refuses a radius there — so its first click is refused too, with the reason as
        // the live warning and in the status line, rather than accepted and answered after the
        // second click with the engine's raw `directionRequiredForNonUniformScale(…)` text.
        if let refusal = uniformScaleRefusal(at: point) {
            liveFields = []
            liveWarnings = [refusal]
            uniformScaleRefusals += 1
            onToolRefused?(refusal.message)
            return true
        }
        guard armedToolNeedsScale, activeScale == nil else { return false }
        liveFields = []
        liveWarnings = [.missingScale]
        scaleRequiredRefusals += 1
        onScaleRequired?(pageID)
        return true
    }
    // MARK: Uniform scale (L-102)

    /// Called with a sentence when the armed tool refused a click, so the host can put it in the
    /// status line. `AppCoreEnvironment` wires it to the status presenter's tool note.
    public var onToolRefused: (@MainActor (String) -> Void)?
    /// How many clicks were refused because the scale where they landed is not uniform. Test
    /// affordance.
    public private(set) var uniformScaleRefusals = 0

    /// Which scale applies where on the palette's sheet: its own and its Scale Regions'. Rebuilt
    /// with ``activeScale`` whenever a snapshot is adopted or the page turns.
    private var scaleCoverage = UniformScaleCoverage.none

    /// The two refusals a circle tool can earn: nowhere on the sheet, or not here.
    private static let uniformScaleWarnings: Set<MeasurementWarningSummary> = [.circleNeedsUniformScale, .circleNeedsUniformScaleHere]

    /// Whether the armed tool reads a radius, and so needs one scale for both directions.
    /// A boundary capture measures nothing, so it never does.
    private var armedToolNeedsUniformScale: Bool {
        guard let activeKind, boundaryPurpose == nil else { return false }
        return activeKind.needsUniformScale
    }

    /// The refusal a circle tool earns where the scale has separate X and Y, or `nil`.
    ///
    /// Radius, Diameter and Three-Point Circle read one radius off a circle, and under separate
    /// X and Y scales a drawn circle is an ellipse in real units: the engine throws
    /// `directionRequiredForNonUniformScale` rather than pick an axis. Before L-102 the tool took
    /// both clicks and the tray then showed that raw engine text.
    ///
    /// The scale is the one the commit will use, which is a Scale Region's inside one. The first
    /// L-102 fix read only the sheet's own scale and refused every circle on an X/Y sheet — also
    /// inside a uniform detail region where the commit measured it correctly — with advice to
    /// recalibrate the sheet. Now:
    /// - nothing placed and no `point`: refused only when no part of the sheet has one scale
    ///   (``MeasurementWarningSummary/circleNeedsUniformScale``) — what the status line says on
    ///   arming;
    /// - `point` (the click about to be placed): refused when the scale there has separate X
    ///   and Y — the sheet-wide sentence when that is true everywhere, else
    ///   ``MeasurementWarningSummary/circleNeedsUniformScaleHere``;
    /// - points placed: refused only when none of them lies where a circle can be read.
    func uniformScaleRefusal(at point: PDFPointValue? = nil) -> MeasurementWarningSummary? {
        guard armedToolNeedsUniformScale else { return nil }
        if scaleCoverage.circlesImpossibleOnSheet { return .circleNeedsUniformScale }
        let probes = point.map { [$0] } ?? placedPoints
        guard !probes.isEmpty, !probes.contains(where: scaleCoverage.admitsCircle(at:)) else { return nil }
        return .circleNeedsUniformScaleHere
    }

    /// Why the armed tool cannot measure anything on this sheet, for the status line from the
    /// moment the tool is armed: a circle tool where no part of the sheet has one scale.
    public var toolUnavailableReason: String? {
        guard armedToolNeedsUniformScale, scaleCoverage.circlesImpossibleOnSheet else { return nil }
        return MeasurementWarningSummary.circleNeedsUniformScale.message
    }

    /// Where on this sheet the armed tool can measure, when that is only part of it: a circle tool
    /// on a sheet whose own scale and Scale Regions disagree about separate X and Y. Said on
    /// arming, before the click a part of the sheet would refuse (L-102).
    public var toolRestrictionNote: String? {
        guard armedToolNeedsUniformScale, !scaleCoverage.circlesImpossibleOnSheet,
              let pageScale = scaleCoverage.pageScale else { return nil }
        if !pageScale.isUniform, scaleCoverage.hasUniformRegion {
            return NSLocalizedString(
                "Outside its Scale Regions this sheet has separate X and Y scales. Measure circles inside a Scale Region that has one scale for both directions.",
                comment: "Status line: a circle tool armed on a sheet with a non-uniform scale that holds a uniform Scale Region"
            )
        }
        if pageScale.isUniform, scaleCoverage.hasNonUniformRegion {
            return NSLocalizedString(
                "Some Scale Regions on this sheet have separate X and Y scales. Circles cannot be measured inside them.",
                comment: "Status line: a circle tool armed on a uniform sheet that holds a Scale Region with a non-uniform scale"
            )
        }
        return nil
    }

    /// `warnings` with the uniform-scale refusal in force added, and any stale one removed.
    private func withUniformScaleRefusal(_ warnings: [MeasurementWarningSummary]) -> [MeasurementWarningSummary] {
        var composed = warnings.filter { !Self.uniformScaleWarnings.contains($0) }
        if let refusal = uniformScaleRefusal() { composed.append(refusal) }
        return composed
    }

    /// Re-reads the sheet's own scale and its Scale Regions from the last snapshot.
    private func adoptScaleCoverage() {
        activeScale = latestSnapshot?.scale(onPage: pageID.rawValue)
        scaleCoverage = UniformScaleCoverage(
            pageID: pageID,
            pageScale: activeScale,
            regions: latestSnapshot?.scaleRegions ?? []
        )
        refreshUniformScaleRefusal()
    }

    /// Re-states the refusal after the tool, the page or the scale changed, so the warning is
    /// on screen before the first click and gone the moment it no longer applies.
    private func refreshUniformScaleRefusal() {
        let shown = withUniformScaleRefusal(liveWarnings)
        if shown != liveWarnings { liveWarnings = shown }
    }

    // MARK: Continue (NL-MEASURE-06, NL-MEASURE-12)

    /// The committed markup being continued: its points are preloaded, new points append,
    /// and the finish writes one `editVertices` instead of a new markup — same identity, same
    /// row, same audit trail, one ⌘Z.
    public private(set) var continuingMarkupID: MarkupID?
    /// The geometry the continuation started from, so a count keeps its marks' identities.
    private var continuationBase: MeasurementGeometry?
    /// Called with the continued markup and its extended geometry.
    public var onCommitContinuation: (@MainActor (MarkupID, MeasurementGeometry) -> Void)?

    /// The tools Continue offers: an open polyline grows at its end, a count gains marks.
    public static func canContinue(_ tool: Domain.Tool?) -> Bool {
        tool == .polylength || tool == .count
    }

    /// Arms the record's tool with its points preloaded. Returns `false` for a record whose
    /// tool cannot continue, or on another page than the one being drawn on.
    @discardableResult
    public func beginContinuation(of record: MarkupRecord) -> Bool {
        guard Self.canContinue(record.tool), let tool = record.tool, var geometry = record.geometry,
              record.pageID == pageID, !record.locked else { return false }
        // A count whose marks sit in `points` (a preset placement before V-031) continues from
        // those marks, moved into `countPoints`, instead of dropping them.
        if tool == .count { geometry = geometry.countMarksInCountPoints(makeID: identifiers) }
        activate(kind: Shown.Kind(domain: tool))
        let existing: [PDFPointValue] = tool == .count
            ? geometry.countPoints.map { PDFPointValue(domain: $0.position) }
            : geometry.points.map { PDFPointValue(domain: $0) }
        placedPoints = existing
        placedSequences = existing.map { _ in 0 }
        // A chain's arcs come with it (ADR-0030 §5.6), so the preview and the continued
        // geometry keep them.
        placedArcBulges = [:]
        if tool != .count, let bulges = geometry.validPointBulges {
            for (index, bulge) in bulges.enumerated() where bulge != 0 && index < existing.count - 1 {
                placedArcBulges[index] = bulge
            }
        }
        continuingMarkupID = record.id
        continuationBase = geometry
        schedulePreview()
        return true
    }

    /// The continued markup's geometry: **every** point placed now, or `nil` when it is the
    /// geometry the continuation started from (a continuation that changed nothing is not an edit).
    ///
    /// Built from the whole of ``placedPoints``, never from the base plus what lies past its count
    /// (T-022). Backspace, Remove Last Vertex and ⌥-click remove preloaded points too, so a slice by
    /// position committed a chain A-B-C-E for the A-B-D-E on screen, and a count with one mark
    /// ⌥-clicked away and none added returned `nil` and kept all five in the ledger.
    private func continuedGeometry() -> MeasurementGeometry? {
        guard let base = continuationBase, let kind = activeKind else { return nil }
        var edited = base
        if kind == .count {
            // A mark still standing keeps its identity (matched by position, each base mark used
            // once); a new mark gets a new one.
            var standing = base.countPoints
            edited.countPoints = placedPoints.map { shown in
                let position = PDFPoint(shown: shown)
                if let index = standing.firstIndex(where: { $0.position == position }) {
                    return standing.remove(at: index)
                }
                return CountPoint(id: CountPointID(identifiers()), position: position)
            }
            // The marks are all in `countPoints`; a stray `points` would be counted instead of
            // them if `countPoints` were ever emptied, and drawn as a chain (V-031).
            edited.points = []
            edited.pointBulges = nil
            guard edited.countPoints != base.countPoints else { return nil }
        } else {
            edited.points = placedPoints.map { PDFPoint(shown: $0) }
            // One bulge per point, the old arcs and any drawn now (ADR-0030 §5.6). Appending
            // points to a chain whose bulges then no longer lined up made every arc straight.
            edited.pointBulges = chainBulges(count: edited.points.count)
            let baseBulges = base.validPointBulges.flatMap { $0.contains { $0 != 0 } ? $0 : nil }
            guard edited.points != base.points || edited.pointBulges != baseBulges else { return nil }
        }
        return edited
    }

    /// Called when a **cutout** is committed, with the parent area it is a hole in.
    ///
    /// A cutout is the one measurement that cannot go out through ``onCommit``: a free
    /// `.addMarkup` puts an orphan polygon on the page that subtracts nothing, which is
    /// exactly the defect a tool audit found. The environment routes this to
    /// `DocumentCommand.addCutout(parent:cutout:)`, which already unions the holes through
    /// Clipper2, recomputes the parent's net value and carries its own undo inverse.
    public var onCommitCutout: (@MainActor (MarkupID, MarkupRecord) -> Void)?
    /// Called when the snapped point the user is about to place moves, so the canvas can
    /// draw the same glyph the palette is reading.
    public var onSnapFeedback: (@MainActor (SnapFeedbackSnapshot?) -> Void)?

    // MARK: Boundary capture (Scale Regions and Project Zones)

    /// What a committed polygon is for, when it is not a measurement.
    public enum BoundaryPurpose: String, Sendable, Hashable {
        /// The boundary of a Scale Region.
        case scaleRegion
        /// The boundary of a Project Zone.
        case projectZone
    }

    /// What the polygon being drawn is for, or `nil` when it is an ordinary measurement.
    ///
    /// Both panels need the same thing from the canvas — "let the person draw a closed
    /// polygon and hand it back" — and the polygon tool already does every hard part of
    /// that: snapping, the live outline, Escape, remove-last-vertex and the
    /// self-intersection refusal. Reimplementing it beside the measurement family would be
    /// a second polygon editor to keep in step with the first, and the first is the one the
    /// estimator's hands already know.
    public private(set) var boundaryPurpose: BoundaryPurpose?

    /// Called instead of ``onCommit`` when a boundary polygon is finished.
    public var onCommitBoundary: (@MainActor (BoundaryPurpose, [PDFPointValue], PageID) -> Void)?

    /// Called when a boundary capture ends without a polygon, so the panel stops waiting.
    public var onCancelBoundary: (@MainActor (BoundaryPurpose) -> Void)?

    /// Arms the polygon tool to capture a boundary rather than to measure an area.
    ///
    /// Anything half-drawn is discarded first: a polygon started as an area measurement and
    /// finished as a Scale Region boundary would be neither of the two things the person
    /// thought they were drawing.
    public func beginBoundaryCapture(_ purpose: BoundaryPurpose) {
        discardInProgress()
        // `activate(kind:)` ends whatever boundary capture it finds, so the purpose is set
        // after the tool is armed, never before.
        activate(kind: .area)
        boundaryPurpose = purpose
    }

    /// Whether a boundary is being drawn right now.
    public var isCapturingBoundary: Bool { boundaryPurpose != nil }

    /// Ends a boundary capture without a polygon and tells the panel, or does nothing when
    /// no capture is in progress.
    private func endBoundaryCapture() {
        guard let purpose = boundaryPurpose else { return }
        boundaryPurpose = nil
        discardInProgress()
        onCancelBoundary?(purpose)
    }

    // MARK: Private state

    private let session: TakeoffSession
    private let identifiers: @Sendable () -> UUID
    private let clock: @Sendable () -> Date
    private var pageID: PageID
    private var documentID: DocumentID
    private var parameters: MeasurementParameters = .default

    /// The parameter block a Tool Library preset armed, which the options-bar field is folded
    /// into rather than replacing.
    ///
    /// The options bar carries exactly one number per tool by design
    /// (``MeasurementParameterRequirement``); everything else a preset remembers —
    /// the gable's second height, the fall-line azimuth, the cutout and perimeter policies, the
    /// volume depth reference — has no field there. Without this, `setParameterText` rebuilding
    /// from `.default` meant the first keystroke in the depth field silently threw away the
    /// azimuth the preset had just supplied.
    private var presetBaseParameters: MeasurementParameters = .default
    /// The text typed for each requirement, so switching Volume → Wall Area → Volume does
    /// not make the estimator retype a depth they already gave.
    private var parameterTexts: [MeasurementParameterRequirement: String] = [:]
    /// The exact value behind options-bar text a preset supplied.
    ///
    /// A preset stores its depth in metres, and the field shows it in the display unit. In feet
    /// the quotient does not terminate — 0.2 m is 0.656167979… ft — and the field used to carry
    /// all 38 digits of `Decimal`'s expansion (BH-084). The field now shows a rounded figure and
    /// the engine keeps the preset's exact metres for as long as the estimator leaves the field
    /// alone; the first keystroke makes the typed number the value, as it always was.
    private var exactParameterOverride: ExactParameterOverride?

    private struct ExactParameterOverride {
        let requirement: MeasurementParameterRequirement
        let text: String
        let lengthUnit: ZPDFUIPresentation.LengthUnit
        let value: Decimal
    }
    /// Raw pointer positions of placements still waiting for their snap to resolve, by
    /// sequence. A count finished by a page turn or a tool switch takes these as marks rather
    /// than letting them die in the queue (BH-112).
    private var pendingPlacements: [Int: PDFPointValue] = [:]
    /// The sequence of an arc through point still waiting for its snap (NL-MEASURE-05).
    private var pendingArcThroughSequence: Int?
    private var arcPreviewTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pointerSequence: Int = 0
    /// The chain of in-flight point placements.
    ///
    /// Chained rather than concurrent because vertex *order* is the polygon: three clicks
    /// that resolve their snaps in whatever order the scheduler chose would produce a
    /// bow-tie instead of a rectangle, and the shoelace area of a bow-tie is not the area
    /// the user drew (spec 12.3).
    private var placementTask: Task<Void, Never>?
    /// Bumped for every queued placement, so ``settlePlacements()`` can tell "the task I
    /// awaited" from "another click arrived while I waited". `Task` is a struct and has no
    /// identity to compare.
    private var placementGeneration: Int = 0
    /// The records behind ``temporaryMeasurements``, kept so a promotion has something real
    /// to commit. The summaries alone are display values and cannot be stored.
    private var temporaryRecords: [MarkupRecord] = []
    /// The measurement of the tape committed last, in flight (L-104).
    private var temporaryMeasureTask: Task<Void, Never>?

    /// View geometry, refreshed by the canvas on every layout.
    public var layout: PageViewLayout = PageViewLayout()
    /// Subject and label the next committed markup takes, from the armed tool preset.
    public var defaultSubject: String = ""
    public var defaultLabel: String = ""
    /// The status the next committed measurement takes, from the armed tool preset.
    ///
    /// Draw mode used to honour only a preset's subject and ink, so a preset carrying a status
    /// and a cost code committed rows with neither while Place and Apply honoured both — the
    /// estimator re-typed them on every drawn markup, which is the chore a Tool Library exists
    /// to remove (BH-085). Cleared with the subject whenever nothing is armed.
    public var defaultStatus: Domain.Status = .none
    /// The custom ledger column values the next committed measurement takes, already resolved
    /// against the document's own column set by ``AppCoreEnvironment``.
    public var defaultCustomValues: [ColumnID: Domain.CellValue] = [:]
    /// The symbol a committed **count** takes, from the armed tool preset (spec 12.13).
    ///
    /// A property of the mark, not a tool option resolved at draw time: two count groups made
    /// with two tools may legitimately disagree about their glyph, and editing or deleting the
    /// preset afterwards must not reach either of them (ADR-0011 §2.1). Set by
    /// ``AppCoreEnvironment``'s arming hook and cleared whenever nothing is armed, so a plain
    /// Count keeps the record's `symbol` empty rather than inheriting the last preset's.
    public var countSymbol: MarkupSymbol?
    /// The author recorded on committed markups.
    public var author: String = ""
    /// The area the cutout in progress is a hole in, resolved from its first vertex.
    ///
    /// Set by the canvas the moment a cutout's first point lands inside an area
    /// (`CutoutParentResolver`), cleared whenever the tool is disarmed or the shape is
    /// discarded. A cutout with no parent is refused rather than committed as a free
    /// polygon — see ``commitActiveMeasurement()``. Setting it fetches the parent's outline for
    /// the engine's overlap verdict (X-cutout-ui).
    public var cutoutParentID: MarkupID? {
        didSet { if cutoutParentID != oldValue { loadCutoutParentOutline() } }
    }
    /// The parent's stored outer ring, fetched from the session when ``cutoutParentID`` is set.
    @ObservationIgnored private var cutoutParentOutline: (id: MarkupID, ring: PolygonRing)?
    @ObservationIgnored private var cutoutParentOutlineTask: Task<Void, Never>?
    /// What ``cutoutOverlapWarning`` was computed from, so the engine is asked once per change
    /// of the shape rather than once per pointer move.
    @ObservationIgnored private var cutoutOverlapBasis: CutoutOverlapBasis?
    /// The engine's verdict on the cutout in progress against its parent, as a live warning:
    /// `cutoutOutsideParent` (informs) for a partial overlap, `cutoutDoesNotOverlapParent`
    /// (blocks Finish) for none, `nil` when it lies inside or nothing can be said yet.
    @ObservationIgnored private(set) var cutoutOverlapWarning: MeasurementWarningSummary?
    /// Resolves the author at commit time, so a Settings change affects the next
    /// measurement rather than requiring a new document.
    /// `nil` keeps ``author``.
    public var authorProvider: (@MainActor () -> String)?
    /// The colour committed markups take: the measurement blue unless a tool preset
    /// overrides it.
    public var color: RGBAColor = AppMeasurementToolPresenter.measurementInk

    /// The Zenit measurement ink — the `#1A55CF` blue for dimension lines, polygon strokes
    /// and area fills (since 2026-09-23). Committed markups must carry it in their stored
    /// style: before this existed only the live preview was coloured and every committed
    /// markup rendered near-black from `MarkupStyle.default` (found 2026-08-24).
    ///
    /// It replaced the `#50D6DE` cyan, which measured about 1.6:1 against the white sheet —
    /// a line an estimator could barely see.
    /// A default only: a stored markup keeps the colour it was committed with.
    public static let measurementInk = RGBAColor(
        red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 1.0
    )

    /// The fill closed areas take: the stroke colour at 20 % alpha.
    public static func measurementFill(for stroke: RGBAColor) -> RGBAColor {
        RGBAColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: measurementFillAlpha)
    }

    /// The alpha of ``measurementFill(for:)``: the one shared 20 % area-fill constant, so the
    /// tools, the canvas and the Inspector cannot drift apart.
    public static let measurementFillAlpha = MarkupFillDefaults.derivedAreaFillAlpha

    /// Creates a presenter over a session.
    public init(
        session: TakeoffSession,
        documentID: DocumentID,
        pageID: PageID,
        units: DisplayUnitSelection = .metric,
        identifiers: @escaping @Sendable () -> UUID = { UUID() },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.documentID = documentID
        self.pageID = pageID
        self.lengthUnit = units.length
        self.areaUnit = units.area
        self.volumeUnit = units.volume
        self.slopeDisplayMode = units.slope
        self.imperialPrecision = units.imperialPrecision
        self.identifiers = identifiers
        self.clock = clock
    }

    /// The units currently in force, as one value.
    public var units: DisplayUnitSelection {
        DisplayUnitSelection(
            length: lengthUnit,
            area: areaUnit,
            volume: volumeUnit,
            slope: slopeDisplayMode,
            imperialPrecision: imperialPrecision
        )
    }

    /// The formatter a live value, the arc pill and a Temporary Measure are written with: `units`
    /// in the session's locale — the locale every ledger cell and committed pill already uses.
    ///
    /// L-104: these four call sites built `QuantityFormatter(units:)`, whose locale defaults to
    /// `en_US_POSIX`, so on a Swedish Mac the tape read "5.20 m" beside a ledger reading "5,20 m".
    func displayFormatter(_ units: DisplayUnitSelection) -> QuantityFormatter {
        QuantityFormatter(units: units, localeIdentifier: session.localeIdentifier)
    }

    /// Moves the palette to a different page.
    public func setPage(_ pageID: PageID) {
        guard self.pageID != pageID else { return }
        // A count in progress is finished, not thrown away — the rule `deactivate()` applies
        // to a tool switch, which a page turn contradicted: ten marks placed, next sheet, ten
        // marks gone (CR-8). Committed before `self.pageID` moves, so the group is recorded on
        // the sheet the marks were placed on.
        finishCountInProgress()
        cancelActiveMeasurement()
        self.pageID = pageID
        // The scale follows the page. Turning to an uncalibrated sheet clears it, so
        // `liveWarnings` raises `.missingScale` there instead of on the sheet being left.
        // Its Scale Regions follow too (L-102).
        adoptScaleCoverage()
    }

    /// The last snapshot adopted, so a page change can re-resolve the scale without waiting
    /// for the next one. Turning a page must not leave the palette showing the scale of the
    /// page that is no longer on screen.
    private var latestSnapshot: DocumentSnapshot?

    /// The document units the palette last followed, so only a *change* of the document's
    /// units overrides the palette's own unit menu.
    private var lastAdoptedUnits: DisplayUnitSelection?

    /// Follows the document's units when they change.
    ///
    /// The palette's units were fixed at init, so a job template that switched the document
    /// to imperial left the live preview reading square metres under a ledger reading square
    /// feet (CR-11). Only a change since the last snapshot is adopted: a person who picked
    /// millimetres in the palette's own menu keeps them across refreshes that did not touch
    /// the document's units.
    private func adoptUnits(_ documentUnits: DisplayUnitSelection) {
        if let last = lastAdoptedUnits, !Self.unitsDiffer(last, documentUnits) { return }
        lastAdoptedUnits = documentUnits
        guard Self.unitsDiffer(units, documentUnits) else { return }
        lengthUnit = documentUnits.length
        areaUnit = documentUnits.area
        volumeUnit = documentUnits.volume
        slopeDisplayMode = documentUnits.slope
        imperialPrecision = documentUnits.imperialPrecision
        reformatLiveFields()
    }

    private static func unitsDiffer(_ a: DisplayUnitSelection, _ b: DisplayUnitSelection) -> Bool {
        a.length != b.length || a.area != b.area || a.volume != b.volume
            || a.slope != b.slope || a.imperialPrecision != b.imperialPrecision
    }

    /// Adopts the document scale from a snapshot, and seeds the label allocator from the
    /// labels already in the document — so a reopened project continues at the highest
    /// letter it ever reached rather than restarting at "A" (the "Length A" auto-label
    /// pattern).
    public func adopt(_ snapshot: DocumentSnapshot) {
        // The palette's page, not the document's first. A palette showing 1:100 while the
        // person is drawing on the 1:20 detail sheet is the readout half of the wrong number.
        latestSnapshot = snapshot
        adoptScaleCoverage()
        adoptUnits(snapshot.units)
        var population: [AutoLabelKey: Int] = [:]
        var inUse: [AutoLabelKey: Set<String>] = [:]
        var candidates: [(AutoLabelKey, Int)] = []
        for summary in snapshot.markups {
            guard let kind = summary.measurementKind else { continue }
            let key = AutoLabelKey(pageID: summary.pageID, kind: kind)
            population[key, default: 0] += 1
            inUse[key, default: []].insert(summary.label)
            guard let ordinal = Self.autoLabelOrdinal(of: summary.label, kind: kind) else { continue }
            candidates.append((key, ordinal))
        }
        labelsInUse = inUse
        for (key, ordinal) in candidates {
            // The allocator hands out letters one at a time, so a genuine auto label is at most
            // as far past the tool's surviving population as markups were deleted. A label more
            // than a whole alphabet beyond that is a name somebody typed in capitals —
            // "Area GARAGE" — and seeding from it made the next area "Area GARAGF" (BH-113).
            // Any letter skipped by this bound is still never duplicated: `nextAutoLabel`
            // steps over labels already on the page.
            guard ordinal <= (population[key] ?? 0) + Self.autoLabelSlack else { continue }
            labelHighWater[key] = max(labelHighWater[key] ?? 0, ordinal)
        }
    }

    /// How far past a tool's population on a page an auto label may sit and still seed the
    /// allocator: one full alphabet of deletions.
    static let autoLabelSlack = 26
    /// The longest letter run an auto label can have: "ZZZZ" is ordinal 475 254, far beyond
    /// any page, and short enough that the ordinal can never overflow `Int` (BH-012).
    static let maximumAutoLabelLetters = 4

    /// Labels already on each page, per tool, so the allocator never issues one twice.
    private var labelsInUse: [AutoLabelKey: Set<String>] = [:]

    // MARK: Auto labels ("Length A" pattern)

    /// One allocator per tool per page.
    private struct AutoLabelKey: Hashable {
        let pageID: UUID
        let kind: Shown.Kind
    }

    /// The highest letter ever handed out, per (page, tool). Deliberately **not** part of
    /// undo state and never decremented: deleting or undoing "Length B" must not make the
    /// next length another "Length B" — a freed letter is never reused within a page.
    private var labelHighWater: [AutoLabelKey: Int] = [:]

    /// The next auto label for a tool on a page: tool name + letter (A…Z, AA, AB, …).
    /// Bumps the allocator, so calling it *is* the allocation.
    func nextAutoLabel(for kind: Shown.Kind, pageID: PageID) -> String {
        let key = AutoLabelKey(pageID: pageID.rawValue, kind: kind)
        let taken = labelsInUse[key] ?? []
        var next = (labelHighWater[key] ?? 0) + 1
        var label = "\(kind.displayName) \(Self.letters(for: next))"
        while taken.contains(label) {
            next += 1
            label = "\(kind.displayName) \(Self.letters(for: next))"
        }
        labelHighWater[key] = next
        labelsInUse[key, default: []].insert(label)
        return label
    }

    /// 1 → "A", 26 → "Z", 27 → "AA" — bijective base 26.
    static func letters(for ordinal: Int) -> String {
        var remaining = ordinal
        var text = ""
        while remaining > 0 {
            remaining -= 1
            let scalar = UnicodeScalar(UInt8(65 + remaining % 26))
            text = String(Character(scalar)) + text
            remaining /= 26
        }
        return text
    }

    /// Parses a label of the exact form "<tool name> <LETTERS>" back to its ordinal, or
    /// `nil` for anything a user typed. Only auto-shaped labels seed the allocator; a
    /// user label always wins and never collides, so it never has to advance a letter.
    ///
    /// A piece of a measurement split at a Scale Region boundary is labelled
    /// "<tool name> <LETTERS> (n of m)"; the suffix is stripped before parsing, so a reopened
    /// project that holds only the pieces still seeds the allocator from their letter and does
    /// not issue that letter again (BH-414). More than ``maximumAutoLabelLetters`` letters is
    /// never an auto label — and the bound is also what keeps the base-26 ordinal from
    /// overflowing `Int` and trapping on a long capitalised label while a project opens
    /// (BH-012).
    static func autoLabelOrdinal(of label: String, kind: Shown.Kind) -> Int? {
        let prefix = kind.displayName + " "
        guard label.hasPrefix(prefix) else { return nil }
        var letters = Substring(label.dropFirst(prefix.count))
        if letters.hasSuffix(")"), let open = letters.range(of: " (", options: .backwards) {
            letters = letters[..<open.lowerBound]
        }
        guard !letters.isEmpty, letters.count <= maximumAutoLabelLetters,
              letters.allSatisfy({ $0.isASCII && ("A"..."Z").contains($0) }) else {
            return nil
        }
        var ordinal = 0
        for character in letters {
            guard let ascii = character.asciiValue else { return nil }
            ordinal = ordinal * 26 + Int(ascii - 65) + 1
        }
        return ordinal
    }

    /// Sets the depth, height, slope and cutout policy the next measurement uses.
    ///
    /// This had no caller in the product until 2026-08-24, so five tools collected points,
    /// previewed, and then vanished because `parameters` was still `.default`. ``setParameterText(_:)`` is the caller now — the
    /// tool options bar's field composes a `MeasurementParameters` and hands it here, so
    /// there is still exactly one place the engine's parameters are written.
    public func setParameters(_ parameters: MeasurementParameters) {
        self.parameters = parameters
        schedulePreview()
    }

    /// Sets the tool options bar's parameter field.
    ///
    /// The text is kept as text and parsed by ``parseParameter(_:)`` (the shared typed-number
    /// grammar, converted in the POSIX locale), so `"0.15"` reaches the engine as exactly
    /// fifteen hundredths rather than as the nearest binary double. An empty or unparseable string clears the value, which puts the tool
    /// back into "cannot be committed yet" instead of quietly reusing the last number.
    public func setParameterText(_ text: String) {
        parameterText = text
        if let requirement = requiredParameter { parameterTexts[requirement] = text }
        parameterValue = Self.parseParameter(text, for: requiredParameter)
        setParameters(
            Self.parameters(
                applying: requiredParameter,
                value: parameterValue,
                lengthUnit: lengthUnit,
                exactValue: exactValue(for: text),
                to: presetBaseParameters
            )
        )
    }

    /// Puts a preset's saved value in the options-bar field as (rounded) display text, while
    /// the engine keeps the preset's exact value for as long as the field still shows that
    /// text. `exactValue` is in engine terms: metres for a length, the percentage for a slope.
    public func setParameterText(_ text: String, exactValue: Decimal) {
        if let requirement = requiredParameter {
            exactParameterOverride = ExactParameterOverride(
                requirement: requirement,
                text: text,
                lengthUnit: lengthUnit,
                value: exactValue
            )
        }
        setParameterText(text)
    }

    /// The preset's exact value when the field still shows exactly the preset's text — for a
    /// length, in the unit it was written for.
    private func exactValue(for text: String) -> Decimal? {
        guard let override = exactParameterOverride else { return nil }
        guard override.requirement == requiredParameter,
              override.text == text,
              !override.requirement.isLength || override.lengthUnit == lengthUnit
        else {
            exactParameterOverride = nil
            return nil
        }
        return override.value
    }

    /// The parameter block the engine will be handed for the next commit.
    ///
    /// Read-only and published for the same reason the options-bar text is: the estimator has to
    /// be able to find out what the armed tool is actually going to compute with, and a preset
    /// can now supply values — an azimuth, a depth reference, a cutout policy — that no field on
    /// screen shows. Without a way to read them there is no way to tell "the preset armed the
    /// slope" from "the preset looked like it did".
    public var parametersInEffect: MeasurementParameters { parameters }

    /// Installs the parameter block a tool preset carries, under whatever the options bar says.
    ///
    /// Called by ``AppCoreEnvironment`` when a Draw-mode preset is armed, after
    /// ``activate(kind:)`` — which resets the base — and after ``setParameterText(_:)`` has put
    /// the preset's one options-bar number in the field. The field wins over the block for the
    /// value it owns, because the field is what the estimator can see.
    public func setPresetParameters(_ parameters: MeasurementParameters) {
        presetBaseParameters = parameters
        setParameters(
            Self.parameters(
                applying: requiredParameter,
                value: parameterValue,
                lengthUnit: lengthUnit,
                exactValue: exactValue(for: parameterText),
                to: parameters
            )
        )
    }

    /// Parses the options-bar field and the Inspector's Depth, Height and Height at end rows by
    /// ``TypedDecimalGrammar``, Zenit's one grammar for a typed number — the one a ledger cell
    /// reads the same text with.
    ///
    /// The whole string has to be a number (BH-449: `Decimal(string:)` took the leading prefix,
    /// so "0.15.2" became 0.15). Both decimal marks are accepted, never both at once; spaces,
    /// no-break and narrow no-break spaces group digits ("1 500,5" is how a Swedish estimator
    /// writes it); U+2212 and the other minus signs, bidirectional marks and native digits are
    /// spellings of the same number. This used to be a second grammar with its own regular
    /// expressions, so "−0,25" — how the sv formatter writes a negative — was refused in the
    /// Rise/Drop field while a ledger cell read it as −0.25 (X-020). Zero is refused here: no
    /// tool computes with a zero depth, height, slope or rise, so it leaves the tool waiting.
    nonisolated static func parseParameter(_ text: String) -> Decimal? {
        guard let value = TypedDecimalGrammar.decimal(text), value != 0 else { return nil }
        return value
    }

    /// Parses the field for one requirement.
    ///
    /// Only a rise or drop may be negative — a drop is a negative rise. A negative depth
    /// committed a negative volume that summed into the totals, and a negative wall height or
    /// slope has no meaning, so for those tools a negative is refused like any other
    /// unusable text (BH-114).
    static func parseParameter(
        _ text: String,
        for requirement: MeasurementParameterRequirement?
    ) -> Decimal? {
        guard let value = parseParameter(text) else { return nil }
        if value < 0, requirement != .totalRiseDrop { return nil }
        return value
    }

    /// Folds one options-bar value into a set of measurement parameters.
    ///
    /// Lengths are converted to metres through the display unit's *exact* `Decimal` factor,
    /// never through `Double`: a depth typed as `6 in` must store as exactly 0.1524 m or the
    /// stored quantity disagrees with the number the estimator typed.
    static func parameters(
        applying requirement: MeasurementParameterRequirement?,
        value: Decimal?,
        lengthUnit: ZPDFUIPresentation.LengthUnit,
        exactValue: Decimal? = nil,
        to base: MeasurementParameters
    ) -> MeasurementParameters {
        var result = base
        guard let requirement, let value else { return result }
        let metres = exactValue ?? value * lengthUnit.metresPerUnit
        switch requirement {
        case .depth:
            result.depth = .length(metres)
        case .wallHeight:
            result.height = .length(metres)
        case .slopePercent:
            // The field owns the steepness, not the direction: a `Roof 6:12` preset's fall-line
            // azimuth survives the field's value being folded in over it.
            result.slope = .uniformPlane(.percent(exactValue ?? value), azimuth: base.slope.azimuth)
        case .totalRiseDrop:
            result.slope = .total(metres)
        }
        return result
    }

    /// The parameters actually handed to the engine for a given set of points.
    ///
    /// One thing is derived rather than typed: True Sloped Length applies a uniform plane
    /// to a *length*, and ADR-0004 refuses that without a fall line — a typed error, never
    /// a scalar fallback. Asking the estimator for an azimuth in a toolbar field would be
    /// absurd, and the run they just drew is the fall line in every case the tool is for
    /// (a rafter, a ramp, a drainage line), so the azimuth is taken from the first placed
    /// point to the last. A polyline that bends away from that line is stretched less on
    /// the bent segments, which is the correct answer for the plane it names.
    func engineParameters(for kind: Shown.Kind, points: [PDFPointValue]) -> MeasurementParameters {
        var resolved = parameters
        // The Slope tool too: it measures a run on a plane, and without the fall line the
        // engine refuses it (`requireAzimuth`) on every drawn run (BH-164, BH-052).
        guard kind == .trueSlopedLength || kind == .slope,
              resolved.slope.mode == .uniformPlane,
              resolved.slope.azimuth == nil,
              let first = points.first,
              let last = points.last,
              let azimuth = try? SlopeAzimuth.between(PDFPoint(shown: first), PDFPoint(shown: last))
        else { return resolved }
        resolved.slope = resolved.slope.with(azimuth: azimuth)
        return resolved
    }

    // MARK: MeasurementToolPresenting

    public func activate(kind: Shown.Kind) {
        // Picking a tool ends a boundary capture. The purpose used to survive the switch, so
        // Length picked off the toolbar mid-capture turned the next Return into a boundary
        // commit: the panel got a two-point "polygon" and no measurement was ever created
        // (CR-4). The panel is told, so it stops waiting.
        endBoundaryCapture()
        // Re-activating the tool that is already armed changes nothing. That is the toolbar
        // mirroring a Tool Library arm: `AppCoreEnvironment` arms the tool and installs the
        // preset's parameter block, then lights the toolbar chip, and the chip's selection
        // handler calls back in here. Resetting on that echo threw away the gable's second
        // height, the fall line and the policies one statement after they were installed —
        // but only when the toolbar had been on another chip (BH-003).
        if activeKind == kind {
            lastUsedKinds.removeAll { $0 == kind }
            lastUsedKinds.insert(kind, at: 0)
            return
        }
        // A count in progress is finished, not thrown away, on this path too: a Tool Library
        // preset or a toolbar chip switching tools went through here and discarded ten marks,
        // the loss `deactivate()` was fixed for (BH-086).
        finishCountInProgress()
        discardInProgress()
        // Arming a tool clears the previous preset's block. A `Roof 6:12` armed, then Area
        // picked off the toolbar, must not leave Area measuring against a 50 % plane.
        presetBaseParameters = .default
        exactParameterOverride = nil
        activeKind = kind
        isTemporaryMeasurement = kind.isTemporary
        // Re-arming a tool restores the value it was last given, and arming a tool that
        // needs nothing clears the field rather than leaving a stale number under a tool
        // that would ignore it.
        setParameterText(kind.requiredParameter.flatMap { parameterTexts[$0] } ?? "")
        lastUsedKinds.removeAll { $0 == kind }
        lastUsedKinds.insert(kind, at: 0)
        if lastUsedKinds.count > 8 { lastUsedKinds.removeLast(lastUsedKinds.count - 8) }
        // L-102: a circle tool on a sheet with separate X and Y scales says so on arming.
        refreshUniformScaleRefusal()
    }

    public func deactivate() {
        // A count in progress is **committed**, not discarded.
        //
        // Reported 2026-08-26: ten counts placed, then a tool change, and the counts were
        // gone. Every other measurement has a shape that can be half-drawn — three points of a
        // polygon are not an area, and throwing that away on a tool change is right. A count has
        // no such state: each mark the estimator placed is a whole answer the moment it lands,
        // and `minimumPointCount` for `.count` is 1 precisely because of that.
        //
        // So switching tools finishes the count group instead of deleting it. The commit is a
        // normal undoable command, so `⌘Z` still removes it — which is the difference between
        // ending work and losing it.
        finishCountInProgress()
        // Disarming ends a boundary capture too, and says so (CR-4).
        endBoundaryCapture()
        discardInProgress()
        activeKind = nil
        isTemporaryMeasurement = false
        refreshUniformScaleRefusal()
    }

    /// Adds a point, snapped.
    ///
    /// The snap resolve is awaited here — unlike the hover path, which must never wait —
    /// because a click is one event per user gesture and placing the *unsnapped* point and
    /// correcting it a frame later is visible as a jump.
    /// Bumped by every cancel-shaped discard. A placement still in the snap queue when the
    /// measurement it belonged to was cancelled must die in the queue: before this epoch,
    /// Escape cleared the points and the queued placements landed AFTERWARDS, resurrecting
    /// two zombie vertices into the next measurement (LT-6, 2026-08-29 —
    /// four clicks became six marks).
    private var cancelEpoch: UInt64 = 0

    /// The commit fence: placements issued after Finish was pressed belong to the NEXT
    /// measurement, never to the one being committed. Without it, the finish path's settle
    /// wait swept the after-Return clicks into the old polygon and then discarded them —
    /// four clicks became zero (LT-6's other half).
    ///
    /// One per Finish not yet released, in Return order (RT-2). A single slot used to hold
    /// the fence, so a second Return that arrived while the first Finish was still waiting
    /// for its snaps overwrote it: the first Finish found "not my fence", cut nothing and
    /// committed both shapes' clicks as one polygon, and the second had nothing left.
    private struct CommitFence {
        /// What ``beginCommitFence()`` handed out; unique, so two Returns with no click
        /// between them are still two fences.
        let token: Int
        /// The last pointer sequence that belongs to the measurement this Finish commits.
        let sequence: Int
    }
    private var commitFences: [CommitFence] = []
    private var commitFenceTokens = 0
    /// Finishes waiting for an earlier Return's commit to land before they cut (RT-2).
    private var commitFenceWaiters: [CheckedContinuation<Void, Never>] = []
    /// The oldest open fence's sequence: points up to it belong to the measurement being
    /// finished.
    private var commitFenceSequence: Int? { commitFences.first?.sequence }
    /// The clicks after the fence being settled, with their own sequences, so a later fence
    /// can still tell its clicks from the ones after it (RT-2).
    private var carryAfterFence: [(point: PDFPointValue, sequence: Int)] = []
    private var placedSequences: [Int] = []

    /// The snap keys the canvas holds down (`⌘` suspends snapping, spec 13.8).
    ///
    /// Read when a click is made, not when its resolve runs, so a click made with `⌘` held is
    /// placed raw even when it lands behind earlier clicks still resolving. The resolve used to
    /// pass no keys at all, so a `⌘`-click snapped again onto the vector candidate (V-070).
    @ObservationIgnored public var snapModifiers: SnapModifiers = .none

    /// Markups this window does not draw although they are not hidden — the ledger filter's
    /// Hide (V-003) — which no click may snap to. Read when a click is made, like
    /// ``snapModifiers``. The environment points it at the canvas presenter's
    /// ``AppCanvasPresenter/snapExcludedMarkupIDs``, the one rule the drawing also follows.
    @ObservationIgnored public var snapExclusions: (@MainActor () -> Set<MarkupID>)?

    public func placePoint(_ point: PDFPointValue) {
        guard activeKind != nil else { return }
        let anchor = placedPoints.last.map { PDFPoint(shown: $0) }
        pointerSequence &+= 1
        let sequence = pointerSequence
        let pageID = self.pageID
        let layout = self.layout
        let cursor = PDFPoint(shown: point)
        let modifiers = snapModifiers
        let excluded = snapExclusions?() ?? []
        let epoch = cancelEpoch

        let previous = placementTask
        placementGeneration &+= 1
        pendingPlacements[sequence] = point
        placementTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let resolution = try? await self.session.resolveSnap(
                pageID: pageID,
                pagePoint: cursor,
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchor,
                sequence: sequence,
                excludingMarkupIDs: excluded
            )
            // Absorbed already — a count finished by a page turn took this mark — or
            // cancelled: either way it is not this landing's to place.
            guard self.pendingPlacements.removeValue(forKey: sequence) != nil else { return }
            // A cancel between the click and this landing means the measurement this
            // point was aimed at no longer exists.
            guard self.cancelEpoch == epoch else { return }
            self.appendResolved(resolution, fallback: point, pageID: pageID, sequence: sequence)
        }
    }

    /// Marks the moment Finish was pressed. Everything placed up to now is what commits;
    /// clicks after this instant open the next measurement. Synchronous on purpose — it
    /// runs in the key handler, before any await.
    ///
    /// - Returns: this Finish's fence, to hand back to ``settleCommitFence(_:)`` and
    ///   ``releaseCommitFence(_:)``. Every call opens a fence of its own, so Returns pressed
    ///   in a burst finish one after another, in order (RT-2).
    public func beginCommitFence() -> Int {
        commitFenceTokens &+= 1
        commitFences.append(CommitFence(token: commitFenceTokens, sequence: pointerSequence))
        return commitFenceTokens
    }

    /// Waits until every placement at or before the fence has landed, and every earlier
    /// Return's Finish has been released, then sets the point list to exactly the fence's
    /// points — later arrivals are carried for the next measurement.
    ///
    /// The second wait is RT-2: the cut is only right once the shape before it has been
    /// committed. A later Finish that cut first would keep the earlier shape's clicks as its own.
    public func settleCommitFence(_ fence: Int) async {
        while true {
            await settlePlacements()
            // Gone: a cancel threw the measurement and its fences away.
            guard let index = commitFences.firstIndex(where: { $0.token == fence }) else { return }
            if index == 0 { break }
            await withCheckedContinuation { commitFenceWaiters.append($0) }
        }
        let sequence = commitFences[0].sequence
        // Defensive: the two lists are maintained as a pair, but a cut past the point list
        // must never trap the process — a skewed pair keeps everything for this commit.
        if let cut = placedSequences.firstIndex(where: { $0 > sequence }), cut <= placedPoints.count {
            carryAfterFence = Array(zip(placedPoints[cut...], placedSequences[cut...]))
                .map { (point: $0.0, sequence: $0.1) }
            placedPoints = Array(placedPoints[..<cut])
            placedSequences = Array(placedSequences[..<cut])
            // An arc into a point that belongs to the next measurement is not this one's.
            dropArcBulges(from: cut - 1)
        }
    }

    /// Hands the after-Return clicks to the next measurement, whether the commit landed
    /// (points were cleared) or refused (they stayed), and lets the next Return's Finish cut.
    public func releaseCommitFence(_ fence: Int) {
        guard let index = commitFences.firstIndex(where: { $0.token == fence }) else { return }
        commitFences.remove(at: index)
        if index == 0, !carryAfterFence.isEmpty {
            placedPoints.append(contentsOf: carryAfterFence.map(\.point))
            // Their own sequences, not the fence's: a later fence still has to tell its own
            // clicks from the ones made after it (RT-2).
            placedSequences.append(contentsOf: carryAfterFence.map(\.sequence))
            carryAfterFence = []
            schedulePreview()
        }
        resumeCommitFenceWaiters()
    }

    /// Wakes every Finish waiting for its turn; each checks again whether it is now first.
    private func resumeCommitFenceWaiters() {
        let waiters = commitFenceWaiters
        commitFenceWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Waits for every in-flight point placement to land.
    ///
    /// A click is asynchronous because the snap resolve is, so a caller that has to see the
    /// finished point list — a commit driven from a keyboard shortcut, or a test — waits
    /// here rather than guessing at a number of run-loop turns.
    public func settlePlacements() async {
        while let task = placementTask {
            let generation = placementGeneration
            await task.value
            guard placementGeneration == generation else { continue }
            placementTask = nil
        }
    }

    /// Whether a placement issued through ``placePoint(_:)`` has not landed yet.
    ///
    /// `placedPoints` lags a click by one snap resolve. The canvas's input state machine is
    /// synchronised from `placedPoints` only while this is `false`; while it is `true` the
    /// machine's own vertex list, which already holds the click, is the better answer (IM-019).
    public var hasPlacementsInFlight: Bool { !pendingPlacements.isEmpty || pendingArcThroughSequence != nil }

    /// Stores the snapped point, or the raw one when nothing was in range.
    public func appendResolved(
        _ resolution: SnapResolution?,
        fallback: PDFPointValue,
        pageID: PageID,
        sequence: Int = 0
    ) {
        // A point that lands after the tool was disarmed belongs to nothing. A placement
        // still resolving when `deactivate()` ran used to append to a presenter with no
        // active kind — an orphan vertex the next arming inherited (CR-8).
        guard activeKind != nil else { return }
        let resolved = resolution.map { PDFPointValue(domain: $0.resolvedPagePoint) } ?? fallback
        // A point on top of the previous one is a double-click, a nervous finger, or the
        // focus-swallow workaround — never a vertex. Placed anyway, it made the polygon
        // degenerate, `canCommit` false, and Return a silent nothing: the tool sat stuck
        // until Escape (LT-9, 2026-08-29). Count is exempt — two marks in one
        // spot are two real things being counted.
        if activeKind != .count, let last = placedPoints.last,
           abs(last.x - resolved.x) < 0.01, abs(last.y - resolved.y) < 0.01 {
            return
        }
        // The end of an arc segment (NL-MEASURE-05): the edge from the last point to this one
        // bends through the through point that landed before it.
        bendArcSegment(endingAt: resolved)
        placedPoints.append(resolved)
        placedSequences.append(sequence)
        if let resolution, let feedback = resolution.feedback {
            let snapshot = SnapFeedbackSnapshot(
                domain: feedback,
                pageID: pageID,
                confidence: resolution.winner.map { Double($0.confidence) } ?? 1
            )
            snapFeedback = snapshot
            onSnapFeedback?(snapshot)
        }
        schedulePreview()
    }

    public func removeLastPoint() {
        // The most recent input first (ADR-0030 §5.6.1): an arc's through point, placed or still
        // resolving, goes before the vertex it hangs from, and the arc stays armed. The canvas's
        // Backspace already did this through the input machine; Measure ▸ Remove Last Point comes
        // here directly, and removed the vertex while the through point stayed armed.
        if isArcNextSegment, arcThroughPoint != nil || pendingArcThroughSequence != nil {
            removeArcThroughPoint()
            return
        }
        guard !placedPoints.isEmpty else { return }
        placedPoints.removeLast()
        if !placedSequences.isEmpty { placedSequences.removeLast() }
        // The arc that ended at the removed point goes with it (NL-MEASURE-05); with no point
        // left there is no segment for an armed arc to belong to.
        dropArcBulges(from: placedPoints.count - 1)
        if placedPoints.isEmpty {
            isArcNextSegment = false
            arcThroughPoint = nil
            pendingArcThroughSequence = nil
        }
        schedulePreview()
    }

    /// Removes the placed point nearest `point`, if one is within `tolerance` page units.
    ///
    /// The count group's un-place: clicking an existing point with `⌥` removes it. It is a
    /// *point* operation deliberately: a path tool's
    /// vertices are ordered and removing one from the middle changes the shape, so only the
    /// tools whose points are independent placements should offer this.
    ///
    /// - Returns: `true` when a point was removed.
    @discardableResult
    public func removePoint(near point: PDFPointValue, tolerance: Double) -> Bool {
        guard !placedPoints.isEmpty else { return false }
        var bestIndex: Int?
        var bestDistanceSquared = tolerance * tolerance
        for (index, placed) in placedPoints.enumerated() {
            let dx = placed.x - point.x
            let dy = placed.y - point.y
            let distanceSquared = dx * dx + dy * dy
            if distanceSquared <= bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestIndex = index
            }
        }
        guard let bestIndex else { return false }
        placedPoints.remove(at: bestIndex)
        // The sequence list is the fence's index into the point list; an un-place that
        // touched only the points let the next fence slice past the end (CR-2).
        if placedSequences.indices.contains(bestIndex) { placedSequences.remove(at: bestIndex) }
        schedulePreview()
        return true
    }

    /// Commits a count group in progress before the tool, the page or the preset changes.
    ///
    /// Marks whose snap is still resolving are part of the group: the estimator clicked them
    /// before turning the page. They used to die in the queue when the epoch was bumped a line
    /// later, so a count on a heavy vector sheet was recorded one mark short with nothing
    /// said (BH-112). Such a mark lands at the pointer position the click was made at — its
    /// snap has not been computed and waiting for it would block a page turn — which for a
    /// count, whose quantity is the number of marks, loses nothing that is measured.
    private func finishCountInProgress() {
        guard activeKind == .count, boundaryPurpose == nil else { return }
        if !pendingPlacements.isEmpty {
            let fence = commitFenceSequence
            for sequence in pendingPlacements.keys.sorted() where fence.map({ sequence <= $0 }) ?? true {
                if let point = pendingPlacements.removeValue(forKey: sequence) {
                    placedPoints.append(point)
                    placedSequences.append(sequence)
                }
            }
        }
        guard canCommit else { return }
        commitActiveMeasurement()
    }

    public func cancelActiveMeasurement() {
        // A cancelled boundary must tell the panel, or the panel sits in
        // `isAwaitingPolygon` forever with no way out — a dead end, in the one place the
        // person cannot see the mode they are stuck in.
        if boundaryPurpose != nil {
            endBoundaryCapture()
            return
        }
        discardInProgress()
    }

    /// How the geometry now in progress was captured, when a detector placed it (ADR-0031):
    /// set by auto-trace right after it places a traced ring, consumed by the next commit,
    /// cleared with the draft. `nil` — the default — is a person drawing.
    @ObservationIgnored
    public private(set) var pendingCaptureMethod: CaptureMethod?
    /// The points the detector placed, so a point the person adds afterwards makes the capture
    /// theirs: the stamp is honoured only if the committed points are exactly these.
    @ObservationIgnored
    private var pendingCapturePoints: [PDFPointValue] = []

    /// Marks the points now placed as a detector's proposal, captured as `method`.
    public func markPlacedPointsCaptured(as method: CaptureMethod) {
        pendingCaptureMethod = method
        pendingCapturePoints = placedPoints
    }

    public func commitActiveMeasurement() {
        guard canCommit, let kind = activeKind else { return }
        // A boundary is not a measurement: it produces no row, no quantity and no undo
        // entry of its own. The command the panel raises afterwards is what lands on the
        // undo stack, so finishing the polygon and then cancelling the draft leaves the
        // document exactly as it was.
        if let purpose = boundaryPurpose {
            let boundary = placedPoints
            boundaryPurpose = nil
            let page = pageID
            discardInProgress()
            onCommitBoundary?(purpose, boundary, page)
            return
        }
        // A cutout without a parent is not a smaller cutout, it is a different thing: a
        // polygon that subtracts nothing. Refused here, *before* the label is allocated —
        // `nextAutoLabel` bumps the allocator, and a refused cutout used to burn a letter, so
        // the next one read "B" after an "A" nobody could see (CR-16). This is the last line
        // of the rule the canvas enforces at the first click.
        if let continuing = continuingMarkupID {
            // A continuation writes the extended geometry to the same markup (NL-MEASURE-06).
            if let geometry = continuedGeometry() { onCommitContinuation?(continuing, geometry) }
            discardInProgress(bumpingCancelEpoch: false)
            return
        }
        let cutoutParent = kind.isCutout ? cutoutParentID : nil
        if kind.isCutout, cutoutParent == nil { return }
        let tool = Domain.Tool(shown: kind)
        var record = MarkupRecord(
            id: MarkupID(identifiers()),
            documentID: documentID,
            pageID: pageID,
            kind: kind.isCutout ? .polygon : .measurement,
            tool: tool,
            // A new measurement defaults its subject to the tool
            // name, so grouping by subject works out of the box. A subject from the user
            // or an armed tool preset always wins.
            subject: defaultSubject.isEmpty ? kind.displayName : defaultSubject,
            // The "Length A" pattern: a new measurement gets tool name + letter,
            // per tool per page. A user- or preset-supplied label always wins, and the
            // allocator never re-issues a freed letter. A Temporary Measure gets no
            // label — it is not a row, and its tool changes on promotion.
            label: (defaultLabel.isEmpty && !isTemporaryMeasurement)
                ? nextAutoLabel(for: kind, pageID: pageID)
                : defaultLabel,
            author: authorProvider?() ?? author,
            status: isTemporaryMeasurement ? .none : defaultStatus,
            style: committedStyle(for: kind),
            geometry: geometry(for: kind),
            parameters: engineParameters(for: kind, points: placedPoints),
            customValues: isTemporaryMeasurement ? [:] : defaultCustomValues,
            // Only a count carries a symbol. A length with a glyph on it would be a picture
            // nothing draws, and a record that stores a decision no reader honours is the
            // shape of defect this field was added to remove.
            symbol: kind == .count ? countSymbol : nil,
            createdAt: clock(),
            modifiedAt: clock()
        )
        // ADR-0031 (NL-AUTO-18): a geometry a detector proposed and the person
        // accepted says so, and says what the detector assumed. Consumed by this one commit.
        if let method = pendingCaptureMethod, !isTemporaryMeasurement, placedPoints == pendingCapturePoints {
            record = CaptureStamp.stamped(record, method: method)
        }
        pendingCaptureMethod = nil
        if isTemporaryMeasurement {
            // A Temporary Measure never becomes a row. It is kept in the overlay until the
            // user promotes it or clears it (spec 12.14), so it cannot silently join a
            // total the estimator did not ask for.
            temporaryRecords.append(record)
            temporaryMeasurements.append(
                MarkupBridge.summary(
                    of: record,
                    names: .empty,
                    formatter: displayFormatter(units)
                )
            )
            measureTemporary(record)
        } else if let cutoutParent {
            onCommitCutout?(cutoutParent, record)
        } else {
            onCommit?(record)
        }
        discardInProgress(bumpingCancelEpoch: false)
    }

    /// Measures a committed tape so it keeps its reading on screen (L-104).
    ///
    /// The record goes into the overlay without a measurement — the session never computes one
    /// for a Temporary Measure, it is not a row — so its summary had no fields and the canvas's
    /// "the value, small and unboxed" beside the tape drew nothing once the live readout was
    /// gone. The engine is asked once, for the committed geometry (never the cursor), and the
    /// summary is rebuilt in the session's locale.
    private func measureTemporary(_ record: MarkupRecord) {
        guard let tool = record.tool, let geometry = record.geometry else { return }
        let id = record.id
        let parameters = record.parameters ?? .default
        let previous = temporaryMeasureTask
        temporaryMeasureTask = Task { [weak self, session] in
            await previous?.value
            let result = await session.preview(tool: tool, geometry: geometry, parameters: parameters)
            guard let self, let result,
                  let index = self.temporaryRecords.firstIndex(where: { $0.id == id }) else { return }
            self.temporaryRecords[index].measurement = result
            let summary = MarkupBridge.summary(
                of: self.temporaryRecords[index], names: .empty, formatter: self.displayFormatter(self.units)
            )
            if let shown = self.temporaryMeasurements.firstIndex(where: { $0.id == id.rawValue }) {
                self.temporaryMeasurements[shown] = summary
            }
        }
    }

    /// Waits for the tape measurements in flight. A test seam, like ``settlePreviewsForTesting()``.
    public func settleTemporaryMeasurementsForTesting() async {
        await temporaryMeasureTask?.value
    }

    /// Turns the accumulated Temporary Measures into real markups.
    ///
    /// They go out through ``onCommit``, one command each, so promoting is undoable — a
    /// user who promotes twenty scratch measurements by accident gets them back.
    public func promoteTemporaryMeasurementsToMarkups() {
        let records = temporaryRecords
        temporaryRecords = []
        temporaryMeasurements = []
        for record in records {
            var promoted = record
            promoted.tool = Self.promotedTool(for: record.geometry)
            promoted.kind = .measurement
            if promoted.label.isEmpty {
                let shown = Shown.Kind(domain: promoted.tool ?? .polylength)
                promoted.label = nextAutoLabel(for: shown, pageID: promoted.pageID)
            }
            onCommit?(promoted)
        }
    }

    /// The tool a promoted Temporary Measure becomes.
    ///
    /// `temporaryMeasure` is the omnivorous tool: it measures whatever geometry it is
    /// handed. A stored markup cannot be, because its tool is what the ledger reads its
    /// quantity from — so promotion picks the tool that matches the shape the user actually
    /// drew, rather than keeping a tool that spec 12.14 says is never stored.
    static func promotedTool(for geometry: MeasurementGeometry?) -> Domain.Tool {
        guard let geometry else { return .polylength }
        if !geometry.countPoints.isEmpty { return .count }
        if !geometry.polygons.isEmpty { return .area }
        if !geometry.circles.isEmpty { return .radius }
        if !geometry.arcs.isEmpty { return .arcLength }
        return .polylength
    }

    public func clearTemporaryMeasurements() {
        temporaryRecords = []
        temporaryMeasurements = []
    }

    public func setLengthUnit(_ unit: ZPDFUIPresentation.LengthUnit) {
        lengthUnit = unit
        reformatLiveFields()
    }

    public func setAreaUnit(_ unit: ZPDFUIPresentation.AreaUnit) {
        areaUnit = unit
        reformatLiveFields()
    }

    public func setVolumeUnit(_ unit: ZPDFUIPresentation.VolumeUnit) {
        volumeUnit = unit
        reformatLiveFields()
    }

    public func setSlopeDisplayMode(_ mode: SlopeDisplayMode) {
        slopeDisplayMode = mode
        reformatLiveFields()
    }

    public func setImperialPrecision(_ precision: ImperialPrecision) {
        imperialPrecision = precision
        reformatLiveFields()
    }

    // MARK: Live preview

    /// Moves the live cursor and recomputes the running value from it.
    ///
    /// `nil` when the pointer leaves the page, which drops the cursor out of the preview so
    /// the readout falls back to the placed points alone.
    public func updateLiveCursor(_ point: PDFPointValue?) {
        guard liveCursorPoint != point else { return }
        liveCursorPoint = point
        schedulePreview()
    }

    /// The points the live preview measures: the placed vertices plus the cursor.
    ///
    /// For the one-gesture rectangle tool the anchor and the cursor are opposite corners, so
    /// the preview expands them to the four corners the commit will produce — the value the
    /// user watches during the drag is the value that lands in the ledger. For the
    /// three-point rectangle with its edge placed, the cursor is the depth point and the
    /// preview is the inferred quadrilateral `P1 P2 cursor P4` with `P4 = P1 + cursor − P2`
    /// — a running area from the second point on.
    func previewPoints() -> [PDFPointValue] {
        guard let cursor = liveCursorPoint, let kind = activeKind, !placedPoints.isEmpty else {
            return placedPoints
        }
        if kind == .rectangleArea, placedPoints.count == 1, let anchor = placedPoints.first {
            return Self.rectangleCorners(anchor: anchor, opposite: cursor)
        }
        if kind == .rectangleArea, placedPoints.count == 2 {
            return Self.inferredQuadrilateral(
                edgeStart: placedPoints[0],
                edgeEnd: placedPoints[1],
                depth: cursor
            )
        }
        return placedPoints + [cursor]
    }

    /// The inferred quadrilateral of the three-point rectangle: the placed edge, the depth
    /// point, and the derived fourth corner, in drawing order. Shared by the live preview
    /// and the commit so the number the user watched is the number the ledger gets.
    public static func inferredQuadrilateral(
        edgeStart: PDFPointValue,
        edgeEnd: PDFPointValue,
        depth: PDFPointValue
    ) -> [PDFPointValue] {
        [
            edgeStart,
            edgeEnd,
            depth,
            PDFPointValue(x: edgeStart.x + depth.x - edgeEnd.x, y: edgeStart.y + depth.y - edgeEnd.y)
        ]
    }

    /// The four corners of an axis-aligned rectangle from two opposite corners, in drawing
    /// order. Shared by the drag preview and the drag commit so they cannot disagree.
    public static func rectangleCorners(
        anchor: PDFPointValue,
        opposite: PDFPointValue
    ) -> [PDFPointValue] {
        [
            anchor,
            PDFPointValue(x: opposite.x, y: anchor.y),
            opposite,
            PDFPointValue(x: anchor.x, y: opposite.y)
        ]
    }

    /// Appends points without another snap resolve — the drag commit path, where the corner
    /// points are derived from two already-snapped corners.
    public func appendRawPoints(_ points: [PDFPointValue]) {
        guard activeKind != nil else { return }
        // An arc's through point still resolving (NL-MEASURE-05): the raw end of the arc waits
        // behind it in the placement chain, so the arc bends through the point that was clicked
        // first. Tracked as in flight, so the canvas does not resynchronise past it.
        if pendingArcThroughSequence != nil, let first = points.first {
            pointerSequence &+= 1
            let sequence = pointerSequence
            pendingPlacements[sequence] = first
            let epoch = cancelEpoch
            let previous = placementTask
            placementGeneration &+= 1
            placementTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, self.pendingPlacements.removeValue(forKey: sequence) != nil,
                      self.cancelEpoch == epoch, self.activeKind != nil else { return }
                self.appendRawNow(points, sequence: sequence)
            }
            return
        }
        appendRawNow(points, sequence: pointerSequence)
    }

    /// Appends raw points at once; the first may end an arc segment.
    private func appendRawNow(_ points: [PDFPointValue], sequence: Int) {
        if let first = points.first { bendArcSegment(endingAt: first) }
        placedPoints.append(contentsOf: points)
        // Raw points are placed "now": they belong to whatever fence comes next (CR-2).
        placedSequences.append(contentsOf: points.map { _ in sequence })
        schedulePreview()
    }

    /// The geometry the armed tool would measure from the points placed so far, with the arc
    /// segments drawn so far (ADR-0030 §5.6) — the geometry a commit stores.
    public func geometry(for kind: Shown.Kind) -> MeasurementGeometry {
        committedGeometry(for: kind)
    }

    /// The stored style a committed measurement carries: the
    /// active stroke colour, and for tools whose outline closes — the same set that
    /// produces polygon geometry, plus the ellipse area — a fill of that colour at
    /// ~18 % alpha. Existing stored markups keep their stored style untouched.
    func committedStyle(for kind: Shown.Kind) -> MarkupStyle {
        switch kind {
        case .area, .rectangleArea, .ellipseArea, .trueSlopedArea, .volume, .wallArea,
             .perimeter, .polygonCutout, .ellipseCutout:
            return MarkupStyle(color: color, fill: Self.measurementFill(for: color))
        case .length:
            // A new Length is drawn dashed. A default for new
            // measurements only: stored ones keep the line style they were committed with.
            return MarkupStyle(color: color, lineStyle: .dashed)
        default:
            return MarkupStyle(color: color)
        }
    }

    /// The geometry a tool would measure from an explicit point list.
    ///
    /// - Parameter bulges: arc segments (ADR-0030 §5.6), one per point: a ring's last entry bends
    ///   its closing edge, a chain's last is ignored. `nil` is every edge straight.
    private func geometry(for kind: Shown.Kind, from source: [PDFPointValue], bulges: [Double]? = nil) -> MeasurementGeometry {
        let points = source.map { PDFPoint(shown: $0) }
        let aligned = bulges.flatMap { $0.count == points.count && $0.contains { $0 != 0 } ? $0 : nil }
        switch kind {
        case .area, .rectangleArea, .trueSlopedArea, .volume, .wallArea, .perimeter,
             .polygonCutout, .ellipseCutout:
            guard points.count >= 3 else {
                return MeasurementGeometry(pageID: pageID, points: points, pointBulges: aligned)
            }
            return MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: points, isClosed: true, bulges: aligned))]
            )
        case .count:
            return MeasurementGeometry(
                pageID: pageID,
                countPoints: points.map { CountPoint(id: CountPointID(identifiers()), position: $0) }
            )
        default:
            return MeasurementGeometry(pageID: pageID, points: points, pointBulges: aligned)
        }
    }

    /// Recomputes the live readout for the points placed so far.
    ///
    /// Superseding rather than queued: a user dragging a polyline generates a preview per
    /// point, and only the newest one is worth drawing.
    public func schedulePreview() {
        previewTask?.cancel()
        refreshCutoutOverlap()
        guard let kind = activeKind, !placedPoints.isEmpty else {
            liveFields = []
            // Removing the last point leaves the tool armed on the same sheet, so a sheet-wide
            // refusal stays said (L-102).
            liveWarnings = withUniformScaleRefusal([])
            return
        }
        let tool = Domain.Tool(shown: kind)
        let points = previewPoints()
        let geometry = self.geometry(for: kind, from: points, bulges: previewBulges(count: points.count))
        let parameters = engineParameters(for: kind, points: points)
        let units = self.units
        // The scale the commit will measure with: a Scale Region's when the shape lies wholly
        // inside one (L-102 — a circle inside a uniform detail on an X/Y sheet had no live value).
        let scaleID = boundaryPurpose == nil ? scaleCoverage.regionScaleID(for: geometry, tool: tool) : nil
        scheduleArcSegmentPreview(units: units)
        previewTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.session.preview(
                tool: tool,
                geometry: geometry,
                parameters: parameters,
                scaleID: scaleID
            )
            guard !Task.isCancelled else { return }
            self.applyPreview(result, tool: tool, units: units)
        }
    }

    /// Installs a preview result.
    public func applyPreview(_ result: MeasurementResult?, tool: Domain.Tool, units: DisplayUnitSelection) {
        guard let result else {
            liveFields = []
            // No scale means no number, and saying so is the point: an unscaled drawing
            // must not produce a plausible-looking figure (spec 10.2).
            //
            // Count is the exception, and it is not a loophole: a count is a number of
            // *things*, not a number of metres, so no scale can be missing from it.
            // `.missingScale` is a blocking warning, so leaving it on a count made the
            // whole group vanish on commit with nothing said — a silent failure, on the one
            // tool that never needed a scale.
            liveWarnings = withUniformScaleRefusal(withCutoutOverlap((activeScale == nil && activeKind != .count) ? [.missingScale] : []))
            return
        }
        let formatter = displayFormatter(units)
        liveFields = MarkupBridge.fields(of: result, tool: tool, formatter: formatter)
        liveWarnings = withUniformScaleRefusal(withCutoutOverlap(MarkupBridge.warnings(of: result)))
    }

    // MARK: Cutout overlap (X-cutout-ui)

    /// What the overlap verdict was computed from.
    private struct CutoutOverlapBasis: Equatable {
        let tool: Domain.Tool
        let parentID: MarkupID
        let parentRing: PolygonRing
        let geometry: MeasurementGeometry
    }

    /// The two live warnings the overlap verdict owns.
    private static let cutoutOverlapWarnings: Set<MeasurementWarningSummary> = [.cutoutOutsideParent, .cutoutDoesNotOverlapParent]

    /// `warnings` with the overlap verdict of the cutout in progress in place of any earlier one.
    ///
    /// The engine accepts a cutout that only partly overlaps its area and subtracts the part
    /// inside, and refuses one that overlaps nothing (ADR-0015). The interface used to decide
    /// this with containment geometry of its own, stricter than the engine's, and refused the
    /// partial overlap at the click (X-cutout-ui). The verdict here is the engine's
    /// (``CutoutOverlapJudge``), on the geometry this presenter commits and the parent's stored
    /// ring: a partial overlap shows the informing `cutoutOutsideParent`, no overlap the blocking
    /// `cutoutDoesNotOverlapParent`, which keeps Finish from sending a cutout the engine would
    /// refuse and gives the refusal its words.
    private func withCutoutOverlap(_ warnings: [MeasurementWarningSummary]) -> [MeasurementWarningSummary] {
        var composed = warnings.filter { !Self.cutoutOverlapWarnings.contains($0) }
        if let verdict = cutoutOverlapWarning { composed.append(verdict) }
        return composed
    }

    /// Recomputes the overlap verdict when the cutout or its parent changed, and shows it at once
    /// rather than after the next preview.
    private func refreshCutoutOverlap() {
        var basis: CutoutOverlapBasis?
        if let kind = activeKind, kind.isCutout, boundaryPurpose == nil,
           let outline = cutoutParentOutline, outline.id == cutoutParentID,
           placedPoints.count >= kind.minimumPointCount {
            basis = CutoutOverlapBasis(
                tool: Domain.Tool(shown: kind),
                parentID: outline.id,
                parentRing: outline.ring,
                geometry: committedGeometry(for: kind)
            )
        }
        if basis != cutoutOverlapBasis {
            cutoutOverlapBasis = basis
            cutoutOverlapWarning = basis.flatMap { basis -> MeasurementWarningSummary? in
                switch CutoutOverlapJudge.overlap(cutout: basis.geometry, tool: basis.tool, parentOuter: basis.parentRing) {
                case .disjoint?: return .cutoutDoesNotOverlapParent
                case .partial?: return .cutoutOutsideParent
                case .contained?, nil: return nil
                }
            }
        }
        let shown = withCutoutOverlap(liveWarnings)
        if shown != liveWarnings { liveWarnings = shown }
    }

    /// Fetches the parent's stored outer ring for the overlap verdict, then refreshes it.
    private func loadCutoutParentOutline() {
        cutoutParentOutlineTask?.cancel()
        cutoutParentOutline = nil
        guard let id = cutoutParentID else {
            cutoutParentOutlineTask = nil
            refreshCutoutOverlap()
            return
        }
        cutoutParentOutlineTask = Task { [weak self, session] in
            let ring = await session.markup(id)?.geometry?.polygons.first?.outer
            guard let self, !Task.isCancelled, self.cutoutParentID == id else { return }
            self.cutoutParentOutline = ring.map { (id: id, ring: $0) }
            self.refreshCutoutOverlap()
        }
    }

    /// Waits for the parent outline in flight. A test seam, like ``settlePreviewsForTesting()``.
    public func settleCutoutParentForTesting() async {
        await cutoutParentOutlineTask?.value
    }

    /// Re-renders the live fields after a unit change, without asking the engine again:
    /// the raw SI quantity travels with every field precisely so this is possible.
    private func reformatLiveFields() {
        let formatter = displayFormatter(units)
        liveFields = liveFields.map { field in
            var updated = field
            if field.field == .slopeRatio {
                updated.displayText = formatter.slopeText(ratio: field.quantity.value)
                updated.displayUnitSymbol = ""
            } else {
                updated.displayText = formatter.text(field.quantity)
                updated.displayUnitSymbol = formatter.symbol(field.quantity)
            }
            return updated
        }
    }

    private func discardInProgress(bumpingCancelEpoch: Bool = true) {
        // The parent belongs to the shape being drawn, not to the tool: the next cutout
        // resolves its own from its own first click.
        cutoutParentID = nil
        // So is how it was captured (ADR-0031): an abandoned trace leaves no stamp behind.
        pendingCaptureMethod = nil
        previewTask?.cancel()
        previewTask = nil
        placementTask?.cancel()
        placementTask = nil
        placementGeneration &+= 1
        // A commit's own discard must NOT bump: placements issued after Finish are the
        // next measurement's, and they are still in flight. A cancel-shaped discard kills
        // the fence carry too — points aimed at a measurement the user just threw away
        // must not resurrect into the next one.
        if bumpingCancelEpoch {
            cancelEpoch &+= 1
            carryAfterFence = []
            commitFences = []
            // A Finish waiting its turn finds its fence gone and stops waiting.
            resumeCommitFenceWaiters()
            pendingPlacements = [:]
        }
        placedPoints = []
        placedSequences = []
        placedArcBulges = [:]
        isArcNextSegment = false
        arcThroughPoint = nil
        pendingArcThroughSequence = nil
        liveArcSegmentField = nil
        arcPreviewTask?.cancel()
        arcPreviewTask = nil
        continuingMarkupID = nil
        continuationBase = nil
        liveCursorPoint = nil
        liveFields = []
        // A cancel leaves the tool armed on the same sheet, so its refusal stays said (L-102).
        liveWarnings = withUniformScaleRefusal([])
        snapFeedback = nil
        onSnapFeedback?(nil)
        Task { [session] in await session.resetSnapState() }
    }
}

// MARK: - Input-flow seams (IM-019)

extension AppMeasurementToolPresenter: CountPointEditing {

    /// Removes the count mark at `index`, the ⌥-click un-place of a count, as the input
    /// state machine decides it.
    ///
    /// The index is a position in ``placedPoints``. Out of range, or on a tool whose points are
    /// a path rather than independent marks, it does nothing: removing a vertex from the middle
    /// of a polyline changes the shape, which is not what the gesture means.
    public func removePoint(at index: Int) {
        guard activeKind == .count, placedPoints.indices.contains(index) else { return }
        placedPoints.remove(at: index)
        // The sequence list is the fence's index into the point list (CR-2).
        if placedSequences.indices.contains(index) { placedSequences.remove(at: index) }
        schedulePreview()
    }
}

extension AppMeasurementToolPresenter: CutoutCommitting {

    /// Commits the cutout in progress as a hole in `parentMarkupID`.
    ///
    /// The parent is recorded and the ordinary commit runs, which routes a cutout through
    /// ``onCommitCutout`` — `DocumentCommand.addCutout`, never `.addMarkup` — and refuses the
    /// commit, as it always has, when the geometry cannot be committed. On a tool that is not
    /// a cutout it does nothing: a length must never become a hole because a caller said so.
    public func commitActiveCutout(parentMarkupID: UUID) {
        guard let kind = activeKind, kind.isCutout else { return }
        cutoutParentID = MarkupID(parentMarkupID)
        commitActiveMeasurement()
    }
}

// MARK: - Arc segments while drawing (NL-MEASURE-05, ADR-0030 §5.6)

extension AppMeasurementToolPresenter: ArcSegmentDrawing {

    /// Whether A can arm an arc right now (``ArcSegmentDrawing``): not during a Scale Region or
    /// Project Zone boundary capture, whose edges are straight (ADR-0030 §5.7).
    public var drawsArcSegments: Bool { armedToolDrawsArcs }

    /// Whether the armed tool's segments can be arcs: the chain and one-ring area tools, and the
    /// Polygon Cutout, whose hole the engine subtracts on its arcs (ADR-0037, C-08).
    var armedToolDrawsArcs: Bool {
        guard let activeKind, boundaryPurpose == nil else { return false }
        switch activeKind {
        case .length, .polylength, .perimeter, .area, .volume, .wallArea, .trueSlopedArea, .polygonCutout:
            return true
        default:
            return false
        }
    }

    public func setArcNextSegment(_ isArc: Bool) {
        guard armedToolDrawsArcs, !placedPoints.isEmpty || !isArc || hasPlacementsInFlight else {
            isArcNextSegment = false
            arcThroughPoint = nil
            return
        }
        isArcNextSegment = isArc
        arcThroughPoint = nil
        pendingArcThroughSequence = nil
        schedulePreview()
    }

    /// Places the arc's through point, snapped on the session like a vertex and queued behind
    /// the vertices already clicked, so it lands after the vertex it hangs from.
    public func placeArcThroughPoint(_ point: PDFPointValue) {
        placeArcThroughPoint(point, snapping: true)
    }

    /// Places the arc's through point; `snapping: false` stores it exactly as given — a typed or
    /// Shift-held point, which the canvas stores raw for a vertex too.
    public func placeArcThroughPoint(_ point: PDFPointValue, snapping: Bool) {
        guard armedToolDrawsArcs, isArcNextSegment else { return }
        guard snapping else {
            if placementTask == nil || !hasPlacementsInFlight {
                pendingArcThroughSequence = nil
                arcThroughPoint = point
                schedulePreview()
                return
            }
            // Behind a vertex still resolving: queue, so the order of clicks is kept.
            pointerSequence &+= 1
            let sequence = pointerSequence
            pendingArcThroughSequence = sequence
            let epoch = cancelEpoch
            let previous = placementTask
            placementGeneration &+= 1
            placementTask = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, self.pendingArcThroughSequence == sequence else { return }
                self.pendingArcThroughSequence = nil
                guard self.cancelEpoch == epoch, self.isArcNextSegment else { return }
                self.arcThroughPoint = point
                self.schedulePreview()
            }
            return
        }
        pointerSequence &+= 1
        let sequence = pointerSequence
        pendingArcThroughSequence = sequence
        let pageID = self.pageID
        let layout = self.layout
        let cursor = PDFPoint(shown: point)
        let modifiers = snapModifiers
        let excluded = snapExclusions?() ?? []
        let epoch = cancelEpoch
        let previous = placementTask
        placementGeneration &+= 1
        placementTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let anchor = self.placedPoints.last.map { PDFPoint(shown: $0) }
            let resolution = try? await self.session.resolveSnap(
                pageID: pageID,
                pagePoint: cursor,
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchor,
                sequence: sequence,
                excludingMarkupIDs: excluded
            )
            guard self.pendingArcThroughSequence == sequence else { return }
            self.pendingArcThroughSequence = nil
            guard self.cancelEpoch == epoch, self.isArcNextSegment else { return }
            self.arcThroughPoint = resolution.map { PDFPointValue(domain: $0.resolvedPagePoint) } ?? point
            self.schedulePreview()
        }
    }

    public func removeArcThroughPoint() {
        pendingArcThroughSequence = nil
        arcThroughPoint = nil
        schedulePreview()
    }

    /// Bends the edge from the last placed point to `end` through the arc's through point, and
    /// makes the next segment straight again. Nothing happens without a through point, and a
    /// through point on the chord leaves the edge straight.
    func bendArcSegment(endingAt end: PDFPointValue) {
        guard isArcNextSegment, let through = arcThroughPoint, let last = placedPoints.last else { return }
        if let bulge = MarkupTopologyEditing.bulge(from: PDFPoint(shown: last), to: PDFPoint(shown: end), through: PDFPoint(shown: through)),
           bulge != 0, bulge.isFinite {
            placedArcBulges[placedPoints.count - 1] = bulge
        }
        isArcNextSegment = false
        arcThroughPoint = nil
    }

    /// Forgets the arcs of every edge that starts at index `first` or later.
    func dropArcBulges(from first: Int) {
        placedArcBulges = placedArcBulges.filter { $0.key < Swift.max(0, first) }
    }

    /// One bulge per point for a chain of `count` points, or `nil` when every edge is straight.
    func chainBulges(count: Int) -> [Double]? {
        guard count >= 2, !placedArcBulges.isEmpty else { return nil }
        let bulges = (0..<count).map { $0 < count - 1 ? (placedArcBulges[$0] ?? 0) : 0 }
        return bulges.contains { $0 != 0 } ? bulges : nil
    }

    /// The bulges of the live preview's `count` points: the placed arcs, and the segment to the
    /// pointer bent through the through point while an arc is being drawn.
    func previewBulges(count: Int) -> [Double]? {
        guard armedToolDrawsArcs, count >= 2 else { return nil }
        var bulges = (0..<count).map { placedArcBulges[$0] ?? 0 }
        if let cursor = liveCursorPoint, count == placedPoints.count + 1,
           let segment = liveArcBulge(to: cursor) {
            bulges[count - 2] = segment
        }
        bulges[count - 1] = 0
        return bulges.contains { $0 != 0 } ? bulges : nil
    }

    /// The bulge of the arc from the last placed point through the through point to `end`.
    func liveArcBulge(to end: PDFPointValue) -> Double? {
        guard isArcNextSegment, let through = arcThroughPoint, let last = placedPoints.last,
              let bulge = MarkupTopologyEditing.bulge(from: PDFPoint(shown: last), to: PDFPoint(shown: end), through: PDFPoint(shown: through)),
              bulge != 0, bulge.isFinite else { return nil }
        return bulge
    }

    /// The geometry the commit stores: the placed points with their arcs, and for a ring whose
    /// closing click came with a through point placed, the closing edge bent through it.
    func committedGeometry(for kind: Shown.Kind) -> MeasurementGeometry {
        guard armedToolDrawsArcs, placedPoints.count >= 2 else { return geometry(for: kind, from: placedPoints) }
        var bulges = (0..<placedPoints.count).map { placedArcBulges[$0] ?? 0 }
        switch kind {
        case .length, .polylength:
            bulges[bulges.count - 1] = 0
        default:
            // The closing edge: last point back to the first.
            if placedPoints.count >= 3, isArcNextSegment, let through = arcThroughPoint, let first = placedPoints.first, let last = placedPoints.last,
               let closing = MarkupTopologyEditing.bulge(from: PDFPoint(shown: last), to: PDFPoint(shown: first), through: PDFPoint(shown: through)),
               closing.isFinite {
                bulges[bulges.count - 1] = closing
            }
        }
        return geometry(for: kind, from: placedPoints, bulges: bulges)
    }

    /// Waits for the live previews in flight — the running value and the arc's length. A test
    /// seam: the canvas never waits for a preview.
    public func settlePreviewsForTesting() async {
        await previewTask?.value
        await arcPreviewTask?.value
    }

    /// The live length of the arc segment in progress, measured by the engine as a one-edge
    /// length with its bulge — `r·θ` at the page's scale — for the pill.
    func scheduleArcSegmentPreview(units: DisplayUnitSelection) {
        arcPreviewTask?.cancel()
        guard let cursor = liveCursorPoint, let last = placedPoints.last, let bulge = liveArcBulge(to: cursor) else {
            liveArcSegmentField = nil
            return
        }
        let geometry = MeasurementGeometry(
            pageID: pageID,
            points: [PDFPoint(shown: last), PDFPoint(shown: cursor)],
            pointBulges: [bulge, 0]
        )
        // The arc's own scale, a Scale Region's inside one, like the shape's live value.
        let scaleID = scaleCoverage.regionScaleID(for: geometry, tool: .length)
        arcPreviewTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.session.preview(tool: .length, geometry: geometry, parameters: .default, scaleID: scaleID)
            guard !Task.isCancelled else { return }
            let formatter = displayFormatter(units)
            self.liveArcSegmentField = result.flatMap {
                MarkupBridge.fields(of: $0, tool: .length, formatter: formatter).first { $0.field == .planLength }
            }
        }
    }
}
