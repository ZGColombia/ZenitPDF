import CoreGraphics
import Foundation
import PDFKit

extension PDFKitDocumentProvider {

    // MARK: - Reading annotations

    public func annotations(
        of handle: DocumentHandle,
        pageIndex: Int
    ) async throws -> [NeutralAnnotation] {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        // Reading an annotation's contents and appearance goes through PDFKit's
        // Objective-C accessors, which raise on some malformed dictionaries.
        return try EngineBarrier.guarded("annotations") {
            let bounded = page.annotations.prefix(open.limits.maximumAnnotationsPerPage)
            return bounded.map { AnnotationMapping.neutral($0, pageIndex: pageIndex) }
        }
    }

    public func allAnnotations(of handle: DocumentHandle) async throws -> [NeutralAnnotation] {
        let open = try unlockedEntry(handle)
        var out: [NeutralAnnotation] = []
        for index in 0..<open.descriptor.pageCount {
            try checkCancellation()
            out.append(contentsOf: try await annotations(of: handle, pageIndex: index))
        }
        return out
    }

    // MARK: - Writing annotations into a copy

    /// Writes annotations into a **new file**.
    ///
    /// The document held open for `handle` is never modified, and neither is its file.
    /// Both are guaranteed structurally rather than by care: the annotations are added to
    /// a *pristine* `PDFDocument` reopened from the original bytes, and the destination is
    /// refused outright if it resolves to the source or to any other file this provider
    /// has open.
    public func writeAnnotations(
        _ request: AnnotationWriteRequest,
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try checkCancellation()
        let open = try unlockedEntry(handle)

        for annotation in request.annotations {
            guard annotation.pageIndex >= 0, annotation.pageIndex < open.descriptor.pageCount else {
                throw PDFBridgeError.pageIndexOutOfRange(
                    index: annotation.pageIndex,
                    pageCount: open.descriptor.pageCount
                )
            }
        }

        return try performWrite(primary: open, alsoProtecting: [], destination: destination) {
            let copy = try Self.pristineDocument(of: open)
            let touched = Set(request.annotations.map(\.pageIndex))

            switch request.mode {
            case .append:
                break
            case .replaceOnTouchedPages:
                for index in touched { Self.removeAllAnnotations(on: copy, pageIndex: index) }
            case .replaceAll:
                for index in 0..<copy.pageCount { Self.removeAllAnnotations(on: copy, pageIndex: index) }
            case .supersedeZenitOwned:
                let names = Set(request.annotations.compactMap(\.name))
                for index in 0..<copy.pageCount {
                    Self.removeZenitOwnedAnnotations(on: copy, pageIndex: index, replacing: names)
                }
            }

            for neutral in request.annotations {
                guard let page = copy.page(at: neutral.pageIndex) else {
                    throw PDFBridgeError.pageIndexOutOfRange(
                        index: neutral.pageIndex,
                        pageCount: copy.pageCount
                    )
                }
                page.addAnnotation(try AnnotationMapping.annotation(from: neutral))
            }
            return copy
        }
    }

    /// Removes the annotations Zenit wrote before: owner-marked, named like one being written, or
    /// the first export's `/Subj (Zenit)` with no name. Everybody else's stay.
    private static func removeZenitOwnedAnnotations(
        on document: PDFDocument,
        pageIndex: Int,
        replacing names: Set<String>
    ) {
        guard let page = document.page(at: pageIndex) else { return }
        for annotation in page.annotations {
            let neutral = AnnotationMapping.neutral(annotation, pageIndex: pageIndex)
            let owned = neutral.isZenitOwned
                || (neutral.name.map(names.contains) ?? false)
                || (neutral.name == nil && neutral.subject == ZenitAnnotationOwnership.legacySubject)
            if owned { page.removeAnnotation(annotation) }
        }
    }

    private static func removeAllAnnotations(on document: PDFDocument, pageIndex: Int) {
        guard let page = document.page(at: pageIndex) else { return }
        for annotation in page.annotations { page.removeAnnotation(annotation) }
    }

