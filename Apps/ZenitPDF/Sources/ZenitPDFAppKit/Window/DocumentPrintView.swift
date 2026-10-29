import AppKit
import CoreGraphics
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFRenderer

/// The printed representation of a drawing: the sheet, and **the markups on it**.
///
/// # What this used to be
///
/// One `CGImage` per page and nothing else. `printDocument(_:)` rasterised
/// `drawing.rasterSource.render(pageIndex:…)` at 2x and handed the images here, so an estimator
/// who measured a drawing and pressed ⌘P received the drawing back with every dimension, pill and
/// count symbol missing — silently, with no error anywhere, on the one artefact that leaves the
/// building. It was the largest functional gap in the build.
///
/// # What it is now
///
/// The fourth consumer of the flatten path. Each sheet is painted by
/// `ZPDFExport.FlattenedPDFWriter.paintSheet(page:shape:content:into:rect:)` — the identical
/// sequence the flattened PDF export writes — so the paper and the exported file cannot show
/// different pictures, and neither can drift from the canvas, because the markups are painted by
/// the renderer that draws the canvas.
///
/// # Vector, not pixels
///
/// `NSPrintOperation` hands the view a PDF context. The page underneath is replayed from the
/// original's own content stream by ``ZPDFExport/CGPDFPageContentSource``, and the markups leave
/// as path operators, so a 1:100 sheet prints at the plotter's resolution rather than at whatever
/// scale a rasteriser happened to be asked for. A page the source will not open falls back to a
/// supplied raster, which is a visibly coarser sheet and never a blank one.
///
/// That sentence was **three quarters true** until a review read a printed sheet's
/// decompressed content stream and counted 46 image XObjects in it: the strokes and fills were
/// paths, and every glyph and count symbol was a 4 × 5-to-19 × 21-pixel soft-masked bitmap, because
/// the flatten path compiles at `zoom: 1, backingScale: 1` and so one atlas pixel became one PDF
/// point. Text now leaves as outlines and a count marker as its own geometry — see
/// `ZPDFExport.MarkupFlattener`'s "Text is text" note — and
/// `FlattenedVectorTextTests.flattenedSheetContainsNoImageXObject` fails if either comes back.
///
/// # One sheet per page, at the page's own size
///
/// A construction set mixes ARCH-D details into an ARCH-E set, and scaling them all to one paper
/// size would print the wrong scale — which, in this application, means printing a wrong
/// dimension.
/// # Scale, stated; oversize, tiled (NL-PDF-06, NL-PDF-07)
///
/// The print panel's accessory (``PrintOptionsAccessory``) sets ``options``; the pages are laid
/// out by ``DocumentPrintLayout``. Each sheet says in its corner what scale it printed at —
/// "Printed scale 1:200 (drawn 1:100 at 50 %)" when the factor carries the calibrated ratio onto
/// another exact one, "not to scale" when it does not — and a sheet that does not fit the paper
/// at a fixed factor is tiled with an overlap, crop marks and a tile label instead of shrinking.
@MainActor
final class DocumentPrintView: NSView {

    /// One printable sheet: what to draw, and how big it is on paper.
    struct Sheet {
        /// The page and its markups, already filtered by ``ZPDFExport/PDFFlattenPolicy``.
        let flatten: FlattenPage
        /// The calibrated drawing scale's denominator (100 for 1:100), or `nil`.
        var drawnRatio: Double? = nil
        /// The sheet's size on paper, in points — the page's `/Rotate`-applied crop box times
        /// its `/UserUnit`, so a large-format sheet prints at its real size (BH-509).
        var size: CGSize { flatten.paperSize }

        init(flatten: FlattenPage) {
            self.flatten = flatten
        }

        init(flatten: FlattenPage, drawnRatio: Double?) {
            self.flatten = flatten
            self.drawnRatio = drawnRatio
        }
    }

    private let sheets: [Sheet]
    private let content: (any FlattenPageContentDrawing)?
    /// The printable area of the paper the operation settled on. Read when AppKit asks for
    /// the page range — after the print panel — so a paper chosen there is the one laid out.
    private var slotSize: CGSize
    /// The print panel's choices. Setting them lays the pages out again.
    var options = DocumentPrintLayout.Options() {
        didSet { relayout() }
    }
    private(set) var layout: DocumentPrintLayout

