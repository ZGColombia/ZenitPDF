import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFUIPresentation
import ZPDFUIWorkflows
import ZPDFVectorExtraction

/// Where a symbol search looks (NL-AUTO-05).
enum SymbolSearchScope: String, CaseIterable, Sendable {
    case thisPage
    case navigatorSelection
    case matchingSize
    case allPages

    var displayName: String {
        switch self {
        case .thisPage:
            return NSLocalizedString("This page", comment: "Symbol search scope: the current page only")
        case .navigatorSelection:
            return NSLocalizedString("Navigator selection", comment: "Batch apply scope choice")
        case .matchingSize:
            return NSLocalizedString("Pages of one size", comment: "Batch apply scope choice")
        case .allPages:
            return NSLocalizedString("All pages", comment: "Batch apply scope choice")
        }
    }
}

/// What the person asked for in the symbol prompt.
struct SymbolSearchRequest: Sendable, Equatable {
    var designation: String
    var scope: SymbolSearchScope
    /// Box another type before searching (NL-AUTO-06): several legend symbols in one run, where
    /// a place two types both match is shown as contested and counted once.
    var addAnotherType: Bool = false
}

/// Feature 12's application flow, reviewed (NL-AUTO-02) and set-wide (NL-AUTO-05): the estimator
/// boxes ONE placed symbol, names it — the tag beside it is offered as a prefill (NL-AUTO-06) —
/// chooses where to look, and reviews every match, near miss and already-counted place before
/// anything lands. Accepting lands one count markup per page in one undoable step.
extension ProjectWindowController {

    /// How the designation and scope are asked for. Injectable for tests.
    static var symbolSearchPrompt: (@MainActor (NSWindow?, _ suggestion: String?) async -> SymbolSearchRequest?) = { window, suggestion in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Name This Symbol",
                comment: "Symbol schedule designation prompt title"
            )
            alert.informativeText = NSLocalizedString(
                "The type designation printed beside the symbol — D-12, F01. Every match is shown for review before anything is counted.",
                comment: "Symbol schedule designation prompt body"
            )
            let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
            field.placeholderString = NSLocalizedString(
                "Designation",
                comment: "Symbol designation field placeholder"
            )
            field.stringValue = suggestion ?? ""
            field.setAccessibilityLabel(NSLocalizedString(
                "Designation", comment: "Symbol designation field placeholder"
            ))
            let scope = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
            for choice in SymbolSearchScope.allCases {
                scope.addItem(withTitle: choice.displayName)
            }
            scope.setAccessibilityLabel(NSLocalizedString(
                "Where to look for matches", comment: "Accessibility label for the symbol search scope picker"
            ))
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
            container.addSubview(field)
            container.addSubview(scope)
            alert.accessoryView = container
            alert.addButton(withTitle: NSLocalizedString("Find Matches", comment: "Designation prompt confirm"))
            alert.addButton(withTitle: NSLocalizedString("Add Another Type…", comment: "Designation prompt: box another symbol type before searching"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Designation prompt cancel"))
            ZenitModalPresenter.runAlert(
                alert,
                identifier: "symbolSchedule.designationPrompt",
                sheetedOn: window
            ) { answer in
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                let chosen = SymbolSearchScope.allCases[max(0, scope.indexOfSelectedItem)]
                let button = answer.buttonIndex ?? 2
                continuation.resume(
                    returning: button <= 1 && !name.isEmpty
                        ? SymbolSearchRequest(designation: name, scope: chosen, addAnotherType: button == 1) : nil
                )
            }
        }
    }

