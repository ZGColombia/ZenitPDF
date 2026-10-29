import CoreGraphics
import CryptoKit
import Foundation
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFRenderer

/// The fourth export shape of ADR-0013: the drawing, unchanged, plus the markups as **optional
/// content** the recipient switches on and off in any reader.
///
/// # What it produces, and why that is not the flatten path with a flag
///
/// `flattened` paints the markups into a new page content stream and the recipient can never take
/// them off again. `annotated` writes PDF annotations, which toggle one at a time and are objects
/// beside the page rather than ink on it. This shape is the third thing: the markup ink is *in*
/// the page's content stream, painted by the same ``MarkupFlattener`` the flatten path and the
/// printer use — so it is vector, it is the same geometry, and it prints identically — but every
/// markup's operators are enclosed in a `/OC … BDC … EMC` marked-content span bound to a
/// document-level optional-content group. With no ``Options/layers`` that is one group named
/// "Zenit Markups"; with the project's markup layers (ADR-0042, L-22) it is one group per layer
/// that has markups, named after the layer, listed in layer order (top first), each on or off by
/// default as the layer is shown or hidden. Switch the groups off and the sheet is the drawing
/// again, in any reader and in `CGContext` (proved, not assumed: `LayeredMarkupExportTests`
/// renders the artefact with the group forced off and compares the raster against the `clean`
/// export of the same project).
///
/// # Zenit's own earlier annotations are not drawn a second time
///
/// A drawing that went through Save Markups into PDF carries one standard annotation per markup,
/// its `/NM` the markup's id. Painting the same markups onto the page and keeping those
/// annotations drew every markup twice (L-23). So on every sheet given to this exporter, an
/// annotation that stands for a markup of this export — one painted here, or one named in
/// ``Options/supersededAnnotationNames`` (the project's markups that are not painted: a hidden
/// markup, a layer kept off paper) — is left out of the superseding page dictionary's `/Annots`,
/// with the replies that point at them, and so is the first export's unnamed `/Subj (Zenit)`
/// mark. Everybody else's annotations are kept exactly as they were — including the ones a
/// colleague's Zenit wrote for markups this project does not hold, which the canvas draws too:
/// the owner key alone never removes an annotation here. ``LayeredExportOutcome/supersededAnnotationCount``
/// says how many were left out.
///
/// # The drawing is not rewritten, and that is measurable
///
/// The artefact is the **source file byte for byte**, followed by an incremental update: new
/// objects for the markup ink, a superseding page dictionary per marked sheet (and per sheet whose
/// Zenit-written annotations are left out), and a superseding catalog carrying `/OCProperties`. ``LayeredExportOutcome/preservedSourceBytes`` is the length
/// of that untouched prefix and the test hashes it. Invariant: the export never *claims* the
/// drawing is unmodified while rewriting its page content; here the claim is checkable, and
/// ``LayeredExportOutcome/modificationStatement`` names the three changes in one sentence.
///
/// # When it refuses
///
/// ADR-0013 §2: if the group cannot be added to the catalog — an encrypted document, a catalog
/// whose `/OCProperties` is not a dictionary, a file with no cross-reference section to chain an
/// update to — the export **fails with a sentence naming why**. It never falls back to a
/// flattened file, because a recipient who asked for a layer and received burned-in ink has no
/// way to tell.
public struct LayeredMarkupExporter: Sendable {

    /// Export-time choices. The layer name is stored verbatim, so a localised build stores the
    /// localised name (ADR-0013 §2).
    public struct Options: Sendable, Hashable {
        /// The name the recipient sees in the reader's layer panel.
        public var layerName: String
        /// Whether the group is on in the document's default configuration. ADR-0013 says on.
        public var visibleByDefault: Bool
        /// Whether the appended markup content stream is compressed.
        public var compressContent: Bool
        /// `false` appends the markup ink **without** an optional-content group: no `/OC` spans,
        /// no catalog change — the structure-preserving flatten of NL-PDF-05, which keeps the
        /// drawing's outline, links, page labels and layers because no page is rebuilt.
        public var asSwitchableLayer: Bool
        /// The project's markup layers, **top first** (ADR-0042, L-22). Each layer that has a
        /// markup on an exported sheet becomes its own optional-content group, named after the
        /// layer and listed in this order. Empty: every markup on one group named ``layerName``,
        /// on or off by ``visibleByDefault`` — ADR-0013's single group. A markup no layer names
        /// goes to that group too, so nothing given to the exporter is ever left out.
        public var layers: [Layer]
        /// The `/NM` names (a markup id's `uuidString`) of markups whose earlier Zenit annotation
        /// is left out although this export does not paint them — every markup of the project,
        /// hidden or kept off paper included (L-23). The markups painted here are superseded
        /// without being named. An annotation named by neither is kept, whoever wrote it.
        public var supersededAnnotationNames: Set<String>

