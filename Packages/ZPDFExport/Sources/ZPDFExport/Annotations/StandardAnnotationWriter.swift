import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFRenderer
import ZPDFPDFKitBridge

/// Writes ``StandardAnnotation``s into a drawing as an **incremental update** (NL-PDF-01).
///
/// # What the artefact is
///
/// The source file byte for byte, then: one annotation object per markup, one appearance form
/// per annotation, a hidden review-state reply where the markup has a terminal status, and a
/// superseding page dictionary per annotated sheet whose `/Annots` names the drawing's own
/// annotations plus the new ones and whose `/VP` names the drawing's own viewports around Zenit's
/// scales. Nothing else. ``StandardAnnotationOutcome/preservedSourceBytes`` is the length of the
/// untouched prefix, and a test hashes it.
///
/// Because the drawing is never rewritten, a digital signature in the source keeps covering
/// exactly the bytes it signed. The first annotated export rewrote the whole file through PDFKit
/// and broke every signature without a word.
///
/// # Who owns an annotation
///
/// Every annotation this writer puts in a file carries ``ownerKey``. On a second export — or an
/// export of a drawing that is itself an earlier annotated export — annotations with that key,
/// annotations whose `/NM` names a markup being written, and the first annotated export's
/// `/Subj (Zenit)` annotations are **superseded**: left out of the new `/Annots`, so there is one
/// set, never two stacked. A reply or pop-up that points at a superseded annotation goes with it.
/// Every other annotation — a reviewer's comments — is kept exactly as it was.
///
/// Viewports follow the same rule (V-052). Each `/VP` entry this writer adds carries
/// ``ownerKey``; a re-export replaces those and keeps every other entry of the page's `/VP` — a
/// CAD drawing's plan and detail viewports — in the order: Zenit's sheet-wide scale, the
/// drawing's own entries, Zenit's Scale Regions. Readers search the array from the last entry,
/// so the drawing's detail viewports still govern wherever Zenit has nothing more specific.
/// The first version replaced the whole array, and a 1:20 detail was measured at the sheet's
/// 1:100 in every other reader.
///
/// # How the appearance is made
///
/// Each annotation's ``StandardAnnotation/appearance`` fragments are painted on their own page
/// of a scratch PDF by ``MarkupFlattener`` — the single painter the flatten, print and layered
/// paths share — and that page's content stream becomes the annotation's `/AP /N` form, its
/// `/Matrix` the sheet-to-page placement the layered export already derives from `/Rotate`. No
/// markup is drawn a second way.
///
/// # When it refuses
///
/// The same cases as the layered export, for the same reason: an encrypted drawing (an update
/// would have to be encrypted with its key), no cross-reference section to chain to, a catalog
/// that cannot be found, or a sheet whose size differs from the one the markups were measured
/// on. The caller decides what to do with a refusal; the app falls back to PDFKit and says so.
public struct StandardAnnotationWriter: Sendable {

    /// The second-class key marking an annotation as Zenit's. Readers ignore keys they do not
    /// know (ISO 32000-1 §7.12.2); this one lets a later export find and replace its own marks.
    public static let ownerKey = ZenitAnnotationOwnership.ownerKey
    /// `/Subj` of every annotation the first (PDFKit) annotated export wrote. Recognised so an
    /// export from one of those files replaces them instead of stacking a second set.
    public static let legacySubject = ZenitAnnotationOwnership.legacySubject

    public init() {}

    // MARK: - Producing the bytes

