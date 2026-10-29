import CryptoKit
import Foundation
import ZPDFContracts
import ZPDFPersistence

/// One PDF annotation as the review import reads it (NL-COLLAB-08): enough of its dictionary to
/// become a markup, a reply or a status change, and nothing that could run.
///
/// Filled by the application's reader from the drawing a reviewer marked up. Coordinates are PDF
/// user space, which is Zenit's page space (the annotated export writes them straight across).
public struct ImportedAnnotation: Sendable, Hashable {
    /// Position among the file's annotations, all pages, in reading order.
    public var index: Int
    public var pageIndex: Int
    /// `/Subtype` without the slash: `Square`, `Circle`, `Polygon`, `PolyLine`, `Line`,
    /// `FreeText`, `Text`, `Ink`, `Highlight`, `Underline`, `StrikeOut`, `Stamp`, …
    public var subtype: String
    /// `/NM`.
    public var name: String?
    /// `/IRT`, resolved to the parent's ``index``.
    public var inReplyToIndex: Int?
    /// `/T`.
    public var author: String?
    /// `/Contents`.
    public var contents: String?
    /// `/Subj`.
    public var subject: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// `/C`, 0…1.
    public var color: RGBAColor?
    /// `/IC`, 0…1.
    public var interiorColor: RGBAColor?
    /// `/BS /W` or `/Border`.
    public var lineWidth: Double?
    /// `/Rect`.
    public var rect: PDFRect
    /// `/Vertices`, `/L` (two points) or `/CL` (callout line), in page space.
    public var points: [PDFPoint]
    /// `/InkList`.
    public var inkPaths: [[PDFPoint]]
    /// `/QuadPoints`, four points per quad.
    public var quadPoints: [PDFPoint]
    /// `/LE` names, e.g. `["None", "OpenArrow"]`.
    public var lineEndings: [String]
    /// `/BE << /S /C >>`.
    public var cloudy: Bool
    /// `/IT` without the slash.
    public var intent: String?
    /// `/StateModel` and `/State` of a state reply.
    public var stateModel: String?
    public var state: String?
    /// Carries Zenit's own ownership key: this annotation came out of Zenit.
    public var zenitOwned: Bool
    /// The Zenit review status an export wrote beside the standard state model (XFDF
    /// `zenit:status`), so Open, In Progress and Resolved survive a Zenit-to-Zenit round trip.
    public var zenitStatus: String?

    public init(
        index: Int, pageIndex: Int, subtype: String, name: String? = nil, inReplyToIndex: Int? = nil,
        author: String? = nil, contents: String? = nil, subject: String? = nil,
        creationDate: Date? = nil, modificationDate: Date? = nil,
        color: RGBAColor? = nil, interiorColor: RGBAColor? = nil, lineWidth: Double? = nil,
        rect: PDFRect, points: [PDFPoint] = [], inkPaths: [[PDFPoint]] = [], quadPoints: [PDFPoint] = [],
        lineEndings: [String] = [], cloudy: Bool = false, intent: String? = nil,
        stateModel: String? = nil, state: String? = nil, zenitOwned: Bool = false, zenitStatus: String? = nil
    ) {
        self.index = index
        self.pageIndex = pageIndex
        self.subtype = subtype
        self.name = name
        self.inReplyToIndex = inReplyToIndex
        self.author = author
        self.contents = contents
        self.subject = subject
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.color = color
        self.interiorColor = interiorColor
        self.lineWidth = lineWidth
        self.rect = rect
        self.points = points
        self.inkPaths = inkPaths
        self.quadPoints = quadPoints
        self.lineEndings = lineEndings
        self.cloudy = cloudy
        self.intent = intent
        self.stateModel = stateModel
        self.state = state
        self.zenitOwned = zenitOwned
        self.zenitStatus = zenitStatus
    }
}

/// What a review import would do, before anybody agrees to it (NL-COLLAB-08).
public struct AnnotationImportPlan: Sendable {

    /// A reply that will be added to a markup's thread.
    public struct Reply: Sendable, Hashable {
        public var id: UUID
        public var markupID: MarkupID
        public var author: String
        public var body: String
        public var createdAt: Date
    }