        public init(
            layerName: String = LayeredMarkupExporter.defaultLayerName,
            visibleByDefault: Bool = true,
            compressContent: Bool = true,
            asSwitchableLayer: Bool = true,
            layers: [Layer] = [],
            supersededAnnotationNames: Set<String> = []
        ) {
            self.layerName = layerName
            self.visibleByDefault = visibleByDefault
            self.compressContent = compressContent
            self.asSwitchableLayer = asSwitchableLayer
            self.layers = layers
            self.supersededAnnotationNames = supersededAnnotationNames
        }
    }

    /// One markup layer as the layered export carries it: a name, a default state, and the
    /// markups on it.
    public struct Layer: Sendable, Hashable {
        /// The group's name in the reader's layer panel, stored verbatim.
        public var name: String
        /// Whether the group is on when the file is opened — the layer shown or hidden.
        public var visibleByDefault: Bool
        /// The markups on the layer, by the markup's own identity. A renderer fragment of a
        /// markup (a stamp contour, a count symbol of a group: ``StampArtworkScene/shapeIdentity(base:ordinal:)``)
        /// belongs to its markup's layer by the family rule of ``StampArtworkScene/isPart(_:of:)``.
        public var markupIDs: Set<MarkupID>

        public init(name: String, visibleByDefault: Bool = true, markupIDs: Set<MarkupID>) {
            self.name = name
            self.visibleByDefault = visibleByDefault
            self.markupIDs = markupIDs
        }
    }

    /// The untranslated name of the group. `NSLocalizedString` is applied by the caller that owns
    /// a bundle; this package has none.
    public static let defaultLayerName = "Zenit Markups"

    public init() {}

    // MARK: - Producing the bytes

    /// Produces the artefact from the source drawing's bytes and the pages to mark.
    ///
    /// - Parameters:
    ///   - source: the drawing exactly as it is on disk. Copied into the output unmodified.
    ///   - pages: the sheets to mark, each naming its zero-based index in `source`. A sheet the
    ///     caller leaves out is not touched at all. The `printable` and `hidden` rules are
    ///     applied before this call, by whoever built the values — see ``PDFFlattenPolicy``.
    public func data(
        source: Data,
        pages: [FlattenPage],
        options: Options = Options()
    ) throws -> (data: Data, outcome: LayeredExportOutcome) {
        guard !pages.isEmpty else { throw PDFFlattenError.noPages }
        var seen: Set<Int> = []
        for page in pages {
            guard seen.insert(page.sourcePageIndex).inserted else {
                throw ExportError.layeredSourceUnreadable(
                    "page \(page.sourcePageIndex + 1) was given to the layered export twice, and "
                        + "two markup layers on one sheet would overwrite each other."
                )
            }
        }

        let scan = try PDFDocumentScan(data: source)
        let sourcePages = try scan.pages()
        var update = PDFIncrementalUpdate()
        var allocator = scan.nextObjectNumber

        func allocate() -> Int {
            defer { allocator += 1 }
            return allocator
        }

        var groups = options.asSwitchableLayer ? GroupPlan(options: options) : nil

        var spanCount = 0
        var paintedCount = 0
        var rejectedCount = 0
        var markedPages = 0
        var sawMarkups = false
        var superseded = 0
        // The markups whose earlier Zenit annotation is left out (L-23): every one painted here,
        // by family so a stamp's or a count's fragments name their markup, and every one the
        // caller names. Nothing else — not the owner key on its own.
        let superseding = Set(pages.flatMap { $0.markups.map { GroupPlan.Family($0.id) } })
            .union(options.supersededAnnotationNames.compactMap { UUID(uuidString: $0).map { GroupPlan.Family(MarkupID($0)) } })

        for job in pages.sorted(by: { $0.sourcePageIndex < $1.sourcePageIndex }) {
            guard job.sourcePageIndex >= 0, job.sourcePageIndex < sourcePages.count else {
                throw ExportError.layeredSourceUnreadable(
                    "the export names page \(job.sourcePageIndex + 1), and the drawing has "
                        + "\(sourcePages.count) page\(sourcePages.count == 1 ? "" : "s")."
                )
            }
            let target = sourcePages[job.sourcePageIndex]
            // Zenit's own annotations from an earlier Save Markups into PDF or annotated export:
            // the markups are painted again below, so those are left out (L-23).
            let annotations = Self.annotationsWithoutZenits(of: target, superseding: superseding, scan: scan)
            superseded += annotations?.superseded ?? 0
            guard !job.markups.isEmpty else {
                if let annotations {
                    var page = target.dictionary
                    Self.setAnnotations(annotations.kept, in: &page)
                    update.objects[target.number] = .dictionary(page)
                }
                continue
            }
            sawMarkups = true
            // Before a single markup is painted: the sheet the caller measured has to be the
            // sheet in the file.
            try verifySheetMatchesPage(job: job, target: target, scan: scan)
            let painted = try paint(job)
            paintedCount += painted.painted
            rejectedCount += painted.rejected
            guard !painted.spans.isEmpty else {
                if let annotations {
                    var page = target.dictionary
                    Self.setAnnotations(annotations.kept, in: &page)
                    update.objects[target.number] = .dictionary(page)
                }
                continue
            }

            let assembled = try assemble(
                spans: painted.spans,
                markupScan: painted.scan,
                job: job,
                target: target,
                scan: scan,
                groups: &groups,
                keptAnnotations: annotations?.kept,
                options: options,
                allocate: allocate,
                update: &update
            )
            spanCount += assembled
            markedPages += 1
        }

        guard sawMarkups else {
            // Not a painter failure: there was nothing to paint. Saying "could not be painted"
            // here sends the user looking for a defect that does not exist.
            throw ExportError.layeredSourceUnreadable(
                "the exported pages carry no markups, so there is nothing to put in a layer "
                    + "named \"\(options.layerName)\"; add markups to the drawing, or export it "
                    + "without markups instead."
            )
        }
        guard spanCount > 0 else {
            throw ExportError.layeredSourceUnreadable(
                "none of the markups given to the layered export could be painted, so the "
                    + "artefact would carry an empty layer named \"\(options.layerName)\"."
            )
        }

        let written = groups?.written ?? []
        try OptionalContentCatalog.attach(
            written.map { OptionalContentCatalog.Entry(reference: $0.reference, visible: $0.visible) },
            in: scan,
            to: &update
        )

        let bytes = try update.appended(to: source, scan: scan)
        var outcome = LayeredExportOutcome(
            layerName: written.first?.name ?? options.layerName,
            pageCount: sourcePages.count,
            markedPageCount: markedPages,
            markupSpanCount: spanCount,
            paintedMarkupCount: paintedCount,
            rejectedMarkupCount: rejectedCount,
            preservedSourceBytes: source.count,
            visibleByDefault: written.isEmpty ? options.visibleByDefault : written.allSatisfy { $0.visible }
        )
        outcome.groups = written.map {
            LayeredExportOutcome.Group(name: $0.name, visibleByDefault: $0.visible, markupCount: $0.markups.count)
        }
        outcome.supersededAnnotationCount = superseded
        return (bytes, outcome)
    }