    /// How the review reaches the screen, returning its dismissal. A test injects a capture.
    static var symbolReviewPresenter: (@MainActor (SymbolCountReviewModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else { return {} }
        let host = NSHostingController(rootView: SymbolCountReviewView(model: model))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "symbolSchedule.review") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// The one identity the schedule's incomplete-search warning uses.
    static let symbolScheduleWarningID = UUID(uuidString: "5E2F8D31-7A66-4B02-9C1D-8F4A3B6C7D21")!

    /// How far from the boxed symbol a tag may sit to be offered as its designation, in page
    /// points: two symbol diagonals, and never under an inch.
    static func designationSearchRadius(for exemplar: SymbolExemplar) -> Double {
        let diagonal = (exemplar.bounds.width * exemplar.bounds.width + exemplar.bounds.height * exemplar.bounds.height).squareRoot()
        return max(72, diagonal * 2)
    }

    func beginSymbolSchedule(for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document) else { return }
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a box around one instance of the symbol.",
            comment: "Status note after Measure ▸ Create Symbol Schedule…"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString(
                "Symbol schedule cancelled.",
                comment: "Status note when the symbol-schedule region capture ends without a rectangle"
            )
        ) { [weak self, weak document] (pageRect: PDFRectValue) in
            guard let self, let document else { return }
            self.runSymbolSchedule(for: document, region: pageRect)
        }
    }

    /// The status words for an extraction that failed, as distinct from one that found nothing.
    static func symbolScheduleExtractionFailureNote(_ error: any Error) -> String {
        String(
            format: NSLocalizedString(
                "Could not read this page's vector geometry: %@",
                comment: "Status note when the symbol schedule's geometry extraction failed; the argument is the reason"
            ),
            DocumentSessionLoader.extractionFailureDetail(error)
        )
    }

    /// The primitives a symbol search may match on one page: the page's layer-aware extraction
    /// minus every layer the person has hidden there.
    func symbolSearchPrimitives(
        for document: ZenitPDFProjectDocument,
        page: ZPDFContracts.PageDescriptor
    ) async throws -> [VectorPrimitive] {
        try await symbolSearchInput(for: document, page: page).primitives
    }

    /// The page's extraction and the primitives a search may match on it.
    func symbolSearchInput(
        for document: ZenitPDFProjectDocument,
        page: ZPDFContracts.PageDescriptor
    ) async throws -> (extraction: VectorPageExtraction, primitives: [VectorPrimitive]) {
        let extraction = try await automationExtraction(for: document, page: page)
        // The layer panel hides the primary drawing's layers only (U-012).
        let hidden = document.hiddenLayerNames(for: page, snap: false)
        return (extraction, extraction.primitives(excludingLayerIDs: hidden))
    }

    private func runSymbolSchedule(
        for document: ZenitPDFProjectDocument,
        region: PDFRectValue,
        pending: [(designation: String, exemplar: SymbolExemplar)] = []
    ) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing else { return }
            guard let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID })
            else { return }
            let primitives: [VectorPrimitive]
            do {
                // The page the canvas already holds, or the document's layer-aware store — never
                // a second XPC round trip for the same page, and never a layer the person hid.
                primitives = try await self.symbolSearchPrimitives(for: document, page: page)
            } catch {
                // A timeout, a stopped service or a locked drawing is not "no geometry": that
                // wording sent the estimator off believing the sheet was a scan (BH-900).
                core.status.setActiveToolNote(Self.symbolScheduleExtractionFailureNote(error))
                return
            }
            // A scanned sheet has no vector geometry: its symbols are found in the page picture
            // instead (NL-AUTO-14), when the box holds ink there.
            let scanReadable = pending.isEmpty && drawing.documentID == document.drawing?.documentID
            guard !primitives.isEmpty else {
                if scanReadable, await self.beginScanSymbolCount(
                    for: document, page: page, pages: drawing.pages, region: region, core: core
                ) { return }
                core.status.setActiveToolNote(NSLocalizedString(
                    "This page has no vector geometry to match symbols in.",
                    comment: "Status note when the symbol matcher has nothing to search"
                ))
                return
            }

            let bounds = VectorBounds(
                minX: region.minX, minY: region.minY,
                maxX: region.maxX, maxY: region.maxY
            )
            let exemplar: SymbolExemplar
            do {
                exemplar = try SymbolExemplar(primitives: primitives, region: bounds)
            } catch {
                // No vector line inside the box, on a sheet that has some elsewhere: a scanned
                // plan under a vector title block. The box is read from the page picture.
                if case SymbolExemplarError.noPrimitivesInRegion = error, scanReadable,
                   await self.beginScanSymbolCount(for: document, page: page, pages: drawing.pages, region: region, core: core) {
                    return
                }
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "No usable symbol inside the box: %@",
                        comment: "Status note when the boxed region yields no exemplar"
                    ),
                    String(describing: error)
                ))
                return
            }

            // The tag beside the boxed symbol, offered as the designation (NL-AUTO-06).
            let lines = ((try? await drawing.rasterSource.pageTextLines(pageIndex: page.index)) ?? []).map {
                RecognisedTextLine(
                    text: $0.text,
                    boundsInPageSpace: PDFRectValue(
                        x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                        width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
                    )
                )
            }
            let suggestion = NearbyDesignationSuggester(lines: lines).suggestion(
                near: PDFPoint(x: exemplar.centroid.x, y: exemplar.centroid.y),
                maximumDistance: Self.designationSearchRadius(for: exemplar)
            )
            guard let request = await Self.symbolSearchPrompt(self.window, suggestion) else { return }
            let types = pending + [(request.designation, exemplar)]
            if request.addAnotherType {
                // Box the next legend symbol; the types collected so far wait for it.
                guard let canvas = self.canvasController(for: document) else { return }
                core.status.setActiveToolNote(String(
                    format: NSLocalizedString(
                        "%d type(s) boxed. Drag a box around the next symbol type.",
                        comment: "Status note while boxing several symbol types"
                    ),
                    types.count
                ))
                self.beginRegionCapture(
                    on: canvas,
                    for: document,
                    cancelNote: NSLocalizedString(
                        "Symbol schedule cancelled.",
                        comment: "Status note when the symbol-schedule region capture ends without a rectangle"
                    )
                ) { [weak self, weak document] (next: PDFRectValue) in
                    guard let self, let document else { return }
                    self.runSymbolSchedule(for: document, region: next, pending: types)
                }
                return
            }
            let pages = Self.pages(for: request.scope, current: page, in: drawing.pages, core: core)
            if types.count == 1 {
                self.presentSymbolReview(
                    request: request, exemplar: exemplar, pages: pages, drawing: drawing, document: document, core: core
                )
            } else {
                self.presentMultiTypeReview(types: types, pages: pages, document: document, core: core)
            }
        }
    }

    /// The pages a scope covers, current page first so the boxed example leads the review, the
    /// rest in set order.
    ///
    /// `drawingPages` is the sheet on screen's drawing, every page of its file; only the sheets
    /// of the set are searched (V-026). All Pages and Matching Size used to walk the whole file
    /// in PDF order, so a sheet the person removed from the set was searched and counts landed
    /// on it — counted in the note, absent from the Quantity Ledger — as Find Repeated Sheets
    /// and the Takeoff Assistant no longer do (T-005). Both the vector and the scan searches
    /// take their pages here.
    static func pages(
        for scope: SymbolSearchScope,
        current: ZPDFContracts.PageDescriptor,
        in drawingPages: [ZPDFContracts.PageDescriptor],
        core: AppCoreEnvironment
    ) -> [ZPDFContracts.PageDescriptor] {
        let byID = Dictionary(drawingPages.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let all = core.snapshot.pages.compactMap { byID[$0.id] }
        let chosen: [ZPDFContracts.PageDescriptor]
        switch scope {
        case .thisPage:
            chosen = [current]
        case .allPages:
            chosen = all
        case .matchingSize:
            let size = current.visibleBox.size
            chosen = all.filter {
                abs($0.visibleBox.size.width - size.width) <= 2 && abs($0.visibleBox.size.height - size.height) <= 2
            }
        case .navigatorSelection:
            let selected = Set(core.document.selectedPageIDs)
            let pages = all.filter { selected.contains($0.id.rawValue) }
            chosen = pages.isEmpty ? [current] : pages
        }
        return [current] + chosen.filter { $0.id != current.id }
    }

    // MARK: - Review

    /// - Parameter drawing: the drawing `pages` come from — the sheet on screen's own. Its text
    ///   and pictures are read for the tag cross-count and the thumbnails (U-011); the primary
    ///   drawing's same-index sheet used to be read.
    private func presentSymbolReview(
        request: SymbolSearchRequest,
        exemplar: SymbolExemplar,
        pages: [ZPDFContracts.PageDescriptor],
        drawing: LoadedDrawing,
        document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment
    ) {
        let box = SheetDismissBox()
        let search = SymbolSearchRun(pages: pages)
        let model = SymbolCountReviewModel(
            designation: request.designation,
            pageTotal: pages.count,
            onAccept: { [weak self, weak document] outcome in
                search.cancel()
                box.dismiss()
                guard let self, let document else { return }
                self.canvasController(for: document)?.setAutomationOverlay(nil)
                Task { @MainActor in
                    if outcome.saveToLibrary { self.saveToSymbolLibrary(designation: outcome.designation, exemplar: exemplar, core: core) }
                    await self.landSymbolCounts(
                        groups: [(outcome.designation, search.results, exemplar)],
                        selected: outcome.selectedRowIDs,
                        core: core
                    )
                }
            },
            onCancel: { [weak self, weak document] in
                search.cancel()
                box.dismiss()
                guard let self, let document else { return }
                self.canvasController(for: document)?.setAutomationOverlay(nil)
                core.status.setActiveToolNote(NSLocalizedString(
                    "Symbol schedule cancelled.",
                    comment: "Status note when the symbol-schedule region capture ends without a rectangle"
                ))
            },
            onStopSearch: { search.cancel() },
            onReveal: { [weak self, weak document] row in
                guard let self, let document else { return }
                self.revealSymbolRow(row, search: search, document: document, core: core)
            }
        )
        let rasterSource = drawing.rasterSource
        model.thumbnailProvider = { row in
            let rect = row.bounds
            let margin = max(4, max(rect.size.width, rect.size.height) * 0.25)
            let region = PDFRect(
                x: rect.minX - margin, y: rect.minY - margin,
                width: rect.size.width + 2 * margin, height: rect.size.height + 2 * margin
            )
            let scale = 88 / max(1, max(region.width, region.height))
            return try? await rasterSource.renderRegion(pageIndex: row.pageIndex, region: region, pixelsPerPoint: scale)
        }
        box.dismiss = Self.symbolReviewPresenter(model, window)

        search.task = Task { @MainActor [weak self, weak document] in
            let existing = await Self.existingCountPoints(session: core.session)
            // A window of two: the next page's geometry is fetched while this page is matched.
            var prefetch: Task<Result<(extraction: VectorPageExtraction, primitives: [VectorPrimitive]), any Error>, Never>?
            func fetch(_ page: ZPDFContracts.PageDescriptor) -> Task<Result<(extraction: VectorPageExtraction, primitives: [VectorPrimitive]), any Error>, Never> {
                Task { @MainActor [weak self, weak document] in
                    guard let self, let document else { return .failure(CancellationError()) }
                    do { return .success(try await self.symbolSearchInput(for: document, page: page)) } catch {
                        return .failure(error)
                    }
                }
            }
            for (offset, page) in pages.enumerated() {
                if Task.isCancelled { break }
                let current = prefetch ?? fetch(page)
                prefetch = offset + 1 < pages.count ? fetch(pages[offset + 1]) : nil
                let label = Self.pageLabel(page, core: core)
                switch await current.value {
                case .failure(let error):
                    guard !Task.isCancelled else { break }
                    model.append(
                        page: SymbolCountReviewPage(
                            pageIndex: page.index, pageLabel: label, otherShapeCount: 0, isTruncated: false,
                            failure: Self.symbolScheduleExtractionFailureNote(error)
                        ),
                        rows: []
                    )
                case .success(let input):
                    let primitives = input.primitives
                    let extraction = input.extraction
                    // A CAD block drawn as a Form XObject is counted exactly (NL-AUTO-12); anything
                    // else is matched by shape.
                    // The exemplar's page says whether the boxed symbol is one CAD block; every page is
                    // then searched for that block's drawings first (NL-AUTO-12).
                    let isExemplarPage = offset == 0
                    if isExemplarPage { search.block = ExactBlockMatcher.block(of: exemplar, in: extraction) }
                    let block = search.block
                    let (report, isExact) = await Task.detached(priority: .userInitiated) { () -> (SymbolMatchReport?, Bool) in
                        if let block {
                            let exact = ExactBlockMatcher.instances(of: block, in: extraction, visible: primitives, isExemplarPage: isExemplarPage)
                            if !exact.confirmed.isEmpty { return (exact, true) }
                        }
                        return (try? SymbolMatcher().matches(exemplar: exemplar, in: primitives), false)
                    }.value
                    if isExact { search.exactPages.insert(page.index) }
                    guard !Task.isCancelled else { break }
                    guard let report else {
                        model.append(
                            page: SymbolCountReviewPage(pageIndex: page.index, pageLabel: label, otherShapeCount: 0, isTruncated: false),
                            rows: []
                        )
                        continue
                    }
                    let result = SymbolCountReviewBuilder().pageResult(
                        pageID: page.id,
                        pageIndex: page.index,
                        exemplar: exemplar,
                        report: report,
                        existing: existing[page.id] ?? []
                    )
                    search.results.append(result)
                    // Two counts that must agree (NL-AUTO-23): the symbols found, and the tags
                    // printed beside them. Recorded before the page is appended: appending the
                    // last page ends the search, and a review read as finished had no tag count
                    // for that page yet (the count arrived one suspension later).
                    let tags = await Self.tagCrossCount(
                        designation: request.designation, result: result, exemplar: exemplar,
                        pageIndex: page.index, drawing: drawing
                    )
                    if let tags {
                        model.setTagCount(
                            pageIndex: page.index, symbols: tags.symbolCount,
                            tags: tags.tagCount, orphanTags: tags.orphanTags.count
                        )
                        search.orphanTags[page.index] = tags.orphanTags
                    }
                    model.append(
                        page: SymbolCountReviewPage(
                            pageIndex: page.index, pageLabel: label,
                            otherShapeCount: result.otherShapeCount, isTruncated: result.wasTruncated
                        ),
                        rows: result.candidates.map {
                            Self.reviewRow($0, pageLabel: label, exactBlock: search.exactPages.contains(page.index))
                        }
                    )
                    if page.id.rawValue == core.document.currentPageID, let self, let document {
                        self.canvasController(for: document)?.setAutomationOverlay(
                            Self.overlay(for: result, orphanTags: search.orphanTags[page.index] ?? [])
                        )
                    }
                }
            }
            prefetch?.cancel()
            model.finishSearch()
        }
    }

    /// The tags of `designation` on the page against the places found, or `nil` when the page's
    /// text cannot be read. `drawing` is the drawing the page comes from: `pageIndex` names a
    /// page only inside it (U-011).
    static func tagCrossCount(
        designation: String,
        result: SymbolCountPageResult,
        exemplar: SymbolExemplar,
        pageIndex: Int,
        drawing: LoadedDrawing?
    ) async -> TagCrossCount? {
        guard let source = drawing?.rasterSource,
              let lines = try? await source.pageTextLines(pageIndex: pageIndex) else { return nil }
        let recognised = lines.map {
            RecognisedTextLine(
                text: $0.text,
                boundsInPageSpace: PDFRectValue(
                    x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                    width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
                )
            )
        }
        let symbols = result.candidates.compactMap { candidate -> PDFPoint? in
            if case .nearMiss = candidate.status { return nil }
            return candidate.position
        }
        return TagCrossCount.count(
            designation: designation, lines: recognised, symbols: symbols,
            maximumDistance: designationSearchRadius(for: exemplar)
        )
    }

    /// The canvas highlight for one page: hits boxed solid, near misses and tags with no symbol
    /// beside them dashed.
    static func overlay(for result: SymbolCountPageResult, orphanTags: [PDFRectValue] = []) -> CanvasAutomationOverlay {
        var overlay = CanvasAutomationOverlay()
        overlay.nearMisses.append(contentsOf: orphanTags)
        for candidate in result.candidates {
            let rect = PDFRectValue(
                x: candidate.bounds.minX, y: candidate.bounds.minY,
                width: candidate.bounds.width, height: candidate.bounds.height
            )
            if case .nearMiss = candidate.status { overlay.nearMisses.append(rect) } else { overlay.hits.append(rect) }
        }
        return overlay
    }

    static func reviewRow(_ candidate: SymbolCountCandidate, pageLabel: String, exactBlock: Bool = false) -> SymbolCountReviewRow {
        let status: SymbolCountReviewRow.Status
        switch candidate.status {
        case .confirmed: status = .confirmed
        case .nearMiss: status = .nearMiss
        case .alreadyCounted(let subject): status = .alreadyCounted(subject: subject)
        }
        return SymbolCountReviewRow(
            id: candidate.id,
            pageIndex: candidate.pageIndex,
            pageLabel: pageLabel,
            position: PDFPointValue(x: candidate.position.x, y: candidate.position.y),
            bounds: PDFRectValue(
                x: candidate.bounds.minX, y: candidate.bounds.minY,
                width: candidate.bounds.width, height: candidate.bounds.height
            ),
            status: status,
            detail: exactBlock
                ? ([NSLocalizedString("exact block", comment: "Symbol review detail: the same CAD block, counted exactly")]
                    + partialBlockDetail(candidate)
                    + (candidate.isMirrored ? [NSLocalizedString("mirrored", comment: "Symbol review detail: the instance is a mirror image")] : []))
                    .joined(separator: " · ")
                : detail(for: candidate),
            isExemplar: candidate.isExemplar
        )
    }

    /// Why a drawing of the exact block is a near miss rather than a match: a clip or a hidden
    /// layer shows only part of it (T-066). Empty for every other candidate.
    static func partialBlockDetail(_ candidate: SymbolCountCandidate) -> [String] {
        guard case .nearMiss(let reason) = candidate.status,
              case .partialBlock(let visible, let total) = reason else { return [] }
        return [String(
            format: NSLocalizedString(
                "partly hidden — %1$d of %2$d strokes visible",
                comment: "Symbol review detail: a clipped or partly hidden drawing of the CAD block; strokes shown, strokes in the block"
            ),
            visible, total
        )]
    }

    /// How close a candidate came, in measured numbers only.
    static func detail(for candidate: SymbolCountCandidate) -> String {
        var parts: [String] = []
        if case .nearMiss(let reason) = candidate.status, case .scaleOutsideBand(let scale, let band) = reason {
            parts.append(String(
                format: NSLocalizedString(
                    "size %1$.2f× — outside %2$.2f–%3$.2f×",
                    comment: "Symbol review detail: measured size outside the accepted band"
                ),
                scale, band.lowerBound, band.upperBound
            ))
        } else if let ratio = candidate.residualRatio {
            parts.append(String(
                format: NSLocalizedString(
                    "residual %.2f of the bar",
                    comment: "Symbol review detail: residual over the acceptance threshold"
                ),
                ratio
            ))
        }
        if candidate.isMirrored {
            parts.append(NSLocalizedString("mirrored", comment: "Symbol review detail: the instance is a mirror image"))
        }
        if let scale = candidate.scaleFactor, candidate.status == .confirmed || { if case .alreadyCounted = candidate.status { return true } else { return false } }() {
            parts.append(String(format: NSLocalizedString("%.2f×", comment: "Symbol review detail: instance size over example size"), scale))
        }
        return parts.joined(separator: " · ")
    }

    static func pageLabel(_ page: ZPDFContracts.PageDescriptor, core: AppCoreEnvironment) -> String {
        if let shown = core.document.pages.first(where: { $0.id == page.id.rawValue }) {
            if let title = shown.sheetTitle, !title.isEmpty { return title }
            if !shown.label.isEmpty { return shown.label }
        }
        return String(format: NSLocalizedString("Page %d", comment: "A page named by its one-based number"), page.index + 1)
    }

    /// Every count point already in the takeoff, by page — every subject, so a place counted as
    /// D-13 is never counted again as D-12.
    static func existingCountPoints(session: TakeoffSession) async -> [PageID: [ExistingCountPoint]] {
        var result: [PageID: [ExistingCountPoint]] = [:]
        for record in await session.orderedMarkups where record.tool == .count {
            guard let geometry = record.geometry else { continue }
            let subject = record.subject
            for point in geometry.countPoints {
                result[record.pageID, default: []].append(ExistingCountPoint(subject: subject, position: point.position))
            }
        }
        return result
    }

    /// Turns to the row's sheet and shows the place. The sheet is found among the run's own
    /// pages — all of one drawing, where a page index is unique — never among the whole set's,
    /// where it repeats across drawings and Reveal turned to the primary drawing's sheet (U-011).
    private func revealSymbolRow(
        _ row: SymbolCountReviewRow,
        search: SymbolSearchRun,
        document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment
    ) {
        guard let pageID = search.pageID(forPageIndex: row.pageIndex) else { return }
        if core.document.currentPageID != pageID { core.document.goToPage(id: pageID) }
        let results = search.results, orphanTags = search.orphanTags
        guard let canvas = canvasController(for: document) else { return }
        if let result = results.first(where: { $0.pageIndex == row.pageIndex }) {
            canvas.setAutomationOverlay(Self.overlay(for: result, orphanTags: orphanTags[row.pageIndex] ?? []))
        }
        canvas.revealPageRect(row.bounds, highlight: true)
    }

    /// A landed schedule row's geometry: **count points**, the shape every other count
    /// producer builds. Bare `points` made the canvas draw the four doors as one dimensioned
    /// polyline with a length label and no count symbols (BH-074).
    static func scheduleCountGeometry(pageID: PageID, positions: [PDFPoint]) -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: pageID,
            countPoints: positions.map { CountPoint(id: CountPointID(UUID()), position: $0) }
        )
    }

    /// Lands the accepted places: one count markup per page and designation, one batch, one ⌘Z
    /// (IM-184).
    func landSymbolCounts(
        groups: [(designation: String, results: [SymbolCountPageResult], exemplar: SymbolExemplar)],
        selected: Set<Int>,
        core: AppCoreEnvironment
    ) async {
        let placed = groups.flatMap { group in
            SymbolCountReviewBuilder.acceptedPositions(from: group.results, selected: selected, exemplar: group.exemplar)
                .map { (designation: group.designation, pageID: $0.pageID, positions: $0.positions) }
        }
        let results = groups.flatMap(\.results)
        guard !placed.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString(
                "No matching symbols found — nothing was counted.",
                comment: "Status note when the matcher confirmed nothing"
            ))
            return
        }
        let now = Date()
        let documentID = await core.session.documentID
        let commands: [DocumentCommand] = placed.map { entry in
            // r2-platform, ADR-0031: a count found by the symbol matcher says so.
            .addMarkup(CaptureStamp.stamped(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: entry.pageID,
                kind: .measurement,
                tool: .count,
                subject: entry.designation,
                geometry: Self.scheduleCountGeometry(pageID: entry.pageID, positions: entry.positions),
                createdAt: now,
                modifiedAt: now
            ), method: CaptureMethod(kind: .symbolMatched)))
        }
        do {
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString(
                    "Symbol Schedule",
                    comment: "Undo action name for landing a symbol schedule's counts"
                )
            )
        } catch {
            core.status.setActiveToolNote(String(describing: error))
            return
        }
        await core.commands.settle()
        await core.refresh()

        let counted = placed.reduce(0) { $0 + $1.positions.count }
        let truncated = results.filter(\.wasTruncated)
        let designation = Set(placed.map(\.designation)).sorted().joined(separator: ", ")
        let pageCount = Set(placed.map(\.pageID)).count
        if truncated.isEmpty {
            core.status.setActiveToolNote(String(
                format: NSLocalizedString(
                    "%1$@: %2$d counted on %3$d page(s).",
                    comment: "Status note after landing reviewed symbol counts; designation, count, pages"
                ),
                designation, counted, pageCount
            ))
        } else {
            // The one warning left: a search that stopped before it had looked everywhere.
            core.document.post(AppWarning(
                id: Self.symbolScheduleWarningID,
                severity: .warning,
                title: String(
                    format: NSLocalizedString(
                        "Schedule for %1$@: %2$d counted — the search stopped early on %3$d page(s).",
                        comment: "Symbol schedule warning when a cap stopped the search"
                    ),
                    designation, counted, truncated.count
                ),
                message: NSLocalizedString(
                    "Those pages may hold more of this symbol. Count them by hand or box a tighter example.",
                    comment: "Symbol schedule warning body when a cap stopped the search"
                ),
                source: NSLocalizedString("Symbol schedule", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            ))
        }
    }
}