    // NL-PDF-06, round 2: what the print panel narrows and adds (`Workflows/PrintExtras.swift`).

    /// Which markups print — the same predicate as the Marked export's scope sheet.
    var scope: DrawingOutputScope = .everything {
        didSet { needsDisplay = true }
    }
    /// Subject and status per markup, for ``scope``.
    var facts: [UUID: DrawingOutputScope.Facts] = [:]
    /// The takeoff's markups, for the print panel's scope controls.
    var scopeRecords: [MarkupRecord] = []
    /// The project's markup layers, for the scope controls' layer boxes (ADR-0032).
    var scopeLayers: [MarkupLayer] = []
    /// The sheet on screen when printing started, for "This sheet only".
    var currentPageID: UUID?
    /// The header's first part: the takeoff's name.
    var headerTitle: String?
    /// The date the header states.
    var headerDate = Date()
    /// Whether the scale bar is in feet.
    var imperialScaleBar = Locale.current.measurementSystem == .us
    /// The ledger summary, printed after the sheets when ``DocumentPrintLayout/Options/includeSummary``.
    var summary: CGPDFDocument? {
        didSet { relayout() }
    }

    /// Summary pages that print after the sheets.
    var summaryPageCount: Int {
        guard options.includeSummary, let summary else { return 0 }
        return min(summary.numberOfPages, 500)
    }

    /// Every printed page: the sheets' pages, then the summary's.
    var totalPageCount: Int { layout.pages.count + summaryPageCount }

    init(sheets: [Sheet], content: (any FlattenPageContentDrawing)?, slotSize: CGSize? = nil) {
        self.sheets = sheets
        self.content = content
        let largest = Self.largestSheet(sheets)
        let slot = slotSize ?? largest
        self.slotSize = slot
        self.layout = DocumentPrintLayout(sheets: Self.layoutSheets(sheets), slot: slot, options: DocumentPrintLayout.Options())
        super.init(frame: Self.frame(pageCount: layout.pages.count, slot: slot))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// The largest sheet, which the default paper is sized to.
    static func largestSheet(_ sheets: [Sheet]) -> CGSize {
        CGSize(
            width: sheets.map(\.size.width).max() ?? 612,
            height: sheets.map(\.size.height).max() ?? 792
        )
    }

    private static func layoutSheets(_ sheets: [Sheet]) -> [DocumentPrintLayout.Sheet] {
        sheets.map { DocumentPrintLayout.Sheet(size: $0.size, drawnRatio: $0.drawnRatio) }
    }

    private static func frame(pageCount: Int, slot: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: max(slot.width, 1), height: max(slot.height * CGFloat(max(1, pageCount)), 1))
    }

    private func relayout() {
        layout = DocumentPrintLayout(sheets: Self.layoutSheets(sheets), slot: slotSize, options: options)
        setFrameSize(Self.frame(pageCount: totalPageCount, slot: slotSize).size)
        needsDisplay = true
    }