    // MARK: - Zenit's own earlier annotations (L-23)

    /// The page's `/Annots` without Zenit's pictures of the `superseding` markups (and the replies
    /// pointing at them), or `nil` when the page carries none and is left exactly as it is.
    static func annotationsWithoutZenits(
        of target: PDFDocumentScan.PageEntry,
        superseding families: Set<GroupPlan.Family>,
        scan: PDFDocumentScan
    ) -> (kept: [PDFObject], superseded: Int)? {
        let existing = StandardAnnotationWriter.existingAnnotations(of: target, scan: scan)
        guard !existing.isEmpty else { return nil }
        let partition = StandardAnnotationWriter.partition(existing, scan: scan) {
            supersedes($0, families: families)
        }
        guard partition.superseded > 0 else { return nil }
        return (partition.kept, partition.superseded)
    }

    /// Whether an annotation is Zenit's picture of one of `families`' markups — its `/NM` (or the
    /// copy PDFKit keeps under ``ZenitAnnotationOwnership/nameKey``) is such a markup's id — or
    /// one of the first export's unnamed `/Subj (Zenit)` marks. The owner key alone is not enough:
    /// a colleague's annotation for a markup this project does not hold is kept (L-23).
    static func supersedes(_ dictionary: [String: PDFObject], families: Set<GroupPlan.Family>) -> Bool {
        let name = StandardAnnotationWriter.text(dictionary["NM"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? StandardAnnotationWriter.text(dictionary[ZenitAnnotationOwnership.nameKey])
        if let name, !name.isEmpty {
            guard let id = UUID(uuidString: name) else { return false }
            return families.contains(GroupPlan.Family(MarkupID(id)))
        }
        return StandardAnnotationWriter.text(dictionary["Subj"]) == StandardAnnotationWriter.legacySubject
    }

    /// Writes `annotations` as the page's `/Annots`, or removes the key when nothing is left.
    static func setAnnotations(_ annotations: [PDFObject], in page: inout [String: PDFObject]) {
        if annotations.isEmpty {
            page.removeValue(forKey: "Annots")
        } else {
            page["Annots"] = .array(annotations)
        }
    }

    // MARK: - Which group a markup is painted in

    /// The optional-content groups of one export: the layers given, in order, and the single
    /// fallback group named ``Options/layerName`` for a markup no layer names. A group's object
    /// is allocated the first time a markup is painted in it, so a layer with nothing on the
    /// exported sheets is not in the file.
    struct GroupPlan {
        struct Group {
            var name: String
            var visible: Bool
            var reference: PDFObject?
            /// Markup families painted in this group, for the outcome's per-layer count.
            var markups: Set<Family> = []
        }

        /// The first twelve bytes of a markup id: the identity a renderer fragment shares with its
        /// markup (``StampArtworkScene/shapeIdentity(base:ordinal:)``).
        struct Family: Hashable {
            let high: UInt64
            let low: UInt32

            init(_ id: MarkupID) {
                let b = id.rawValue.uuid
                high = UInt64(b.0) << 56 | UInt64(b.1) << 48 | UInt64(b.2) << 40 | UInt64(b.3) << 32
                    | UInt64(b.4) << 24 | UInt64(b.5) << 16 | UInt64(b.6) << 8 | UInt64(b.7)
                low = UInt32(b.8) << 24 | UInt32(b.9) << 16 | UInt32(b.10) << 8 | UInt32(b.11)
            }
        }

        private(set) var groups: [Group]
        private let index: [Family: Int]
        private let fallback: Int

        init(options: Options) {
            var groups = options.layers.map { Group(name: $0.name, visible: $0.visibleByDefault) }
            var index: [Family: Int] = [:]
            for (position, layer) in options.layers.enumerated() {
                for id in layer.markupIDs where index[Family(id)] == nil {
                    index[Family(id)] = position
                }
            }
            fallback = groups.count
            groups.append(Group(name: options.layerName, visible: options.visibleByDefault))
            self.groups = groups
            self.index = index
        }

        /// The group a painted markup (or fragment of one) belongs to.
        func group(of id: MarkupID) -> Int { index[Family(id)] ?? fallback }

        /// The group's reference, allocating and writing its object on first use.
        mutating func reference(
            of group: Int,
            for id: MarkupID,
            allocate: () -> Int,
            update: inout PDFIncrementalUpdate
        ) -> PDFObject {
            groups[group].markups.insert(Family(id))
            if let reference = groups[group].reference { return reference }
            let number = allocate()
            update.objects[number] = OptionalContentCatalog.group(named: groups[group].name)
            let reference = PDFObject.reference(number: number, generation: 0)
            groups[group].reference = reference
            return reference
        }

        /// The groups that received a markup, in layer order with the fallback last.
        var written: [(name: String, visible: Bool, reference: PDFObject, markups: Set<Family>)] {
            groups.compactMap { group in
                group.reference.map { (group.name, group.visible, $0, group.markups) }
            }
        }
    }

    /// Produces the artefact and writes it.
    ///
    /// - Parameter protecting: paths the output may not land on. The source drawing is added to
    ///   that list automatically, because an export that overwrites the drawing it is exporting
    ///   is the one mistake this shape must never make — the original bytes are the artefact's
    ///   own foundation.
    @discardableResult
    public func write(
        source sourceURL: URL,
        pages: [FlattenPage],
        to url: URL,
        options: Options = Options(),
        protecting sources: [URL] = []
    ) throws -> LayeredExportOutcome {
        // The one same-file rule every drawing writer shares: by path and by file identifier, so a
        // case-variant name on a case-insensitive volume or a hard link is the drawing too (W-058).
        try StagedFileReplacement.refuseOverwriting(
            sources + [sourceURL], with: url,
            refusal: PDFFlattenError.fileWriteFailed(path: url.path, reason: "the destination is the drawing being exported")
        )
        let source: Data
        do {
            source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        } catch {
            // The system's sentence, never the error's dump: the refusal's words are quoted as
            // they are by the Marked export's report and the export alerts (V-051).
            throw ExportError.layeredSourceUnreadable(
                "the drawing at \(sourceURL.path) could not be read: \(error.localizedDescription)"
            )
        }
        let produced = try data(source: source, pages: pages, options: options)
        do {
            try produced.data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.fileWriteFailed(path: url.path, reason: error.localizedDescription)
        }
        return produced.outcome
    }

    // MARK: - Painting, one span per markup

    private struct PaintedSheet {
        /// The decoded content stream of each markup that produced ink, in painter order, with the
        /// markup it came from.
        var spans: [(content: Data, resources: [String: PDFObject], markup: MarkupID)] = []
        var scan: PDFDocumentScan
        var painted = 0
        var rejected = 0
    }

    /// Paints each markup **on its own page** of a scratch PDF, so the operators of one markup can
    /// be enclosed in one marked-content span.
    ///
    /// The painter is ``MarkupFlattener/paint(page:markups:into:rect:)`` — the single function the
    /// flatten path, the print path and the snippet compositor all call. Nothing about the ink is
    /// re-implemented here; this method only decides where the pen strokes are separated.
    private func paint(_ job: FlattenPage) throws -> PaintedSheet {
        let size = job.sheetSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw PDFFlattenError.unusablePage(
                index: job.page.index,
                reason: "the crop box is empty or non-finite"
            )
        }
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData) else {
            throw PDFFlattenError.pdfContextUnavailable
        }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFFlattenError.pdfContextUnavailable
        }
        var painted = 0
        var rejected = 0
        var producedInk: [Bool] = []
        for markup in job.markups {
            var pageBox = box
            let info: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(
                    bytes: &pageBox,
                    count: MemoryLayout<CGRect>.size
                ) as CFData
            ]
            context.beginPDFPage(info as CFDictionary)
            let outcome = try MarkupFlattener.paint(
                page: job.page,
                markups: [markup],
                into: context,
                rect: box
            )
            context.endPDFPage()
            painted += outcome.paintedMarkupCount
            rejected += outcome.rejectedMarkupCount
            producedInk.append(outcome.paintedMarkupCount > 0)
        }
        context.closePDF()

        let scan = try PDFDocumentScan(data: buffer as Data)
        let scratchPages = try scan.pages()
        guard scratchPages.count == job.markups.count else {
            throw ExportError.layeredSourceUnreadable(
                "the markup painter produced \(scratchPages.count) sheets for "
                    + "\(job.markups.count) markups on page \(job.page.index + 1), so the "
                    + "layer's spans could not be matched to the markups they belong to."
            )
        }
        var sheet = PaintedSheet(scan: scan, painted: painted, rejected: rejected)
        for (index, scratch) in scratchPages.enumerated() where producedInk[index] {
            guard case let .stream(dictionary, raw)? = scan.object(scratch.dictionary["Contents"]),
                  let content = PDFStreamCodec.decode(dictionary: dictionary, data: raw)
            else {
                throw ExportError.layeredSourceUnreadable(
                    "the markup painter's own page content could not be read back, so the "
                        + "operators of markup \(index + 1) on page \(job.page.index + 1) could "
                        + "not be enclosed in an optional-content span."
                )
            }
            sheet.spans.append((content, scan.dictionary(scratch.inheritedResources) ?? [:], job.markups[index].id))
        }
        return sheet
    }

    // MARK: - Assembling one sheet's update

    private func assemble(
        spans: [(content: Data, resources: [String: PDFObject], markup: MarkupID)],
        markupScan: PDFDocumentScan,
        job: FlattenPage,
        target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan,
        groups: inout GroupPlan?,
        keptAnnotations: [PDFObject]?,
        options: Options,
        allocate: () -> Int,
        update: inout PDFIncrementalUpdate
    ) throws -> Int {
        // Resource categories are routinely written as their own objects and shared between
        // forty sheets. Resolving them here means the page's new `/Resources` holds a copy of
        // the *entries* — which are themselves references, so nothing is duplicated — and the
        // shared object is never modified. Modifying it would put page 12's markup properties on
        // page 3.
        var existingResources = scan.dictionary(target.inheritedResources) ?? [:]
        for (category, value) in existingResources where value.referenceValue != nil {
            guard let resolved = scan.object(value)?.dictionaryValue else { continue }
            existingResources[category] = .dictionary(resolved)
        }
        var merge = ResourceMerge(existing: existingResources)
        var copied: [Int: Int] = [:]
        var body = Data()

        // One `/Properties` name per group used on this sheet, handed out (and added, so the next
        // name cannot collide with it) the first time a span of that group is written.
        var ocNames: [Int: String] = [:]
        for span in spans {
            var renames: [String: String] = [:]
            for (category, value) in span.resources {
                guard category != "ProcSet" else { continue }
                guard let entries = markupScan.object(value)?.dictionaryValue else { continue }
                for (name, resource) in entries {
                    let copiedValue = try update.copy(
                        resource,
                        from: markupScan,
                        memo: &copied,
                        allocate: allocate,
                        tooDeep: Self.resourceTooDeep
                    )
                    let assigned = merge.name(
                        for: copiedValue,
                        in: category,
                        original: resource
                    )
                    renames[name] = assigned
                }
            }
            if let group = groups?.group(of: span.markup),
               let reference = groups?.reference(of: group, for: span.markup, allocate: allocate, update: &update) {
                let ocName: String
                if let named = ocNames[group] {
                    ocName = named
                } else {
                    ocName = merge.uniqueName("ZMOC", in: "Properties")
                    merge.add(reference, as: ocName, in: "Properties")
                    ocNames[group] = ocName
                }
                body.append(contentsOf: Array("q\n/OC /\(ocName) BDC\n".utf8))
                body.append(PDFContentNameRewriter.rewrite(span.content, map: renames))
                body.append(contentsOf: Array("\nEMC\nQ\n".utf8))
            } else {
                body.append(contentsOf: Array("q\n".utf8))
                body.append(PDFContentNameRewriter.rewrite(span.content, map: renames))
                body.append(contentsOf: Array("\nQ\n".utf8))
            }
        }

        // The markups were painted onto a sheet whose origin is the crop box's corner and whose
        // axes are the ones the estimator saw. The page they are being added to still carries its
        // own `/CropBox` offset and its `/Rotate`, and a viewer applies the rotation *after* the
        // content stream. So one matrix carries sheet space onto the page — and it is derived
        // from `/Rotate`, never assumed, because a `/Rotate 90` sheet with the identity matrix is
        // markups lying across a drawing at right angles to it.
        let placement = Self.placement(for: job.page)
        // Read before anything is written: a `/Contents` this cannot interpret must stop the
        // export, not silently produce a sheet with markups and no drawing.
        let carried = try existingContents(of: target, scan: scan)
        // The drawing is bracketed so the layer is painted in the page's default state. A
        // drawing that leaves `q`s open or pops state it never saved needs a wider bracket, or
        // the single `Q` pops the drawing's own state and the `cm` lands on its leftover CTM.
        // A stream this codec cannot decode is assumed balanced, which is what it was before.
        let balance = Self.stateBalance(of: carried, scan: scan) ?? .balanced

        var content = Data(String(repeating: "Q\n", count: balance.restoresAfter).utf8)
        content.append(contentsOf: Array("q\n".utf8))
        content.append(contentsOf: Array("\(placement) cm\n".utf8))
        content.append(body)
        content.append(contentsOf: Array("Q\n".utf8))

        let prefixNumber = allocate()
        update.objects[prefixNumber] = .stream(
            dictionary: [:],
            data: Data(String(repeating: "q\n", count: balance.savesBefore).utf8)
        )
        let contentNumber = allocate()
        update.objects[contentNumber] = Self.stream(content, compressed: options.compressContent)

        let resourcesNumber = allocate()
        update.objects[resourcesNumber] = .dictionary(merge.merged())

        var page = target.dictionary
        if let keptAnnotations { Self.setAnnotations(keptAnnotations, in: &page) }
        page["Resources"] = .reference(number: resourcesNumber, generation: 0)
        page["Contents"] = .array(
            [.reference(number: prefixNumber, generation: 0)]
                + carried
                + [.reference(number: contentNumber, generation: 0)]
        )
        update.objects[target.number] = .dictionary(page)
        return spans.count
    }

    /// The sheet the markups were painted on must be the sheet in the file. A mismatch means the
    /// caller handed the exporter a different drawing than the one it measured, and the ink would
    /// land somewhere plausible and wrong.
    private func verifySheetMatchesPage(
        job: FlattenPage,
        target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan
    ) throws {
        let box = try Self.visibleSheet(of: target, scan: scan, pageIndex: job.sourcePageIndex)
        let rotation = scan.object(target.inheritedRotation)?.integerValue ?? 0
        let swaps = (((rotation % 360) + 360) % 360) % 180 != 0
        let width = swaps ? box.height : box.width
        let height = swaps ? box.width : box.height
        let sheet = job.sheetSize
        guard abs(width - Double(sheet.width)) <= 1, abs(height - Double(sheet.height)) <= 1
        else {
            throw ExportError.layeredSourceUnreadable(
                "page \(job.sourcePageIndex + 1) of the drawing is "
                    + "\(PDFObject.format(width)) x \(PDFObject.format(height)) pt, and the "
                    + "markups were measured on a sheet of "
                    + "\(PDFObject.format(Double(sheet.width))) x "
                    + "\(PDFObject.format(Double(sheet.height))) pt; the layer would be placed on "
                    + "the wrong drawing."
            )
        }
    }

    /// The sheet a reader shows: the crop box intersected with the media box (ISO 32000-1
    /// §14.11.2), which is also what the page descriptor's crop was measured from. Comparing the
    /// raw `/CropBox` instead refuses the right drawing whenever a CAD export's crop box
    /// overhangs its media box.
    ///
    /// A box that is present but unreadable is a refusal, not a skipped check: this comparison is
    /// the only thing between the measured sheet and the file's sheet.
    static func visibleSheet(
        of target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan,
        pageIndex: Int
    ) throws -> (width: Double, height: Double) {
        func unreadable(_ key: String) -> ExportError {
            ExportError.layeredSourceUnreadable(
                "page \(pageIndex + 1)'s /\(key) cannot be read as four numbers, so the sheet the "
                    + "markups were measured on cannot be checked against the sheet in the file."
            )
        }
        var media: CGRect?
        if target.inheritedMediaBox != nil {
            guard let box = rectangle(target.inheritedMediaBox, scan: scan) else {
                throw unreadable("MediaBox")
            }
            media = box
        }
        var crop: CGRect?
        if target.inheritedCropBox != nil {
            guard let box = rectangle(target.inheritedCropBox, scan: scan) else {
                throw unreadable("CropBox")
            }
            crop = box
        }
        let visible: CGRect
        switch (media, crop) {
        case let (media?, crop?):
            let clipped = crop.intersection(media)
            visible = clipped.isNull || clipped.isEmpty ? media : clipped
        case let (media?, nil):
            visible = media
        case let (nil, crop?):
            visible = crop
        case (nil, nil):
            throw unreadable("MediaBox")
        }
        return (Double(visible.width), Double(visible.height))
    }

    /// A box array, its elements resolved when they are indirect, normalised so the width and
    /// height are never negative.
    static func rectangle(_ value: PDFObject?, scan: PDFDocumentScan) -> CGRect? {
        guard let values = scan.object(value)?.arrayValue, values.count == 4 else { return nil }
        let numbers = values.compactMap { scan.object($0)?.doubleValue }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return nil }
        return CGRect(
            x: min(numbers[0], numbers[2]),
            y: min(numbers[1], numbers[3]),
            width: abs(numbers[2] - numbers[0]),
            height: abs(numbers[3] - numbers[1])
        )
    }

    /// The `q`/`Q` balance of the page's existing content, or `nil` when a stream cannot be
    /// decoded (a filter chain this codec does not implement).
    static func stateBalance(
        of carried: [PDFObject],
        scan: PDFDocumentScan
    ) -> PDFContentStateBalance? {
        var joined: [UInt8] = []
        for reference in carried {
            guard case let .stream(dictionary, raw)? = scan.object(reference),
                  let decoded = PDFStreamCodec.decode(dictionary: dictionary, data: raw)
            else { return nil }
            joined.append(contentsOf: decoded)
            // Streams split at token boundaries; a separator keeps two tokens from fusing.
            joined.append(0x0A)
        }
        return PDFContentStateBalance.measure(joined)
    }

    /// The matrix that carries sheet space (origin at the displayed sheet's bottom-left corner)
    /// onto the page's own default user space, `/Rotate` undone and the crop offset restored.
    static func placement(for page: PageDescriptor) -> String {
        placementMatrix(for: page).map { PDFObject.format($0) }.joined(separator: " ")
    }

    /// The same matrix as six numbers `[a b c d e f]`. The annotated export's appearance forms
    /// use it as their `/Matrix`, so annotation ink and layer ink are placed by one derivation.
    static func placementMatrix(for page: PageDescriptor) -> [Double] {
        let box = page.visibleBox
        let width = box.maxX - box.minX
        let height = box.maxY - box.minY
        let matrix: [Double]
        switch page.rotation {
        case .degrees0:
            matrix = [1, 0, 0, 1, box.minX, box.minY]
        case .degrees90:
            matrix = [0, 1, -1, 0, box.minX + width, box.minY]
        case .degrees180:
            matrix = [-1, 0, 0, -1, box.minX + width, box.minY + height]
        case .degrees270:
            matrix = [0, -1, 1, 0, box.minX, box.minY + height]
        }
        return matrix
    }

    /// The page's existing content streams, in order, as the references the new `/Contents`
    /// array must keep.
    ///
    /// A `/Contents` this cannot interpret is a refusal rather than an empty list: returning
    /// nothing here would produce an artefact whose markups are perfect and whose drawing has
    /// vanished, which is the worst outcome this export has available to it.
    private func existingContents(
        of target: PDFDocumentScan.PageEntry,
        scan: PDFDocumentScan
    ) throws -> [PDFObject] {
        guard let contents = target.dictionary["Contents"] else { return [] }
        if let values = contents.arrayValue { return values }
        if contents.referenceValue != nil {
            if let values = scan.object(contents)?.arrayValue { return values }
            guard case .stream? = scan.object(contents) else {
                throw ExportError.layeredSourceUnreadable(
                    "page \(target.number)'s /Contents does not resolve to a content stream or an "
                        + "array of them, so the markup layer could not be added without risking "
                        + "the drawing's own content."
                )
            }
            return [contents]
        }
        throw ExportError.layeredSourceUnreadable(
            "page \(target.number)'s /Contents is neither an array nor a reference, so the markup "
                + "layer could not be added without risking the drawing's own content."
        )
    }

    private static func stream(_ content: Data, compressed: Bool) -> PDFObject {
        guard compressed, let deflated = PDFStreamCodec.flateEncode(content),
              deflated.count < content.count
        else {
            return .stream(dictionary: [:], data: content)
        }
        return .stream(dictionary: ["Filter": .name("FlateDecode")], data: deflated)
    }

    // MARK: - Copying the painter's resources into the drawing

    /// The refusal for a painter resource nested past what this exporter reads; the copy itself
    /// is ``PDFIncrementalUpdate/copy(_:from:memo:allocate:tooDeep:depth:)``, shared with the
    /// annotated export.
    private static func resourceTooDeep() -> ExportError {
        .layeredSourceUnreadable("the markup painter produced a resource nested deeper than this exporter reads.")
    }
}

