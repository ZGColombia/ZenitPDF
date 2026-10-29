import Foundation
import Observation
import ZPDFContracts
import ZPDFUIPresentation

/// The markup family's counterpart to ``AppMeasurementToolPresenter``: Text, Callout and
/// the seven Shapes.
///
/// It is a sibling, not a subclass and not a second door. It collects page points exactly
/// as the measurement presenter does, and it commits through the **same** `onCommit`
/// closure, which `AppCoreEnvironment` routes to `DocumentCommandBus.perform(.addMarkup)`.
/// That is what buys undo in one `⌘Z`, a History entry, the audit trail and survival
/// through save → reopen without a line of new plumbing for any of them.
///
/// Two things it deliberately does **not** do:
///
/// - **No snap resolve.** A shape is placed where the user put it. Snapping a callout's
///   text box onto a wall corner would be a surprise, not a service; measurement points
///   snap because their *number* depends on it, and a markup has no number.
/// - **No ledger row.** `MarkupKind.producesQuantity` is false for every kind here and the
///   record carries no `tool`, so the engine never computes a quantity for it. A row
///   appears only once the user gives the markup a subject, and
///   `TakeoffSession.ledgerMarkups` is where the decision is made.
@MainActor
@Observable
public final class AppMarkupToolPresenter {

    // MARK: Published state

    /// The armed markup kind, or `nil`.
    public private(set) var activeKind: Shown.Markup?
    /// The points placed so far, in page space.
    public private(set) var placedPoints: [PDFPointValue] = []
    /// The pointer, in page space, while the tool is armed — the rubber band's far end.
    public private(set) var liveCursorPoint: PDFPointValue?
    /// The text being typed into a Text or Callout box, before it is committed.
    public private(set) var draftText: String = ""
    /// The style the next committed markup takes.
    public private(set) var style: ToolStyleSelection = .zenitInk
    /// The armed variant — the highlighter, the clouded callout — or `nil` (round 2).
    public private(set) var variant: MarkupToolVariant?
    /// How far a sampled freehand point may stray from the simplified stroke, in page points.
    /// The canvas sets it from the zoom (half a view point); the default suits 100 %.
    public var freehandTolerance: Double = 0.5

    /// Called with the record to add. `AppCoreEnvironment` routes it through the command
    /// bus, so a markup lands on the undo stack like every other document mutation.
    public var onCommit: (@MainActor (MarkupRecord) -> Void)?

    // MARK: Private state

    private let identifiers: @Sendable () -> UUID
    private let clock: @Sendable () -> Date
    private(set) var pageID: PageID
    private var documentID: DocumentID

    /// Resolved at commit time so a Settings change signs the next markup.
    public var authorProvider: (@MainActor () -> String)?
    /// The subject a committed markup takes. Empty by default, which is what keeps a shape
    /// out of the Quantity Ledger until the user classifies it.
    public var defaultSubject: String = ""
    /// The label, status and custom ledger column values a committed markup takes, from the
    /// armed tool preset — the rest of what a preset says about its row, which Place and Apply
    /// always wrote and a hand-drawn cloud, rectangle or text dropped (W-030, the markup half of
    /// BH-085). Custom values arrive resolved against the document's columns by
    /// ``AppCoreEnvironment``; all three are cleared with the subject whenever nothing is armed.
    public var defaultLabel: String = ""
    public var defaultStatus: Domain.Status = .none
    public var defaultCustomValues: [ColumnID: Domain.CellValue] = [:]

    /// Creates a presenter.
    public init(
        documentID: DocumentID,
        pageID: PageID,
        identifiers: @escaping @Sendable () -> UUID = { UUID() },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.documentID = documentID
        self.pageID = pageID
        self.identifiers = identifiers
        self.clock = clock
    }

    // MARK: Arming

    /// Arms a markup tool. Re-arming the same kind keeps whatever is in progress.
    public func activate(kind: Shown.Markup, style: ToolStyleSelection, variant: MarkupToolVariant? = nil) {
        if activeKind != kind || self.variant != variant { discardInProgress() }
        activeKind = kind
        self.variant = variant?.kind == kind ? variant : nil
        self.style = style
    }

