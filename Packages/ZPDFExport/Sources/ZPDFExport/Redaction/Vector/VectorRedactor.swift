import CoreGraphics
import Foundation
import PDFKit
import ZPDFPDFKitBridge

/// Which marked sheets can be redacted as vector, and why the others cannot — asked before the
/// confirmation, so the person sees which sheets would become pictures.
public struct RedactionAssessment: Sendable, Hashable {
    public var markedPages: [Int]
    /// Marked sheets the vector rewriter cannot cut exactly, with the reason for each.
    public var fallbacks: [RedactionFallback]

    public init(markedPages: [Int], fallbacks: [RedactionFallback]) {
        self.markedPages = markedPages
        self.fallbacks = fallbacks
    }

    /// Every marked sheet can stay vector.
    public var vectorQualifies: Bool { fallbacks.isEmpty }
    /// At least one marked sheet can stay vector.
    public var anyVector: Bool { fallbacks.count < markedPages.count }
    public var vectorPages: [Int] { markedPages.filter { page in !fallbacks.contains { $0.pageIndex == page } } }
}

/// Redaction, phase 2: the marked sheets stay vector — linework sharp, text outside the boxes
/// searchable — and only what lies under the boxes is cut out of the file (NL-PDF-14,
/// ADR-0033).
///
/// # How
///
/// The source is read through Zenit's own object layer (``PDFDocumentScan``, honouring the free
/// entries of later revisions) and each marked sheet's content stream is rewritten by
/// ``RedactionContentRewriter``: glyphs under a box removed with their advances kept, paths cut
/// at the box edges, image samples blanked, form XObjects and single-tile pattern cells
/// rewritten per placement, shadings painted only under a box removed. The black boxes are
/// painted last, in a content stream of their own. The copy is written from nothing by
/// ``RedactionDocumentWriter`` — one revision, only reachable objects, no metadata, no scripts,
/// no attachments or associated files, no structure tree.
///
/// # Nothing cut under a box travels in its original form
///
/// Every source object the rewrite cut or removed under a box is recorded, and so is every
/// object that reaches one. The marked sheets are then rewritten again knowing all of them: a
/// picture or form cut under a box and drawn again elsewhere is kept whole only where that use
/// shows it whole, and otherwise replaced by a copy holding only what the use shows. Unmarked
/// sheets and annotation appearances that reach one are rewritten without boxes the same way,
/// with their resources pruned to what they use — a shared resource dictionary never carries
/// the original along. Fonts that lost glyphs keep only the codes still drawn: widths, Unicode
/// entries, glyph procedures and embedded glyph outlines (``RedactionFontPruner``) (ADR-0033 §11).
///
/// # Sheets it cannot cut exactly
///
/// A marked sheet with something the rewriter cannot handle exactly — a font without a width
/// table, a predefined CMap, vertical writing, a mesh shading, a shading or repeating pattern
/// painted partly under a box, a filter it does not decode, a broken stream — becomes a picture
/// of itself exactly as ``RasterRedactor`` draws it, and ``RedactionOutcome/rasterFallbacks``
/// says which sheet and why. Such a sheet is still read, to learn what lay under its boxes. A
/// vector sheet that leaks is never written.
///
/// # Proved before it is kept
///
/// ``verify`` re-reads the copy through PDFKit and through Core Graphics' own parser
/// (`CGPDFScanner`), and refuses it — nothing is written — unless no removed word can be found
/// by either, in the decompressed bytes or in any string (hex or literal, in any case); no path,
/// glyph, image sample, pattern cell or shading lies inside a box; no original of anything cut
/// under a box is in the file unless shown whole elsewhere; nothing is painted under a box; and
/// every sheet — marked or not — renders as before outside the boxes, through PDFKit and again
/// through Core Graphics' own drawing transform.
public enum VectorRedactor {

    // MARK: - Public entry points

    /// Which marked sheets would stay vector. Reads the drawing; writes nothing.
    /// ``VectorRedactionSession`` keeps the preparation for the redaction that follows.
    public static func assess(source: URL, password: String? = nil, marks: [RedactionMark]) -> RedactionAssessment {
        assessment(of: try? prepare(source: source, password: password, marks: marks), marks: marks)
    }

    /// What a preparation says about each marked sheet; `nil`: the drawing could not be read.
    static func assessment(of prepared: Prepared?, marks: [RedactionMark]) -> RedactionAssessment {
        let marked = Array(Set(marks.map(\.pageIndex))).sorted()
        guard let prepared else {
            return RedactionAssessment(markedPages: marked, fallbacks: marked.map {
                RedactionFallback(pageIndex: $0, reason: "the drawing could not be read by the vector rewriter")
            })
        }
        return RedactionAssessment(markedPages: marked, fallbacks: prepared.fallbacks)
    }

    /// Writes a redacted copy keeping every sheet it can as vector; the others become pictures.
    public static func redact(
        source: URL,
        password: String? = nil,
        marks: [RedactionMark],
        to output: URL,
        dpi: Double = RasterRedactor.defaultDPI
    ) throws -> RedactionOutcome {
        guard !marks.isEmpty else { throw RedactionRefusal.noMarks }
        try StagedFileReplacement.refuseOverwriting([source], with: output, refusal: RedactionRefusal.outputIsSource)
        let prepared = try prepare(source: source, password: password, marks: marks)
        return try redact(prepared, source: source, password: password, marks: marks, to: output, dpi: dpi)
    }

    /// Builds, proves and writes the copy from a preparation of exactly this source and these
    /// marks. The preparation is spent: building it adds to its rewrite context.
    static func redact(
        _ prepared: Prepared, source: URL, password: String?, marks: [RedactionMark], to output: URL, dpi: Double
    ) throws -> RedactionOutcome {
        guard let scan = prepared.scan, let entries = prepared.entries else {
            // No object layer to copy the unmarked sheets from: the whole redaction is raster.
            var outcome = try RasterRedactor.redact(source: source, password: password, marks: marks, to: output, dpi: dpi)
            outcome.method = .vector
            outcome.rasterFallbacks = prepared.fallbacks
            return outcome
        }
        let built = try build(prepared, scan: scan, entries: entries, dpi: dpi)
        let checks = try verify(built, prepared: prepared)

        try StagedFileReplacement.write(
            to: output, protecting: [source], refusal: RedactionRefusal.outputIsSource, stagingPrefix: ".zpdf-redact-"
        ) { staging in
            try built.bytes.write(to: staging, options: .atomic)
        }
        return RedactionOutcome(
            redactedPages: prepared.byPage.keys.sorted(),
            markCount: marks.count,
            removedWordCount: built.words.count,
            checks: checks,
            method: .vector,
            vectorPages: prepared.rewritten.keys.sorted(),
            rasterFallbacks: prepared.fallbacks
        )
    }