/// What one layered export did, in numbers a caller can assert on and a sentence a person can
/// read.
public struct LayeredExportOutcome: Sendable, Hashable {
    public var layerName: String
    /// Pages in the source drawing. All of them are in the artefact; the ones with no markups are
    /// not changed at all.
    public var pageCount: Int
    public var markedPageCount: Int
    /// `/OC … BDC … EMC` spans written. One per markup that produced ink.
    public var markupSpanCount: Int
    public var paintedMarkupCount: Int
    /// Markups the renderer refused — non-finite or out-of-bounds geometry. They produce no span,
    /// and they are reported rather than dropped silently.
    public var rejectedMarkupCount: Int
    /// Length of the artefact's prefix that is the source file byte for byte.
    public var preservedSourceBytes: Int
    /// Whether every group written is on when the file is opened.
    public var visibleByDefault: Bool
    /// The optional-content groups written, in the layer panel's order (ADR-0042). One for a
    /// single-group export; one per markup layer that had a markup on an exported sheet
    /// otherwise; none when the ink was appended without a layer.
    public var groups: [Group] = []
    /// Zenit's own annotations from an earlier save or annotated export that were left out of
    /// the sheets' `/Annots`, because the markups they stood for are painted again (L-23).
    public var supersededAnnotationCount: Int = 0

