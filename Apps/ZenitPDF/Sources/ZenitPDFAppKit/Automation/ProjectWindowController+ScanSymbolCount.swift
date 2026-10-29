import AppKit
import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFRasterAnalysis
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Scan-based symbol counting (NL-AUTO-14, scan path): Create Symbol Schedule on a sheet that is a
/// scan. The boxed symbol is cut from the page picture and found again by ``TemplateMatcher`` —
/// normalised cross-correlation at the four right angles and their mirrors — on every page the
/// person chose. Every place goes through the same review as a vector search, each row saying it
/// was read from the scan and how sure the match is, and only the ticked places land: one count
/// markup per page, stamped `CaptureMethod.fromScan` with the weakest accepted score as its
/// confidence (ADR-0031). Nothing from the scan is a snap target, and nothing is counted without
/// the person's click.
enum ScanSymbolCount {

    /// Scores at or above this are listed as matches, ticked — the matcher's own acceptance bar,
    /// benchmarked in `ScanAutomationBenchmarkTests` (recall at least 90 %, no stray match).
    static let matchThreshold = TemplateMatcher.Options.standard.threshold
    /// Scores from here up to ``matchThreshold`` are listed as near misses, unticked: the person
    /// sees what almost matched and decides.
    static let nearMissFloor = 0.6
    /// The matcher's options for a search: its own, with the bar lowered to the near-miss floor
    /// so the weaker places can be listed unticked.
    static let searchOptions: TemplateMatcher.Options = {
        var options = TemplateMatcher.Options.standard
        options.threshold = nearMissFloor
        return options
    }()
    /// A pixel darker than this is ink.
    static let inkLevel: UInt8 = 128
    /// The fewest ink pixels a boxed example needs: fewer is a speck, and would match any mark.
    static let minimumInkPixels = 12
    /// Paper kept around the example's ink, in pixels, so a stroke on its edge still correlates.
    static let templateMargin = 2