extension ProjectWindowController {

    /// Several legend symbols in one run (NL-AUTO-06). Each type's matches are listed under its
    /// designation; a place two types both confirm is listed under each, unticked, and ticking
    /// one claim unticks the others — a contested place is counted once or not at all.
    func presentMultiTypeReview(
        types: [(designation: String, exemplar: SymbolExemplar)],
        pages: [ZPDFContracts.PageDescriptor],
        document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment
    ) {
        let box = SheetDismissBox()
        let search = SymbolSearchRun(pages: pages)
        let model = SymbolCountReviewModel(
            designation: types.map(\.designation).joined(separator: ", "),
            pageTotal: pages.count,
            onAccept: { [weak self, weak document] outcome in
                search.cancel()
                box.dismiss()
                guard let self, let document else { return }
                self.canvasController(for: document)?.setAutomationOverlay(nil)
                let groups = types.enumerated().map { index, type in
                    (designation: type.designation, results: search.resultsByType[index] ?? [], exemplar: type.exemplar)
                }
                Task { @MainActor in
                    await self.landSymbolCounts(groups: groups, selected: outcome.selectedRowIDs, core: core)
                }
            },
            onCancel: { [weak self, weak document] in
                search.cancel()
                box.dismiss()
                guard let self, let document else { return }
                self.canvasController(for: document)?.setAutomationOverlay(nil)
            },
            onStopSearch: { search.cancel() },
            onReveal: { [weak self, weak document] row in
                guard let self, let document else { return }
                // The run's own sheet, never the set's first page of that index (U-011).
                if let pageID = search.pageID(forPageIndex: row.pageIndex), core.document.currentPageID != pageID {
                    core.document.goToPage(id: pageID)
                }
                self.canvasController(for: document)?.revealPageRect(row.bounds, highlight: true)
            }
        )
        box.dismiss = Self.symbolReviewPresenter(model, window)

        search.task = Task { @MainActor [weak self, weak document] in
            let existing = await Self.existingCountPoints(session: core.session)
            var nextGroup = 1
            for page in pages {
                if Task.isCancelled { break }
                guard let self, let document else { break }
                let label = Self.pageLabel(page, core: core)
                let primitives: [VectorPrimitive]
                do {
                    primitives = try await self.symbolSearchPrimitives(for: document, page: page)
                } catch {
                    model.append(
                        page: SymbolCountReviewPage(
                            pageIndex: page.index, pageLabel: label, otherShapeCount: 0, isTruncated: false,
                            failure: Self.symbolScheduleExtractionFailureNote(error)
                        ),
                        rows: []
                    )
                    continue
                }
                var runs: [SymbolCountReviewBuilder.TypeRun] = []
                for (index, type) in types.enumerated() {
                    let exemplar = type.exemplar
                    guard let report = await Task.detached(priority: .userInitiated, operation: {
                        try? SymbolMatcher().matches(exemplar: exemplar, in: primitives)
                    }).value else { continue }
                    let result = SymbolCountReviewBuilder().pageResult(
                        pageID: page.id, pageIndex: page.index, exemplar: exemplar, report: report,
                        existing: existing[page.id] ?? [], idOffset: (index + 1) * 1_000_000_000
                    )
                    search.resultsByType[index, default: []].append(result)
                    runs.append(SymbolCountReviewBuilder.TypeRun(designation: type.designation, report: report, result: result))
                }
                guard !Task.isCancelled else { break }
                // Places two types both confirmed.
                var groupOf: [Int: Int] = [:]
                var designationOf: [Int: String] = [:]
                for run in runs { for candidate in run.result.candidates { designationOf[candidate.id] = run.designation } }
                for group in SymbolCountReviewBuilder.contestedGroups(runs) {
                    for id in group { groupOf[id] = nextGroup }
                    nextGroup += 1
                }
                var rows: [SymbolCountReviewRow] = []
                var others = 0
                var truncated = false
                for run in runs {
                    others += run.result.otherShapeCount
                    truncated = truncated || run.result.wasTruncated
                    for candidate in run.result.candidates {
                        if case .nearMiss = candidate.status { continue }
                        let row = Self.reviewRow(candidate, pageLabel: label)
                        let group = groupOf[candidate.id]
                        let rivals = group.map { g in
                            groupOf.filter { $0.value == g && $0.key != candidate.id }.compactMap { designationOf[$0.key] }
                        } ?? []
                        rows.append(SymbolCountReviewRow(
                            id: row.id, pageIndex: row.pageIndex, pageLabel: row.pageLabel, position: row.position,
                            bounds: row.bounds, status: row.status, detail: row.detail, isExemplar: row.isExemplar,
                            designation: run.designation, exclusiveGroup: group,
                            alsoClaimedBy: Array(Set(rivals)).sorted()
                        ))
                    }
                }
                model.append(
                    page: SymbolCountReviewPage(pageIndex: page.index, pageLabel: label, otherShapeCount: others, isTruncated: truncated),
                    rows: rows
                )
                if page.id.rawValue == core.document.currentPageID {
                    var overlay = CanvasAutomationOverlay()
                    overlay.hits = rows.filter { $0.exclusiveGroup == nil }.map(\.bounds)
                    overlay.nearMisses = rows.filter { $0.exclusiveGroup != nil }.map(\.bounds)
                    self.canvasController(for: document)?.setAutomationOverlay(overlay)
                }
            }
            model.finishSearch()
        }
    }
}