    /// One optional-content group of the artefact.
    public struct Group: Sendable, Hashable {
        public var name: String
        public var visibleByDefault: Bool
        /// Markups painted in the group — markups, not renderer fragments.
        public var markupCount: Int
    }

    /// Markups painted across every group.
    public var layeredMarkupCount: Int { groups.reduce(0) { $0 + $1.markupCount } }

    /// The one sentence ADR-0013 §2 asks the export to state about what it changed. It is the
    /// whole truth: an appended layer, superseded page dictionaries, a superseded catalog, and
    /// not one byte of the drawing rewritten.
    public var modificationStatement: String {
        let markups = "\(markupSpanCount) markup\(markupSpanCount == 1 ? "" : "s")"
        let sheets = "\(markedPageCount) of the \(pageCount) sheet\(pageCount == 1 ? "" : "s")"
        let replaced = markedPageCount == 1 ? "that sheet" : "each of those sheets"
        var text = "The drawing's first \(preservedSourceBytes) bytes are the original file, "
            + "unchanged. Appended to it: the markup ink of \(markups), enclosed in "
            + "optional-content spans, on \(sheets); a replacement page dictionary for "
            + "\(replaced), naming the added content; and a replacement document catalog listing "
        if groups.count > 1 {
            let listed = groups.map {
                "\"\($0.name)\" (\($0.visibleByDefault ? "on" : "off") by default)"
            }.joined(separator: ", ")
            text += "the optional-content groups \(listed), one per markup layer, each of which "
                + "can be switched in any reader."
        } else {
            text += "the optional-content group \"\(layerName)\", which is "
                + "\(visibleByDefault ? "on" : "off") by default and can be switched in any reader."
        }
        if supersededAnnotationCount > 0 {
            text += " \(supersededAnnotationCount) annotation"
                + "\(supersededAnnotationCount == 1 ? "" : "s") Zenit wrote for these markups "
                + "before \(supersededAnnotationCount == 1 ? "is" : "are") left out of the sheets' "
                + "annotation lists, so no markup is drawn twice; everybody else's annotations are kept."
        }
        return text
    }
}