    /// The boxed example cut from `raster` and trimmed to its ink, or `nil` when the box holds no
    /// usable ink (blank paper, a speck, or a box that is all ink).
    static func template(from raster: GrayRaster, box: PDFRectValue) -> GrayRaster? {
        let topLeft = raster.pixel(of: CGPoint(x: box.minX, y: box.maxY))
        let bottomRight = raster.pixel(of: CGPoint(x: box.maxX, y: box.minY))
        let x = Int(topLeft.x.rounded(.down)), y = Int(topLeft.y.rounded(.down))
        let width = Int(bottomRight.x.rounded(.up)) - x, height = Int(bottomRight.y.rounded(.up)) - y
        guard width >= 4, height >= 4, let boxed = raster.crop(x: x, y: y, width: width, height: height) else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min, ink = 0
        for row in 0..<boxed.height {
            for column in 0..<boxed.width where boxed[column, row] < inkLevel {
                ink += 1
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard ink >= minimumInkPixels, ink < boxed.width * boxed.height else { return nil }
        return boxed.crop(
            x: minX - templateMargin, y: minY - templateMargin,
            width: maxX - minX + 1 + 2 * templateMargin, height: maxY - minY + 1 + 2 * templateMargin
        )
    }

    /// One place the matcher found, as the review needs it.
    struct Found: Hashable, Sendable {
        var center: CGPoint
        var score: Double
        var quarterTurns: Int
        var mirrored: Bool

        init(center: CGPoint, score: Double, quarterTurns: Int = 0, mirrored: Bool = false) {
            self.center = center
            self.score = score
            self.quarterTurns = quarterTurns
            self.mirrored = mirrored
        }

        init(_ match: TemplateMatcher.Match) {
            self.init(center: match.center, score: match.score, quarterTurns: match.quarterTurns, mirrored: match.mirrored)
        }
    }

    /// The template's footprint in page points.
    static func sizeInPoints(of template: GrayRaster) -> CGSize {
        CGSize(width: template.pageRegion.width, height: template.pageRegion.height)
    }

    /// One page's review rows, ids from `idBase` up, in the matcher's reading order.
    ///
    /// - Parameters:
    ///   - templateSize: the example's footprint in page points, unrotated.
    ///   - existing: count points already on the page; a match on one is listed as already
    ///     counted and left unticked, so accepting cannot count a place twice.
    ///   - exemplarCenter: the boxed example's centre on its own page, so its row says so.
    static func rows(
        matches: [Found],
        templateSize: CGSize,
        pageIndex: Int,
        pageLabel: String,
        existing: [ExistingCountPoint],
        exemplarCenter: CGPoint?,
        idBase: Int
    ) -> [SymbolCountReviewRow] {
        let radius = max(1, min(templateSize.width, templateSize.height) / 2)
        return matches.enumerated().map { offset, match in
            let turned = match.quarterTurns % 2 == 1
            let width = turned ? templateSize.height : templateSize.width
            let height = turned ? templateSize.width : templateSize.height
            let status: SymbolCountReviewRow.Status
            if let counted = existing.first(where: { hypot($0.position.x - match.center.x, $0.position.y - match.center.y) <= radius }) {
                status = .alreadyCounted(subject: counted.subject)
            } else {
                status = match.score >= matchThreshold ? .confirmed : .nearMiss
            }
            return SymbolCountReviewRow(
                id: idBase + offset,
                pageIndex: pageIndex,
                pageLabel: pageLabel,
                position: PDFPointValue(x: match.center.x, y: match.center.y),
                bounds: PDFRectValue(x: match.center.x - width / 2, y: match.center.y - height / 2, width: width, height: height),
                status: status,
                detail: detail(for: match),
                isExemplar: exemplarCenter.map { hypot($0.x - match.center.x, $0.y - match.center.y) <= radius } ?? false
            )
        }
    }

    /// How the match was read, in words: always "from the scan", then its score and orientation.
    static func detail(for match: Found) -> String {
        var parts = [
            NSLocalizedString("from the scan", comment: "Symbol review detail: the place was read from the page's pixels"),
            String(format: NSLocalizedString("score %.2f", comment: "Symbol review detail: normalised correlation of a scan match, 0 to 1"), match.score)
        ]
        if match.quarterTurns != 0 {
            parts.append(String(
                format: NSLocalizedString("turned %d°", comment: "Symbol review detail: the scan match is the example turned clockwise"),
                match.quarterTurns * 90
            ))
        }
        if match.mirrored {
            parts.append(NSLocalizedString("mirrored", comment: "Symbol review detail: the instance is a mirror image"))
        }
        return parts.joined(separator: " · ")
    }

    /// The count markups the ticked rows land as: one per page, in page order, each with its
    /// positions in review order and the weakest ticked score as its confidence.
    static func landings(
        rows: [SymbolCountReviewRow],
        selected: Set<Int>,
        scores: [Int: Double],
        pageIDs: [Int: PageID]
    ) -> [(pageID: PageID, positions: [PDFPoint], confidence: Double)] {
        var byPage: [Int: [SymbolCountReviewRow]] = [:]
        for row in rows where selected.contains(row.id) { byPage[row.pageIndex, default: []].append(row) }
        return byPage.keys.sorted().compactMap { pageIndex in
            guard let pageID = pageIDs[pageIndex], let picked = byPage[pageIndex], !picked.isEmpty else { return nil }
            let confidence = picked.compactMap { scores[$0.id] }.min() ?? matchThreshold
            return (pageID, picked.map { PDFPoint(x: $0.position.x, y: $0.position.y) }, min(1, max(0, confidence)))
        }
    }
}

/// The running scan search: what the review lists, and the score behind each row.
@MainActor
final class ScanSymbolSearchRun {
    var task: Task<Void, Never>?
    var rows: [SymbolCountReviewRow] = []
    var scores: [Int: Double] = [:]
    var pageIDs: [Int: PageID] = [:]

    func cancel() { task?.cancel() }
}

extension ProjectWindowController {

    /// Starts a scan search for the symbol boxed at `region` on `page`, when the page picture has
    /// a usable symbol there. Returns `false` — nothing started, nothing said — when the page
    /// cannot be rendered or the box holds no ink, so the caller's own refusal stands.
    func beginScanSymbolCount(
        for document: ZenitPDFProjectDocument,
        page: ZPDFContracts.PageDescriptor,
        pages allPages: [ZPDFContracts.PageDescriptor],
        region: PDFRectValue,
        core: AppCoreEnvironment
    ) async -> Bool {
        guard let raster = await ScanTrace.raster(document: document, pageIndex: page.index, pageID: page.id.rawValue),
              let template = ScanSymbolCount.template(from: raster, box: region)
        else { return false }
        guard let request = await Self.symbolSearchPrompt(window, nil) else { return true }
        if request.addAnotherType {
            core.status.setActiveToolNote(NSLocalizedString(
                "Several types at once are read from vector symbols only; this scan search counts one type.",
                comment: "Status note when Add Another Type is chosen on a scanned sheet"
            ))
        }
        let pages = Self.pages(for: request.scope, current: page, in: allPages, core: core)
        let exemplarCenter = CGPoint(x: template.pageRegion.midX, y: template.pageRegion.midY)
        presentScanSymbolReview(
            designation: request.designation,
            template: template,
            exemplarPage: page,
            exemplarCenter: exemplarCenter,
            exemplarBox: region,
            pages: pages,
            document: document,
            core: core
        )
        return true
    }

    private func presentScanSymbolReview(
        designation: String,
        template: GrayRaster,
        exemplarPage: ZPDFContracts.PageDescriptor,
        exemplarCenter: CGPoint,
        exemplarBox: PDFRectValue,
        pages: [ZPDFContracts.PageDescriptor],
        document: ZenitPDFProjectDocument,
        core: AppCoreEnvironment
    ) {
        let box = SheetDismissBox()
        let search = ScanSymbolSearchRun()
        let model = SymbolCountReviewModel(
            designation: designation,
            pageTotal: pages.count,
            onAccept: { [weak self, weak document] outcome in
                search.cancel()
                box.dismiss()
                guard let self, let document else { return }
                self.canvasController(for: document)?.setAutomationOverlay(nil)
                Task { @MainActor in
                    await self.landScanSymbolCounts(
                        designation: outcome.designation,
                        landings: ScanSymbolCount.landings(
                            rows: search.rows, selected: outcome.selectedRowIDs,
                            scores: search.scores, pageIDs: search.pageIDs
                        ),
                        askedForLibrary: outcome.saveToLibrary,
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
                if let shown = core.document.pages.first(where: { $0.index == row.pageIndex }), core.document.currentPageID != shown.id {
                    core.document.goToPage(id: shown.id)
                }
                guard let canvas = self.canvasController(for: document) else { return }
                canvas.setAutomationOverlay(Self.scanOverlay(for: search.rows.filter { $0.pageIndex == row.pageIndex }))
                canvas.revealPageRect(row.bounds, highlight: true)
            }
        )
        if let rasterSource = document.drawing?.rasterSource {
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
        }
        box.dismiss = Self.symbolReviewPresenter(model, window)

        search.task = Task { @MainActor [weak self, weak document] in
            let existing = await Self.existingCountPoints(session: core.session)
            // The example at each page picture's own scale: pages of another size render at
            // another scale, and a correlation only compares pixels of one size.
            var templates: [Int: GrayRaster] = [:]
            var nextID = 1
            for page in pages {
                if Task.isCancelled { break }
                guard let self, let document else { break }
                let label = Self.pageLabel(page, core: core)
                search.pageIDs[page.index] = page.id
                guard let raster = await ScanTrace.raster(document: document, pageIndex: page.index, pageID: page.id.rawValue) else {
                    model.append(
                        page: SymbolCountReviewPage(
                            pageIndex: page.index, pageLabel: label, otherShapeCount: 0, isTruncated: false,
                            failure: NSLocalizedString(
                                "This page could not be rendered to read it as a scan.",
                                comment: "Symbol review: a page the scan search could not render"
                            )
                        ),
                        rows: []
                    )
                    continue
                }
                let scaleKey = Int((raster.pointsPerPixel * 10_000).rounded())
                let example: GrayRaster
                if let cached = templates[scaleKey] {
                    example = cached
                } else if abs(raster.pointsPerPixel - template.pointsPerPixel) <= template.pointsPerPixel * 0.01 {
                    example = template
                } else if let rendered = await self.scanTemplate(
                    document: document, pageIndex: exemplarPage.index, box: exemplarBox, pointsPerPixel: raster.pointsPerPixel
                ) {
                    example = rendered
                } else {
                    example = template
                }
                templates[scaleKey] = example
                let options = ScanSymbolCount.searchOptions
                let matches = await Task.detached(priority: .userInitiated) {
                    TemplateMatcher.matches(of: example, in: raster, options: options).map(ScanSymbolCount.Found.init)
                }.value
                guard !Task.isCancelled else { break }
                let rows = ScanSymbolCount.rows(
                    matches: matches,
                    templateSize: ScanSymbolCount.sizeInPoints(of: example),
                    pageIndex: page.index,
                    pageLabel: label,
                    existing: existing[page.id] ?? [],
                    exemplarCenter: page.id == exemplarPage.id ? exemplarCenter : nil,
                    idBase: nextID
                )
                for (row, match) in zip(rows, matches) { search.scores[row.id] = match.score }
                nextID += max(1, rows.count)
                search.rows.append(contentsOf: rows)
                model.append(
                    page: SymbolCountReviewPage(
                        pageIndex: page.index, pageLabel: label, otherShapeCount: 0,
                        isTruncated: matches.count >= options.maximumMatches
                    ),
                    rows: rows
                )
                if page.id.rawValue == core.document.currentPageID {
                    self.canvasController(for: document)?.setAutomationOverlay(Self.scanOverlay(for: rows))
                }
            }
            model.finishSearch()
        }
    }

    /// The boxed example rendered at another page picture's scale, trimmed as on its own page.
    private func scanTemplate(
        document: ZenitPDFProjectDocument,
        pageIndex: Int,
        box: PDFRectValue,
        pointsPerPixel: Double
    ) async -> GrayRaster? {
        guard pointsPerPixel > 0, let source = document.drawing?.rasterSource,
              let image = try? await source.renderRegion(
                pageIndex: pageIndex,
                region: PDFRect(x: box.minX, y: box.minY, width: box.size.width, height: box.size.height),
                pixelsPerPoint: 1 / pointsPerPixel
              ),
              let raster = GrayRaster(image: image, pageRegion: CGRect(x: box.minX, y: box.minY, width: box.size.width, height: box.size.height))
        else { return nil }
        return ScanSymbolCount.template(from: raster, box: box)
    }

    /// The canvas highlight for one page's scan rows: matches solid, near misses dashed.
    static func scanOverlay(for rows: [SymbolCountReviewRow]) -> CanvasAutomationOverlay {
        var overlay = CanvasAutomationOverlay()
        for row in rows {
            if row.status == .nearMiss { overlay.nearMisses.append(row.bounds) } else { overlay.hits.append(row.bounds) }
        }
        return overlay
    }

    /// Lands the ticked scan matches as one undoable step, each page's markup stamped as read
    /// from the scan (ADR-0031).
    func landScanSymbolCounts(
        designation: String,
        landings: [(pageID: PageID, positions: [PDFPoint], confidence: Double)],
        askedForLibrary: Bool,
        core: AppCoreEnvironment
    ) async {
        guard !landings.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString(
                "No matching symbols found — nothing was counted.",
                comment: "Status note when the matcher confirmed nothing"
            ))
            return
        }
        let now = Date()
        let documentID = await core.session.documentID
        let commands: [DocumentCommand] = landings.map { entry in
            .addMarkup(CaptureStamp.stamped(MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: entry.pageID,
                kind: .measurement,
                tool: .count,
                subject: designation,
                geometry: Self.scheduleCountGeometry(pageID: entry.pageID, positions: entry.positions),
                createdAt: now,
                modifiedAt: now
            ), method: CaptureMethod(kind: .fromScan, confidence: entry.confidence)))
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
        let counted = landings.reduce(0) { $0 + $1.positions.count }
        var note = String(
            format: NSLocalizedString(
                "%1$@: %2$d counted from the scan on %3$d page(s). They were read from the pixels; check them before you rely on them.",
                comment: "Status note after landing scan symbol counts; designation, count, pages"
            ),
            designation, counted, landings.count
        )
        if askedForLibrary {
            note += " " + NSLocalizedString(
                "A symbol boxed on a scan is not kept in the symbol library, which holds vector symbols.",
                comment: "Status note suffix when Save to library was ticked on a scan search"
            )
        }
        core.status.setActiveToolNote(note)
    }
}