    // MARK: - Page operations

    public func planPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle
    ) async throws -> PageOperationPlan {
        let open = try unlockedEntry(handle)
        var rotations: [Int] = []
        rotations.reserveCapacity(open.descriptor.pageCount)
        for index in 0..<open.descriptor.pageCount {
            rotations.append(PageRotationMath.normalised(open.document.page(at: index)?.rotation ?? 0))
        }
        do {
            return try PageOperationPlanner.plan(
                operations: operations,
                document: handle,
                initialRotations: rotations,
                pageCounts: pageCounts(),
                externalRotations: pageRotations(),
                limits: open.limits
            )
        } catch let fault {
            throw PDFBridgeError.pageOperation(fault)
        }
    }

    public func applyPageOperations(
        _ operations: [PageOperation],
        on handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        let plan = try await planPageOperations(operations, on: handle)

        // Every document the plan draws pages from must still be open and unlocked.
        var contributors: [DocumentHandle: OpenDocument] = [handle: open]
        for other in plan.externalDocuments {
            contributors[other] = try unlockedEntry(other)
        }

        let protectedURLs = contributors.values.compactMap { $0.origin.fileURL }
        // Structure the fresh document would otherwise lose (documents bug 5):
        // bookmarks and links are rebuilt, page labels appended after the write.
        var carried: CarriedStructure = ([], nil)
        return try performWrite(
            primary: open,
            alsoProtecting: protectedURLs,
            destination: destination,
            finish: { url in try Self.appendCarriedPageLabels(&carried, toFileAt: url) },
            notCarried: { carried.notCarried }
        ) {
            let (pristine, carriers) = try Self.pristineContributors(contributors)

            let result = PDFDocument()
            for (position, planned) in plan.resultingPages.enumerated() {
                guard let sourceDocument = pristine[planned.source.document],
                      let sourcePage = sourceDocument.page(at: planned.source.pageIndex),
                      let copiedPage = sourcePage.copy() as? PDFPage
                else {
                    throw PDFBridgeError.pageOperation(
                        .pageIndexOutOfRange(
                            index: planned.source.pageIndex,
                            count: pristine[planned.source.document]?.pageCount ?? 0
                        )
                    )
                }
                // Inserted before the rotation is set: a copied `PDFPage` has no
                // document until it is inserted, and PDFKit does not like being asked to
                // change a page that belongs to nothing.
                result.insert(copiedPage, at: position)
                result.page(at: position)?.rotation = planned.rotation
            }
            carried = PageStructureCarrier.carry(
                into: result,
                sources: plan.resultingPages.map { ($0.source.document, $0.source.pageIndex) },
                contributors: carriers,
                primary: handle
            )
            return result
        }
    }

    public func extractPages(
        _ pageIndices: [Int],
        of handle: DocumentHandle,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try await applyPageOperations([.extract(pageIndices: pageIndices)], on: handle, to: destination)
    }

    public func mergeDocuments(
        _ handles: [DocumentHandle],
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        guard let first = handles.first else {
            throw PDFBridgeError.pageOperation(.resultWouldBeEmpty)
        }
        var operations: [PageOperation] = []
        for other in handles.dropFirst() {
            let open = try unlockedEntry(other)
            operations.append(.merge(document: other, pageCount: open.descriptor.pageCount))
        }
        return try await applyPageOperations(operations, on: first, to: destination)
    }

    // MARK: - The one write path

    /// Guards the destination, hashes every source before and after, writes, and proves
    /// the originals are untouched.
    ///
    /// Every public write in this package funnels through here. There is deliberately no
    /// second way to put bytes on disk.
    /// Writes to `destination` atomically, through ``StagedFileReplacement`` — the one staging
    /// rule every writer shares (V-056): `write` fills a file in a private staging folder on the
    /// destination's volume (never beside the destination, which a sandboxed save panel does not
    /// grant), which is then placed with `replaceItemAt` (or `moveItem` when nothing is there
    /// yet). The destination is never removed first, so a `write` that returns `false` or a
    /// placement that fails leaves whatever was already at `destination` untouched (CR-77); both
    /// are reported as ``PDFBridgeError/writeFailed(path:reason:)``. Nonisolated and free of
    /// PDFKit types so the atomicity can be tested with an injected `write`.
    package static func atomicallyWrite(to destination: URL, write: (URL) throws -> Bool) throws {
        var placing = false
        do {
            try StagedFileReplacement.write(
                to: destination,
                protecting: [],
                refusal: PDFBridgeError.destinationIsSource(path: destination.path),
                stagingPrefix: "zpdf-write-"
            ) { temporaryURL in
                guard try write(temporaryURL) else {
                    throw PDFBridgeError.writeFailed(path: destination.path, reason: "PDFKit refused the write")
                }
                placing = true
            }
        } catch where placing {
            throw PDFBridgeError.writeFailed(
                path: destination.path,
                reason: "atomic replace failed: \(error.localizedDescription)"
            )
        }
    }

    func performWrite(
        primary: OpenDocument,
        alsoProtecting extraURLs: [URL],
        destination: DocumentDestination,
        finish: (URL) throws -> Void = { _ in },
        notCarried: () -> Set<DocumentStructureFeature> = { [] },
        build: () throws -> PDFDocument
    ) throws -> DocumentWriteReceipt {
        var protectedURLs = openFileURLs()
        protectedURLs.append(contentsOf: extraURLs)
        try Self.validateDestination(destination, protecting: protectedURLs)

        let sourceURL = primary.origin.fileURL
        let before = try sourceURL.map {
            try FileDigestReader.digest(ofFileAt: $0, maximumByteCount: primary.limits.maximumFileByteCount)
        }
        // The bytes on disk must still be the bytes that were opened. `build` reopens the file
        // as it is *now*, so a revision swapped in by a sync client or another application
        // since the open would receive the markups the person made on the revision they saw,
        // and the before/after check below — which only spans the write — would pass (BH-174).
        if let before, before != primary.digest {
            throw PDFBridgeError.sourceMutatedDuringWrite(path: sourceURL?.path ?? "")
        }

        let document = try build()
        guard document.pageCount > 0 else { throw PDFBridgeError.pageOperation(.resultWouldBeEmpty) }

        // Atomic write (CR-77): PDFKit writes to a staged file in a private folder, then it is
        // placed with `replaceItemAt`. The destination is never removed first, so a write that
        // fails — disk full, sandbox refusal, PDFKit refusal — leaves the previous export exactly
        // as it was.
        try Self.atomicallyWrite(to: destination.url) { temporaryURL in
            let wrote = try EngineBarrier.guarded("write") { document.write(to: temporaryURL) }
            if wrote { try finish(temporaryURL) }
            return wrote
        }

        let after = try sourceURL.map {
            try FileDigestReader.digest(ofFileAt: $0, maximumByteCount: primary.limits.maximumFileByteCount)
        }
        if let before, let after, before != after {
            throw PDFBridgeError.sourceMutatedDuringWrite(path: sourceURL?.path ?? "")
        }

        // Hashed without the *source* size limit: the file is already committed, and a merged
        // result of several in-limit sets can legitimately be larger than any one of them.
        // Bounding it by the source limit threw `fileTooLarge` with the export on disk and no
        // receipt (BH-574). The hash streams, so its memory does not depend on the size.
        let digest = try FileDigestReader.digest(
            ofFileAt: destination.url,
            maximumByteCount: Int.max
        )
        return DocumentWriteReceipt(
            destination: destination.url,
            digest: digest,
            pageCount: document.pageCount,
            sourceDigestBefore: before,
            sourceDigestAfter: after,
            structureNotCarried: notCarried()
        )
    }

    /// What a write that rebuilds a fresh document reports of the source structure: the features
    /// it could not carry, and the page labels ``PageStructureCarrier`` asks to be appended after
    /// the write (`nil` when none are needed).
    typealias CarriedStructure = (notCarried: Set<DocumentStructureFeature>, labels: [String]?)

    /// A pristine copy of every contributing drawing, and what ``PageStructureCarrier`` needs to
    /// know of each — its page labels, whether its catalog has `/OCProperties`, whether it has
    /// named destinations. Pristine, so no page object of a document the caller has open is ever
    /// handed to a writer or has its rotation changed.
    ///
    /// The one rule ``composeDocument(_:bookmarks:to:)`` and
    /// ``applyPageOperations(_:on:to:)`` share (W-059): each used to build both maps with its own
    /// copy of this loop, so a new structure flag added to one would silently be missing from the
    /// other.
    static func pristineContributors(
        _ contributors: [DocumentHandle: OpenDocument]
    ) throws -> (pristine: [DocumentHandle: PDFDocument], carriers: [DocumentHandle: PageStructureCarrier.Contributor]) {
        var pristine: [DocumentHandle: PDFDocument] = [:]
        var carriers: [DocumentHandle: PageStructureCarrier.Contributor] = [:]
        for (handle, contributor) in contributors {
            let document = try pristineDocument(of: contributor)
            pristine[handle] = document
            var ocProperties: CGPDFDictionaryRef?
            let hasLayers = document.documentRef?.catalog.map {
                CGPDFDictionaryGetDictionary($0, "OCProperties", &ocProperties)
            } ?? false
            carriers[handle] = PageStructureCarrier.Contributor(
                document: document,
                labels: contributor.labels,
                hasOptionalContent: hasLayers,
                hasNamedDestinations: !contributor.namedDestinations.isEmpty
            )
        }
        return (pristine, carriers)
    }

    /// The finish step of a write that rebuilt a fresh document: the carried page labels are
    /// appended to the written file by incremental update, and when they cannot be,
    /// ``DocumentStructureFeature/pageLabels`` is reported as not carried (W-059: one copy for
    /// both writes).
    static func appendCarriedPageLabels(_ carried: inout CarriedStructure, toFileAt url: URL) throws {
        guard let labels = carried.labels else { return }
        if try !PageStructureCarrier.appendPageLabels(labels, toFileAt: url) {
            carried.notCarried.insert(.pageLabels)
        }
    }

    /// Reopens a document from its original bytes.
    ///
    /// Not `document.copy()`: a copy of an in-memory `PDFDocument` shares PDFKit's own
    /// object graph in ways that are not contractually guaranteed, and the point of this
    /// package's immutability rule is that it does not depend on a guess about PDFKit's
    /// internals.
    static func pristineDocument(of open: OpenDocument) throws -> PDFDocument {
        let document: PDFDocument?
        switch open.origin {
        case .file(let url):
            document = PDFDocument(url: url)
        case .memory:
            document = open.sourceData.flatMap(PDFDocument.init(data:))
        }
        guard let document else { throw PDFBridgeError.damaged(.unparsable) }
        if document.isLocked, let password = open.password {
            guard document.unlock(withPassword: password) else {
                throw PDFBridgeError.incorrectPassword
            }
        }
        if document.isLocked { throw PDFBridgeError.documentLocked }
        return document
    }

    /// Refuses a destination that would land on any file this provider has open.
    ///
    /// "The same file" is ``StagedFileReplacement/sameItem(_:_:)`` — the one comparison every
    /// writer uses (V-056): by resolved path *and*, when both files exist, by the file system's
    /// own identifier, so a symlink, a `/private` prefix or a hard link cannot smuggle a write
    /// onto an original.
    static func validateDestination(_ destination: DocumentDestination, protecting urls: [URL]) throws {
        let manager = FileManager.default
        let target = destination.url.standardizedFileURL.resolvingSymlinksInPath()

        let parent = target.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw PDFBridgeError.destinationDirectoryMissing(path: parent.path)
        }

        if let source = urls.first(where: { StagedFileReplacement.sameItem($0, destination.url) }) {
            throw PDFBridgeError.destinationIsSource(path: source.path)
        }

        if manager.fileExists(atPath: target.path), destination.overwritePolicy == .fail {
            throw PDFBridgeError.destinationExists(path: destination.url.path)
        }
    }
}