    // MARK: - Preparation: read, and rewrite every marked sheet

    struct RewrittenPage {
        var operations: [RedactionOperation]
        var endsInText: Bool
        var resources: [String: PDFObject]
        var work: RedactionPageWork
    }

    /// Page text read once: the word checks ask for it per word and per sheet.
    final class TextCache {
        private let document: PDFDocument
        private var pages: [Int: String] = [:]
        /// What PDFKit selects under each box, per marked sheet.
        let selections: [Int: [String]]

        init(document: PDFDocument, byPage: [Int: [RedactionMark]]) {
            self.document = document
            var selections: [Int: [String]] = [:]
            for (index, marks) in byPage {
                selections[index] = marks.map { document.page(at: index)?.selection(for: $0.rect)?.string ?? "" }
            }
            self.selections = selections
        }

        func text(_ index: Int) -> String {
            if let cached = pages[index] { return cached }
            let text = document.page(at: index)?.string ?? ""
            pages[index] = text
            return text
        }
    }

    struct Prepared {
        var document: PDFDocument
        var sourceData: Data
        var byPage: [Int: [RedactionMark]]
        var texts: TextCache
        var scan: PDFDocumentScan?
        var entries: [PDFDocumentScan.PageEntry]?
        var pool: RedactionObjectPool
        var rewritten: [Int: RewrittenPage] = [:]
        var fallbacks: [RedactionFallback] = []
        /// What the rewrite learned: what lay under the boxes, and the objects that reach it.
        var context: RedactionRewriteContext?
    }

    static func prepare(source: URL, password: String?, marks: [RedactionMark]) throws -> Prepared {
        guard !marks.isEmpty else { throw RedactionRefusal.noMarks }
        guard let document = PDFDocument(url: source), let data = try? Data(contentsOf: source) else { throw RedactionRefusal.unreadable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password), !document.isLocked else { throw RedactionRefusal.locked }
        }
        let byPage = Dictionary(grouping: marks, by: \.pageIndex)
        for (index, pageMarks) in byPage {
            guard let page = document.page(at: index) else { throw RedactionRefusal.markOutsidePage(index) }
            let media = page.bounds(for: .mediaBox)
            for mark in pageMarks where !mark.rect.intersects(media) { throw RedactionRefusal.markOutsidePage(index) }
        }
        var prepared = Prepared(
            document: document, sourceData: data, byPage: byPage, texts: TextCache(document: document, byPage: byPage), pool: RedactionObjectPool()
        )
        let marked = byPage.keys.sorted()
        let scan: PDFDocumentScan
        do {
            scan = try PDFDocumentScan(data: data, honoringFreeEntries: true)
        } catch {
            let reason = document.isEncrypted
                ? "the drawing is encrypted, and the vector rewriter reads only unencrypted files"
                : "the drawing's object layer cannot be read"
            prepared.fallbacks = marked.map { RedactionFallback(pageIndex: $0, reason: reason) }
            return prepared
        }
        guard let entries = try? scan.pages(), entries.count == document.pageCount else {
            prepared.fallbacks = marked.map { RedactionFallback(pageIndex: $0, reason: "the drawing's page tree cannot be read exactly") }
            return prepared
        }
        prepared.scan = scan
        prepared.entries = entries
        let context = RedactionRewriteContext(scan: scan, pool: prepared.pool)

