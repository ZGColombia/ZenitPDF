import CoreGraphics
import CryptoKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFRenderer
import ZPDFUIPresentation

/// File ▸ Export Annotated PDF…, second version (NL-PDF-01): **one standard annotation per
/// markup**, written as an incremental update onto the drawing's own bytes.
///
/// # Where the values come from
///
/// The same place the print sheet and the flattened file get theirs: the canvas's own
/// `CanvasSceneBuilder` scene, filtered by `PDFFlattenPolicy`, turned into renderer fragments by
/// `SnippetSceneBuilder`. The difference is only where the fragments are cut: per markup, so each
/// markup's fragments become one annotation's appearance, and the markup's record supplies the
/// identity, author, subject, dates and review status the annotation carries.
///
/// # Two writers, one decision
///
/// `ZPDFExport.StandardAnnotationWriter` appends to the source — the drawing's bytes, and any
/// signature over them, survive. When it refuses (an encrypted drawing), PDFKit rewrites the file
/// with the same annotations mapped to what it can carry, and the export report says which writer
/// ran, why, and — for a signed drawing — that the signature did not survive.
@MainActor
public enum StandardAnnotationExport {

    /// Everything one annotated export needs, gathered off the document.
    public struct Job: Sendable {
        public var pages: [StandardAnnotationPage]
        public var sourceURL: URL
        /// The digest of the drawing as it was opened, so a file swapped underneath the project
        /// is refused rather than annotated with markups measured on another revision (BH-174).
        public var sourceDigest: FileDigest?

        public var annotationCount: Int { pages.reduce(0) { $0 + $1.annotations.count } }
    }

    /// Which writer produced the file, and what it did.
    public enum Writer: Sendable {
        /// The drawing's bytes, then an incremental update.
        case incremental(StandardAnnotationOutcome)
        /// A full PDFKit rewrite, because the incremental writer refused the drawing.
        case rewritten(reason: String, receipt: DocumentWriteReceipt)
    }

    /// The result of one annotated export.
    public struct Result: Sendable {
        public var writer: Writer
        /// Whether the source file's bytes were identical before and after the write.
        public var sourceIsUnchanged: Bool
        /// Whether the source carries a digital signature.
        public var drawingIsSigned: Bool
        /// Annotations in the file, one per markup.
        public var annotationCount: Int
    }

    // MARK: - The job

    /// - Parameter replies: each markup's review thread (NL-COLLAB-07), written as replies to
    ///   its annotation. Filled by the collaboration wiring; empty by default.
    public static func job(
        for document: ZenitPDFProjectDocument,
        artwork resolve: ((String) async -> ArtworkGeometry?)? = nil,
        replies: [MarkupID: [StandardAnnotation.Reply]] = [:]
    ) async throws -> Job {
        try await job(for: document, artwork: resolve, replies: replies, set: nil)
    }