    /// Disarms, discarding anything half-drawn — except a text box being typed, which is
    /// **committed**, as clicking away and Escape commit it (L-10).
    ///
    /// The count rule's twin (`AppMeasurementToolPresenter.deactivate()`): typed words are a
    /// whole answer, a half-dragged shape is not. It matters since a toolbar pick disarms the
    /// armed Tool Library preset first (X-018): that disarm reaches here before the canvas
    /// commits its open text box, and discarding then threw away a note typed under a Text or
    /// Callout preset. The commit runs before the preset's row defaults are put down, so the
    /// note keeps the subject, label, status and ledger values of the preset it was typed with.
    /// Empty text still discards the box.
    public func deactivate() {
        if let kind = activeKind, Self.typedKinds.contains(kind), canCommit { _ = commit() }
        discardInProgress()
        activeKind = nil
        variant = nil
    }

    /// The kinds whose markup in progress is a text box being typed.
    static let typedKinds: Set<Shown.Markup> = [.text, .callout, .note]

    /// Adds one sampled point to a freehand stroke, skipping a sample closer than a tenth of a
    /// point to the last one (a stationary pointer would otherwise pile up duplicates).
    public func appendFreehandPoint(_ point: PDFPointValue) {
        guard activeKind == .freehand else { return }
        if let last = placedPoints.last, last.distance(to: point) < 0.1 { return }
        placedPoints.append(point)
    }

    /// Moves the tool to a different page, discarding a markup half-drawn on the old one.
    public func setPage(_ pageID: PageID) {
        guard self.pageID != pageID else { return }
        discardInProgress()
        self.pageID = pageID
    }

    /// Adopts the document identity from a snapshot.
    public func adopt(documentID: DocumentID) {
        self.documentID = documentID
    }

    // MARK: Input

    /// Places one vertex.
    public func placePoint(_ point: PDFPointValue) {
        guard activeKind != nil else { return }
        placedPoints.append(point)
    }

    /// Replaces every placed vertex — the drag path, where the release derives the shape.
    public func setPoints(_ points: [PDFPointValue]) {
        guard activeKind != nil else { return }
        placedPoints = points
    }

    /// Removes the last vertex, if any.
    public func removeLastPoint() {
        guard !placedPoints.isEmpty else { return }
        placedPoints.removeLast()
    }

    /// Moves the rubber band's far end.
    public func updateLiveCursor(_ point: PDFPointValue?) {
        liveCursorPoint = point
    }

    /// Replaces the text being typed into a Text or Callout box.
    public func setDraftText(_ text: String) {
        draftText = text
    }

    /// Throws away the markup in progress.
    public func cancel() {
        discardInProgress()
    }

    // MARK: Commit