    /// Produces the annotated artefact.
    ///
    /// - Parameters:
    ///   - source: the drawing exactly as it is on disk. Copied into the output unmodified.
    ///   - pages: the sheets to annotate. A sheet not named is not touched at all.
    ///   - takeoff: the complete takeoff to carry as an associated file (NL-PDF-03), or `nil`.
    ///   - attachments: further Zenit files carried beside the takeoff and superseded with it —
    ///     the session archive a reopen restores from (NL-PDF-03 restore). Ignored without a
    ///     takeoff.
    public func data(
        source: Data,
        pages: [StandardAnnotationPage],
        takeoff: EmbeddedTakeoff? = nil,
        attachments: [EmbeddedTakeoff] = []
    ) throws -> (data: Data, outcome: StandardAnnotationOutcome) {
        var seen: Set<Int> = []
        for page in pages where !seen.insert(page.sourcePageIndex).inserted {
            throw ExportError.annotationExportRefused(
                "page \(page.sourcePageIndex + 1) was given to the annotated export twice."
            )
        }

        let scan: PDFDocumentScan
        let sourcePages: [PDFDocumentScan.PageEntry]
        do {
            scan = try PDFDocumentScan(data: source)
            sourcePages = try scan.pages()
        } catch let error as ExportError {
            throw ExportError.annotationExportRefused(Self.reword(error))
        }

        var update = PDFIncrementalUpdate()
        var allocator = scan.nextObjectNumber
        func allocate() -> Int {
            defer { allocator += 1 }
            return allocator
        }

        var outcome = StandardAnnotationOutcome(pageCount: sourcePages.count, preservedSourceBytes: source.count)
        // Every page of the file, for a sheet link's destination.
        let pageReferences = sourcePages.map { PDFObject.reference(number: $0.number, generation: scan.generation(of: $0.number)) }

        for job in pages.sorted(by: { $0.sourcePageIndex < $1.sourcePageIndex }) {
            guard job.sourcePageIndex >= 0, job.sourcePageIndex < sourcePages.count else {
                throw ExportError.annotationExportRefused(
                    "the export names page \(job.sourcePageIndex + 1), and the drawing has "
                        + "\(sourcePages.count) page\(sourcePages.count == 1 ? "" : "s")."
                )
            }
            let target = sourcePages[job.sourcePageIndex]
            try verifySheet(job: job, target: target, scan: scan)

            // What the page already carries, minus Zenit's own earlier marks.
            let existing = Self.existingAnnotations(of: target, scan: scan)
            let partition = Self.partition(
                existing,
                replacing: Set(job.annotations.map(\.name)),
                adopted: job.adoptedOriginals,
                scan: scan
            )
            outcome.supersededAnnotationCount += partition.superseded
            outcome.keptForeignAnnotationCount += partition.kept.count

            outcome.adoptedOriginalCount += partition.adopted
            // The page's own viewports, minus Zenit's from an earlier export (V-052).
            let existingViewports = Self.existingViewports(of: target, scan: scan)
            let drawingViewports = existingViewports.filter { !Self.isZenitViewport($0, scan: scan) }
            let replacesViewports = !job.viewports.isEmpty || drawingViewports.count < existingViewports.count
            guard !job.annotations.isEmpty || partition.superseded > 0 || partition.adopted > 0
                || replacesViewports else { continue }

            let painted = try paintAppearances(job)
            // One memo per sheet: the painter's scratch PDF shares its ICC colour space and
            // ExtGState across the sheet's markups, and a memo per markup copied them once per
            // annotation — about 2.6 KB each (U-051).
            var copiedResources: [Int: Int] = [:]
            let pageReference = PDFObject.reference(
                number: target.number,
                generation: scan.generation(of: target.number)
            )
            let placement = Self.placement(for: job.page)
            let inverse = placement.inverted()

            var added: [PDFObject] = []
            for (index, annotation) in job.annotations.enumerated() {
                let appearance = painted.appearances[index]
                if appearance == nil, !annotation.appearance.isEmpty {
                    // The painter refused every fragment: non-finite or out-of-range geometry.
                    // An annotation whose appearance is missing would be drawn by each reader its
                    // own way, so it is left out and counted.
                    outcome.rejectedMarkupCount += 1
                    continue
                }
                guard let rect = Self.pageRect(of: annotation) else {
                    outcome.rejectedMarkupCount += 1
                    continue
                }
                // A sheet link whose sheet is not in this file points nowhere: left out, counted.
                if case let .pageLink(_, target) = annotation.geometry, !pageReferences.indices.contains(target) {
                    outcome.rejectedMarkupCount += 1
                    continue
                }

                var appearanceReference: PDFObject?
                if let appearance {
                    let formNumber = allocate()
                    update.objects[formNumber] = try form(
                        appearance,
                        painted: painted.scan,
                        bbox: rect.applying(inverse),
                        placement: placement,
                        memo: &copiedResources,
                        allocate: allocate,
                        update: &update
                    )
                    appearanceReference = .reference(number: formNumber, generation: 0)
                }

                let number = allocate()
                let reference = PDFObject.reference(number: number, generation: 0)
                update.objects[number] = .dictionary(Self.dictionary(
                    for: annotation,
                    rect: rect,
                    appearance: appearanceReference,
                    page: pageReference,
                    pageReferences: pageReferences
                ))
                added.append(reference)
                outcome.writtenAnnotationCount += 1

                if let state = annotation.reviewState {
                    let replyNumber = allocate()
                    update.objects[replyNumber] = .dictionary(Self.reviewReply(
                        state: state,
                        to: reference,
                        annotation: annotation,
                        rect: rect,
                        page: pageReference
                    ))
                    added.append(.reference(number: replyNumber, generation: 0))
                    outcome.reviewReplyCount += 1
                }
                for reply in annotation.replies {
                    let replyNumber = allocate()
                    update.objects[replyNumber] = .dictionary(Self.threadReply(
                        reply, to: reference, rect: rect, page: pageReference
                    ))
                    added.append(.reference(number: replyNumber, generation: 0))
                    outcome.reviewReplyCount += 1
                }
            }

            var dictionary = target.dictionary
            if replacesViewports {
                // Zenit's sheet-wide scale first, the drawing's own entries (as written: direct
                // or by reference) next, Zenit's Scale Regions last — readers search from the end.
                let merged = job.viewports.filter { $0.coverage == .sheet }.map(Self.viewportDictionary)
                    + drawingViewports
                    + job.viewports.filter { $0.coverage == .region }.map(Self.viewportDictionary)
                if merged.isEmpty {
                    dictionary.removeValue(forKey: "VP")
                } else {
                    dictionary["VP"] = .array(merged)
                }
                outcome.viewportCount += job.viewports.count
                outcome.keptDrawingViewportCount += drawingViewports.count
            }
            let annots = partition.kept + added
            if annots.isEmpty {
                dictionary.removeValue(forKey: "Annots")
            } else {
                dictionary["Annots"] = .array(annots)
            }
            update.objects[target.number] = .dictionary(dictionary)
            outcome.annotatedPageCount += added.isEmpty ? 0 : 1
        }

        if let takeoff {
            let embedded = try Self.embed([takeoff] + attachments, scan: scan, allocate: allocate, update: &update)
            outcome.takeoffEmbedded = embedded.embedded
            outcome.takeoffNote = embedded.note
        }

        let bytes = try update.appended(to: source, scan: scan)
        return (bytes, outcome)
    }