    /// A print info whose paper is the largest sheet, with no margins and the matching
    /// orientation, so every sheet prints at its own size on the paper the drawing needs.
    static func printInfo(for sheets: [Sheet], base: NSPrintInfo) -> NSPrintInfo {
        let info = (base.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let largest = largestSheet(sheets)
        info.paperSize = largest
        info.orientation = largest.width > largest.height ? .landscape : .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.scalingFactor = 1
        return info
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo {
            let bounds = info.imageablePageBounds.size
            let paper = info.paperSize
            let usable = CGSize(
                width: max(1, min(paper.width - info.leftMargin - info.rightMargin, bounds.width > 0 ? bounds.width : paper.width)),
                height: max(1, min(paper.height - info.topMargin - info.bottomMargin, bounds.height > 0 ? bounds.height : paper.height))
            )
            if usable != slotSize {
                slotSize = usable
                relayout()
            }
        }
        range.pointee = NSRange(location: 1, length: max(1, totalPageCount))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let index = page - 1
        guard index >= 0, index < totalPageCount else { return .zero }
        return NSRect(origin: CGPoint(x: 0, y: CGFloat(index) * slotSize.height), size: slotSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, page) in layout.pages.enumerated() {
            let slot = NSRect(origin: CGPoint(x: 0, y: CGFloat(index) * slotSize.height), size: slotSize)
            guard slot.intersects(dirtyRect), sheets.indices.contains(page.sheetIndex) else { continue }
            let sheet = sheets[page.sheetIndex]
            let scale = CGFloat(page.factor)
            let drawn = CGSize(width: sheet.size.width * scale, height: sheet.size.height * scale)
            // Untiled: centred (a fixed-factor sheet a few per cent over the paper loses the
            // overhang evenly on both sides). Tiled: the tile's region lands on the slot.
            let origin: CGPoint = page.tile == nil
                ? CGPoint(x: slot.minX + (slot.width - drawn.width) / 2, y: slot.minY + (slot.height - drawn.height) / 2)
                : CGPoint(x: slot.minX - page.region.minX, y: slot.minY - page.region.minY)
            let rect = NSRect(origin: origin, size: drawn)

            // Flipped view: undo the flip so the sheet prints the right way up, and so the
            // flatten path is handed the bottom-left-origin space every other consumer gives
            // it. See `CanvasPageView.draw(_:)` for the same correction on screen.
            context.saveGState()
            context.clip(to: slot)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: scale, y: -scale)
            // The print panel's scope narrows the markups, exactly as the Marked export does.
            let flatten = scope.apply(to: [sheet.flatten], facts: facts).first ?? sheet.flatten
            do {
                try FlattenedPDFWriter.paintSheet(
                    page: flatten,
                    shape: options.includeMarkups ? .flattened : .clean,
                    content: content,
                    into: context,
                    rect: CGRect(origin: .zero, size: sheet.size)
                )
            } catch {
                // A sheet whose geometry the flatten path refuses prints as the page without
                // its markups rather than aborting the job. The refusal is typed and rare —
                // a degenerate crop box — and losing forty good sheets to one is worse.
                CanvasLog.printing.error(
                    "sheet \(sheet.flatten.sourcePageIndex, privacy: .public) could not be flattened: \(String(describing: error), privacy: .public)"
                )
            }
            context.restoreGState()

            let visible = rect.intersection(slot)
            var lines: [String] = []
            if let tile = page.tile {
                lines.append(String(
                    format: NSLocalizedString(
                        "Tile %1$@ of %2$@ — sheet %3$d",
                        comment: "Label printed on one tile of a sheet printed across several pages; the tile, the last tile, the sheet number"
                    ),
                    tile.cell, tile.lastCell, sheet.flatten.sourcePageIndex + 1
                ))
                drawCropMarks(tile: tile, in: slot, context: context)
            }
            if let note = DocumentPrintLayout.scaleNote(drawnRatio: sheet.drawnRatio, factor: page.factor) {
                lines.append(note)
            }
            if !lines.isEmpty {
                drawNote(lines.joined(separator: "   "), in: visible.isNull ? slot : visible)
            }
            let area = visible.isNull ? slot : visible
            if options.scaleBar, page.tile == nil || page.tile?.row == (page.tile?.rows ?? 1) - 1 && page.tile?.column == 0,
               let printed = DocumentPrintLayout.printedRatio(drawn: sheet.drawnRatio, factor: page.factor),
               let bar = DocumentPrintLayout.scaleBar(printedRatio: printed, imperial: imperialScaleBar) {
                drawScaleBar(bar, printedRatio: printed, in: area, context: context)
            }
            if options.header {
                drawHeader(for: sheet, in: area)
            }
        }
        drawSummaryPages(in: dirtyRect, context: context)
    }