    /// A status a reviewer set on a markup through the review state model.
    public struct StatusChange: Sendable, Hashable {
        public var markupID: MarkupID
        public var status: ZPDFContracts.MarkupStatus
        public var author: String
    }

    /// Markups to add, in file order.
    public var newMarkups: [ZPDFContracts.MarkupRecord] = []
    public var replies: [Reply] = []
    public var statusChanges: [StatusChange] = []
    /// Annotations that are already in the project (Zenit's own, or imported before).
    public var alreadyInProject = 0
    /// Replies already in a thread, from an earlier import of the same file.
    public var repliesAlreadyInProject = 0
    /// Annotations left out, with the reason, e.g. "Stamp: its picture is not imported".
    public var skipped: [String] = []
    /// New markups, replies and status changes per author, for the preview.
    public var countsByAuthor: [String: Int] = [:]
    /// Measurement annotations whose geometry lies across two or more Scale Regions: only a person
    /// can choose the scale (spec §10.4), so each comes in as the plain markup it would be on an
    /// uncalibrated sheet, and the preview says how many (T-025).
    public var measurementsAcrossScaleRegions = 0

    public var isEmpty: Bool { newMarkups.isEmpty && replies.isEmpty && statusChanges.isEmpty }

    /// "3 new markups, 2 replies, 1 status change, 1 already in project".
    public var summary: String {
        var parts: [String] = []
        func add(_ count: Int, _ one: String, _ many: String) {
            guard count > 0 else { return }
            parts.append(String(format: count == 1 ? one : many, count))
        }
        add(newMarkups.count,
            NSLocalizedString("%lld new markup", comment: "Review import summary: one new markup"),
            NSLocalizedString("%lld new markups", comment: "Review import summary: several new markups"))
        add(replies.count,
            NSLocalizedString("%lld reply", comment: "Review import summary: one reply"),
            NSLocalizedString("%lld replies", comment: "Review import summary: several replies"))
        add(statusChanges.count,
            NSLocalizedString("%lld status change", comment: "Review import summary: one status change"),
            NSLocalizedString("%lld status changes", comment: "Review import summary: several status changes"))
        let already = NSLocalizedString("%lld already in project", comment: "Review import summary: annotations already in the project")
        add(alreadyInProject + repliesAlreadyInProject, already, already)
        let skippedText = NSLocalizedString("%lld not imported", comment: "Review import summary: annotations left out")
        add(skipped.count, skippedText, skippedText)
        add(measurementsAcrossScaleRegions,
            NSLocalizedString("%lld measurement lies across Scale Regions and comes in unmeasured", comment: "Review import summary: one measurement spanning Scale Regions, imported as a plain markup"),
            NSLocalizedString("%lld measurements lie across Scale Regions and come in unmeasured", comment: "Review import summary: several measurements spanning Scale Regions, imported as plain markups"))
        return parts.isEmpty
            ? NSLocalizedString("Nothing to import.", comment: "Review import summary when the file adds nothing")
            // Joined plainly rather than through `ListFormatter`, which follows the system
            // locale and put a Swedish "och" between English parts.
            : parts.joined(separator: NSLocalizedString(", ", comment: "Review import summary separator"))
    }
}