        // Pass 1: each marked sheet under its boxes, to learn what lay under them.
        var fallbacks: [Int: String] = [:]
        for index in marked {
            do {
                _ = try rewritePage(entries[index], boxes: byPage[index]?.map(\.rect) ?? [], context: context)
            } catch {
                fallbacks[index] = (error as? RedactionUnsupported)?.reason ?? "the sheet's content could not be read"
            }
        }
        // A sheet that becomes a picture is still read, to learn what lay under its boxes: a
        // picture or form drawn there and again elsewhere must not travel whole (ADR-0033 §11).
        var surveyed: Set<Int> = []
        // Pass 2: again, knowing everything that lay under a box anywhere, so every other use of it
        // on a marked sheet is examined. A sheet that fails now falls back as well, and pass 2
        // runs again with what it adds.
        var rewritten: [Int: RewrittenPage] = [:]
        while true {
            for index in fallbacks.keys.sorted() where !surveyed.contains(index) {
                surveyed.insert(index)
                survey(entries[index], boxes: byPage[index]?.map(\.rect) ?? [], context: context)
            }
            context.dirty = dirtyClosure(scan, tainted: context.tainted)
            context.justified = []
            context.drawnCodes = [:]
            rewritten = [:]
            var failed = false
            for index in marked where fallbacks[index] == nil {
                do {
                    rewritten[index] = try rewritePage(entries[index], boxes: byPage[index]?.map(\.rect) ?? [], context: context)
                } catch {
                    fallbacks[index] = (error as? RedactionUnsupported)?.reason ?? "the sheet's content could not be read"
                    failed = true
                    break
                }
            }
            if !failed { break }
        }
        prepared.rewritten = rewritten
        prepared.fallbacks = fallbacks.keys.sorted().map { RedactionFallback(pageIndex: $0, reason: fallbacks[$0] ?? "") }
        prepared.pool = context.pool
        prepared.context = context
        return prepared
    }

    static func rewritePage(_ entry: PDFDocumentScan.PageEntry, boxes: [CGRect], context: RedactionRewriteContext) throws -> RewrittenPage {
        setUp(entry, boxes: boxes, context: context)
        let content = try pageContent(entry, context: context)
        let operations = try RedactionContentLexer.parse(content)
        let resources = context.resolve(entry.inheritedResources)?.dictionaryValue ?? [:]
        var rewriter = RedactionContentRewriter(context: context, resources: resources, ctm: .identity)
        let output = try rewriter.rewrite(operations)
        return RewrittenPage(operations: output.operations, endsInText: output.endsInText, resources: output.resources, work: context.work)
    }

    /// Points the context at one sheet: its boxes, its visible area, its frame.
    @discardableResult
    static func setUp(_ entry: PDFDocumentScan.PageEntry, boxes: [CGRect], context: RedactionRewriteContext) -> CGRect {
        context.boxes = boxes
        context.cropRect = nil
        context.work = RedactionPageWork()
        let media = rect(context.resolve(entry.inheritedMediaBox), context) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let crop = rect(context.resolve(entry.inheritedCropBox), context)?.intersection(media) ?? media
        context.visibleBox = crop.isNull ? media : crop
        context.frame = boxes.reduce(media) { $0.union($1) }.insetBy(dx: -1000, dy: -1000)
        return media
    }

    /// Reads a sheet that becomes a picture under its boxes without stopping at what cannot be
    /// cut, marking what lay under them; a sheet that cannot be read at all marks every picture,
    /// form and font its content names.
    static func survey(_ entry: PDFDocumentScan.PageEntry, boxes: [CGRect], context: RedactionRewriteContext) {
        context.surveying = true
        defer { context.surveying = false }
        do {
            _ = try rewritePage(entry, boxes: boxes, context: context)
        } catch {
            let resources = context.resolve(entry.inheritedResources)?.dictionaryValue ?? [:]
            var names: [String: Set<String>]?
            if let content = try? pageContent(entry, context: context), let operations = try? RedactionContentLexer.parse(content) {
                names = usedNames(operations)
            }
            for category in ["XObject", "Font"] {
                let entries = context.resolve(resources[category])?.dictionaryValue ?? [:]
                for (name, value) in entries where names?[category]?.contains(name) ?? true {
                    context.surveyTaint([value])
                }
            }
        }
    }

    /// The resource names a content stream uses, by category.
    static func usedNames(_ operations: [RedactionOperation]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for operation in operations {
            let first = operation.operands.first?.nameValue
            switch operation.name {
            case "Do": if let first { out["XObject", default: []].insert(first) }
            case "Tf": if let first { out["Font", default: []].insert(first) }
            case "gs": if let first { out["ExtGState", default: []].insert(first) }
            case "sh": if let first { out["Shading", default: []].insert(first) }
            case "scn", "SCN": if let name = operation.operands.last?.nameValue { out["Pattern", default: []].insert(name) }
            default: break
            }
        }
        return out
    }

    /// Every object that reaches one in `tainted` by reference — a resource dictionary holding a
    /// picture cut under a box, a form drawing it, a pattern cell using it (findings 4, 8, 11).
    /// Links up the page tree and to destinations are not followed: a page does not make what it
    /// points at shared.
    static func dirtyClosure(_ scan: PDFDocumentScan, tainted: Set<Int>) -> Set<Int> {
        guard !tainted.isEmpty else { return [] }
        var reverse: [Int: [Int]] = [:]
        for (number, entry) in scan.objects {
            var targets: [Int] = []
            references(entry.object, into: &targets, depth: 0)
            for target in targets { reverse[target, default: []].append(number) }
        }
        var dirty = tainted
        var queue = Array(tainted)
        while let number = queue.popLast() {
            for parent in reverse[number] ?? [] where !dirty.contains(parent) {
                dirty.insert(parent)
                queue.append(parent)
            }
        }
        return dirty
    }

    private static let unfollowedKeys: Set<String> = [
        "Parent", "P", "StructParent", "StructParents", "Prev", "Next", "First", "Last", "Dest", "D", "A", "IRT", "Popup", "Kids", "Annots", "B"
    ]

    private static func references(_ object: PDFObject, into targets: inout [Int], depth: Int) {
        guard depth < 64 else { return }
        switch object {
        case let .reference(number, _): targets.append(number)
        case let .array(values): for value in values { references(value, into: &targets, depth: depth + 1) }
        case let .dictionary(entries), let .stream(entries, _):
            for (key, value) in entries where !unfollowedKeys.contains(key) { references(value, into: &targets, depth: depth + 1) }
        default: break
        }
    }

    /// Whether `object` (direct or not) reaches something that lay under a box.
    static func reachesDirty(_ object: PDFObject?, _ context: RedactionRewriteContext, depth: Int = 0) -> Bool {
        guard let object, depth < 32 else { return false }
        switch object {
        case let .reference(number, _): return context.dirty.contains(number)
        case let .array(values): return values.contains { reachesDirty($0, context, depth: depth + 1) }
        case let .dictionary(entries), let .stream(entries, _): return entries.values.contains { reachesDirty($0, context, depth: depth + 1) }
        default: return false
        }
    }

    static func pageContent(_ entry: PDFDocumentScan.PageEntry, context: RedactionRewriteContext) throws -> Data {
        var parts: [PDFObject] = []
        switch context.resolve(entry.dictionary["Contents"]) {
        case .stream?: parts = [entry.dictionary["Contents"]].compactMap { $0 }
        case let .array(items)?: parts = items
        case nil, .null?: return Data()
        default: throw RedactionUnsupported("the sheet's content is not a stream")
        }
        var out = Data()
        for part in parts {
            out.append(try RedactionStreamFilters.decodeFully(context.resolve(part)))
            out.append(0x0A)
        }
        return out
    }

    static func rect(_ object: PDFObject?, _ context: RedactionRewriteContext) -> CGRect? {
        RedactionContentRewriter.rect(object, context)
    }

    // MARK: - Building the copy

    struct Built {
        var bytes: Data
        /// Bytes of the copy without the black boxes, for the check that nothing is painted
        /// under them.
        var unboxed: Data
        var words: [String]
        var rasterPages: Set<Int>
        var removedGlyphQuads: [Int: [[CGPoint]]]
        /// Source objects the copy holds in their original form.
        var writtenSources: Set<Int> = []
        /// Source objects cut or removed under a box, and those of them shown whole by a use
        /// that keeps them.
        var tainted: Set<Int> = []
        var justified: Set<Int> = []
        /// Values of form fields that went because they showed only under a box.
        var removedFieldValues: [String] = []
        /// Per sheet, where annotations went: the render comparison ignores those places.
        var removedAnnotationRects: [Int: [CGRect]] = [:]
    }

    static func build(_ prepared: Prepared, scan: PDFDocumentScan, entries: [PDFDocumentScan.PageEntry], dpi: Double) throws -> Built {
        let context = prepared.context ?? RedactionRewriteContext(scan: scan, pool: prepared.pool)
        let resolve: (PDFObject?) -> PDFObject? = { scan.object($0) }
        var writer = RedactionDocumentWriter(source: scan, pool: context.pool)
        writer.droppedKeys.formUnion(["StructParents", "StructParent", "SE"])

        var boxesByPage: [Int: [CGRect]] = [:]
        for (index, marks) in prepared.byPage { boxesByPage[index] = marks.map(\.rect) }
        var pageIndexByNumber: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() { pageIndexByNumber[entry.number] = index }
        let catalog = scan.dictionary(scan.rootReference) ?? [:]
        let named = namedDestinations(catalog, resolve: resolve)
        let targeting = DestinationTargeting(resolve: resolve, pageIndexByNumber: pageIndexByNumber, boxesByPage: boxesByPage, named: named)

        // The page objects, reserved first so every reference to an old page can point at the new one.
        let pagesNumber = context.pool.reserve()
        let pagesReference = PDFObject.reference(number: pagesNumber, generation: 0)
        var pageNumbers: [Int] = []
        for entry in entries {
            let number = context.pool.reserve()
            pageNumbers.append(number)
            writer.pageMap[entry.number] = .reference(number: number, generation: 0)
        }

        // Words that stood under the boxes.
        var words = Set(RasterRedactor.wordsUnderMarks(prepared.document, marks: prepared.byPage.values.flatMap { $0 }))
        for page in prepared.rewritten.values {
            for word in page.work.removedWords {
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                if trimmed.count >= 3 { words.insert(trimmed) }
            }
        }

        var removed: Set<Int> = []
        var rasterPages: Set<Int> = []
        var unboxedContents: [Int: PDFObject] = [:]
        let fallbackPages = Set(prepared.fallbacks.map(\.pageIndex))
        var removedAnnotationRects: [Int: [CGRect]] = [:]

        // Annotations first: which go, on every sheet.
        var keptAnnotations: [Int: [PDFObject]] = [:]
        var removedParents: Set<Int> = []
        var removedUnderBox: Set<Int> = []
        var annotationPage: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let boxes = boxesByPage[index] ?? []
            let items = resolve(entry.dictionary["Annots"])?.arrayValue ?? []
            var kept: [PDFObject] = []
            for item in items {
                guard let annotation = resolve(item)?.dictionaryValue else { continue }
                let number = item.referenceValue?.number
                if let number { annotationPage[number] = index }
                var drop = fallbackPages.contains(index)
                if !boxes.isEmpty, let rect = rect(resolve(annotation["Rect"]), scan: scan),
                   boxes.contains(where: { RedactionGeometry.intersects(rect.insetBy(dx: -0.01, dy: -0.01), $0) }) {
                    drop = true
                    if let number { removedUnderBox.insert(number) }
                }
                if !drop, targeting.targetsBox(annotation["Dest"]) || targeting.actionTargetsBox(annotation["A"]) { drop = true }
                // Attachments and embedded media travel inside the annotation (finding 17).
                if !drop, let subtype = resolve(annotation["Subtype"])?.nameValue, Self.droppedAnnotationKinds.contains(subtype) { drop = true }
                if drop {
                    if let number { removed.insert(number); removedParents.insert(number) }
                    if let rect = rect(resolve(annotation["Rect"]), scan: scan) { removedAnnotationRects[index, default: []].append(rect) }
                } else {
                    kept.append(item)
                }
            }
            keptAnnotations[index] = kept
        }

        // A form field whose value showed only under a box goes with every widget it has, hidden
        // ones included (finding 2); a button field keeps only the state its visible widgets show.
        var removedFieldValues: [String] = []
        let form = resolve(catalog["AcroForm"])?.dictionaryValue
        if let fields = resolve(form?["Fields"])?.arrayValue {
            let keptNumbers = Set(keptAnnotations.values.flatMap { $0 }.compactMap { $0.referenceValue?.number })
            let work = cleanFields(fields, removedUnderBox: removedUnderBox, removed: removed, kept: keptNumbers, resolve: resolve, pool: &context.pool)
            removed.formUnion(work.removed)
            removedParents.formUnion(work.removed)
            removedFieldValues = work.values
            for (number, replacement) in work.replacements { writer.replacements[number] = replacement }
            for number in work.removed {
                if let index = annotationPage[number], let rect = rect(resolve(resolve(.reference(number: number, generation: 0))?.dictionaryValue?["Rect"]), scan: scan) {
                    removedAnnotationRects[index, default: []].append(rect)
                }
            }
        }
        // Pop-ups and replies of removed annotations go with them.
        for index in keptAnnotations.keys {
            keptAnnotations[index] = keptAnnotations[index]?.filter { item in
                guard let annotation = resolve(item)?.dictionaryValue else { return false }
                if let number = item.referenceValue?.number, removed.contains(number) { return false }
                let parent = annotation["Parent"]?.referenceValue?.number ?? annotation["IRT"]?.referenceValue?.number
                if let parent, removedParents.contains(parent), resolve(annotation["Subtype"])?.nameValue != "Widget" {
                    if let number = item.referenceValue?.number { removed.insert(number) }
                    if let rect = rect(resolve(annotation["Rect"]), scan: scan) { removedAnnotationRects[index, default: []].append(rect) }
                    return false
                }
                return true
            }
        }

        // Unmarked sheets that share something with a redacted area are rewritten without boxes,
        // so the resources they carry are only those they use and a picture or form cut under a
        // box travels only as far as each of them shows it (findings 4, 8). A sheet that cannot
        // be rewritten refuses the copy rather than carry the original along.
        var unresolved: String?
        var foreignIndex = 0
        for (index, entry) in entries.enumerated() {
            var page = entry.dictionary
            for key in ["Parent", "Annots", "Thumb", "B", "PieceInfo", "Metadata", "AA", "StructParents", "ID", "PZ",
                        "SeparationInfo", "Resources", "Contents", "MediaBox", "CropBox", "Rotate"] {
                page.removeValue(forKey: key)
            }
            page["Type"] = .name("Page")
            page["Parent"] = pagesReference
            if let media = entry.inheritedMediaBox { page["MediaBox"] = media }
            if let crop = entry.inheritedCropBox { page["CropBox"] = crop }
            if let rotation = entry.inheritedRotation { page["Rotate"] = rotation }

            if let rewritten = prepared.rewritten[index] {
                let content = balancedContent(rewritten)
                let boxes = boxesByPage[index] ?? []
                var boxOps: [RedactionOperation] = [RedactionOperation("q"), RedactionOperation("rg", [.integer(0), .integer(0), .integer(0)])]
                for box in boxes {
                    boxOps.append(RedactionOperation("re", [.real(box.minX), .real(box.minY), .real(box.width), .real(box.height)]))
                }
                boxOps.append(RedactionOperation("f"))
                boxOps.append(RedactionOperation("Q"))
                let contentReference = context.pool.add(stream(RedactionContentLexer.serialize(content)))
                let boxReference = context.pool.add(stream(RedactionContentLexer.serialize(boxOps)))
                page["Contents"] = .array([contentReference, boxReference])
                page["Resources"] = .dictionary(rewritten.resources)
                unboxedContents[index] = .array([contentReference])
            } else if boxesByPage[index] != nil, let pdfPage = prepared.document.page(at: index) {
                // Falls back: the sheet as a picture of itself, imported from a one-page document.
                let data = try RasterRedactor.rasterPageDocument(pdfPage, marks: prepared.byPage[index] ?? [], index: index, dpi: dpi)
                let rasterScan = try PDFDocumentScan(data: data)
                guard let rasterPage = try rasterScan.pages().first else { throw RedactionRefusal.checkFailed("sheet \(index + 1) did not render") }
                writer.foreign.append(rasterScan)
                foreignIndex = writer.foreign.count
                for key in ["CropBox", "Rotate", "Annots", "UserUnit", "VP", "Group"] { page.removeValue(forKey: key) }
                page["MediaBox"] = rasterPage.inheritedMediaBox.map { writer.rebase($0, origin: foreignIndex) }
                if let contents = rasterPage.dictionary["Contents"] { page["Contents"] = writer.rebase(contents, origin: foreignIndex) }
                if let resources = rasterPage.inheritedResources { page["Resources"] = writer.rebase(resources, origin: foreignIndex) }
                rasterPages.insert(index)
            } else if reachesDirty(entry.inheritedResources, context) {
                do {
                    let output = try rewriteUnmarked(entry, context: context)
                    if output.changed {
                        page["Contents"] = context.pool.add(stream(RedactionContentLexer.serialize(output.operations + (output.endsInText ? [RedactionOperation("ET")] : []))))
                    } else if let contents = entry.dictionary["Contents"] {
                        page["Contents"] = contents
                    }
                    page["Resources"] = .dictionary(output.resources)
                } catch {
                    unresolved = unresolved ?? "sheet \(index + 1) shares a picture, form, pattern or font with a redacted area in a way that cannot be rewritten (\((error as? RedactionUnsupported)?.reason ?? "its content cannot be read")); mark it too, or redact as pictures"
                    if let contents = entry.dictionary["Contents"] { page["Contents"] = contents }
                    if let resources = entry.inheritedResources { page["Resources"] = resources }
                }
            } else {
                if let contents = entry.dictionary["Contents"] { page["Contents"] = contents }
                if let resources = entry.inheritedResources { page["Resources"] = resources }
            }

            // Kept annotations whose appearance draws something cut under a box get their
            // appearance rewritten the same way.
            var annotations: [PDFObject] = []
            for item in keptAnnotations[index] ?? [] {
                guard reachesDirty(resolve(item)?.dictionaryValue?["AP"], context), let annotation = resolve(item)?.dictionaryValue else {
                    annotations.append(item)
                    continue
                }
                do {
                    let rewritten = try rewriteAppearances(annotation, entry: entry, context: context)
                    let copy = context.pool.add(.dictionary(rewritten))
                    if let number = item.referenceValue?.number, case let .reference(synthetic, _) = copy {
                        writer.replacements[number] = synthetic
                        annotations.append(item)
                    } else {
                        annotations.append(copy)
                    }
                } catch {
                    unresolved = unresolved ?? "an annotation on sheet \(index + 1) draws something that lay under a box in a way that cannot be rewritten; delete it or redact as pictures"
                    annotations.append(item)
                }
            }
            if !annotations.isEmpty { page["Annots"] = .array(annotations) }
            context.pool.set(pageNumbers[index], .dictionary(page))
        }
        context.pool.set(pagesNumber, .dictionary([
            "Type": .name("Pages"),
            "Kids": .array(pageNumbers.map { .reference(number: $0, generation: 0) }),
            "Count": .integer(pageNumbers.count)
        ]))
        if let unresolved { throw RedactionRefusal.checkFailed(unresolved) }

        // Fonts that lost glyphs under a box keep only the codes still drawn: widths, Unicode
        // entries, glyph procedures and glyph outlines of characters that stood only in the
        // removed text do not travel (findings 9, 19).
        for number in context.taintedFonts.sorted() {
            guard let font = resolve(.reference(number: number, generation: 0))?.dictionaryValue else { continue }
            do {
                let pruned = try RedactionFontPruner.prune(font, codes: context.drawnCodes[number] ?? [], context: context)
                if case let .reference(synthetic, _) = pruned { writer.replacements[number] = synthetic }
            } catch {
                throw RedactionRefusal.checkFailed("a font that lost characters under a box could not be reduced to the characters still shown (\((error as? RedactionUnsupported)?.reason ?? "unreadable"))")
            }
        }

        // Fields whose every widget went.
        var newCatalog: [String: PDFObject] = ["Type": .name("Catalog"), "Pages": pagesReference]
        if let form, let fields = resolve(form["Fields"])?.arrayValue {
            var visited: Set<Int> = []
            let keptFields = fields.filter { !fieldIsGone($0, removed: &removed, resolve: resolve, visited: &visited, depth: 0) }
            if !keptFields.isEmpty {
                var newForm = form
                newForm.removeValue(forKey: "XFA")
                newForm["Fields"] = .array(keptFields)
                newCatalog["AcroForm"] = context.pool.add(.dictionary(newForm))
            }
        }
        for key in ["PageLabels", "OCProperties", "ViewerPreferences", "PageLayout", "PageMode", "Lang", "OutputIntents"] {
            if let value = catalog[key] { newCatalog[key] = value }
        }
        // Words that exist only under the boxes: a bookmark titled with one goes too.
        // Counted without regard to case: “Falcon” in a title is the “FALCON” that stood under
        // the box unless the word is readable, in some case, outside the boxes (finding 3).
        let secretWords = words.filter { word in
            (0..<prepared.document.pageCount).allSatisfy { index in
                RedactionWordSearch.occurrences(of: word, in: prepared.texts.text(index), caseInsensitive: true)
                    <= underBoxCount(word, prepared: prepared, page: index, caseInsensitive: true)
            }
        }
        if let outlines = rebuildOutlines(catalog["Outlines"], targeting: targeting, secretWords: secretWords, resolve: resolve, pool: &context.pool) {
            newCatalog["Outlines"] = outlines
        }
        let keptNamed = named.filter { !targeting.targetsBox($0.value) }
        if resolve(catalog["Dests"])?.dictionaryValue != nil {
            var dests: [String: PDFObject] = [:]
            for (key, value) in keptNamed where key.hasPrefix("n:") { dests[String(key.dropFirst(2))] = value }
            if !dests.isEmpty { newCatalog["Dests"] = context.pool.add(.dictionary(dests)) }
        }
        let treeEntries = keptNamed.filter { $0.key.hasPrefix("s:") }.sorted { $0.key < $1.key }
        if !treeEntries.isEmpty {
            let names: [PDFObject] = treeEntries.flatMap { [PDFObject.string(Array($0.key.dropFirst(2).unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })), $0.value] }
            newCatalog["Names"] = .dictionary(["Dests": context.pool.add(.dictionary(["Names": .array(names)]))])
        }

        writer.pool = context.pool
        writer.removed = removed
        let info: [String: PDFObject] = ["Producer": .string(Array("Zenit PDF".utf8))]
        let bytes = try writer.write(catalog: .dictionary(newCatalog), info: info)
        let written = writer.writtenSources

        // The same copy with the boxes left out, for the check that nothing is painted under them.
        var unboxedWriter = writer
        var unboxedPool = context.pool
        for (index, contents) in unboxedContents {
            if case var .dictionary(page)? = unboxedPool.objects[pageNumbers[index]] {
                page["Contents"] = contents
                unboxedPool.set(pageNumbers[index], .dictionary(page))
            }
        }
        unboxedWriter.pool = unboxedPool
        let unboxed = try unboxedWriter.write(catalog: .dictionary(newCatalog), info: info)

        var quads: [Int: [[CGPoint]]] = [:]
        for (index, page) in prepared.rewritten { quads[index] = page.work.removedGlyphQuads }
        return Built(
            bytes: bytes, unboxed: unboxed, words: words.sorted(), rasterPages: rasterPages, removedGlyphQuads: quads,
            writtenSources: written, tainted: context.tainted,
            justified: context.justified, removedFieldValues: removedFieldValues,
            removedAnnotationRects: removedAnnotationRects
        )
    }

    /// An unmarked sheet rewritten without boxes: its resources pruned to what it uses, and every
    /// use of something cut under a box examined.
    static func rewriteUnmarked(_ entry: PDFDocumentScan.PageEntry, context: RedactionRewriteContext) throws -> RedactionContentRewriter.Output {
        setUp(entry, boxes: [], context: context)
        let content = try pageContent(entry, context: context)
        let operations = try RedactionContentLexer.parse(content)
        let resources = context.resolve(entry.inheritedResources)?.dictionaryValue ?? [:]
        var rewriter = RedactionContentRewriter(context: context, resources: resources, ctm: .identity)
        return try rewriter.rewrite(operations)
    }

    /// An annotation whose appearance streams are rewritten without boxes for where the
    /// annotation draws them (ISO 32000-1 §12.5.5): each stream's box mapped onto the annotation's
    /// rectangle, clipped to it — or to nothing, when the annotation is hidden.
    static func rewriteAppearances(_ annotation: [String: PDFObject], entry: PDFDocumentScan.PageEntry, context: RedactionRewriteContext) throws -> [String: PDFObject] {
        guard var appearances = context.resolve(annotation["AP"])?.dictionaryValue,
              let rect = rect(context.resolve(annotation["Rect"]), context) else { return annotation }
        let flags = context.resolve(annotation["F"])?.integerValue ?? 0
        let hidden = flags & 2 != 0 || flags & 32 != 0
        func rewrite(_ reference: PDFObject) throws -> PDFObject {
            guard reachesDirty(reference, context), case let .stream(dictionary, data)? = context.resolve(reference) else { return reference }
            let bbox = RedactionContentRewriter.rect(context.resolve(dictionary["BBox"]), context) ?? .null
            let matrix = RedactionContentRewriter.matrix(context.resolve(dictionary["Matrix"]), context) ?? .identity
            let transformed = bbox.applying(matrix)
            var placement = matrix
            if !transformed.isNull, transformed.width > 0, transformed.height > 0 {
                let fit = CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
                    .concatenating(CGAffineTransform(scaleX: rect.width / transformed.width, y: rect.height / transformed.height))
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
                placement = matrix.concatenating(fit)
            }
            setUp(entry, boxes: [], context: context)
            context.visibleBox = hidden ? .null : rect
            let content = try RedactionStreamFilters.decode(dictionary: dictionary, data: data).data
            let operations = try RedactionContentLexer.parse(content)
            let resources = context.resolve(dictionary["Resources"])?.dictionaryValue ?? [:]
            var rewriter = RedactionContentRewriter(context: context, resources: resources, ctm: placement)
            let output = try rewriter.rewrite(operations)
            var copy = dictionary
            for key in ["Length", "Metadata", "PieceInfo", "StructParents", "StructParent"] { copy.removeValue(forKey: key) }
            copy["Resources"] = .dictionary(output.resources)
            var payload = data
            if output.changed {
                copy.removeValue(forKey: "Filter")
                copy.removeValue(forKey: "DecodeParms")
                let serialized = RedactionContentLexer.serialize(output.operations)
                payload = serialized
                if let flate = PDFStreamCodec.flateEncode(serialized) {
                    payload = flate
                    copy["Filter"] = .name("FlateDecode")
                }
            }
            return context.pool.add(.stream(dictionary: copy, data: payload))
        }
        for key in ["N", "R", "D"] {
            guard let value = appearances[key] else { continue }
            if case .stream? = context.resolve(value) {
                appearances[key] = try rewrite(value)
            } else if var states = context.resolve(value)?.dictionaryValue {
                for (state, stream) in states { states[state] = try rewrite(stream) }
                appearances[key] = .dictionary(states)
            }
        }
        var copy = annotation
        copy["AP"] = .dictionary(appearances)
        return copy
    }

    /// Annotations that carry files or media, dropped on every sheet like the document's
    /// attachments.
    static let droppedAnnotationKinds: Set<String> = ["FileAttachment", "Sound", "Movie", "Screen", "RichMedia", "3D"]

    private static func stream(_ data: Data) -> PDFObject {
        if let flate = PDFStreamCodec.flateEncode(data) {
            return .stream(dictionary: ["Filter": .name("FlateDecode")], data: flate)
        }
        return .stream(dictionary: [:], data: data)
    }

    /// The rewritten operators bracketed so they can neither pop below the page's default state
    /// nor leave it changed for the boxes painted after them.
    private static func balancedContent(_ page: RewrittenPage) -> [RedactionOperation] {
        var depth = 0, minimum = 0
        for operation in page.operations {
            if operation.name == "q" { depth += 1 }
            if operation.name == "Q" { depth -= 1; minimum = min(minimum, depth) }
        }
        let before = 1 + max(0, -minimum)
        var out = Array(repeating: RedactionOperation("q"), count: before)
        out.append(contentsOf: page.operations)
        if page.endsInText { out.append(RedactionOperation("ET")) }
        out.append(contentsOf: Array(repeating: RedactionOperation("Q"), count: before + depth))
        return out
    }

    private static func rect(_ object: PDFObject?, scan: PDFDocumentScan) -> CGRect? {
        guard let values = object?.arrayValue?.compactMap({ scan.object($0)?.doubleValue }), values.count == 4 else { return nil }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]), width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }

    /// Whether a form field is gone because every widget it had is; marks it removed if so.
    private static func fieldIsGone(
        _ field: PDFObject, removed: inout Set<Int>, resolve: (PDFObject?) -> PDFObject?, visited: inout Set<Int>, depth: Int
    ) -> Bool {
        guard depth < 32 else { return false }
        if let number = field.referenceValue?.number {
            if removed.contains(number) { return true }
            guard !visited.contains(number) else { return false }
            visited.insert(number)
        }
        guard let dictionary = resolve(field)?.dictionaryValue else { return true }
        guard let kids = resolve(dictionary["Kids"])?.arrayValue, !kids.isEmpty else { return false }
        var allGone = true
        for kid in kids where !fieldIsGone(kid, removed: &removed, resolve: resolve, visited: &visited, depth: depth + 1) {
            allGone = false
        }
        if allGone, let number = field.referenceValue?.number { removed.insert(number) }
        return allGone
    }

    struct FieldWork {
        var removed: Set<Int> = []
        var values: [String] = []
        var replacements: [Int: Int] = [:]
    }

    /// Terminal fields that lost a widget under a box: when none of the widgets left is visible
    /// (hidden, not viewable, empty, or gone), the field and every widget go; a button field
    /// that keeps a visible widget keeps only the state its visible widgets show (finding 2).
    static func cleanFields(
        _ fields: [PDFObject], removedUnderBox: Set<Int>, removed: Set<Int>, kept: Set<Int>,
        resolve: (PDFObject?) -> PDFObject?, pool: inout RedactionObjectPool
    ) -> FieldWork {
        var work = FieldWork()
        var visited: Set<Int> = []
        var copies: [(Int, [String: PDFObject])] = []
        func visible(_ widget: PDFObject) -> Bool {
            guard let number = widget.referenceValue?.number, !removed.contains(number), kept.contains(number),
                  let dictionary = resolve(widget)?.dictionaryValue else { return false }
            let flags = resolve(dictionary["F"])?.integerValue ?? 0
            guard flags & 2 == 0, flags & 32 == 0 else { return false }
            guard let values = resolve(dictionary["Rect"])?.arrayValue?.compactMap({ resolve($0)?.doubleValue }), values.count == 4,
                  abs(values[2] - values[0]) > 0.5, abs(values[3] - values[1]) > 0.5 else { return false }
            return true
        }
        func walk(_ node: PDFObject, type inherited: String?, depth: Int) {
            guard depth < 32, let dictionary = resolve(node)?.dictionaryValue else { return }
            if let number = node.referenceValue?.number {
                guard visited.insert(number).inserted else { return }
            }
            let type = resolve(dictionary["FT"])?.nameValue ?? inherited
            var widgets: [PDFObject] = []
            if resolve(dictionary["Subtype"])?.nameValue == "Widget" { widgets.append(node) }
            for kid in resolve(dictionary["Kids"])?.arrayValue ?? [] {
                guard let kidDictionary = resolve(kid)?.dictionaryValue else { continue }
                if kidDictionary["T"] == nil, resolve(kidDictionary["Subtype"])?.nameValue == "Widget" {
                    widgets.append(kid)
                } else {
                    walk(kid, type: type, depth: depth + 1)
                }
            }
            let numbers = widgets.compactMap { $0.referenceValue?.number }
            guard numbers.contains(where: removedUnderBox.contains) else { return }
            let showing = widgets.filter(visible)
            if showing.isEmpty {
                if let number = node.referenceValue?.number { work.removed.insert(number) }
                work.removed.formUnion(numbers)
                for key in ["V", "DV", "RV"] {
                    if let text = fieldText(dictionary[key], resolve), !text.isEmpty { work.values.append(text) }
                }
            } else if type == "Btn", let number = node.referenceValue?.number {
                var copy = dictionary
                let on = showing.compactMap { resolve(resolve($0)?.dictionaryValue?["AS"])?.nameValue }.first { $0 != "Off" }
                copy["V"] = .name(on ?? "Off")
                copy.removeValue(forKey: "Opt")
                copy.removeValue(forKey: "DV")
                copies.append((number, copy))
            }
        }
        for field in fields { walk(field, type: nil, depth: 0) }
        for (number, copy) in copies {
            if case let .reference(synthetic, _) = pool.add(.dictionary(copy)) { work.replacements[number] = synthetic }
        }
        return work
    }

    static func fieldText(_ object: PDFObject?, _ resolve: (PDFObject?) -> PDFObject?) -> String? {
        switch resolve(object) {
        case let .string(bytes)?, let .hexString(bytes)?: return text(bytes)
        case let .array(items)?: return items.compactMap { fieldText($0, resolve) }.joined(separator: " ")
        default: return nil
        }
    }

    // MARK: - Destinations, bookmarks

    /// Named destinations: `n:` keys from the catalog's `/Dests`, `s:` keys from the name tree.
    private static func namedDestinations(_ catalog: [String: PDFObject], resolve: (PDFObject?) -> PDFObject?) -> [String: PDFObject] {
        var out: [String: PDFObject] = [:]
        if let dests = resolve(catalog["Dests"])?.dictionaryValue {
            for (key, value) in dests { out["n:" + key] = value }
        }
        func walk(_ node: PDFObject?, depth: Int) {
            guard depth < 32, let dictionary = resolve(node)?.dictionaryValue else { return }
            if let names = resolve(dictionary["Names"])?.arrayValue {
                var index = 0
                while index + 1 < names.count {
                    if let key = stringBytes(resolve(names[index])) { out["s:" + latin1(key)] = names[index + 1] }
                    index += 2
                }
            }
            for kid in resolve(dictionary["Kids"])?.arrayValue ?? [] { walk(kid, depth: depth + 1) }
        }
        walk(resolve(catalog["Names"])?.dictionaryValue?["Dests"], depth: 0)
        return out
    }

    static func stringBytes(_ object: PDFObject?) -> [UInt8]? {
        switch object {
        case let .string(bytes)?, let .hexString(bytes)?: bytes
        default: nil
        }
    }

    static func text(_ bytes: [UInt8]) -> String {
        if bytes.starts(with: [0xFE, 0xFF]) { return RedactionCMap.utf16(Array(bytes.dropFirst(2))) }
        return latin1(bytes)
    }

    /// Bytes one-to-one as characters, so a name-tree key survives the round trip.
    static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
    }

    struct DestinationTargeting {
        let resolve: (PDFObject?) -> PDFObject?
        let pageIndexByNumber: [Int: Int]
        let boxesByPage: [Int: [CGRect]]
        let named: [String: PDFObject]

        func targetsBox(_ destination: PDFObject?, depth: Int = 0) -> Bool {
            guard depth < 8, let value = resolve(destination) else { return false }
            switch value {
            case let .array(items):
                guard let number = items.first?.referenceValue?.number, let index = pageIndexByNumber[number],
                      let boxes = boxesByPage[index], items.count >= 2 else { return false }
                let numbers = items.dropFirst(2).map { resolve($0)?.doubleValue }
                // A null coordinate keeps the viewer's current one, so the destination is the
                // whole line through the other (finding 3: `/XYZ null 724 null`, the most common
                // bookmark, and every /FitH and /FitV, used to count as pointing nowhere).
                switch resolve(items[1])?.nameValue {
                case "XYZ":
                    let left = numbers.count > 0 ? numbers[0] : nil, top = numbers.count > 1 ? numbers[1] : nil
                    switch (left, top) {
                    case let (x?, y?): return boxes.contains { $0.contains(CGPoint(x: x, y: y)) }
                    case let (nil, y?): return boxes.contains { y >= $0.minY && y <= $0.maxY }
                    case let (x?, nil): return boxes.contains { x >= $0.minX && x <= $0.maxX }
                    default: return false
                    }
                case "FitH", "FitBH":
                    guard let top = numbers.first ?? nil else { return false }
                    return boxes.contains { top >= $0.minY && top <= $0.maxY }
                case "FitV", "FitBV":
                    guard let left = numbers.first ?? nil else { return false }
                    return boxes.contains { left >= $0.minX && left <= $0.maxX }
                case "FitR":
                    guard numbers.count >= 4, let l = numbers[0], let b = numbers[1], let r = numbers[2], let t = numbers[3] else { return false }
                    let rect = CGRect(x: min(l, r), y: min(b, t), width: abs(r - l), height: abs(t - b))
                    return boxes.contains { RedactionGeometry.intersects(rect, $0) }
                default:
                    return false
                }
            case let .dictionary(entries):
                return targetsBox(entries["D"], depth: depth + 1)
            case let .string(bytes), let .hexString(bytes):
                return targetsBox(named["s:" + VectorRedactor.latin1(bytes)], depth: depth + 1)
            case let .name(name):
                return targetsBox(named["n:" + name], depth: depth + 1)
            default:
                return false
            }
        }

        func actionTargetsBox(_ action: PDFObject?, depth: Int = 0) -> Bool {
            guard depth < 8, let dictionary = resolve(action)?.dictionaryValue else { return false }
            if resolve(dictionary["S"])?.nameValue == "GoTo", targetsBox(dictionary["D"]) { return true }
            if let next = resolve(dictionary["Next"]) {
                if let list = next.arrayValue { return list.contains { actionTargetsBox($0, depth: depth + 1) } }
                return actionTargetsBox(next, depth: depth + 1)
            }
            return false
        }
    }

    /// The bookmark tree without the bookmarks that point into a box or whose title carries a
    /// removed word; their children move up a level.
    private static func rebuildOutlines(
        _ root: PDFObject?, targeting: DestinationTargeting, secretWords: Set<String>,
        resolve: (PDFObject?) -> PDFObject?, pool: inout RedactionObjectPool
    ) -> PDFObject? {
        struct Item { var dictionary: [String: PDFObject]; var children: [Item]; var open: Bool }
        var visited: Set<Int> = []
        func items(from first: PDFObject?, depth: Int) -> [Item] {
            guard depth < 32 else { return [] }
            var out: [Item] = []
            var cursor = first
            var steps = 0
            while let current = cursor, steps < 100_000 {
                steps += 1
                if let number = current.referenceValue?.number {
                    guard !visited.contains(number) else { break }
                    visited.insert(number)
                }
                guard let dictionary = resolve(current)?.dictionaryValue else { break }
                let children = items(from: dictionary["First"], depth: depth + 1)
                let title = VectorRedactor.text(stringBytes(resolve(dictionary["Title"])) ?? [])
                let goes = targeting.targetsBox(dictionary["Dest"]) || targeting.actionTargetsBox(dictionary["A"])
                    || secretWords.contains { RedactionWordSearch.contains($0, in: title, caseInsensitive: true) }
                if goes {
                    out.append(contentsOf: children)
                } else {
                    var kept: [String: PDFObject] = [:]
                    for key in ["Title", "Dest", "A", "C", "F"] { if let value = dictionary[key] { kept[key] = value } }
                    out.append(Item(dictionary: kept, children: children, open: (resolve(dictionary["Count"])?.integerValue ?? 0) >= 0))
                }
                cursor = dictionary["Next"]
            }
            return out
        }
        guard let rootDictionary = resolve(root)?.dictionaryValue else { return nil }
        let top = items(from: rootDictionary["First"], depth: 0)
        guard !top.isEmpty else { return nil }

        func descendants(_ item: Item) -> Int { item.children.reduce(item.children.count) { $0 + (($1.open) ? descendants($1) : 0) } }
        func write(_ list: [Item], parent: Int) -> (first: Int, last: Int, visible: Int) {
            let numbers = list.map { _ in pool.reserve() }
            var visible = 0
            for (position, item) in list.enumerated() {
                var dictionary = item.dictionary
                dictionary["Parent"] = .reference(number: parent, generation: 0)
                if position > 0 { dictionary["Prev"] = .reference(number: numbers[position - 1], generation: 0) }
                if position + 1 < list.count { dictionary["Next"] = .reference(number: numbers[position + 1], generation: 0) }
                if !item.children.isEmpty {
                    let child = write(item.children, parent: numbers[position])
                    dictionary["First"] = .reference(number: child.first, generation: 0)
                    dictionary["Last"] = .reference(number: child.last, generation: 0)
                    let count = descendants(item)
                    dictionary["Count"] = .integer(item.open ? count : -item.children.count)
                }
                pool.set(numbers[position], .dictionary(dictionary))
                visible += 1 + (item.open ? descendants(item) : 0)
            }
            return (numbers.first ?? 0, numbers.last ?? 0, visible)
        }
        let rootNumber = pool.reserve()
        let written = write(top, parent: rootNumber)
        pool.set(rootNumber, .dictionary([
            "Type": .name("Outlines"),
            "First": .reference(number: written.first, generation: 0),
            "Last": .reference(number: written.last, generation: 0),
            "Count": .integer(written.visible)
        ]))
        return .reference(number: rootNumber, generation: 0)
    }

    // MARK: - Word counting shared with the verifier

    /// How many times `word` stood under the boxes of sheet `page`, as a whole word (R-099).
    static func underBoxCount(_ word: String, prepared: Prepared, page: Int, caseInsensitive: Bool = false) -> Int {
        guard let selections = prepared.texts.selections[page] else { return 0 }
        var fromSelection = 0
        for selected in selections {
            fromSelection += RedactionWordSearch.occurrences(of: word, in: selected, caseInsensitive: caseInsensitive)
        }
        let fromRewrite = prepared.rewritten[page]?.work.removedWords.filter {
            RedactionWordSearch.contains(word, in: $0.trimmingCharacters(in: .punctuationCharacters), caseInsensitive: caseInsensitive)
        }.count ?? 0
        return max(fromSelection, fromRewrite)
    }
}