    // MARK: - Ownership

    /// The page's `/Annots` elements, as written (references or direct dictionaries).
    static func existingAnnotations(
        of target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan
    ) -> [PDFObject] {
        guard let annots = target.dictionary["Annots"] else { return [] }
        if let values = annots.arrayValue { return values }
        return scan.object(annots)?.arrayValue ?? []
    }

    /// Splits a page's annotations into the ones kept and a count of the ones superseded.
    static func partition(
        _ existing: [PDFObject],
        replacing names: Set<String>,
        adopted: [AdoptedOriginal] = [],
        scan: PDFDocumentScan
    ) -> (kept: [PDFObject], superseded: Int, adopted: Int) {
        partition(existing, adopted: adopted, scan: scan) { isZenitOwned($0, replacing: names) }
    }

    /// Splits a page's annotations by `isSuperseded`: the ones it picks (and, with them, the
    /// replies and pop-ups that point at them) are left out, every other one is kept as written.
    /// The writer here supersedes by ``isZenitOwned(_:replacing:)``; the layered export by the
    /// narrower rule of `LayeredMarkupExporter` (L-23).
    static func partition(
        _ existing: [PDFObject],
        adopted: [AdoptedOriginal] = [],
        scan: PDFDocumentScan,
        isSuperseded: ([String: PDFObject]) -> Bool
    ) -> (kept: [PDFObject], superseded: Int, adopted: Int) {
        var owned: Set<Int> = []
        var ownedIndices: Set<Int> = []
        var adoptedCount = 0
        for (index, element) in existing.enumerated() {
            guard let dictionary = scan.object(element)?.dictionaryValue else { continue }
            if isSuperseded(dictionary) {
                ownedIndices.insert(index)
                if let number = element.referenceValue?.number { owned.insert(number) }
                continue
            }
            guard !adopted.isEmpty else { continue }
            let name = text(dictionary["NM"])
            let subtype = dictionary["Subtype"]?.nameValue
            let rect = LayeredMarkupExporter.rectangle(dictionary["Rect"], scan: scan)
            if adopted.contains(where: { $0.matches(name: name, subtype: subtype, rect: rect) }) {
                ownedIndices.insert(index)
                adoptedCount += 1
                if let number = element.referenceValue?.number { owned.insert(number) }
            }
        }
        var kept: [PDFObject] = []
        var superseded = ownedIndices.count - adoptedCount
        for (index, element) in existing.enumerated() where !ownedIndices.contains(index) {
            if let dictionary = scan.object(element)?.dictionaryValue {
                let parent = dictionary["IRT"]?.referenceValue?.number
                    ?? dictionary["Parent"]?.referenceValue?.number
                if let parent, owned.contains(parent) {
                    superseded += 1
                    continue
                }
            }
            kept.append(element)
        }
        return (kept, superseded, adoptedCount)
    }

    /// The page's `/VP` elements, as written (references or direct dictionaries), whether the
    /// array is direct or itself a reference.
    static func existingViewports(
        of target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan
    ) -> [PDFObject] {
        guard let viewports = target.dictionary["VP"] else { return [] }
        if let values = viewports.arrayValue { return values }
        return scan.object(viewports)?.arrayValue ?? []
    }

    /// Whether a `/VP` element is one this writer added to an earlier export.
    static func isZenitViewport(_ element: PDFObject, scan: PDFDocumentScan) -> Bool {
        scan.object(element)?.dictionaryValue?[ownerKey] != nil
    }

    /// One of Zenit's viewports as a `/VP` entry, marked as Zenit's so a re-export replaces it.
    static func viewportDictionary(_ viewport: MeasureViewport) -> PDFObject {
        .dictionary([
            "Type": .name("Viewport"),
            "BBox": array(CGRect(
                x: viewport.bounds.minX, y: viewport.bounds.minY,
                width: viewport.bounds.width, height: viewport.bounds.height
            )),
            "Name": OptionalContentCatalog.textString(viewport.name),
            "Measure": measureDictionary(viewport.measure),
            ownerKey: .boolean(true)
        ])
    }

    /// Whether an annotation dictionary is one of Zenit's own.
    static func isZenitOwned(_ dictionary: [String: PDFObject], replacing names: Set<String>) -> Bool {
        if dictionary[ownerKey] != nil { return true }
        let name = text(dictionary["NM"])
        if let name, names.contains(name) { return true }
        if name == nil, text(dictionary["Subj"]) == legacySubject { return true }
        return false
    }