/// Turns a reviewer's PDF annotations into Zenit markups, replies and status changes, without
/// touching the document (NL-COLLAB-08). Pure: the plan is shown first, and accepting it is the
/// caller's one undoable step.
///
/// ### Mapping
///
/// | Annotation | Markup |
/// |---|---|
/// | Square | rectangle |
/// | Circle | ellipse |
/// | Polygon | polygon, or cloud when `/BE /S /C` or `/IT /PolygonCloud` |
/// | PolyLine | polyline |
/// | Line | arrow when an end is an arrow, else line |
/// | FreeText | callout when `/IT /FreeTextCallout` with a callout line, else text |
/// | Text (sticky note) | note, its words as the note; its replies as thread entries |
/// | Ink | one polyline per stroke |
/// | Highlight | a filled rectangle over each quad's bounds |
/// | Underline, StrikeOut | a line along each quad |
/// | Stamp, FileAttachment, Sound, Link, Widget, Popup | not imported, said in the preview |
///
/// A reply (`/IRT`, no `/StateModel`) becomes a thread reply signed with its `/T`. A state reply
/// (`/StateModel /Review`) becomes a status change on its parent — the newest one wins. An
/// annotation whose `/NM` is a markup already in the project, or that carries Zenit's ownership
/// key for one, is counted as already there and never duplicated.
///
/// ### Identity, so a second import adds nothing
///
/// A new markup's id is its `/NM` when that is a UUID, and otherwise a UUID derived from the
/// file's digest, the page and the `/NM` (or the annotation's position). Importing the same file
/// again therefore finds every markup and reply already present.
///
/// ### Hostile input
///
/// At most ``maximumAnnotations`` annotations and ``maximumVertices`` vertices per annotation are
/// read, and ``maximumTotalPoints`` points over the whole file; text is cut at
/// ``maximumTextLength`` characters; a non-finite coordinate drops its vertex (a highlight's quad
/// whole). At most ``maximumNewMarkups`` markups come out of one import, however many strokes or
/// quads the annotations hold (U-032); what is left out is said in the preview.
/// Nothing in the file is executed, and no quantity is ever read from it: imported shapes are
/// markups — except a measurement annotation on a calibrated page, which
/// `MeasuredAnnotationImport` (NL-MEASURE-16) turns into a measurement Zenit measures
/// again at the scale where it lies (a Scale Region's, or the page's); the file's own number is
/// only quoted in its note.
public enum AnnotationImportPlanner {

    public static let maximumAnnotations = 10_000
    public static let maximumVertices = 10_000
    public static let maximumTextLength = 16_000
    /// One file's geometry budget: points over every annotation read (U-032).
    public static let maximumTotalPoints = 1_000_000
    /// The markups one import may add (U-032). An Ink stroke and a highlight's quad are each one.
    public static let maximumNewMarkups = 10_000

