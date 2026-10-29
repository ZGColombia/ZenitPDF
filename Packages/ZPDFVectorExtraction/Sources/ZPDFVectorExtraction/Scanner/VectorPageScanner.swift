import CoreGraphics
import Foundation

/// Drives one page scan from start to finished ``VectorPageExtraction``.
enum VectorPageScanner {

    /// The version stamped into every cache key. **Bump on any change that can move a
    /// coordinate, change a filter outcome, or change which primitives are emitted** —
    /// a stale cache entry served after such a change is a silently wrong snap.
    ///
    /// 2: marked content is lexical rather than saved by `q`/`Q` (CR-39), a segment after
    /// `h`/`re` starts at the closed subpath's start (CR-42), `/P` and `/VE` decide
    /// membership visibility and form-local layer names resolve to the page's (CR-48), and a
    /// form at the `q`-stack cap no longer disturbs the outer state (CR-51).
    ///
    /// 3: stored cubic bounds follow the cancellation-free extremum roots (BH-059), `/OC`
    /// on a form or image XObject hides it (BH-328), a form `/BBox` or a `W n` disjoint
    /// from the clip in force empties the clip instead of replacing it (BH-329, BH-331),
    /// `s` closes only the current subpath (BH-330), `/BaseState /OFF` is honoured
    /// (BH-864), form-local layer names the page does not know are qualified per group
    /// (BH-865), `h` on a closed subpath is a no-op (BH-866), and a stray `EMC` inside a
    /// form cannot end the page's section (BH-867).
    ///
    /// 4: every painted primitive carries the fill and/or stroke colour in force
    /// (`VectorPrimitive.fillColor`/`strokeColor`, BH-167). Geometry and filtering are
    /// unchanged, but emitted primitives are not, so older cache entries must miss.
    ///
    /// 5: the extraction records every Form XObject drawing — its content digest, transform
    /// and primitive range (`VectorPageExtraction.formInvocations`, NL-AUTO-12) — so a block
    /// drawn many times can be counted exactly. Older entries lack the table and must miss.
    ///
    /// 6: a composite form's block identity also covers the identities of the forms it draws
    /// (W-080), so byte-identical composites over different sub-forms are different blocks.
    /// Older entries carry the content-only identity and must miss.
    static let extractorVersion = 6