    /// - Parameter set: a project of several drawings, composed (``DrawingSetOutput``); the
    ///   annotations go onto the composed file, each sheet at its position. `nil` is the one
    ///   drawing.
    static func job(
        for document: ZenitPDFProjectDocument,
        artwork resolve: ((String) async -> ArtworkGeometry?)? = nil,
        replies: [MarkupID: [StandardAnnotation.Reply]] = [:],
        set: DrawingSetOutput?
    ) async throws -> Job {
        guard let core = document.core, let drawing = document.drawing else {
            throw FlattenedDrawingExport.PreparationFailure.noDocument
        }
        let sheets = set?.pages ?? drawing.pages
        guard !sheets.isEmpty else { throw FlattenedDrawingExport.PreparationFailure.noPages }
        // Where a sheet link lands in the file written: its position in the set, or its index
        // in the one drawing (a link to a sheet of another drawing then has no page here).
        let pageIndexOf: (PageID) -> Int? = { id in
            if let set { return set.pageIndex(of: id) }
            return drawing.pages.first { $0.id == id }?.index
        }

        // ADR-0032: with each markup layer's hidden and printable flags folded in.
        let records = await core.session.effectiveMarkups
        var byID: [UUID: MarkupRecord] = [:]
        for record in records { byID[record.id.rawValue] = record }
        let artwork = await FlattenedDrawingExport.artworkGeometry(for: records, resolve: resolve)
        // ADR-0043 (L-81): an inserted picture's appearance is its own pixels, as on screen.
        let pictures = await SnippetSceneBuilder.insertedImageBytes(for: records, package: document.projectPackage)
        let snapshot = core.snapshot
        let adopted = set == nil ? adoptedOriginals(for: document) : [:]

        var pages: [StandardAnnotationPage] = []
        for page in sheets {
            let pageUUID = page.id.rawValue
            let shapes = CanvasSceneBuilder.build(
                records: records,
                summaries: snapshot.markups(onPage: pageUUID),
                pageID: pageUUID,
                artwork: artwork,
                // NL-MEASURE-09: a moved caption and segment lengths are part
                // of the annotation's appearance, as on screen.
                segmentLabelling: SnippetSceneBuilder.segmentLabelling(core: core, page: pageUUID)
            )
            var annotations: [StandardAnnotation] = []
            for shape in shapes
            where PDFFlattenPolicy.isOnPaper(hidden: shape.hidden, printable: shape.printable) && !shape.isTemporary {
                let fragments = SnippetSceneBuilder.renderables(
                    from: [shape], for: .paper, rotation: page.rotation, insertedImages: pictures
                )
                guard !fragments.isEmpty else { continue }
                let record = byID[shape.id]
                var annotation = annotation(for: shape, record: record, fragments: fragments, pageIndex: pageIndexOf)
                annotation.replies = replies[MarkupID(shape.id)] ?? []
                // NL-PDF-02: the scale the markup was measured at, for another reader's tools.
                if let record, record.kind == .measurement,
                   let scale = await core.session.scale(onPage: record.pageID, scaleID: record.scaleID) {
                    annotation.measure = measureScale(scale, userUnit: page.userUnit)
                }
                annotations.append(annotation)
            }
            let viewports = await viewports(for: page, session: core.session)
            let originals = adopted[page.index] ?? []
            guard !annotations.isEmpty || !viewports.isEmpty || !originals.isEmpty else { continue }
            var entry = StandardAnnotationPage(
                page: page, sourcePageIndex: page.index, annotations: annotations, viewports: viewports
            )
            entry.adoptedOriginals = originals
            pages.append(entry)
        }
        return Job(pages: pages, sourceURL: set?.url ?? drawing.url, sourceDigest: set == nil ? drawing.digest : nil)
    }

    // MARK: - Adopted originals (NL-UX-04 hand-off)

    /// The drawing's own annotations that "Make Drawing Annotations Editable" turned into
    /// markups still present, by page — the ones the canvas hides. The export leaves them out,
    /// because the markup is written as its own annotation and the mark would appear twice.
    static func adoptedOriginals(for document: ZenitPDFProjectDocument) -> [Int: [AdoptedOriginal]] {
        guard let reading = document.adoptionReading, let core = document.core else { return [:] }
        let present = Set(core.snapshot.markups.map(\.id))
        var out: [Int: [AdoptedOriginal]] = [:]
        for binding in DrawingAnnotationAdoption.adoptedBindings(
            reading: reading, markupIDs: present, touched: document.adoptionTouchedIDs
        ) where binding.layerID == DrawingAnnotationAdoption.adoptedLayer {
            out[binding.pageIndex, default: []].append(AdoptedOriginal(
                name: binding.annotationName, subtype: binding.subtype, rect: binding.rect ?? .zero
            ))
        }
        return out
    }

    // MARK: - Measurement interop (NL-PDF-02)

    /// A uniform scale as a PDF measure; `nil` for a separately calibrated X/Y scale, which has
    /// no single ratio another reader could apply.
    static func measureScale(_ scale: ScaleTransform, userUnit: Double) -> MeasureScale? {
        guard scale.matrix.isUniform else { return nil }
        let metres = scale.matrix.metresPerPointX
        guard metres.isFinite, metres > 0 else { return nil }
        return MeasureScale(ratioLabel: ScaleBridge.ratioText(for: scale, userUnit: userUnit), metresPerPoint: metres)
    }

    /// The page's viewports: the sheet's own scale over the whole sheet, then each Scale Region
    /// over its boundary. Readers search viewports from the last, so a region wins inside it; the
    /// writer puts the drawing's own viewports between the two (V-052).
    static func viewports(for page: ZPDFContracts.PageDescriptor, session: TakeoffSession) async -> [MeasureViewport] {
        var out: [MeasureViewport] = []
        let box = page.visibleBox
        if let scale = await session.pageScale(page.id), let measure = measureScale(scale, userUnit: page.userUnit) {
            out.append(MeasureViewport(
                bounds: PDFRect(x: box.minX, y: box.minY, width: box.maxX - box.minX, height: box.maxY - box.minY),
                name: measure.ratioLabel,
                measure: measure,
                coverage: .sheet
            ))
        }
        let regions = await session.scaleRegionDefinitions
            .filter { $0.pageID == page.id && $0.boundary.count >= 3 }
            .sorted { $0.priority < $1.priority }
        for region in regions {
            guard let scale = await session.scale(onPage: page.id, scaleID: region.scaleID),
                  let measure = measureScale(scale, userUnit: page.userUnit)
            else { continue }
            let xs = region.boundary.map(\.x), ys = region.boundary.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            out.append(MeasureViewport(
                bounds: PDFRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                name: region.name.isEmpty ? measure.ratioLabel : region.name,
                measure: measure
            ))
        }
        return out
    }