    public static func plan(
        annotations input: [ImportedAnnotation],
        pages: [PageDescriptor],
        documentID: DocumentID,
        existingMarkupIDs: Set<UUID>,
        existingReplyIDs: Set<UUID>,
        fileDigest: String,
        importedAt: Date = Date(),
        annotationsOverBudget: Int = 0
    ) -> AnnotationImportPlan {
        var plan = AnnotationImportPlan()
        let annotations = Array(input.prefix(maximumAnnotations))
        if input.count > maximumAnnotations {
            plan.skipped.append(String(
                format: NSLocalizedString(
                    "%lld annotations beyond the first %lld",
                    comment: "Review import: annotations past the cap; count, cap"
                ),
                input.count - maximumAnnotations, maximumAnnotations
            ))
        }
        if annotationsOverBudget > 0 {
            plan.skipped.append(String(
                format: NSLocalizedString(
                    "%lld annotations past the file's limit of %lld points",
                    comment: "Review import: annotations the reader did not read because the file's geometry budget ran out; count, point budget"
                ),
                annotationsOverBudget, maximumTotalPoints
            ))
        }
        var overMarkupLimit = 0
        let byIndex = Dictionary(annotations.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var markupForIndex: [Int: MarkupID] = [:]
        var newIDs: Set<UUID> = []

        // Pass 1: shapes (every annotation that is not a reply).
        // An annotation's page is its index in the reviewed PDF, and a page's `index` is its index
        // in its own PDF (ADR-0022). Resolved by that identity — the drawing and the index — never
        // by position in `pages`: with a sheet removed from the set, or several drawings in it,
        // position N is not PDF page N, and marks landed one sheet over or were skipped (S-030).
        let pageByIndex = Dictionary(
            pages.filter { $0.documentID == documentID }.map { ($0.index, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for annotation in annotations where annotation.inReplyToIndex == nil {
            guard let page = pageByIndex[annotation.pageIndex] else {
                plan.skipped.append(subtypeName(annotation) + " — " + NSLocalizedString(
                    "on a page this drawing does not have", comment: "Review import skip reason"
                ))
                continue
            }
            let id = identity(of: annotation, fileDigest: fileDigest)
            if existingMarkupIDs.contains(id.rawValue) || newIDs.contains(id.rawValue) {
                markupForIndex[annotation.index] = id
                plan.alreadyInProject += 1
                continue
            }
            if annotation.zenitOwned {
                // Zenit wrote it for a markup this project does not have: another project's mark.
                // Imported like a reviewer's, under the same identity, so it is never doubled.
            }
            let made = markups(for: annotation, id: id, page: page, documentID: documentID, importedAt: importedAt)
            if made.isEmpty {
                plan.skipped.append(subtypeName(annotation) + " — " + skipReason(annotation))
                continue
            }
            guard plan.newMarkups.count + made.count <= maximumNewMarkups else {
                overMarkupLimit += 1
                continue
            }
            markupForIndex[annotation.index] = made[0].id
            for record in made {
                newIDs.insert(record.id.rawValue)
                plan.newMarkups.append(record)
                plan.countsByAuthor[record.author, default: 0] += 1
            }
        }

        if overMarkupLimit > 0 {
            plan.skipped.append(String(
                format: NSLocalizedString(
                    "%lld annotations past the limit of %lld new markups",
                    comment: "Review import: annotations left out because one import adds at most so many markups; count, limit"
                ),
                overMarkupLimit, maximumNewMarkups
            ))
        }

        // Pass 2: replies and state replies, attached to the root they answer.
        var latestState: [MarkupID: (date: Date, change: AnnotationImportPlan.StatusChange)] = [:]
        for annotation in annotations where annotation.inReplyToIndex != nil {
            guard let root = rootMarkup(of: annotation, byIndex: byIndex, markupForIndex: markupForIndex) else {
                plan.skipped.append(NSLocalizedString(
                    "A reply to an annotation that was not imported", comment: "Review import skip reason"
                ))
                continue
            }
            let author = bounded(annotation.author ?? "")
            let date = annotation.modificationDate ?? annotation.creationDate ?? importedAt
            if let model = annotation.stateModel {
                guard model.caseInsensitiveCompare("Review") == .orderedSame,
                      let status = status(fromState: annotation.state)
                else { continue } // "Marked"/"Unmarked" is a reader's checkbox, not a review status.
                let change = AnnotationImportPlan.StatusChange(markupID: root, status: status, author: author)
                if let previous = latestState[root], previous.date > date { continue }
                latestState[root] = (date, change)
                continue
            }
            let body = bounded(annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let replyID = identity(of: annotation, fileDigest: fileDigest).rawValue
            if existingReplyIDs.contains(replyID) {
                plan.repliesAlreadyInProject += 1
                continue
            }
            plan.replies.append(AnnotationImportPlan.Reply(
                id: replyID, markupID: root, author: author, body: body,
                createdAt: annotation.creationDate ?? date
            ))
            plan.countsByAuthor[author, default: 0] += 1
        }
        plan.statusChanges = latestState.values
            .sorted { $0.date < $1.date }
            .map(\.change)
        for change in plan.statusChanges { plan.countsByAuthor[change.author, default: 0] += 1 }
        plan.replies.sort { $0.createdAt < $1.createdAt }
        return plan
    }

    // MARK: - Identity

    /// The markup id an annotation imports under: its `/NM` when that is a UUID, otherwise a
    /// UUID derived from the file, the page and the name or position — stable across imports.
    public static func identity(of annotation: ImportedAnnotation, fileDigest: String) -> MarkupID {
        if let name = annotation.name, let uuid = UUID(uuidString: name) { return MarkupID(uuid) }
        let key = "zenit-review-import|\(fileDigest)|\(annotation.pageIndex)|" + (annotation.name.map { "nm:\($0)" } ?? "ix:\(annotation.index)")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 layout, name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return MarkupID(uuid)
    }

    // MARK: - Mapping

    static func status(fromState state: String?) -> ZPDFContracts.MarkupStatus? {
        switch state?.lowercased() {
        case "accepted": return .accepted
        case "rejected": return .rejected
        case "cancelled": return .cancelled
        case "completed": return .completed
        case "none": return ZPDFContracts.MarkupStatus.none
        default: return nil
        }
    }

    private static func rootMarkup(
        of annotation: ImportedAnnotation,
        byIndex: [Int: ImportedAnnotation],
        markupForIndex: [Int: MarkupID]
    ) -> MarkupID? {
        var current = annotation
        var hops = 0
        while let parent = current.inReplyToIndex, hops < 64 {
            if let id = markupForIndex[parent] { return id }
            guard let next = byIndex[parent] else { return nil }
            current = next
            hops += 1
        }
        return nil
    }

    private static func markups(
        for annotation: ImportedAnnotation,
        id: MarkupID,
        page: PageDescriptor,
        documentID: DocumentID,
        importedAt: Date
    ) -> [ZPDFContracts.MarkupRecord] {
        let points = finite(annotation.points)
        let rect = annotation.rect
        let rx = rect.origin.x, ry = rect.origin.y, rw = rect.size.width, rh = rect.size.height
        let corners = [PDFPoint(x: rx, y: ry), PDFPoint(x: rx + rw, y: ry + rh)]
        let rectFinite = rx.isFinite && ry.isFinite && rw.isFinite && rh.isFinite
            && rw >= 0 && rh >= 0
        func record(_ kind: MarkupKind, _ geometry: MeasurementGeometry, id: MarkupID, fill: Bool = false,
                    caption: String? = nil, comment: String? = nil) -> ZPDFContracts.MarkupRecord {
            let stroke = annotation.color ?? RGBAColor(red: 0.86, green: 0.1, blue: 0.1, alpha: 1)
            var style = MarkupStyle.default
            style.color = stroke
            style.lineWidth = max(0.25, min(annotation.lineWidth ?? 1, 50))
            if fill {
                style.fill = annotation.interiorColor ?? RGBAColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 0.35)
            } else if let interior = annotation.interiorColor {
                style.fill = interior
            }
            return ZPDFContracts.MarkupRecord(
                id: id,
                documentID: documentID,
                pageID: page.id,
                kind: kind,
                subject: bounded(annotation.subject ?? ""),
                comment: comment ?? bounded(annotation.contents ?? ""),
                author: bounded(annotation.author ?? ""),
                status: annotation.zenitStatus.flatMap(ZPDFContracts.MarkupStatus.init(rawValue:)) ?? .none,
                style: style,
                caption: caption,
                geometry: geometry,
                createdAt: annotation.creationDate ?? importedAt,
                modifiedAt: annotation.modificationDate ?? annotation.creationDate ?? importedAt
            )
        }
        func ring(_ ring: [PDFPoint]) -> MeasurementGeometry {
            MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))])
        }
        func line(_ points: [PDFPoint]) -> MeasurementGeometry {
            MeasurementGeometry(pageID: page.id, points: points)
        }

        switch annotation.subtype {
        case "Square":
            guard rectFinite else { return [] }
            return [record(.rectangle, ring([
                PDFPoint(x: rx, y: ry), PDFPoint(x: rx + rw, y: ry),
                PDFPoint(x: rx + rw, y: ry + rh), PDFPoint(x: rx, y: ry + rh)
            ]), id: id)]
        case "Circle":
            guard rectFinite else { return [] }
            return [record(.ellipse, line(corners), id: id)]
        case "Polygon":
            guard points.count >= 3 else { return [] }
            let cloud = annotation.cloudy || annotation.intent == "PolygonCloud"
            return [record(cloud ? .cloud : .polygon, ring(points), id: id)]
        case "PolyLine":
            guard points.count >= 2 else { return [] }
            return [record(.polyline, line(points), id: id)]
        case "Line":
            guard points.count >= 2 else { return [] }
            let arrow = annotation.lineEndings.contains { $0.contains("Arrow") }
            var ends = Array(points.prefix(2))
            // The canvas draws the arrowhead at the second point; a start-only arrow is flipped.
            if arrow, annotation.lineEndings.first?.contains("Arrow") == true,
               annotation.lineEndings.dropFirst().first?.contains("Arrow") != true {
                ends.reverse()
            }
            var made = record(arrow ? .arrow : .line, line(ends), id: id)
            // The canvas draws the stored ends now, not a head chosen by kind, so an
            // imported arrow carries its ends on its style. A start-only arrow was flipped above.
            if arrow {
                func cap(_ name: String?) -> LineCapStyle {
                    guard let name else { return .none }
                    if name.contains("ClosedArrow") { return .closedArrow }
                    if name.contains("OpenArrow") { return .openArrow }
                    return .none
                }
                let first = cap(annotation.lineEndings.first)
                let second = cap(annotation.lineEndings.dropFirst().first)
                if second != .none {
                    made.style.startCap = first
                    made.style.endCap = second
                } else {
                    made.style.endCap = first
                }
            }
            return [made]
        case "FreeText":
            guard rectFinite else { return [] }
            let words = bounded(annotation.contents ?? "")
            if annotation.intent == "FreeTextCallout", let target = points.first {
                return [record(.callout, line([target] + corners), id: id, caption: words, comment: "")]
            }
            return [record(.text, line(corners), id: id, caption: words, comment: "")]
        case "Text":
            guard rectFinite else { return [] }
            return [record(.note, line(corners), id: id)]
        case "Ink":
            let strokes = annotation.inkPaths.map(finite).filter { $0.count >= 2 }
            guard !strokes.isEmpty else { return [] }
            return strokes.enumerated().map { offset, stroke in
                record(.polyline, line(stroke), id: offset == 0 ? id : derived(id, offset))
            }
        case "Highlight", "Underline", "StrikeOut":
            // Bounded once, grouped in fours as the file wrote them, and a quad with a non-finite
            // corner dropped whole (T-030). Filtering first shifted every later quad by a point,
            // and rebuilding the filtered array for each quad cost 2 500 copies of 10 000 points
            // for one crafted highlight, on the main actor.
            let bounded = Array(annotation.quadPoints.prefix(maximumVertices))
            let quads = stride(from: 0, to: bounded.count - 3, by: 4).compactMap { start -> [PDFPoint]? in
                let quad = Array(bounded[start..<(start + 4)])
                return quad.allSatisfy { $0.x.isFinite && $0.y.isFinite } ? quad : nil
            }
            guard !quads.isEmpty else { return [] }
            return quads.enumerated().compactMap { offset, quad in
                let xs = quad.map(\.x), ys = quad.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
                let markupID = offset == 0 ? id : derived(id, offset)
                switch annotation.subtype {
                case "Highlight":
                    return record(.rectangle, ring([
                        PDFPoint(x: minX, y: minY), PDFPoint(x: maxX, y: minY),
                        PDFPoint(x: maxX, y: maxY), PDFPoint(x: minX, y: maxY)
                    ]), id: markupID, fill: true)
                case "Underline":
                    return record(.line, line([PDFPoint(x: minX, y: minY), PDFPoint(x: maxX, y: minY)]), id: markupID)
                default:
                    let middle = (minY + maxY) / 2
                    return record(.line, line([PDFPoint(x: minX, y: middle), PDFPoint(x: maxX, y: middle)]), id: markupID)
                }
            }
        default:
            return []
        }
    }