    static func scan(
        page: CGPDFPage,
        pageIndex: Int,
        documentDigest: String,
        options: VectorExtractionOptions
    ) throws -> VectorPageExtraction {
        let mediaBox = VectorBounds(page.getBoxRect(.mediaBox))
        var cropBox = VectorBounds(page.getBoxRect(.cropBox))
        if cropBox.width <= 0 || cropBox.height <= 0 { cropBox = mediaBox }

        let pageTransform = VectorPageTransform(
            convention: options.pageSpaceConvention,
            mediaBox: mediaBox,
            cropBox: cropBox,
            rotation: Int(page.rotationAngle)
        )

        let hiddenGroups = hiddenOptionalContentGroups(in: page.document)
        let state = VectorScanState(
            options: options,
            pageTransform: pageTransform,
            hiddenOptionalContentGroups: hiddenGroups
        )

        if let pageDictionary = page.dictionary {
            if let annotations = PDFObject.arrayEntry(pageDictionary, "Annots"),
               CGPDFArrayGetCount(annotations) > 0 {
                state.note(.annotationAppearanceStreamsNotExtracted)
            }
            state.noteContentStreamEntered(bytes: contentByteCount(of: pageDictionary))
            state.pageLevelLayerNames = pageLevelPropertyNames(of: pageDictionary)
        }

        guard let table = VectorOperatorTable.make() else {
            throw VectorExtractionError.contentStreamUnavailable(pageIndex: pageIndex)
        }
        state.operatorTable = table

        let contentStream = CGPDFContentStreamCreateWithPage(page)
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(contentStream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
        CGPDFOperatorTableRelease(table)
        state.operatorTable = nil
        state.finaliseElapsed()

        if state.wasCancelled || Task.isCancelled {
            throw VectorExtractionError.cancelled
        }

        if !state.stopRequested, let pageDictionary = page.dictionary {
            state.noteContentStreamCompleted(bytes: contentByteCount(of: pageDictionary))
        }

        let statistics = VectorExtractionStatistics(
            operatorCount: state.operatorCount,
            primitiveCount: state.primitives.count,
            filteredCount: state.filteredSubpathCount,
            paintedPathCount: state.paintedPathCount,
            subpathCount: state.subpathCount,
            formInvocationCount: state.formInvocationCount,
            maximumNestingDepthReached: state.maximumNestingDepthReached,
            rasterRegionCount: state.rasterRegions.count,
            inlineImageCount: state.inlineImageCount,
            malformedOperandCount: state.malformedOperandCount,
            contentBytesCompleted: state.contentBytesCompleted,
            contentBytesEntered: state.contentBytesEntered,
            elapsedNanoseconds: state.elapsedNanoseconds,
            estimatedMemoryBytes: state.estimatedMemoryBytes
        )

        let reasons = state.sortedPartialReasons
        let availability = resolveAvailability(
            primitiveCount: state.primitives.count,
            filteredCount: state.filteredSubpathCount,
            contentBytesEntered: state.contentBytesEntered,
            reasons: reasons
        )

        let key = VectorCacheKey(
            documentDigest: documentDigest,
            pageIndex: pageIndex,
            extractorVersion: extractorVersion,
            configurationFingerprint: options.fingerprint
        )

        return VectorPageExtraction(
            cacheKey: key,
            availability: availability,
            partialReasons: reasons,
            primitives: state.primitives,
            rasterRegions: state.rasterRegions,
            filterDecisions: state.filterDecisions,
            pageTransform: pageTransform,
            statistics: statistics,
            formInvocations: state.formInvocations
        )
    }

    /// The three-state contract of `QUALITY_BAR` 3.6, in one place so the predicate can
    /// be read and tested on its own.
    ///
    /// One deliberate refinement: a reason that means geometry was *missed* — a budget,
    /// the form depth cap, a cycle, a malformed stream — reports `partial` **even with
    /// zero primitives**. Calling such a page "no vector content" would be a claim about
    /// content the extractor never reached, and honesty about what was not done is the
    /// whole point of the three states. See
    /// ``VectorPartialReason/meansGeometryWasMissed``.
    static func resolveAvailability(
        primitiveCount: Int,
        filteredCount: Int,
        contentBytesEntered: Int,
        reasons: [VectorPartialReason]
    ) -> VectorAvailability {
        if let first = reasons.first, first.meansGeometryWasMissed {
            return .partial(reason: first)
        }
        if primitiveCount == 0 {
            if filteredCount > 0 {
                return .unavailable(reason: .onlyFilteredGeometry(filteredCount: filteredCount))
            }
            if contentBytesEntered == 0 {
                return .unavailable(reason: .emptyContentStream)
            }
            return .unavailable(reason: .noVectorContent)
        }
        if let first = reasons.first {
            return .partial(reason: first)
        }
        return .available
    }

    // MARK: - Page helpers

    /// The declared encoded length of the page's content stream or streams.
    private static func contentByteCount(of pageDictionary: CGPDFDictionaryRef) -> Int {
        if let stream = PDFObject.streamEntry(pageDictionary, "Contents") {
            return PDFObject.encodedLength(of: stream)
        }
        guard let array = PDFObject.arrayEntry(pageDictionary, "Contents") else { return 0 }
        let count = CGPDFArrayGetCount(array)
        // A `/Contents` array is small in every real file; the loop is bounded anyway.
        var total = 0
        for index in 0..<Swift.min(count, 65_536) {
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, index, &stream), let stream else { continue }
            total += PDFObject.encodedLength(of: stream)
        }
        return total
    }