    // MARK: - One markup

    /// One markup as one standard annotation. Pure: the canvas shape, its record, its fragments.
    static func annotation(
        for shape: CanvasMarkupShape,
        record: MarkupRecord?,
        fragments: [RenderableMarkup],
        pageIndex: (PageID) -> Int? = { _ in nil }
    ) -> StandardAnnotation {
        let stroke = SnippetSceneBuilder.color(shape.color)
        let lineWidth = shape.lineWidth.isFinite && shape.lineWidth > 0
            ? shape.lineWidth : SnippetSceneBuilder.fallbackLineWidth
        let fill: RGBAColor = {
            if let fill = shape.fill { return SnippetSceneBuilder.color(fill) }
            var tint = stroke
            tint.alpha *= 0.18
            return tint
        }()
        let dash: [Double] = {
            if case let .pattern(runs, _) = SnippetSceneBuilder.dash(for: shape.lineStyle, lineWidth: lineWidth) {
                return runs
            }
            return []
        }()
        let firstStroke = shape.strokes.first { $0.points.count >= 2 }
        let points = firstStroke?.points.map(SnippetSceneBuilder.point(_:)) ?? []
        let vertices = shape.vertices.map(SnippetSceneBuilder.point(_:))
        let closedFilled = firstStroke.map { $0.closed && $0.filled } ?? false
        let cloudy = shape.lineStyle == .cloud || shape.kind == .cloud || shape.kind == .revisionCloud

        var geometry: StandardAnnotation.Geometry = .stamp
        var intent: StandardAnnotation.Intent?
        var endEnding: StandardAnnotation.LineEnding = .none
        var startEnding: StandardAnnotation.LineEnding = .none
        var withFill = false

        func box(_ source: [PDFPoint]) -> PDFRect? {
            guard let first = source.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in source.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return PDFRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let bounds = PDFRect(
            x: shape.bounds.origin.x, y: shape.bounds.origin.y,
            width: shape.bounds.size.width, height: shape.bounds.size.height
        )

        switch shape.kind {
        case .stamp, .image, .count:
            geometry = .stamp
        case .measurement:
            if !shape.counts.isEmpty || points.count < 2 {
                geometry = .stamp
            } else if firstStroke?.closed == true {
                geometry = .polygon(points)
                intent = .polygonDimension
                withFill = closedFilled
            } else {
                geometry = .polyLine(points)
                intent = .polyLineDimension
            }
        case .text:
            let textBox = shape.textBox.map {
                PDFRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
            } ?? bounds
            geometry = .freeText(textBox, callout: [])
        case .callout:
            let textBox = shape.textBox.map {
                PDFRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
            } ?? bounds
            var leader: [PDFPoint] = []
            if let target = shape.leaderTarget {
                let tip = SnippetSceneBuilder.point(target)
                let edge = PDFPoint(
                    x: min(max(tip.x, textBox.minX), textBox.maxX),
                    y: min(max(tip.y, textBox.minY), textBox.maxY)
                )
                leader = [tip, edge]
            }
            geometry = .freeText(textBox, callout: leader)
            // r2-markup (NL-MARKUP-07): the leader's stored end, open arrow when it has none.
            let leaderEnd = shape.strokes.first { !$0.closed }?.drawnEndCap ?? .none
            endEnding = leaderEnd == .none ? .openArrow : lineEnding(leaderEnd)
        case .note, .issue:
            geometry = .note(PDFPoint(x: bounds.minX, y: bounds.maxY))
        case .freehand:
            let paths = shape.strokes.map { $0.points.map(SnippetSceneBuilder.point(_:)) }.filter { $0.count >= 2 }
            geometry = paths.isEmpty ? .stamp : .ink(paths)
        case .line, .arrow:
            if points.count == 2 {
                geometry = .line(start: points[0], end: points[1])
            } else if points.count > 2 {
                geometry = .polyLine(points)
            }
            // r2-markup (NL-MARKUP-07): the stored ends, not the kind. An Arrow is created with a
            // closed end, so it exports as it always did; a Line given a circle start and an
            // arrow end exports both.
            startEnding = lineEnding(firstStroke?.startCap ?? .none)
            endEnding = lineEnding(firstStroke?.drawnEndCap ?? .none)
            if endEnding == .closedArrow || endEnding == .openArrow {
                intent = points.count == 2 ? .lineArrow : nil
            }
        case .polyline:
            geometry = points.count >= 2 ? .polyLine(points) : .stamp
            startEnding = lineEnding(firstStroke?.startCap ?? .none)
            endEnding = lineEnding(firstStroke?.drawnEndCap ?? .none)
        case .rectangle:
            geometry = box(points).map { .square($0) } ?? .stamp
            withFill = closedFilled
        case .ellipse:
            geometry = box(points).map { .circle($0) } ?? .stamp
            withFill = closedFilled
        case .polygon:
            geometry = points.count >= 3 ? .polygon(points) : .stamp
            withFill = closedFilled
        case .cloud, .revisionCloud:
            let outline = vertices.count >= 3 ? vertices : points
            geometry = outline.count >= 3 ? .polygon(outline) : .stamp
            intent = .polygonCloud
            withFill = closedFilled
        case .highlight:
            geometry = .textMarkup(.highlight, [bounds])
        case .underline:
            geometry = .textMarkup(.underline, [bounds])
        case .strikeout:
            geometry = .textMarkup(.strikeOut, [bounds])
        case .hyperlink:
            // A sheet link of the project: a /Link GoTo to that sheet's page in the file written.
            // A web address: a /Link URI.
            if let target = record?.link?.pageID, record?.link?.isValid == true, let index = pageIndex(target) {
                geometry = .pageLink(bounds, pageIndex: index)
            } else if let uri = hyperlinkTarget(record: record, shape: shape) {
                geometry = .link(bounds, uri: uri)
            }
        }

        let status: StandardAnnotation.ReviewState? = switch record?.status {
        case .accepted?: .accepted
        case .rejected?: .rejected
        case .cancelled?: .cancelled
        case .completed?: .completed
        default: nil
        }

        return StandardAnnotation(
            id: shape.id,
            geometry: geometry,
            contents: contents(shape: shape, record: record),
            subject: record.map(\.subject).flatMap { $0.isEmpty ? nil : $0 } ?? shape.kind.displayName,
            author: record.map(\.author).flatMap { $0.isEmpty ? nil : $0 },
            creationDate: record?.createdAt,
            modificationDate: record?.modifiedAt,
            stroke: stroke,
            fill: withFill ? fill : nil,
            opacity: shape.opacity.isFinite ? min(1, max(0, shape.opacity)) : 1,
            lineWidth: lineWidth,
            dash: dash,
            startEnding: startEnding,
            endEnding: endEnding,
            cloudy: cloudy,
            intent: intent,
            reviewState: status,
            printable: shape.printable,
            fontSize: shape.fontSize,
            appearance: fragments
        )
    }

    /// A stored line end as its `/LE` name (ISO 32000-1 Table 176). `round` is a stroke cap,
    /// not a decoration, and the table has no name for it, so it exports as `None`.
    static func lineEnding(_ cap: ZPDFContracts.LineCapStyle) -> StandardAnnotation.LineEnding {
        switch cap {
        case .none, .round: .none
        case .openArrow: .openArrow
        case .closedArrow: .closedArrow
        case .circle: .circle
        case .square: .square
        case .diamond: .diamond
        case .slash: .slash
        case .butt: .butt
        }
    }

    /// `/Contents`: what a reviewer's comment list should say about the markup — its text, label,
    /// value and comment, each once, one per line.
    static func contents(shape: CanvasMarkupShape, record: MarkupRecord?) -> String? {
        var lines: [String] = []
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !lines.contains(value) else { return }
            lines.append(value)
        }
        add(shape.text)
        add(record?.label)
        add(shape.caption)
        if let stamp = shape.stamp { add(stamp.lines.filter { !$0.isEmpty }.joined(separator: " ")) }
        add(record?.comment)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A hyperlink markup's address: the first of its comment, label or text that is a web or
    /// mail address. `nil` exports the markup as a stamp of what it draws.
    static func hyperlinkTarget(record: MarkupRecord?, shape: CanvasMarkupShape) -> String? {
        // ADR-0029: the stored destination wins when it is a valid web address.
        if let link = record?.link, link.isValid, let url = link.url { return url }
        for candidate in [record?.comment, record?.label, shape.text] {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { continue }
            return text
        }
        return nil
    }

    // MARK: - Writing

    /// Writes the job to `url`: incrementally when the drawing allows it, through PDFKit when it
    /// does not. Never onto the drawing itself.
    public static func write(
        _ job: Job,
        to url: URL,
        fallback: (([NeutralAnnotation]) async throws -> DocumentWriteReceipt)? = nil
    ) async throws -> Result {
        // The same file however it is named, by the one rule every derived-copy writer uses
        // (S-012): resolved path, then file identity, so a hard link to the drawing is refused like
        // the drawing. A case-variant name ("plan.pdf" beside "Plan.pdf") is caught by the path
        // step already: local volumes resolve an existing file to its on-disk case.
        try DerivedCopyGuard.refuseIfSource(url, source: job.sourceURL)
        let signed = DocumentHazardProbe.hazards(ofFileAt: job.sourceURL).contains(.signedDocument)
        let source = try Data(contentsOf: job.sourceURL, options: .mappedIfSafe)
        let before = digest(source)
        if let expected = job.sourceDigest {
            try verifyBegins(source, with: expected)
        }

        do {
            let produced = try StandardAnnotationWriter().data(source: source, pages: job.pages)
            try produced.data.write(to: url, options: .atomic)
            let after = digest(try Data(contentsOf: job.sourceURL, options: .mappedIfSafe))
            return Result(
                writer: .incremental(produced.outcome),
                sourceIsUnchanged: before == after,
                drawingIsSigned: signed,
                annotationCount: produced.outcome.writtenAnnotationCount
            )
        } catch let ExportError.annotationExportRefused(reason) {
            guard let fallback else { throw ExportError.annotationExportRefused(reason) }
            let neutral = job.pages.flatMap { page in
                page.annotations.map { $0.neutralAnnotation(pageIndex: page.sourcePageIndex) }
            }
            let receipt = try await fallback(neutral)
            return Result(
                writer: .rewritten(reason: reason, receipt: receipt),
                sourceIsUnchanged: receipt.sourceIsUnchanged,
                drawingIsSigned: signed,
                annotationCount: neutral.count
            )
        }
    }

    /// What the person is told about an annotated export that is not the whole story: the
    /// writer fell back to a rewrite, a signature did not survive, markups could not be drawn.
    /// `nil` when there is nothing to say.
    public static func reportMessage(for result: Result) -> String? {
        var lines: [String] = []
        switch result.writer {
        case let .incremental(outcome):
            if outcome.rejectedMarkupCount > 0 {
                lines.append(String(
                    format: NSLocalizedString(
                        "%d markups could not be drawn and are missing from the file.",
                        comment: "Flatten report: markups the renderer refused"
                    ),
                    outcome.rejectedMarkupCount
                ))
            }
            if result.drawingIsSigned {
                lines.append(NSLocalizedString(
                    "The drawing is digitally signed. The annotations were appended after the signed content, so the signature still covers the original drawing.",
                    comment: "Annotated export report: signature preserved by the incremental update"
                ))
            }
        case let .rewritten(reason, _):
            lines.append(String(
                format: NSLocalizedString(
                    "The annotations could not be appended to the original file (%@), so the file was rewritten. Appearance streams, opacity settings and review states are simplified in this copy.",
                    comment: "Annotated export report: fallback to a full rewrite; the reason"
                ),
                reason
            ))
            if result.drawingIsSigned {
                lines.append(NSLocalizedString(
                    "The drawing is digitally signed, and a rewritten copy no longer carries a valid signature.",
                    comment: "Annotated export report: signature lost by a full rewrite"
                ))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Refuses a drawing file that does not **begin with** the bytes the document opened.
    ///
    /// Equality would be the obvious test, and it would refuse the one legitimate change: a Save
    /// Markups into PDF appends an incremental update, so the file is the opened drawing plus
    /// Zenit's own annotations. A file replaced or edited underneath the document fails this and
    /// is never written onto with markups measured on another revision (BH-174).
    static func verifyBegins(_ data: Data, with expected: FileDigest) throws {
        let prefix = expected.byteCount <= data.count ? data.prefix(expected.byteCount) : Data()
        guard !prefix.isEmpty, digest(Data(prefix)) == expected.sha256.lowercased() else {
            throw ExportError.annotationExportRefused(
                "the drawing on disk is no longer the file this document opened, so markups measured "
                    + "on one revision would be written onto another; reopen the drawing and try again."
            )
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