    /// A second markup from one annotation (an ink stroke, a quad), with a stable id.
    private static func derived(_ id: MarkupID, _ offset: Int) -> MarkupID {
        let key = "zenit-review-import-part|\(id.rawValue.uuidString)|\(offset)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return MarkupID(UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }

    private static func finite(_ points: [PDFPoint]) -> [PDFPoint] {
        Array(points.prefix(maximumVertices)).filter { $0.x.isFinite && $0.y.isFinite }
    }

    static func bounded(_ text: String) -> String {
        text.count > maximumTextLength ? String(text.prefix(maximumTextLength)) : text
    }

    private static func subtypeName(_ annotation: ImportedAnnotation) -> String {
        annotation.subtype.isEmpty ? NSLocalizedString("Annotation", comment: "Review import: an annotation with no subtype") : annotation.subtype
    }

    private static func skipReason(_ annotation: ImportedAnnotation) -> String {
        switch annotation.subtype {
        case "Stamp":
            return NSLocalizedString("its picture is not imported", comment: "Review import skip reason for a stamp")
        case "Link", "Widget", "Popup", "FileAttachment", "Sound", "Movie", "Screen", "3D", "RichMedia":
            return NSLocalizedString("not a review mark", comment: "Review import skip reason for links, form fields and media")
        default:
            return NSLocalizedString("its shape could not be read", comment: "Review import skip reason for an unreadable shape")
        }
    }
}