    /// The page's `/Resources /Properties` names, keyed by the identity of the dictionary each
    /// names, so a form-local name can be reported under the page's name for the same group.
    ///
    /// `/Resources` is inheritable, so the `/Parent` chain is consulted when the page has
    /// none of its own; the walk is bounded because a file may make the chain a cycle. When
    /// two page names refer to one dictionary the lexicographically first is kept, which is
    /// a function of the file's bytes and not of dictionary iteration order.
    private static func pageLevelPropertyNames(of pageDictionary: CGPDFDictionaryRef) -> [UInt: String] {
        var node: CGPDFDictionaryRef? = pageDictionary
        var resources: CGPDFDictionaryRef?
        var hops = 0
        while let current = node, resources == nil, hops < 64 {
            resources = PDFObject.dictionaryEntry(current, "Resources")
            node = PDFObject.dictionaryEntry(current, "Parent")
            hops += 1
        }
        guard let resources, let properties = PDFObject.dictionaryEntry(resources, "Properties") else {
            return [:]
        }

        final class Collector {
            var pairs: [(name: String, identity: UInt)] = []
        }
        let collector = Collector()
        let info = Unmanaged.passUnretained(collector).toOpaque()
        CGPDFDictionaryApplyBlock(properties, { key, value, info in
            guard let info else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            guard collector.pairs.count < OptionalContentVisibility.maximumTerms else { return false }
            if let dictionary = PDFObject.dictionary(value) {
                collector.pairs.append((String(cString: key), PDFObject.identity(dictionary: dictionary)))
            }
            return true
        }, info)

        var result: [UInt: String] = [:]
        for pair in collector.pairs.sorted(by: { $0.name < $1.name }) where result[pair.identity] == nil {
            result[pair.identity] = pair.name
        }
        return result
    }

    /// The optional-content groups switched off in the document's default configuration.
    ///
    /// PDF 32000-1 8.11.4.3, Table 101: `/BaseState` — `/ON` by default — is applied to
    /// every group in `/OCProperties /OCGs` first, then `/ON` and `/OFF` override it. A
    /// configuration written as `<< /BaseState /OFF /ON [5 0 R] >>` therefore has one
    /// visible group and no `/OFF` array at all; reading `/OFF` alone made every layer of
    /// such a document a snap target (BH-864).
    ///
    /// Membership is by dictionary identity within one open `CGPDFDocument`, which is
    /// the only handle the C API offers. A group that cannot be identified is treated as
    /// visible: showing geometry that should have been hidden is a cosmetic error,
    /// hiding geometry that should be snappable is a functional one.
    private static func hiddenOptionalContentGroups(in document: CGPDFDocument?) -> Set<UInt> {
        guard let document,
              let catalog = document.catalog,
              let properties = PDFObject.dictionaryEntry(catalog, "OCProperties"),
              let configuration = PDFObject.dictionaryEntry(properties, "D")
        else { return [] }

        var result: Set<UInt> = []
        if PDFObject.nameEntry(configuration, "BaseState") == "OFF",
           let allGroups = PDFObject.arrayEntry(properties, "OCGs") {
            result.formUnion(groupIdentities(in: allGroups))
            if let onGroups = PDFObject.arrayEntry(configuration, "ON") {
                result.subtract(groupIdentities(in: onGroups))
            }
        }
        if let offGroups = PDFObject.arrayEntry(configuration, "OFF") {
            result.formUnion(groupIdentities(in: offGroups))
        }
        return result
    }

    private static func groupIdentities(in array: CGPDFArrayRef) -> Set<UInt> {
        var result: Set<UInt> = []
        let count = CGPDFArrayGetCount(array)
        for index in 0..<Swift.min(count, 1_000_000) {
            var group: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &group), let group else { continue }
            result.insert(PDFObject.identity(dictionary: group))
        }
        return result
    }
}