/// Merges the painter's resource dictionary into a page's own, without either one shadowing the
/// other.
private struct ResourceMerge {
    private let existing: [String: PDFObject]
    private var additions: [String: [String: PDFObject]] = [:]
    private var assigned: [String: [String: String]] = [:]
    private var counter = 0

    init(existing: [String: PDFObject]) {
        self.existing = existing
    }

    /// A name in `category` that is neither in the page's own resources nor already handed out.
    mutating func uniqueName(_ base: String, in category: String) -> String {
        var candidate = base
        var suffix = 0
        while taken(candidate, in: category) {
            suffix += 1
            candidate = "\(base)\(suffix)"
        }
        return candidate
    }

    private func taken(_ name: String, in category: String) -> Bool {
        if additions[category]?[name] != nil { return true }
        guard case let .dictionary(entries)? = existing[category] else { return false }
        return entries[name] != nil
    }

    /// The name `value` will be known by on the page. Identical resources — and every markup on a
    /// sheet uses the same colour space and the same alpha states — share one entry.
    mutating func name(for value: PDFObject, in category: String, original: PDFObject) -> String {
        let identity: String
        if let number = value.referenceValue?.number {
            identity = "r\(number)"
        } else {
            identity = "d" + SHA256.hash(data: original.serialized)
                .map { String(format: "%02x", $0) }.joined()
        }
        if let existingName = assigned[category]?[identity] { return existingName }
        counter += 1
        let name = uniqueName("ZMR\(counter)", in: category)
        assigned[category, default: [:]][identity] = name
        additions[category, default: [:]][name] = value
        return name
    }

    mutating func add(_ value: PDFObject, as name: String, in category: String) {
        additions[category, default: [:]][name] = value
    }

    /// The page's new `/Resources`: everything it had, plus everything the markups need.
    ///
    /// A category the page already has is copied entry by entry rather than superseded, so a
    /// `/Font` dictionary shared with forty other sheets keeps every one of its entries — and the
    /// object it was written as is never modified, because other pages point at it too.
    func merged() -> [String: PDFObject] {
        var out = existing
        for (category, entries) in additions {
            var combined: [String: PDFObject] = [:]
            if case let .dictionary(current)? = existing[category] { combined = current }
            for (name, value) in entries { combined[name] = value }
            out[category] = .dictionary(combined)
        }
        return out
    }
}
