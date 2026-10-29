import CoreGraphics
import Foundation
import GRDB
import Vision
import ZPDFPDFKitBridge
import ZPDFPersistence

/// On-device text recognition for scanned sheets, writing `ocr_token` and `search_fts`.
///
/// ### Everything stays on this machine
///
/// Spec 17.4 is a hard requirement, not a default: local only, no cloud OCR, page by page,
/// cancellable, no document text in diagnostics, a memory cap, and an index the user can
/// delete. The recogniser is `Vision`, which runs on the Neural Engine or the CPU and has
/// no network path; this package imports no networking framework, and
/// `NetworkAbsenceTests` reads the linked symbols of the built library to prove it rather
/// than asserting it in prose.
///
/// ### Why the concurrency is a window and not a task per page
///
/// A 1 000-page set must not become 1 000 `VNRecognizeTextRequest`s. Each one owns a
/// rasterised page: an ARCH-D sheet at 300 dpi is 78 megapixels and 311 MB of RGBA, so a
/// thousand of them in flight is not a slow program, it is a dead machine. The run holds a
/// sliding window of ``OCRSettings/maximumConcurrentPages`` pages — four by default — and
/// starts the next page only when one finishes. Peak memory is therefore a function of the
/// window and the page size, never of the document's length.
///
/// ### What cancellation leaves behind
///
/// Each page is committed in its own transaction that writes the page's `ocr_token` rows
/// and its one `search_fts` row together, after deleting whatever that page had before. So
/// at every instant, and in particular at the instant the user presses stop, the invariant
/// holds: a page has all of its tokens and its index row, or it has neither. There is no
/// state in which half a page is searchable. Cancellation stops the window from advancing
/// and throws ``ZPDFSearchError/cancelled``; the pages already reported through the
/// progress callback are exactly the pages that are in the database.
public actor OCRService {

    private let database: ProjectDatabaseActor
    private let provider: any PDFDocumentProviding
    private let limits: SearchLimits
    private let normalization: TextNormalizationOptions
    public private(set) var settings: OCRSettings

    public init(
        database: ProjectDatabaseActor,
        provider: any PDFDocumentProviding,
        settings: OCRSettings = .standard,
        limits: SearchLimits = .standard,
        normalization: TextNormalizationOptions = .standard
    ) {
        self.database = database
        self.provider = provider
        self.settings = settings
        self.limits = limits
        self.normalization = normalization
    }

    /// Replaces the settings for subsequent runs.
    public func update(settings: OCRSettings) {
        self.settings = settings
    }

    /// The language codes this OS can recognise, at the level the settings ask for.
    public nonisolated static func supportedRecognitionLanguages(
        accurate: Bool = true
    ) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    // MARK: - Running

    /// Recognises text on a page range of one document.
    ///
    /// - Parameters:
    ///   - documentId: the `document.id` these pages belong to.
    ///   - handle: the same document, open in the provider.
    ///   - pageRange: `nil` means every page. Out-of-range bounds are an error rather than
    ///     a clamp — a caller that asks for pages 900…1000 of a 300-page set has a bug,
    ///     and silently recognising 900…300 hides it.
    ///   - progress: called after each page is committed, on this actor's executor.
    @discardableResult
    public func recognize(
        documentId: String,
        handle: DocumentHandle,
        pageRange: Range<Int>? = nil,
        progress: (@Sendable (OCRProgress) -> Void)? = nil
    ) async throws -> OCRReport {
        try checkSearchCancellation()
        let startedAt = DispatchTime.now()

        let identity = try await documentIdentity(documentId)
        let pageRows = identity.pages
        guard !pageRows.isEmpty else {
            throw ZPDFSearchError.documentHasNoPageRows(documentId: documentId)
        }

        let descriptors: [PDFPageDescriptor]
        do {
            descriptors = try await provider.pageDescriptors(of: handle, range: nil)
        } catch {
            throw ZPDFSearchError.adaptEngine(error)
        }
        let pageCount = descriptors.count

        let range = pageRange ?? 0..<pageCount
        guard range.lowerBound >= 0, range.upperBound <= pageCount, range.lowerBound <= range.upperBound else {
            throw ZPDFSearchError.pageRangeOutOfBounds(
                lowerBound: range.lowerBound,
                upperBound: range.upperBound,
                pageCount: pageCount
            )
        }
        guard range.count <= limits.maximumOCRPages else {
            throw ZPDFSearchError.tooManyPagesRequested(count: range.count, limit: limits.maximumOCRPages)
        }

        // Everything the workers need, resolved before the window opens so a worker never
        // touches this actor's state.
        var pending: [PageJob] = []
        pending.reserveCapacity(range.count)
        for pageIndex in range {
            guard let row = pageRows[pageIndex] else {
                throw ZPDFSearchError.missingPageRow(documentId: documentId, pageIndex: pageIndex)
            }
            pending.append(
                PageJob(
                    pageIndex: pageIndex,
                    pageId: row.id,
                    box: descriptors[pageIndex].boxes.crop,
                    rotation: descriptors[pageIndex].rotation
                )
            )
        }

        let jobs = pending
        let settings = self.settings
        let provider = self.provider
        let normalization = self.normalization
        let maximumTokens = limits.maximumOCRTokensPerPage
        let projectId = identity.document.projectId

        var completed: [OCRPageResult] = []
        completed.reserveCapacity(jobs.count)
        var tokensWritten = 0

        try await Self.recognisePages(
            jobs,
            handle: handle,
            provider: provider,
            settings: settings,
            normalization: normalization,
            maximumTokens: maximumTokens
        ) { recognition in
            let result = try await commit(
                recognition,
                projectId: projectId,
                documentId: documentId
            )
            tokensWritten += result.tokenCount
            completed.append(result)
            progress?(
                OCRProgress(
                    pagesCompleted: completed.count,
                    pagesTotal: jobs.count,
                    lastPage: result
                )
            )
        }

        completed.sort { $0.pageIndex < $1.pageIndex }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds) / 1e9
        return OCRReport(
            documentId: documentId,
            pagesRequested: jobs.count,
            pagesRecognised: completed.count(where: { !$0.wasSkipped }),
            pagesSkipped: completed.count(where: { $0.wasSkipped }),
            tokensWritten: tokensWritten,
            elapsedSeconds: elapsed,
            pages: completed
        )
    }

    /// Every recognised token of one document, by zero-based page index, in reading order —
    /// what a searchable-PDF export writes as an invisible text layer (NL-PDF-13).
    public func recognisedTokens(documentId: String) async throws -> [Int: [OCRRecognisedToken]] {
        try await storedTokens(documentId: documentId, pageIndex: nil)
    }

    /// One page's recognised tokens, in reading order. Only that page's rows are read and
    /// decoded: a reader of one sheet's words used to decode every token of the drawing to keep
    /// one page's, so walking a scanned set read the whole table once per sheet (U-015).
    public func recognisedTokens(documentId: String, pageIndex: Int) async throws -> [OCRRecognisedToken] {
        try await storedTokens(documentId: documentId, pageIndex: pageIndex)[pageIndex] ?? []
    }

    /// The stored tokens of one document, or of one of its pages, by page index.
    private func storedTokens(documentId: String, pageIndex: Int?) async throws -> [Int: [OCRRecognisedToken]] {
        try await read { db in
            var arguments: StatementArguments = [documentId]
            if let pageIndex { arguments += [pageIndex] }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT p.page_index AS page_index, t.token AS token, t.confidence AS confidence,
                       t.bounds_blob AS bounds_blob
                FROM ocr_token t JOIN page p ON p.id = t.page_id
                WHERE p.document_id = ?\(pageIndex == nil ? "" : " AND p.page_index = ?")
                ORDER BY p.page_index, t.line_index, t.token_index
                """,
                arguments: arguments
            )
            var out: [Int: [OCRRecognisedToken]] = [:]
            for row in rows {
                let data: Data = row["bounds_blob"]
                guard let blob = try? GeometryBlob.decode(data),
                      let points = blob.rings.first, !points.isEmpty
                else { continue }
                let xs = points.map(\.x), ys = points.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
                else { continue }
                let pageIndex: Int = row["page_index"]
                out[pageIndex, default: []].append(OCRRecognisedToken(
                    text: row["token"],
                    confidence: row["confidence"],
                    bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                ))
            }
            return out
        }
    }

    // MARK: - The sliding window

    /// Recognises `jobs` with at most ``OCRSettings/maximumConcurrentPages`` in flight and hands
    /// each finished page to `body`, on the caller's isolation, in completion order.
    ///
    /// The one window both ``recognize(documentId:handle:pageRange:progress:)`` and
    /// ``recogniseFile(handle:provider:settings:limits:normalization:)`` run (R-150: they
    /// carried two copies of it). A page that fails on its own comes back as a
    /// ``OCRSkipReason/notRenderable`` recognition from ``recognisePage``, so only cancellation
    /// and run-wide failures leave the window early.
    static func recognisePages(
        _ jobs: [PageJob],
        handle: DocumentHandle,
        provider: any PDFDocumentProviding,
        settings: OCRSettings,
        normalization: TextNormalizationOptions,
        maximumTokens: Int,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PageRecognition) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: PageRecognition.self) { group in
            var next = 0
            var inFlight = 0

            func startNext() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                inFlight += 1
                group.addTask {
                    try await Self.recognisePage(
                        job: job,
                        handle: handle,
                        provider: provider,
                        settings: settings,
                        normalization: normalization,
                        maximumTokens: maximumTokens
                    )
                }
            }

            for _ in 0..<max(1, settings.maximumConcurrentPages) { startNext() }

            while inFlight > 0 {
                guard let recognition = try await group.next() else { break }
                inFlight -= 1

                if Task.isCancelled {
                    group.cancelAll()
                    throw ZPDFSearchError.cancelled
                }
                try await body(recognition)
                if Task.isCancelled {
                    group.cancelAll()
                    throw ZPDFSearchError.cancelled
                }
                startNext()
            }
        }
    }

    // MARK: - One page

    /// Everything a worker needs about one page. `Sendable` by construction.
    struct PageJob: Sendable {
        let pageIndex: Int
        let pageId: String
        let box: CGRect
        let rotation: Int
    }

    /// One recognised token, before it is a database row.
    struct RecognisedToken: Sendable {
        let text: String
        let normalized: String
        let confidence: Double
        let bounds: CGRect
        let lineIndex: Int
        let tokenIndex: Int
    }

    /// The whole of one page's recognition, ready to be committed.
    struct PageRecognition: Sendable {
        let job: PageJob
        let tokens: [RecognisedToken]
        let lineCount: Int
        let content: String
        let skipReason: OCRSkipReason?
        let elapsedSeconds: Double
        let effectiveDPI: Double
    }

    /// Renders and recognises one page, and reports a page that fails on its own as
    /// ``OCRSkipReason/notRenderable`` instead of throwing.
    ///
    /// R-150: a render refusal, a Vision failure or an engine error on one page used to be
    /// thrown out of the task group, dropping every page still queued behind it — one damaged
    /// sheet in a long scan threw away the rest of the run. Cancellation still throws, and so
    /// does anything that is not about this page. `commit` leaves an earlier recognition of a
    /// `.notRenderable` page in place (BH-205).
    static func recognisePage(
        job: PageJob,
        handle: DocumentHandle,
        provider: any PDFDocumentProviding,
        settings: OCRSettings,
        normalization: TextNormalizationOptions,
        maximumTokens: Int
    ) async throws -> PageRecognition {
        try checkSearchCancellation()
        let startedAt = DispatchTime.now()
        do {
            return try await recognisePageContent(
                job: job, handle: handle, provider: provider, settings: settings,
                normalization: normalization, maximumTokens: maximumTokens, startedAt: startedAt
            )
        } catch let error as ZPDFSearchError {
            switch error {
            case .pageRenderFailed, .recognitionFailed, .engine:
                return PageRecognition(
                    job: job, tokens: [], lineCount: 0, content: "", skipReason: .notRenderable,
                    elapsedSeconds: Double(
                        DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds
                    ) / 1e9,
                    effectiveDPI: 0
                )
            default:
                throw error
            }
        }
    }

    /// Renders and recognises one page.
    ///
    /// `static`, and therefore off the actor: recognition is the expensive part and
    /// serialising it on the actor's executor would make ``OCRSettings/maximumConcurrentPages``
    /// a lie. Nothing here reads actor state — every input is a parameter.
    private static func recognisePageContent(
        job: PageJob,
        handle: DocumentHandle,
        provider: any PDFDocumentProviding,
        settings: OCRSettings,
        normalization: TextNormalizationOptions,
        maximumTokens: Int,
        startedAt: DispatchTime
    ) async throws -> PageRecognition {

        func finished(
            tokens: [RecognisedToken],
            lineCount: Int,
            content: String,
            skip: OCRSkipReason?,
            dpi: Double
        ) -> PageRecognition {
            PageRecognition(
                job: job,
                tokens: tokens,
                lineCount: lineCount,
                content: content,
                skipReason: skip,
                elapsedSeconds: Double(
                    DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds
                ) / 1e9,
                effectiveDPI: dpi
            )
        }

        // Spec 17.3: a page that already has enough text is skipped by default.
        if settings.skipsPagesWithTextLayer {
            let pageText: PageText
            do {
                pageText = try await provider.pageText(of: handle, pageIndex: job.pageIndex)
            } catch {
                throw ZPDFSearchError.adaptEngine(error)
            }
            // BH-644: counted after the indexer's own normalisation, so "enough text"
            // means the same thing here as it does to `TextIndexer`. A layer of forty
            // spaces and newlines is, to the indexer, no text layer at all (it files the
            // page under `pagesWithoutTextLayer`); counting it raw skipped the page here
            // too, and the page ended up neither indexed nor recognised.
            if pageText.availability == .available,
               ZPDFTextNormalizer.indexable(pageText.string, options: normalization).count
                >= settings.sufficientTextLayerCharacterCount {
                return finished(
                    tokens: [], lineCount: 0, content: "",
                    skip: .hasTextLayer, dpi: settings.renderDPI
                )
            }
        }

        try checkSearchCancellation()

        // Fit the rasterisation into the pixel budget before asking for it.
        let rotation = RecognitionGeometry.normalisedRotation(job.rotation)
        let displaySize = PageDisplayGeometry.displaySize(of: job.box.size, rotation: rotation)
        guard displaySize.width > 0, displaySize.height > 0 else {
            return finished(tokens: [], lineCount: 0, content: "", skip: .notRenderable, dpi: 0)
        }
        let requested = Double(settings.renderScale)
        // The render's own ceil-per-axis rule, fitted in the bridge (BH-645, T-069).
        let wholeScale = RenderPixelSize.fittedScale(
            width: Double(displaySize.width),
            height: Double(displaySize.height),
            requested: requested,
            pixelBudget: settings.maximumRenderPixels
        )
        guard wholeScale.isFinite, wholeScale > 0 else {
            return finished(tokens: [], lineCount: 0, content: "", skip: .notRenderable, dpi: 0)
        }

        var positioned: [PositionedLine] = []
        let effectiveDPI: Double
        if settings.tilesLargePages, wholeScale < requested * 0.999 {
            // NL-PDF-13: the whole sheet does not fit the budget at the requested resolution,
            // so it is read in tiles that do, at that resolution, rather than once downscaled.
            let side = min(
                Double(settings.tilePixelSize),
                Double(settings.maximumRenderPixels).squareRoot().rounded(.down) - 2
            )
            let regions = Self.tileRegions(
                box: job.box,
                scale: requested,
                tilePixels: side,
                overlapFraction: settings.tileOverlapFraction
            )
            var lowest = requested
            for (tile, region) in regions.enumerated() {
                try checkSearchCancellation()
                let (rendered, used) = try await Self.render(
                    job: job, region: region, scale: requested, displaySize: region.size,
                    handle: handle, provider: provider
                )
                lowest = min(lowest, used)
                positioned += try await Self.read(
                    rendered, scale: used, job: job, rotation: rotation, settings: settings, tile: tile
                )
            }
            effectiveDPI = lowest * 72.0
        } else {
            let (rendered, used) = try await Self.render(
                job: job, region: nil, scale: wholeScale, displaySize: displaySize,
                handle: handle, provider: provider
            )
            positioned = try await Self.read(
                rendered, scale: used, job: job, rotation: rotation, settings: settings, tile: 0
            )
            effectiveDPI = used * 72.0
        }

        try checkSearchCancellation()

        let assembled = Self.assemble(
            positioned,
            box: job.box,
            rotation: rotation,
            minimumConfidence: settings.minimumStoredConfidence,
            normalization: normalization,
            maximumTokens: maximumTokens
        )
        return finished(
            tokens: assembled.tokens,
            lineCount: assembled.lineCount,
            content: assembled.content,
            skip: Self.skipReason(forRecognisedContent: assembled.content),
            dpi: effectiveDPI
        )
    }

    /// Whether a page the recogniser looked at produced anything. Decided on the page's text,
    /// not on its boxed tokens: a line Vision returned without word boxes still carries
    /// searchable text (``assemble(_:box:rotation:minimumConfidence:normalization:maximumTokens:)``
    /// keeps it), and calling that page "nothing recognised" discarded it (S-103).
    static func skipReason(forRecognisedContent content: String) -> OCRSkipReason? {
        content.isEmpty ? .nothingRecognised : nil
    }

    // MARK: - From readings to page lines (R-159)

    /// One page's recognised lines — from several overlapping tiles and possibly rotated
    /// passes — as stored tokens, a line count, and the FTS content.
    ///
    /// Tiles overlap, so a word in the overlap strip is read twice, and a line that crosses a
    /// seam comes back as two recogniser lines, one per tile. Three rules make that one line
    /// again (R-159):
    ///
    /// 1. **One token per word.** Two readings with the same folded text and boxes overlapping
    ///    by 30 % are one word. The reading that lies farther from an interior tile edge wins —
    ///    it is the one the recogniser saw whole — and confidence breaks a tie (the only rule
    ///    for a whole-page read, where no reading is near a seam).
    /// 2. **Seam lines merge.** Two upright lines read in different tiles are one page line
    ///    when they shared a word (rule 1 joined them) or when their boxes sit on the same
    ///    baseline with no more than a line height between them.
    /// 3. **Indices and content come after the merge.** A merged line's tokens run in reading
    ///    order along the display x axis and are numbered `0, 1, 2 …` on one line index, so a
    ///    phrase that crosses a seam is still consecutive for `SearchService.resolve`; its
    ///    FTS content is its surviving words once each. A line nothing merged into and nothing
    ///    took a word from keeps the recogniser's own text and token order, exactly as before.
    ///
    /// Old output for a line `ROOM 101 NORTH` split by a seam through `101`: `ROOM` (0, 0),
    /// `101` (0, 1), `NORTH` (1, 0), content `"ROOM 101\n101 NORTH"` — no phrase across the
    /// seam, and `101` counted twice by bm25.
    static func assemble(
        _ positioned: [PositionedLine],
        box: CGRect,
        rotation: Int,
        minimumConfidence: Double,
        normalization: TextNormalizationOptions,
        maximumTokens: Int
    ) -> (tokens: [RecognisedToken], lineCount: Int, content: String) {
        struct Reading {
            let text: String
            let folded: String
            let rect: CGRect
            let confidence: Double
            let edgeDistance: Double
            let line: Int
            let order: Int
        }

        let lines = positioned.filter { Double($0.confidence) >= minimumConfidence }
        var readings: [Reading] = []
        var alive: [Bool] = []
        var byText: [String: [Int]] = [:]
        var lostWord = [Bool](repeating: false, count: lines.count)

        // Union-find over lines: which recogniser lines are one page line.
        var parent = Array(lines.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        func join(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            guard ra != rb else { return }
            // The earlier line is the root, so a group's order is its first line's.
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
        func seamPartners(_ a: Int, _ b: Int) -> Bool {
            !lines[a].turned && !lines[b].turned && lines[a].tile != lines[b].tile
        }
        /// Page points within which two readings are equally far from a seam.
        let edgeMargin = 0.5

        // Rule 1.
        for (lineIndex, line) in lines.enumerated() {
            for (order, span) in line.spans.enumerated() {
                let candidate = Reading(
                    text: span.text,
                    folded: ZPDFTextNormalizer.folded(span.text),
                    rect: span.pageRect,
                    confidence: Double(line.confidence),
                    edgeDistance: span.edgeDistance,
                    line: lineIndex,
                    order: order
                )
                let sameWord = byText[candidate.folded]?.firstIndex(where: {
                    alive[$0] && Self.overlapRatio(readings[$0].rect, candidate.rect) >= 0.3
                })
                guard let slot = sameWord, let existing = byText[candidate.folded]?[slot] else {
                    byText[candidate.folded, default: []].append(readings.count)
                    readings.append(candidate)
                    alive.append(true)
                    continue
                }
                let old = readings[existing]
                if seamPartners(old.line, lineIndex) { join(old.line, lineIndex) }
                let candidateWins: Bool
                if candidate.edgeDistance > old.edgeDistance + edgeMargin {
                    candidateWins = true
                } else if old.edgeDistance > candidate.edgeDistance + edgeMargin {
                    candidateWins = false
                } else {
                    candidateWins = candidate.confidence > old.confidence
                }
                if candidateWins {
                    alive[existing] = false
                    lostWord[old.line] = true
                    byText[candidate.folded]?[slot] = readings.count
                    readings.append(candidate)
                    alive.append(true)
                } else {
                    lostWord[lineIndex] = true
                }
            }
        }

        // Display-space boxes of what survived, per line: reading order is a display notion.
        func display(_ rect: CGRect) -> CGRect {
            PageDisplayGeometry.displayRect(forPageRect: rect, box: box, rotation: rotation)
        }
        var survivors = [[Int]](repeating: [], count: lines.count)
        for index in readings.indices where alive[index] {
            survivors[readings[index].line].append(index)
        }
        var lineBoxes = [CGRect?](repeating: nil, count: lines.count)
        for index in lines.indices {
            lineBoxes[index] = survivors[index].reduce(nil as CGRect?) { box, reading in
                let rect = display(readings[reading].rect)
                return box.map { $0.union(rect) } ?? rect
            }
        }

        // Rule 2, the baseline half: a sweep down the display y axis, so only lines whose
        // vertical extents meet are ever compared.
        let upright = lines.indices
            .filter { !lines[$0].turned && lineBoxes[$0] != nil }
            .sorted { lineBoxes[$0]!.minY < lineBoxes[$1]!.minY }
        for (position, a) in upright.enumerated() {
            let boxA = lineBoxes[a]!
            for b in upright[(position + 1)...] {
                let boxB = lineBoxes[b]!
                if boxB.minY > boxA.maxY { break }
                guard lines[a].tile != lines[b].tile else { continue }
                let shared = min(boxA.maxY, boxB.maxY) - max(boxA.minY, boxB.minY)
                let smaller = min(boxA.height, boxB.height)
                guard smaller > 0, shared >= 0.6 * smaller else { continue }
                let gap = max(boxA.minX, boxB.minX) - min(boxA.maxX, boxB.maxX)
                if gap <= max(boxA.height, boxB.height) { join(a, b) }
            }
        }

        // Rule 3.
        var members: [Int: [Int]] = [:]
        for index in lines.indices { members[root(index), default: []].append(index) }
        let groups = members.keys.sorted()

        var tokens: [RecognisedToken] = []
        var contentLines: [String] = []
        var lineCount = 0
        for group in groups {
            guard tokens.count < maximumTokens else { break }
            let memberLines = members[group] ?? []
            let untouched = memberLines.count == 1 && !lostWord[memberLines[0]]
            var ordered = memberLines.flatMap { survivors[$0] }
            if memberLines.count > 1 {
                ordered.sort {
                    let a = display(readings[$0].rect), b = display(readings[$1].rect)
                    return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
                }
            }
            // A line the recogniser gave no boxes for still carries searchable text.
            if ordered.isEmpty {
                if untouched, lines[memberLines[0]].spans.isEmpty {
                    contentLines.append(lines[memberLines[0]].text)
                    lineCount += 1
                }
                continue
            }
            var words: [String] = []
            for (tokenIndex, index) in ordered.enumerated() {
                guard tokens.count < maximumTokens else { break }
                let reading = readings[index]
                tokens.append(RecognisedToken(
                    text: reading.text,
                    normalized: reading.folded,
                    confidence: reading.confidence,
                    bounds: reading.rect,
                    lineIndex: lineCount,
                    tokenIndex: tokenIndex
                ))
                words.append(reading.text)
            }
            contentLines.append(untouched ? lines[memberLines[0]].text : words.joined(separator: " "))
            lineCount += 1
        }

        let content = ZPDFTextNormalizer.indexable(
            contentLines.joined(separator: "\n"),
            options: normalization
        )
        return (tokens, lineCount, content)
    }

    // MARK: - Tiles and rotated passes (NL-PDF-13)

    /// A recognised line with its spans already in page space.
    struct PositionedLine: Sendable {
        let text: String
        let confidence: Float
        let spans: [PositionedSpan]
        /// The region the line was read in: its index among the page's tiles, `0` for a
        /// whole-page read.
        var tile: Int = 0
        /// Read from a quarter-turned image — vertical text, whose reading order is not the
        /// display x axis.
        var turned: Bool = false
    }

    /// One recognised word in page space.
    struct PositionedSpan: Sendable {
        let text: String
        let pageRect: CGRect
        /// Page points from the word to the nearest edge of its tile that is not also the
        /// page's edge — how far from a seam it was read. `infinity` for a whole-page read.
        var edgeDistance: Double = .infinity
    }

    /// How far `rect` lies inside `region`, measured only to the region's edges that are not
    /// the box's own. `infinity` when the region is the whole box.
    static func seamDistance(_ rect: CGRect, region: CGRect, box: CGRect) -> Double {
        let tolerance: CGFloat = 0.5
        var distance = Double.infinity
        if region.minX > box.minX + tolerance { distance = min(distance, Double(rect.minX - region.minX)) }
        if region.maxX < box.maxX - tolerance { distance = min(distance, Double(region.maxX - rect.maxX)) }
        if region.minY > box.minY + tolerance { distance = min(distance, Double(rect.minY - region.minY)) }
        if region.maxY < box.maxY - tolerance { distance = min(distance, Double(region.maxY - rect.maxY)) }
        return distance
    }

    /// The page-space regions a sheet is read in: squares of `tilePixels` at `scale`, stepping
    /// by the tile less the overlap, the last row and column aligned to the box's far edge so
    /// no tile hangs past it. Covers the whole box.
    static func tileRegions(box: CGRect, scale: Double, tilePixels: Double, overlapFraction: Double) -> [CGRect] {
        guard scale > 0, tilePixels > 1, box.width > 0, box.height > 0 else { return [box] }
        let side = tilePixels / scale
        let step = max(1, side * (1 - min(0.4, max(0, overlapFraction))))
        func starts(_ origin: Double, _ length: Double) -> [Double] {
            guard length > side else { return [origin] }
            var values: [Double] = []
            var position = origin
            while position + side < origin + length {
                values.append(position)
                position += step
            }
            values.append(origin + length - side)
            return values
        }
        var regions: [CGRect] = []
        for y in starts(Double(box.minY), Double(box.height)) {
            for x in starts(Double(box.minX), Double(box.width)) {
                regions.append(CGRect(
                    x: x, y: y,
                    width: min(side, Double(box.width)),
                    height: min(side, Double(box.height))
                ).intersection(box))
            }
        }
        return regions
    }

    /// The overlap of two rectangles as a fraction of the smaller one. `0` when disjoint.
    static func overlapRatio(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        guard smaller > 0 else { return 0 }
        return Double(shared.width * shared.height / smaller)
    }

    /// A quarter turn of an image, for reading vertical text.
    enum QuarterTurn: Sendable, CaseIterable {
        case clockwise
        case counterClockwise
    }

    /// `image` turned a quarter turn: width and height swap.
    static func rotated(_ image: CGImage, _ turn: QuarterTurn) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        switch turn {
        case .clockwise:
            // (x, y) -> (y, w - x)
            context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        case .counterClockwise:
            // (x, y) -> (h - y, x)
            context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// A Vision-normalised box found in the turned image, as a box in the original image.
    static func unrotated(_ box: CGRect, _ turn: QuarterTurn) -> CGRect {
        switch turn {
        case .clockwise:
            // original (x/W, y/H) = (1 - v, u)
            return CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
        case .counterClockwise:
            // original (x/W, y/H) = (v, 1 - u)
            return CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
        }
    }

    /// Renders one page region, refitting once to a smaller budget the provider names.
    private static func render(
        job: PageJob,
        region: CGRect?,
        scale requested: Double,
        displaySize: CGSize,
        handle: DocumentHandle,
        provider: any PDFDocumentProviding
    ) async throws -> (RenderedPageImage, Double) {
        var scale = requested
        var attempts = 0
        while true {
            attempts += 1
            do {
                let image = try await provider.renderPageRegion(
                    PageRenderRequest(
                        document: handle,
                        pageIndex: job.pageIndex,
                        box: .crop,
                        region: region,
                        scale: CGFloat(scale),
                        opaqueBackground: true
                    )
                )
                return (image, scale)
            } catch let error as PDFBridgeError {
                if case .cancelled = error { throw ZPDFSearchError.cancelled }
                // BH-645: the provider may enforce a smaller budget of its own
                // (`DocumentLimits.maximumRenderPixels`), which this service cannot see. When it
                // refuses, the refusal names its limit, and the region is fitted to that limit
                // once more instead of aborting the whole run.
                if case let .pixelBudgetExceeded(_, limit) = error, attempts == 1, limit > 0 {
                    let refitted = RenderPixelSize.fittedScale(
                        width: Double(displaySize.width),
                        height: Double(displaySize.height),
                        requested: scale,
                        pixelBudget: limit
                    )
                    if refitted.isFinite, refitted > 0, refitted < scale {
                        scale = refitted
                        continue
                    }
                }
                throw ZPDFSearchError.pageRenderFailed(
                    pageIndex: job.pageIndex,
                    reason: String(describing: error)
                )
            } catch {
                throw ZPDFSearchError.adaptEngine(error)
            }
        }
    }

    /// Recognises one rendered image — upright, and turned both ways when the upright pass
    /// found little — and places every span in page space.
    private static func read(
        _ rendered: RenderedPageImage,
        scale: Double,
        job: PageJob,
        rotation: Int,
        settings: OCRSettings,
        tile: Int
    ) async throws -> [PositionedLine] {
        // The bitmap's own dimensions, not the requested region: the renderer rounds the
        // pixel count up, and a normalised coordinate is normalised against what exists.
        let displayOrigin = PageDisplayGeometry.displayRect(
            forPageRect: rendered.renderedRegion,
            box: job.box,
            rotation: rotation
        ).origin
        let coveredSize = CGSize(
            width: CGFloat(rendered.image.width) / CGFloat(scale),
            height: CGFloat(rendered.image.height) / CGFloat(scale)
        )
        func place(_ lines: [RecognisedLine], turn: QuarterTurn?) -> [PositionedLine] {
            lines.map { line in
                PositionedLine(
                    text: line.text,
                    confidence: line.confidence,
                    spans: line.spans.compactMap { span in
                        let box = turn.map { unrotated(span.normalisedBox, $0) } ?? span.normalisedBox
                        guard let rect = RecognitionGeometry.pageRect(
                            forNormalisedRect: box,
                            displayOrigin: displayOrigin,
                            displaySize: coveredSize,
                            box: job.box,
                            rotation: rotation
                        ) else { return nil }
                        return PositionedSpan(
                            text: span.text,
                            pageRect: rect,
                            edgeDistance: seamDistance(rect, region: rendered.renderedRegion, box: job.box)
                        )
                    },
                    tile: tile,
                    turned: turn != nil
                )
            }
        }

        let upright = try await performRecognition(image: rendered.image, pageIndex: job.pageIndex, settings: settings)
        var out = place(upright, turn: nil)
        if settings.recognisesRotatedText, upright.count < settings.rotatedPassLineThreshold {
            for turn in QuarterTurn.allCases {
                try checkSearchCancellation()
                guard let turned = rotated(rendered.image, turn) else { continue }
                let lines = try await performRecognition(image: turned, pageIndex: job.pageIndex, settings: settings)
                out += place(lines, turn: turn)
            }
        }
        return out
    }

    /// One token of a recognised line, with the recogniser's normalised box for it.
    private struct RecognisedSpan: Sendable {
        let text: String
        /// Vision's unit-square box, origin bottom-left.
        let normalisedBox: CGRect
    }

    /// One recognised line: its best candidate's text and confidence, and its tokens with
    /// their boxes already resolved.
    ///
    /// The boxes are resolved eagerly, inside the Vision call and on its thread, because
    /// `VNRecognizedText` is a class and is not `Sendable`: nothing that crosses back to
    /// the actor may hold one.
    private struct RecognisedLine: Sendable {
        let text: String
        let confidence: Float
        let spans: [RecognisedSpan]
    }

    /// Runs `VNRecognizeTextRequest` off the cooperative pool.
    ///
    /// `VNImageRequestHandler.perform` blocks the calling thread for as long as
    /// recognition takes — a second or more on a dense sheet. Blocking a cooperative
    /// thread that long starves every other task in the process, so the call is handed to
    /// a utility-QoS queue and awaited.
    private static func performRecognition(
        image: CGImage,
        pageIndex: Int,
        settings: OCRSettings
    ) async throws -> [RecognisedLine] {
        try await withCheckedThrowingContinuation { continuation in
            recognitionQueue.async {
                do {
                    continuation.resume(
                        returning: try recogniseSynchronously(
                            image: image,
                            pageIndex: pageIndex,
                            settings: settings
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The queue the blocking Vision call runs on. Concurrent, because the window above
    /// already bounds how many pages are in flight.
    private static let recognitionQueue = DispatchQueue(
        label: "com.zenitgroup.zenitpdf.search.ocr",
        qos: .utility,
        attributes: .concurrent
    )

    private static func recogniseSynchronously(
        image: CGImage,
        pageIndex: Int,
        settings: OCRSettings
    ) throws -> [RecognisedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = settings.usesAccurateRecognition ? .accurate : .fast
        request.usesLanguageCorrection = settings.usesLanguageCorrection
        if settings.usesLanguageCorrection, !settings.customWords.isEmpty {
            request.customWords = settings.customWords
        }
        if !settings.recognitionLanguages.isEmpty {
            // Keep only the codes this OS has. A drawing set in a language the machine
            // does not carry must still be recognised in the languages it does.
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let usable = settings.recognitionLanguages.filter { supported.contains($0) }
            if !usable.isEmpty { request.recognitionLanguages = usable }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // The message is Vision's, about the request; it carries no page content.
            throw ZPDFSearchError.recognitionFailed(
                pageIndex: pageIndex,
                reason: (error as NSError).localizedDescription
            )
        }

        guard let observations = request.results else { return [] }
        var lines: [RecognisedLine] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.isEmpty else { continue }

            // Resolve every span's box here, while the Vision object is still alive and
            // on this thread.
            var spans: [RecognisedSpan] = []
            for span in tokenSpans(of: text) {
                guard let rectangle = try? candidate.boundingBox(for: span.range) else { continue }
                spans.append(RecognisedSpan(text: span.text, normalisedBox: rectangle.boundingBox))
            }
            lines.append(
                RecognisedLine(text: text, confidence: candidate.confidence, spans: spans)
            )
        }
        return lines
    }

    /// Splits a recognised line into the tokens `unicode61` would produce, keeping each
    /// one's range so the recogniser can be asked where it is.
    private static func tokenSpans(of text: String) -> [(text: String, range: Range<String.Index>)] {
        var spans: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let isToken = text[index].unicodeScalars.allSatisfy(ZPDFTextNormalizer.isTokenScalar)
            if isToken {
                if start == nil { start = index }
            } else if let from = start {
                spans.append((String(text[from..<index]), from..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let from = start {
            spans.append((String(text[from..<text.endIndex]), from..<text.endIndex))
        }
        return spans
    }

    // MARK: - Committing

    /// Writes one page's recognition in one transaction.
    ///
    /// Delete-then-insert, tokens and index row together. This is the whole of the
    /// consistency guarantee: there is no ordering of a crash or a cancellation that
    /// leaves a page with tokens but no index row, or with the index row of one run and the
    /// tokens of another. (An index row with no tokens is a legitimate state: the page's
    /// text came without word boxes, S-103.)
    func commit(
        _ recognition: PageRecognition,
        projectId: String,
        documentId: String
    ) async throws -> OCRPageResult {
        let job = recognition.job
        let tokens = recognition.tokens
        let content = recognition.content

        // BH-205: a page that was not recognised this run — skipped because it has a text
        // layer, or because it could not be rasterised — has no new answer to replace the
        // old one with. Deleting its tokens anyway silently erased an earlier recognition
        // (run eagerly, then re-run with the default skip on). Only a page the recogniser
        // actually looked at (`nil`, or `.nothingRecognised`) replaces what was stored.
        let wasRecognised: Bool
        switch recognition.skipReason {
        case .none, .nothingRecognised?: wasRecognised = true
        case .hasTextLayer?, .notRenderable?: wasRecognised = false
        }

        if wasRecognised { try await write { db in
            _ = try SearchIndexStore.deleteOCRTokens(db, pageId: job.pageId)
            _ = try SearchIndexStore.deleteRows(db, pageId: job.pageId, types: [.ocr])

            // The index row follows the page's *text*. Tokens are only the words that came
            // with a box; a page whose lines came without any still gets its row, and a hit
            // on it reports unknown confidence (CR-125). Requiring tokens as well (before
            // S-103) threw that text away after assemble() had kept it on purpose.
            guard !content.isEmpty else { return }

            for token in tokens {
                let blob = GeometryBlob(
                    kind: .rectangle,
                    points: RecognitionGeometry.corners(of: token.bounds).map {
                        GeometryPoint(x: $0.x, y: $0.y)
                    }
                )
                // A blob that will not encode carries a non-finite coordinate, which the
                // mapper already rejects. Skipping the token rather than failing the page
                // keeps the rest of the sheet searchable; the count in the result says how
                // many survived.
                guard let encoded = try? blob.encode() else { continue }
                try SearchIndexStore.insertOCRToken(
                    db,
                    OCRTokenRecord(
                        pageId: job.pageId,
                        token: token.text,
                        normalizedToken: token.normalized,
                        confidence: token.confidence,
                        boundsBlob: encoded,
                        lineIndex: token.lineIndex,
                        tokenIndex: token.tokenIndex
                    )
                )
            }

            try SearchIndexStore.insert(
                db,
                SearchIndexRecord(
                    projectId: projectId,
                    documentId: documentId,
                    pageId: job.pageId,
                    sourceType: SearchSourceType.ocr.rawValue,
                    sourceId: job.pageId,
                    content: content
                )
            )
        } }

        let confidences = tokens.map(\.confidence)
        return OCRPageResult(
            pageIndex: job.pageIndex,
            pageId: job.pageId,
            tokenCount: tokens.count,
            lineCount: recognition.lineCount,
            minimumConfidence: confidences.min(),
            averageConfidence: confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count),
            skipReason: recognition.skipReason,
            elapsedSeconds: recognition.elapsedSeconds,
            effectiveDPI: recognition.effectiveDPI
        )
    }

    // MARK: - Internals

    private struct DocumentIdentity: Sendable {
        let document: SearchIndexStore.DocumentRow
        let pages: [Int: SearchIndexStore.PageRow]
    }

    /// See `TextIndexer.documentIdentity`: the identity check is outside the database
    /// closure so that "no such document" survives as a typed error rather than being
    /// re-presented as a `DatabaseError` by GRDB.
    private func documentIdentity(_ documentId: String) async throws -> DocumentIdentity {
        let identity: DocumentIdentity? = try await read { db in
            guard let document = try SearchIndexStore.documentRow(db, documentId: documentId) else {
                return nil
            }
            return DocumentIdentity(
                document: document,
                pages: try SearchIndexStore.pageRows(db, documentId: documentId)
            )
        }
        guard let identity else {
            throw ZPDFSearchError.unknownDocument(documentId: documentId)
        }
        return identity
    }

    private func read<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do { return try await database.read(body) } catch { throw ZPDFSearchError.adaptStorage(error) }
    }

    private func write<T: Sendable>(
        _ body: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do { return try await database.write(body) } catch { throw ZPDFSearchError.adaptStorage(error) }
    }
}