    /// The ledger summary's pages, each fitted to its slot after the sheets.
    private func drawSummaryPages(in dirtyRect: NSRect, context: CGContext) {
        guard summaryPageCount > 0, let summary else { return }
        for number in 1...summaryPageCount {
            let index = layout.pages.count + number - 1
            let slot = NSRect(origin: CGPoint(x: 0, y: CGFloat(index) * slotSize.height), size: slotSize)
            guard slot.intersects(dirtyRect), let page = summary.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { continue }
            let scale = min(slot.width / box.width, slot.height / box.height, 1)
            let drawn = CGSize(width: box.width * scale, height: box.height * scale)
            context.saveGState()
            context.clip(to: slot)
            // Flipped view: bottom-left origin for the PDF page, centred in the slot.
            context.translateBy(x: slot.minX + (slot.width - drawn.width) / 2, y: slot.minY + (slot.height + drawn.height) / 2)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    /// A scale bar at the bottom-left of the sheet: four alternating segments, "0" and the
    /// length under its ends, and the printed ratio beside it (NL-PDF-06).
    private func drawScaleBar(_ bar: DocumentPrintLayout.ScaleBar, printedRatio: Double, in rect: NSRect, context: CGContext) {
        let length = CGFloat(bar.paperLength)
        guard length > 4, length < rect.width - 24 else { return }
        let height: CGFloat = 4
        let origin = CGPoint(x: rect.minX + 12, y: rect.maxY - 22)
        let segment = length / CGFloat(bar.segments)
        context.saveGState()
        context.setLineWidth(0.5)
        context.setStrokeColor(gray: 0, alpha: 1)
        for index in 0..<bar.segments {
            let cell = CGRect(x: origin.x + CGFloat(index) * segment, y: origin.y, width: segment, height: height)
            context.setFillColor(gray: index.isMultiple(of: 2) ? 0 : 1, alpha: 1)
            context.fill(cell)
            context.stroke(cell)
        }
        context.restoreGState()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        NSGraphicsContext.saveGraphicsState()
        ("0" as NSString).draw(at: CGPoint(x: origin.x - 2, y: origin.y + height + 1), withAttributes: attributes)
        let end = "\(DocumentPrintLayout.ratioText(bar.length)) \(bar.unit)" as NSString
        end.draw(at: CGPoint(x: origin.x + length - end.size(withAttributes: attributes).width / 2, y: origin.y + height + 1), withAttributes: attributes)
        let ratio = String(format: NSLocalizedString("Scale bar 1:%@", comment: "Printed caption beside the scale bar; the ratio denominator"),
                           DocumentPrintLayout.ratioText(printedRatio)) as NSString
        ratio.draw(at: CGPoint(x: origin.x + length + 10, y: origin.y - 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// "Takeoff — Sheet A-101 — 26 Sep 2026" in the sheet's top-right corner.
    private func drawHeader(for sheet: Sheet, in rect: NSRect) {
        let label = sheet.flatten.page.label.isEmpty ? String(sheet.flatten.sourcePageIndex + 1) : sheet.flatten.page.label
        let text = Self.headerText(title: headerTitle, sheetLabel: label, date: headerDate) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let width = text.size(withAttributes: attributes).width
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: CGPoint(x: max(rect.minX + 6, rect.maxX - width - 6), y: rect.minY + 4), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The header line. Pure.
    static func headerText(title: String?, sheetLabel: String, date: Date) -> String {
        let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        let sheet = String(format: NSLocalizedString("Sheet %@", comment: "Print header: the sheet label"), sheetLabel)
        return [title, sheet, day].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// Where the neighbouring tile's overlap begins, as short ticks at the page edges, so the
    /// tiles can be trimmed and taped edge to edge.
    private func drawCropMarks(tile: DocumentPrintLayout.Tile, in slot: NSRect, context: CGContext) {
        let overlap = CGFloat(min(max(0, options.tileOverlap), Double(min(slot.width, slot.height)) / 4))
        let tick: CGFloat = 12
        context.saveGState()
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.5)
        if tile.column < tile.columns - 1 {
            let x = slot.maxX - overlap
            context.strokeLineSegments(between: [
                CGPoint(x: x, y: slot.minY), CGPoint(x: x, y: slot.minY + tick),
                CGPoint(x: x, y: slot.maxY - tick), CGPoint(x: x, y: slot.maxY)
            ])
        }
        if tile.row < tile.rows - 1 {
            let y = slot.maxY - overlap
            context.strokeLineSegments(between: [
                CGPoint(x: slot.minX, y: y), CGPoint(x: slot.minX + tick, y: y),
                CGPoint(x: slot.maxX - tick, y: y), CGPoint(x: slot.maxX, y: y)
            ])
        }
        context.restoreGState()
    }

    /// A sheet's scale statement (and tile label), in its top-left corner.
    private func drawNote(_ text: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        NSGraphicsContext.saveGraphicsState()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