    /// Whether there is enough placed to commit.
    ///
    /// Text and Callout add one condition the shapes do not have: **empty text discards the
    /// markup rather than leaving an invisible one**.
    public var canCommit: Bool {
        guard let activeKind else { return false }
        guard placedPoints.count >= Self.minimumPointCount(for: activeKind) else { return false }
        if Self.typedKinds.contains(activeKind) {
            return !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// The fewest points each markup kind needs. Mirrors `ZenitToolMode.gesture`, which
    /// lives in the measurement UI package the app-core tier does not link.
    static func minimumPointCount(for kind: Shown.Markup) -> Int {
        switch kind {
        case .text: return 1
        case .callout: return 2
        case .line, .arrow, .rectangle, .ellipse, .polyline: return 2
        case .polygon, .cloud: return 3
        case .freehand, .hyperlink: return 2
        case .note: return 1
        default: return .max
        }
    }

    /// Commits the markup in progress, if it can be committed.
    ///
    /// - Returns: the record that was sent, or `nil` when nothing was committable — which
    ///   is the empty-text discard, stated as a value rather than as silence.
    @discardableResult
    public func commit() -> MarkupRecord? {
        guard canCommit, let kind = activeKind else {
            discardInProgress()
            return nil
        }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        var points = placedPoints
        if kind == .freehand {
            points = Self.simplified(points, tolerance: freehandTolerance)
        }
        let geometry: MeasurementGeometry
        if variant == .cloudedCallout, points.count >= 2 {
            geometry = Self.cloudedCalloutGeometry(points: points, hasText: !text.isEmpty, pageID: pageID)
        } else {
            geometry = Self.geometry(kind: kind, points: points, pageID: pageID)
        }
        let isNote = kind == .note
        let record = MarkupRecord(
            id: MarkupID(identifiers()),
            documentID: documentID,
            pageID: pageID,
            kind: Domain.Kind(shown: kind),
            // No `tool`: a markup is not a measurement, and a `tool` is exactly what makes
            // `TakeoffSession.recompute` try to put a number on it.
            tool: nil,
            subject: defaultSubject,
            label: defaultLabel,
            // NL-COLLAB-18: the typed string is what the box *draws*, so it lives in
            // `caption` (see `MarkupVisibleText`). `comment` is the review note and starts
            // empty; a note written later no longer rewrites the words on the sheet.
            // A note's words are its note (NL-MARKUP-17): it draws an icon, not text.
            comment: isNote ? text : "",
            author: authorProvider?() ?? "",
            status: defaultStatus,
            style: Self.markupStyle(kind: kind, style: style),
            caption: isNote || text.isEmpty && kind == .cloud ? nil : text,
            geometry: geometry,
            customValues: defaultCustomValues,
            createdAt: clock(),
            modifiedAt: clock()
        )
        onCommit?(record)
        discardInProgress()
        return record
    }

    // MARK: Geometry and style

    /// The stored geometry for one markup kind, following `ZenitMarkupGeometry`'s schema.
    ///
    /// `static` and pure so the canvas renderer can be tested against the same function
    /// that produced the record.
    public static func geometry(
        kind: Shown.Markup,
        points: [PDFPointValue],
        pageID: PageID
    ) -> MeasurementGeometry {
        let domainPoints = points.map { PDFPoint(x: $0.x, y: $0.y) }
        switch kind {
        case .rectangle:
            guard points.count >= 2 else {
                return MeasurementGeometry(pageID: pageID, points: domainPoints)
            }
            let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[points.count - 1])
            return MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(
                    outer: PolygonRing(
                        points: corners.map { PDFPoint(x: $0.x, y: $0.y) },
                        isClosed: true
                    )
                )]
            )
        case .polygon, .cloud:
            guard points.count >= 3 else {
                return MeasurementGeometry(pageID: pageID, points: domainPoints)
            }
            return MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(
                    outer: PolygonRing(points: domainPoints, isClosed: true)
                )]
            )
        case .note:
            // One click places a note icon, 20 × 20 pt, the click at its top-left (y up).
            guard let first = points.first else { return MeasurementGeometry(pageID: pageID) }
            let corner = points.count >= 2 ? points[1] : PDFPointValue(x: first.x + noteSide, y: first.y - noteSide)
            return MeasurementGeometry(pageID: pageID, points: [first, corner].map { PDFPoint(x: $0.x, y: $0.y) })
        case .hyperlink, .freehand:
            // Two box corners for a link region, every simplified sample for a stroke.
            return MeasurementGeometry(pageID: pageID, points: domainPoints)
        case .text, .callout, .ellipse, .line, .arrow, .polyline:
            // Points, verbatim: two box corners for Text and Ellipse, target plus two box
            // corners for Callout, endpoints for Line and Arrow, every vertex for Polyline.
            return MeasurementGeometry(pageID: pageID, points: domainPoints)
        default:
            return MeasurementGeometry(pageID: pageID, points: domainPoints)
        }
    }

    /// A note icon's side in page points.
    public static let noteSide: Double = 20

    /// A clouded callout's geometry (ADR-0029 §2.4) from `[ringCorner, ringCorner, target,
    /// boxCorner, boxCorner]`: the ring is the rectangle between the first two points, and the
    /// callout points are stored only when the callout has words. With fewer than five points
    /// it is a plain cloud.
    public static func cloudedCalloutGeometry(points: [PDFPointValue], hasText: Bool, pageID: PageID) -> MeasurementGeometry {
        let corners = ZenitMarkupGeometry.rectangleCorners(points[0], points[1])
        let ring = PolygonGeometry(outer: PolygonRing(points: corners.map { PDFPoint(x: $0.x, y: $0.y) }, isClosed: true))
        guard hasText, points.count >= 5 else { return MeasurementGeometry(pageID: pageID, polygons: [ring]) }
        return MeasurementGeometry(
            pageID: pageID,
            points: points[2...4].map { PDFPoint(x: $0.x, y: $0.y) },
            polygons: [ring]
        )
    }

    /// Where a clouded callout's box and target go for a cloud drawn over `ring` (two opposite
    /// corners): the target is the cloud's top-right corner, and the box sits above and to the
    /// right of it, `fontSize`-tall lines, 10 font sizes wide.
    public static func cloudedCalloutPlacement(
        ring first: PDFPointValue,
        _ second: PDFPointValue,
        fontSize: Double
    ) -> (target: PDFPointValue, box: PDFRectValue) {
        let rect = ZenitMarkupGeometry.boundingRect(first, second)
        let target = PDFPointValue(x: rect.maxX, y: rect.maxY)
        let size = max(6, fontSize)
        let box = PDFRectValue(
            x: rect.maxX + size * 2,
            y: rect.maxY + size * 2,
            width: max(80, size * 10),
            height: max(12, size * 1.6)
        )
        return (target, box)
    }

    /// Ramer–Douglas–Peucker simplification (NL-MARKUP-06): the fewest samples that keep every
    /// dropped one within `tolerance` of the kept polyline. The endpoints are always kept.
    public static func simplified(_ points: [PDFPointValue], tolerance: Double) -> [PDFPointValue] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var farthest = start
            var distance = 0.0
            for index in (start + 1)..<end {
                let d = perpendicularDistance(points[index], points[start], points[end])
                if d > distance { distance = d; farthest = index }
            }
            if distance > tolerance {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func perpendicularDistance(_ p: PDFPointValue, _ a: PDFPointValue, _ b: PDFPointValue) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-12 else { return p.distance(to: a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
    }

    /// The stored style: the armed tool's ink, a fill only where a fill means something,
    /// the kind's default ends (an Arrow's head, a Callout leader's open arrow) unless the tool
    /// style names others, and the line style, opacity and alignment the tool carries
    /// (NL-MARKUP-04).
    ///
    /// A field a kind cannot draw is not written: no fill on a line, no ends on a rectangle,
    /// no Cloud line style on anything that does not scallop (`MarkupStyleFit`).
    public static func markupStyle(kind: Shown.Markup, style: ToolStyleSelection) -> MarkupStyle {
        let domainKind = Domain.Kind(shown: kind)
        let stroke = RGBAColor(shown: style.stroke)
        let fill = style.fill.map { RGBAColor(shown: $0) }
        let holdsFill: Bool
        switch kind {
        case .rectangle, .ellipse, .polygon, .cloud, .callout: holdsFill = true  // a Text box is filled only on request (ADR-0029)
        default: holdsFill = false
        }
        var lineStyle: LineStyle = kind == .cloud ? .cloud : .solid
        if let chosen = style.lineStyle, chosen != .cloud || MarkupStyleFit.holdsCloudStyle(domainKind) {
            lineStyle = chosen.domain
        }
        let defaultEnd: LineCapStyle = kind == .arrow ? .closedArrow
            : (kind == .callout || kind == .cloud ? .openArrow : .none)
        let ends = MarkupStyleFit.holdsLineEnds(domainKind)
        let opacity = style.opacity.isFinite ? min(1, max(0.05, style.opacity)) : 1
        return MarkupStyle(
            color: stroke,
            fill: holdsFill ? fill : nil,
            opacity: opacity,
            lineWidth: style.lineWidth,
            lineStyle: lineStyle,
            startCap: ends ? (style.startCap?.domain ?? .none) : .none,
            endCap: ends ? (style.endCap?.domain ?? defaultEnd) : .none,
            fontName: style.fontName,
            fontSize: style.fontSize,
            textAlignment: style.textAlignment?.domain ?? .leading,
            textStyle: textStyle(kind: kind, style: style),
            cloudArcSize: style.cloudArcSize.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            blendMode: style.multiplyBlend && kind == .freehand ? .multiply : nil
        )
    }

    /// The text formatting a tool style carries, for a kind that draws text, or `nil` when it
    /// carries none (so an unformatted markup keeps the version-4 style blob, ADR-0029).
    static func textStyle(kind: Shown.Markup, style: ToolStyleSelection) -> MarkupTextStyle? {
        guard kind == .text || kind == .callout || kind == .cloud else { return nil }
        let text = MarkupTextStyle(
            bold: style.bold,
            italic: style.italic,
            textColor: style.textColor.map { RGBAColor(shown: $0) },
            boxBorder: kind == .text && style.boxBorder
        )
        return text == .plain ? nil : text
    }

    // MARK: Private

    private func discardInProgress() {
        placedPoints = []
        liveCursorPoint = nil
        draftText = ""
    }
}