    /// A PDF text string's value: PDFDocEncoding (read as Latin-1, which agrees on the printable
    /// range) or UTF-16BE behind its byte-order mark.
    static func text(_ value: PDFObject?) -> String? {
        let bytes: [UInt8]
        switch value {
        case let .string(raw)?: bytes = raw
        case let .hexString(raw)?: bytes = raw
        default: return nil
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            var units: [UInt16] = []
            var index = 2
            while index + 1 < bytes.count {
                units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    // MARK: - Painting the appearances

    private struct PaintedAppearances {
        /// Per annotation, the decoded content stream and resources of its appearance, or `nil`
        /// when it has none (no fragments) or the painter refused all of them.
        var appearances: [(content: Data, resources: [String: PDFObject])?]
        var scan: PDFDocumentScan?
    }

    /// Paints each annotation's fragments on its own page of a scratch PDF the size of the sheet.
    private func paintAppearances(_ job: StandardAnnotationPage) throws -> PaintedAppearances {
        let size = job.page.rotatedVisibleSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw PDFFlattenError.unusablePage(
                index: job.page.index,
                reason: "the crop box is empty or non-finite"
            )
        }
        let wanted = job.annotations.enumerated().filter { !$0.element.appearance.isEmpty }
        guard !wanted.isEmpty else {
            return PaintedAppearances(appearances: Array(repeating: nil, count: job.annotations.count), scan: nil)
        }

        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData) else {
            throw PDFFlattenError.pdfContextUnavailable
        }
        var box = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFFlattenError.pdfContextUnavailable
        }
        var producedInk: [Bool] = []
        for (_, annotation) in wanted {
            var pageBox = box
            let info: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ]
            context.beginPDFPage(info as CFDictionary)
            let outcome = try MarkupFlattener.paint(
                page: job.page,
                markups: annotation.appearance,
                into: context,
                rect: box
            )
            context.endPDFPage()
            producedInk.append(outcome.paintedMarkupCount > 0)
        }
        context.closePDF()