/// One running symbol search: its task and what it found so far.
@MainActor
final class SymbolSearchRun {
    /// The run's sheets by page index. They all come from one drawing — the sheet on screen's —
    /// so an index names one of them; across the set it does not (U-011).
    let pageIDsByIndex: [Int: UUID]

    init(pages: [ZPDFContracts.PageDescriptor] = []) {
        pageIDsByIndex = Dictionary(pages.map { ($0.index, $0.id.rawValue) }, uniquingKeysWith: { first, _ in first })
    }

    /// The identity of the run's sheet at `pageIndex`.
    func pageID(forPageIndex pageIndex: Int) -> UUID? { pageIDsByIndex[pageIndex] }

    var task: Task<Void, Never>?
    var results: [SymbolCountPageResult] = []
    /// Tags with no symbol beside them, per page index (NL-AUTO-23).
    var orphanTags: [Int: [PDFRectValue]] = [:]
    /// Per type, for a run of several types (NL-AUTO-06).
    var resultsByType: [Int: [SymbolCountPageResult]] = [:]
    /// Pages whose matches are exact CAD blocks (NL-AUTO-12).
    var exactPages: Set<Int> = []
    /// The CAD block the exemplar is, found on its own page (NL-AUTO-12).
    var block: ExactBlock?

    func cancel() {
        task?.cancel()
    }
}