        let scan = try PDFDocumentScan(data: buffer as Data)
        let scratchPages = try scan.pages()
        guard scratchPages.count == wanted.count else {
            throw ExportError.annotationExportRefused(
                "the markup painter produced \(scratchPages.count) appearances for "
                    + "\(wanted.count) annotations on page \(job.sourcePageIndex + 1)."
            )
        }
        var appearances: [(content: Data, resources: [String: PDFObject])?] =
            Array(repeating: nil, count: job.annotations.count)
        for (slot, entry) in wanted.enumerated() where producedInk[slot] {
            let scratch = scratchPages[slot]
            guard case let .stream(dictionary, raw)? = scan.object(scratch.dictionary["Contents"]),
                  let content = PDFStreamCodec.decode(dictionary: dictionary, data: raw)
            else {
                throw ExportError.annotationExportRefused(
                    "the appearance painted for markup \(entry.offset + 1) on page "
                        + "\(job.sourcePageIndex + 1) could not be read back."
                )
            }
            appearances[entry.offset] = (content, scan.dictionary(scratch.inheritedResources) ?? [:])
        }
        return PaintedAppearances(appearances: appearances, scan: scan)
    }

    /// The `/AP /N` form: the painted content, its resources copied into the drawing, drawn in
    /// sheet space and carried onto the page by `placement`. `memo` is the sheet's: an object
    /// already copied for an earlier markup of the sheet is referenced, not copied again.
    private func form(
        _ appearance: (content: Data, resources: [String: PDFObject]),
        painted scan: PDFDocumentScan?,
        bbox: CGRect,
        placement: CGAffineTransform,
        memo: inout [Int: Int],
        allocate: () -> Int,
        update: inout PDFIncrementalUpdate
    ) throws -> PDFObject {
        var resources: [String: PDFObject] = [:]
        if let scan {
            for (category, value) in appearance.resources where category != "ProcSet" {
                guard let entries = scan.object(value)?.dictionaryValue else { continue }
                var copied: [String: PDFObject] = [:]
                for (name, resource) in entries {
                    copied[name] = try update.copy(
                        resource, from: scan, memo: &memo, allocate: allocate, tooDeep: Self.resourceTooDeep
                    )
                }
                resources[category] = .dictionary(copied)
            }
        }
        var dictionary: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .integer(1),
            "BBox": Self.array(bbox),
            "Matrix": .array([placement.a, placement.b, placement.c, placement.d, placement.tx, placement.ty]
                .map { PDFObject.real(Self.clean($0)) }),
            "Resources": .dictionary(resources)
        ]
        var data = appearance.content
        if let deflated = PDFStreamCodec.flateEncode(data), deflated.count < data.count {
            data = deflated
            dictionary["Filter"] = .name("FlateDecode")
        }
        return .stream(dictionary: dictionary, data: data)
    }

    /// The refusal for a painter resource nested past what this exporter reads.
    private static func resourceTooDeep() -> ExportError {
        .annotationExportRefused("the markup painter produced a resource nested deeper than this exporter reads.")
    }

    // MARK: - The annotation dictionary

    static func dictionary(
        for annotation: StandardAnnotation,
        rect: CGRect,
        appearance: PDFObject?,
        page: PDFObject,
        pageReferences: [PDFObject] = []
    ) -> [String: PDFObject] {
        var d: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name(annotation.geometry.subtype),
            "Rect": array(rect),
            "NM": OptionalContentCatalog.textString(annotation.name),
            ownerKey: .boolean(true),
            "F": .integer(annotation.printable ? 4 : 0),
            "P": page
        ]
        if let appearance { d["AP"] = .dictionary(["N": appearance]) }
        if let contents = annotation.contents, !contents.isEmpty {
            d["Contents"] = OptionalContentCatalog.textString(contents)
        }
        if let modified = annotation.modificationDate { d["M"] = .string(Array(pdfDate(modified).utf8)) }
        if let stroke = annotation.stroke { d["C"] = colour(stroke) }

        if case let .link(_, uri) = annotation.geometry {
            d["Border"] = .array([.integer(0), .integer(0), .integer(0)])
            d["A"] = .dictionary([
                "S": .name("URI"),
                "URI": .string(Array(uri.utf8))
            ])
            return d
        }
        if case let .pageLink(_, target) = annotation.geometry {
            d["Border"] = .array([.integer(0), .integer(0), .integer(0)])
            if pageReferences.indices.contains(target) {
                d["Dest"] = .array([pageReferences[target], .name("Fit")])
            }
            return d
        }

        // Markup-annotation keys (ISO 32000-1 Table 170).
        if let author = annotation.author, !author.isEmpty {
            d["T"] = OptionalContentCatalog.textString(author)
        }
        if let subject = annotation.subject, !subject.isEmpty {
            d["Subj"] = OptionalContentCatalog.textString(subject)
        }
        if let created = annotation.creationDate { d["CreationDate"] = .string(Array(pdfDate(created).utf8)) }
        let opacity = annotation.opacity.isFinite ? min(1, max(0, annotation.opacity)) : 1
        let strokeAlpha = annotation.stroke.map { min(1, max(0, $0.alpha)) } ?? 1
        let fillAlpha = annotation.fill.map { min(1, max(0, $0.alpha)) }
        // `/CA` applies to the whole annotation when a reader regenerates it. The lower of the two
        // alphas: a regenerated 20 % area must not become an opaque polygon over the drawing. The
        // appearance stream carries the exact per-part alpha for every reader that uses it.
        let constant = opacity * min(strokeAlpha, fillAlpha ?? strokeAlpha)
        if constant < 1 { d["CA"] = .real(clean(constant)) }
        if let fillAlpha, fillAlpha * opacity < 1 { d["ca"] = .real(clean(fillAlpha * opacity)) }
        if let intent = annotation.intent { d["IT"] = .name(intent.rawValue) }
        if let measure = annotation.measure { d["Measure"] = measureDictionary(measure) }

        var border: [String: PDFObject] = [
            "Type": .name("Border"),
            "W": .real(clean(max(0, annotation.lineWidth.isFinite ? annotation.lineWidth : 1)))
        ]
        let dash = annotation.dash.filter { $0.isFinite && $0 > 0 }
        if dash.isEmpty {
            border["S"] = .name("S")
        } else {
            border["S"] = .name("D")
            border["D"] = .array(dash.map { .real(clean($0)) })
        }

        switch annotation.geometry {
        case let .polygon(points):
            d["Vertices"] = flat(points)
            d["BS"] = .dictionary(border)
            if let fill = annotation.fill { d["IC"] = colour(fill) }
            if annotation.cloudy {
                d["BE"] = .dictionary(["S": .name("C"), "I": .integer(1)])
            }
        case let .polyLine(points):
            d["Vertices"] = flat(points)
            d["BS"] = .dictionary(border)
            d["LE"] = .array([.name(annotation.startEnding.rawValue), .name(annotation.endEnding.rawValue)])
        case let .line(start, end):
            d["L"] = flat([start, end])
            d["BS"] = .dictionary(border)
            d["LE"] = .array([.name(annotation.startEnding.rawValue), .name(annotation.endEnding.rawValue)])
            if let fill = annotation.fill { d["IC"] = colour(fill) }
        case let .ink(paths):
            d["InkList"] = .array(paths.map { flat($0) })
            d["BS"] = .dictionary(border)
        case let .square(shape), let .circle(shape):
            d["BS"] = .dictionary(border)
            if let fill = annotation.fill { d["IC"] = colour(fill) }
            if annotation.cloudy {
                d["BE"] = .dictionary(["S": .name("C"), "I": .integer(1)])
            }
            d["RD"] = .array([
                rect.minX.distance(to: CGFloat(shape.minX)),
                rect.minY.distance(to: CGFloat(shape.minY)),
                CGFloat(shape.maxX).distance(to: rect.maxX),
                CGFloat(shape.maxY).distance(to: rect.maxY)
            ].map { .real(clean(max(0, Double($0)))) })
        case let .freeText(_, callout):
            let ink = annotation.stroke ?? RGBAColor(red: 0, green: 0, blue: 0)
            let size = annotation.fontSize.isFinite && annotation.fontSize > 0 ? annotation.fontSize : 12
            d["DA"] = .string(Array(
                "\(fmt(ink.red)) \(fmt(ink.green)) \(fmt(ink.blue)) rg /Helv \(fmt(size)) Tf".utf8
            ))
            if callout.count >= 2 {
                d["CL"] = flat(Array(callout.prefix(3)))
                d["IT"] = .name(StandardAnnotation.Intent.freeTextCallout.rawValue)
                d["LE"] = .name(annotation.endEnding == .none ? "OpenArrow" : annotation.endEnding.rawValue)
            }
            d["BS"] = .dictionary(border)
        case .note:
            d["Name"] = .name("Comment")
            d["Open"] = .boolean(false)
        case let .textMarkup(_, rects):
            // Each rectangle as four corners in the order readers use: upper-left, upper-right,
            // lower-left, lower-right.
            d["QuadPoints"] = .array(rects.flatMap { r -> [PDFObject] in
                [r.minX, r.maxY, r.maxX, r.maxY, r.minX, r.minY, r.maxX, r.minY].map { .real(clean($0)) }
            })
        case .stamp:
            break
        case .link, .pageLink:
            break
        }
        return d
    }

    /// A rectilinear measure dictionary (ISO 32000-1 Table 261). `/X` converts page units to
    /// millimetres — a factor near 1, which six decimals carry to a part in a hundred million,
    /// where metres per point at 1:1 would lose a part in a thousand — and `/D` and `/A` show
    /// distances in metres and areas in square metres.
    static func measureDictionary(_ measure: MeasureScale) -> PDFObject {
        let places = min(6, max(0, measure.decimalPlaces))
        var denominator = 1
        for _ in 0..<places { denominator *= 10 }
        func format(_ unit: String, _ factor: Double) -> PDFObject {
            .array([.dictionary([
                "Type": .name("NumberFormat"),
                "U": OptionalContentCatalog.textString(unit),
                "C": .real(factor),
                "F": .name("D"),
                "D": .integer(denominator)
            ])])
        }
        return .dictionary([
            "Type": .name("Measure"),
            "Subtype": .name("RL"),
            "R": OptionalContentCatalog.textString(measure.ratioLabel),
            "X": format("mm", measure.metresPerPoint * 1_000),
            "D": format("m", 0.001),
            "A": format("sq m", 0.000001)
        ])
    }

    /// The hidden reply that carries a terminal review state (ISO 32000-1 §12.5.6.3).
    static func reviewReply(
        state: StandardAnnotation.ReviewState,
        to parent: PDFObject,
        annotation: StandardAnnotation,
        rect: CGRect,
        page: PDFObject
    ) -> [String: PDFObject] {
        var d: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name("Text"),
            "Rect": array(rect),
            "IRT": parent,
            "StateModel": .string(Array("Review".utf8)),
            "State": .string(Array(state.rawValue.utf8)),
            "Contents": .string(Array(state.rawValue.utf8)),
            "NM": OptionalContentCatalog.textString(annotation.name + "-review"),
            ownerKey: .boolean(true),
            // Hidden, NoZoom, NoRotate (+ Print): a state change is a row in the comment list,
            // not a second icon on the sheet.
            "F": .integer(30),
            "P": page
        ]
        if let author = annotation.author, !author.isEmpty {
            d["T"] = OptionalContentCatalog.textString(author)
        }
        if let modified = annotation.modificationDate {
            d["M"] = .string(Array(pdfDate(modified).utf8))
            d["CreationDate"] = .string(Array(pdfDate(modified).utf8))
        }
        return d
    }

    /// One comment of a markup's review thread (NL-COLLAB-07): a hidden `/Text` reply.
    static func threadReply(
        _ reply: StandardAnnotation.Reply,
        to parent: PDFObject,
        rect: CGRect,
        page: PDFObject
    ) -> [String: PDFObject] {
        var d: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name("Text"),
            "Rect": array(rect),
            "IRT": parent,
            "RT": .name("R"),
            "NM": OptionalContentCatalog.textString(reply.id.uuidString),
            "T": OptionalContentCatalog.textString(reply.author),
            "Contents": OptionalContentCatalog.textString(reply.body),
            "CreationDate": .string(Array(pdfDate(reply.createdAt).utf8)),
            "M": .string(Array(pdfDate(reply.modifiedAt ?? reply.createdAt).utf8)),
            ownerKey: .boolean(true),
            "F": .integer(30),
            "P": page
        ]
        if reply.author.isEmpty { d.removeValue(forKey: "T") }
        return d
    }

    // MARK: - Geometry

    /// The annotation's `/Rect` in page space: the extent of what its appearance paints, grown by
    /// a margin, or the geometry's own extent when there is no appearance.
    ///
    /// Estimated from the fragments rather than measured from the painted ink, and generously:
    /// a reader clips the appearance to `/Rect`, so an estimate that is too small loses ink and
    /// one that is a few points too large costs nothing.
    static func pageRect(of annotation: StandardAnnotation) -> CGRect? {
        var box = appearanceBounds(of: annotation.appearance)
        let geometry = geometryBounds(of: annotation.geometry)
        switch (box, geometry) {
        case let (a?, b?): box = a.union(b)
        case let (nil, b?): box = b
        default: break
        }
        guard let box, box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite
        else { return nil }
        let widest = annotation.appearance.map { $0.style.sanitizedLineWidth }.max() ?? annotation.lineWidth
        let pad = CGFloat(2 + max(0, widest.isFinite ? widest : 1))
        return box.insetBy(dx: -pad, dy: -pad)
    }

    static func geometryBounds(of geometry: StandardAnnotation.Geometry) -> CGRect? {
        switch geometry {
        case let .polygon(points), let .polyLine(points):
            return bounds(points)
        case let .line(start, end):
            return bounds([start, end])
        case let .ink(paths):
            return bounds(paths.flatMap { $0 })
        case let .square(rect), let .circle(rect), let .link(rect, _), let .pageLink(rect, _):
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        case let .textMarkup(_, rects):
            return bounds(rects.flatMap { [PDFPoint(x: $0.minX, y: $0.minY), PDFPoint(x: $0.maxX, y: $0.maxY)] })
        case let .freeText(rect, callout):
            let box = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            return bounds(callout).map { $0.union(box) } ?? box
        case let .note(point):
            return CGRect(x: point.x, y: point.y - 20, width: 20, height: 20)
        case .stamp:
            return nil
        }
    }

    /// The page-space extent of a set of renderer fragments, text included by estimate.
    ///
    /// Text is laid out upright on the *sheet*, which on a `/Rotate 90` page is sideways in page
    /// space, so a label's box is taken as a square as large as its longer side — correct at any
    /// of the four rotations.
    static func appearanceBounds(of fragments: [RenderableMarkup]) -> CGRect? {
        var box: CGRect?
        func add(_ rect: CGRect) { box = box.map { $0.union(rect) } ?? rect }
        func around(_ point: PDFPoint, radius: Double) -> CGRect {
            CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        }
        func textRadius(_ text: String, fontSize: Double, lineFactor: Double) -> Double {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let longest = Double(lines.map(\.count).max() ?? 0)
            let size = fontSize.isFinite && fontSize > 0 ? fontSize : 12
            let width = longest * size * 0.62 + size
            let height = Double(max(1, lines.count)) * size * lineFactor
            return max(width, height)
        }
        for fragment in fragments {
            switch fragment.shape {
            case let .polyline(line):
                if let rect = bounds(line.points) { add(rect) }
            case let .filledPolygon(polygon):
                if let rect = bounds(polygon.outer + polygon.holes.flatMap { $0 }) { add(rect) }
            case let .countSymbol(symbol):
                add(around(symbol.center, radius: max(symbol.size, 1)))
            case let .textLabel(label):
                add(around(label.anchorPoint, radius: textRadius(label.text, fontSize: label.fontSize, lineFactor: 1.4)))
            case let .labelPill(pill):
                add(around(pill.anchorPoint, radius: textRadius(pill.text, fontSize: pill.fontSizeViewPoints, lineFactor: 1.8)))
            case let .dimensionLine(dimension):
                if let rect = bounds([dimension.start, dimension.end]) { add(rect) }
                let mid = PDFPoint(
                    x: (dimension.start.x + dimension.end.x) / 2,
                    y: (dimension.start.y + dimension.end.y) / 2
                )
                add(around(mid, radius: textRadius(dimension.label, fontSize: dimension.fontSizeViewPoints, lineFactor: 1.8)))
                let decoration = max(dimension.arrowLengthViewPoints, dimension.tickLengthViewPoints) + 2
                for end in [dimension.start, dimension.end] { add(around(end, radius: decoration)) }
            case let .image(image):
                // A placed picture covers its parallelogram (ADR-0043).
                if let rect = bounds(image.corners) { add(rect) }
            }
        }
        return box
    }

    static func bounds(_ points: [PDFPoint]) -> CGRect? {
        let finite = points.filter(\.isFinite)
        guard let first = finite.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in finite.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Sheet space (origin at the displayed sheet's bottom-left corner) onto page space.
    static func placement(for page: PageDescriptor) -> CGAffineTransform {
        let m = LayeredMarkupExporter.placementMatrix(for: page)
        return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
    }

    private func verifySheet(
        job: StandardAnnotationPage,
        target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan
    ) throws {
        let box: (width: Double, height: Double)
        do {
            box = try LayeredMarkupExporter.visibleSheet(of: target, scan: scan, pageIndex: job.sourcePageIndex)
        } catch let error as ExportError {
            throw ExportError.annotationExportRefused(Self.reword(error))
        }
        let rotation = scan.object(target.inheritedRotation)?.integerValue ?? 0
        let swaps = (((rotation % 360) + 360) % 360) % 180 != 0
        let width = swaps ? box.height : box.width
        let height = swaps ? box.width : box.height
        let sheet = job.page.rotatedVisibleSize
        guard abs(width - sheet.width) <= 1, abs(height - sheet.height) <= 1 else {
            throw ExportError.annotationExportRefused(
                "page \(job.sourcePageIndex + 1) of the drawing is "
                    + "\(PDFObject.format(width)) x \(PDFObject.format(height)) pt, and the markups "
                    + "were measured on a sheet of \(PDFObject.format(sheet.width)) x "
                    + "\(PDFObject.format(sheet.height)) pt; the annotations would land on the wrong drawing."
            )
        }
    }

    // MARK: - Serialisation helpers

    static func array(_ rect: CGRect) -> PDFObject {
        let r = rect.standardized
        return .array([r.minX, r.minY, r.maxX, r.maxY].map { .real(clean(Double($0))) })
    }

    static func flat(_ points: [PDFPoint]) -> PDFObject {
        .array(points.flatMap { [PDFObject.real(clean($0.x)), .real(clean($0.y))] })
    }

    static func colour(_ colour: RGBAColor) -> PDFObject {
        let c = colour.clampedToUnitRange()
        return .array([c.red, c.green, c.blue].map { .real(clean($0)) })
    }

    /// Rounds to 1/10 000 so a value computed in floating point serialises as the short number a
    /// person would write, and `-0` is written as `0`.
    static func clean(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == 0 ? 0 : rounded
    }

    private static func fmt(_ value: Double) -> String { PDFObject.format(clean(value)) }

    /// A PDF date (ISO 32000-1 §7.9.4), in UTC — the bridge's ``PDFDateFormatting``.
    static func pdfDate(_ date: Date) -> String {
        PDFDateFormatting.string(from: date)
    }

    /// The layered scanner's refusals say "layer"; the sentence a person reads here must say
    /// what this export is.
    private static func reword(_ error: ExportError) -> String {
        let text = error.description
        return text
            .replacingOccurrences(of: "a layer added to it", with: "annotations added to it")
            .replacingOccurrences(of: "the layered export cannot be produced", with: "annotations cannot be appended to it")
            .replacingOccurrences(of: "the markup layer cannot be recorded", with: "the annotations cannot be recorded")
            .replacingOccurrences(of: "the optional-content group that makes the markups a layer", with: "the annotations")
            .replacingOccurrences(of: "add a layer to", with: "add annotations to")
    }
}

/// What one annotated export did, in numbers a caller can assert on and a sentence a person can
/// read.
public struct StandardAnnotationOutcome: Sendable, Hashable {
    /// Pages in the source drawing. All of them are in the artefact.
    public var pageCount: Int
    /// Pages that received at least one annotation.
    public var annotatedPageCount: Int = 0
    /// Annotations written: exactly one per markup that could be painted.
    public var writtenAnnotationCount: Int = 0
    /// Hidden review-state replies written beside them.
    public var reviewReplyCount: Int = 0
    /// Zenit's own earlier annotations left out of the new `/Annots` (a re-export).
    public var supersededAnnotationCount: Int = 0
    /// Everybody else's annotations, kept as they were.
    public var keptForeignAnnotationCount: Int = 0
    /// Markups whose appearance the renderer refused. They are missing from the file.
    public var rejectedMarkupCount: Int = 0
    /// `/VP` viewports written (NL-PDF-02).
    public var viewportCount: Int = 0
    /// The drawing's own `/VP` viewports kept beside Zenit's (V-052).
    public var keptDrawingViewportCount: Int = 0
    /// The drawing's own annotations left out because a Zenit markup replaced them (NL-UX-04).
    public var adoptedOriginalCount: Int = 0
    /// Length of the artefact's prefix that is the source file byte for byte.
    public var preservedSourceBytes: Int
    /// Whether the takeoff was embedded as an associated file (NL-PDF-03).
    public var takeoffEmbedded: Bool = false
    /// Why a requested takeoff was not embedded, when it was not.
    public var takeoffNote: String?

    public init(pageCount: Int, preservedSourceBytes: Int) {
        self.pageCount = pageCount
        self.preservedSourceBytes = preservedSourceBytes
    }

    /// The one sentence that says what changed. The whole truth, like the layered export's.
    public var modificationStatement: String {
        var text = "The drawing's first \(preservedSourceBytes) bytes are the original file, "
            + "unchanged. Appended to it: \(writtenAnnotationCount) annotation"
            + "\(writtenAnnotationCount == 1 ? "" : "s"), one per markup, each with its own "
            + "appearance, on \(annotatedPageCount) of the \(pageCount) sheet"
            + "\(pageCount == 1 ? "" : "s")."
        if supersededAnnotationCount > 0 {
            text += " \(supersededAnnotationCount) annotation"
                + "\(supersededAnnotationCount == 1 ? "" : "s") from an earlier Zenit export "
                + "\(supersededAnnotationCount == 1 ? "was" : "were") replaced."
        }
        if keptForeignAnnotationCount > 0 {
            text += " \(keptForeignAnnotationCount) annotation"
                + "\(keptForeignAnnotationCount == 1 ? "" : "s") already in the drawing "
                + "\(keptForeignAnnotationCount == 1 ? "was" : "were") kept."
        }
        return text
    }
}
