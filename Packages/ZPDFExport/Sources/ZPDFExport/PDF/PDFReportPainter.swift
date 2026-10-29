import Foundation
import CoreGraphics
import CoreText

/// The drawing half of ``PDFReportRenderer``.
///
/// It owns the page cursor and every Core Graphics call. Split out because a renderer that both
/// decides the layout and pushes the pixels is a file nobody wants to open twice.
struct Painter {

    /// The legend printed on every table page of a report that mixes the three quantity claims
    /// (ADR-0012 rule 4). The marks are rule 5's own glyphs, so the paper and the ledger say
    /// "derived" and "read" with the same character — and a mark, not a colour, because the
    /// house rule against colour-only status holds on paper twice over.
    static let provenanceLegend =
        "Provenance: unmarked = measured \u{00B7} \u{0192} = derived \u{00B7} \u{2310} = read"

    let context: CGContext
    let mediaBox: CGRect
    let options: PDFReportOptions
    let body: CTFont
    let bold: CTFont
    let title: CTFont
    let subtitle: CTFont

    private(set) var pageCount = 0
    private(set) var drawnText: [String] = []
    /// Every total-line label drawn, in order — recorded beside ``drawnText`` rather than in
    /// it, so the cell trace stays one entry per cell (CR-61).
    private(set) var drawnLabels: [String] = []
    /// The provenance glyphs and legends drawn, beside ``drawnText`` for the same reason
    /// (BH-528).
    private(set) var drawnMarks: [String] = []
    /// The furthest any drawn text reached past the right margin, in points (BH-138, BH-529).
    private(set) var rightMarginOverrun: Double = 0
    private(set) var drewLogo = false
    private(set) var drawnCompanyLines: [String] = []
    private(set) var drawnMatrixText: [String] = []
    private(set) var matrixPageCount = 0
    private var cursorY: Double = 0
    private var pageIsOpen = false
    /// Drawn in the footer of every table page, so a reader who finds a loose sheet knows what
    /// it belongs to.
    private var runningHeader = ""
    /// Columns whose rows are not all shown in the column's unit (``ExportTable/mixedUnitColumns()``):
    /// their heading names no unit and every number in them names its own (T-042).
    var mixedUnitColumns: Set<Int> = []

    init(
        context: CGContext,
        mediaBox: CGRect,
        options: PDFReportOptions,
        body: CTFont,
        bold: CTFont,
        title: CTFont,
        subtitle: CTFont
    ) {
        self.context = context
        self.mediaBox = mediaBox
        self.options = options
        self.body = body
        self.bold = bold
        self.title = title
        self.subtitle = subtitle
    }

    // MARK: - Geometry

    private var contentTop: Double { mediaBox.height - options.margins.top }
    private var contentBottom: Double { options.margins.bottom + options.rowHeight + 6 }
    private var contentLeft: Double { options.margins.left }
    private var contentWidth: Double {
        mediaBox.width - options.margins.left - options.margins.right
    }

    // MARK: - Pages

    private mutating func beginPage() {
        context.beginPDFPage(nil)
        pageIsOpen = true
        pageCount += 1
        cursorY = contentTop
    }

    private mutating func endPage() {
        guard pageIsOpen else { return }
        drawFooter()
        context.endPDFPage()
        pageIsOpen = false
    }

    mutating func finish() {
        endPage()
    }

    /// Where the footer's three pieces go: the running header from the left edge, the note
    /// after it, and the page number right-aligned to the margin.
    ///
    /// The note ends a gap short of where the page number starts. It used to run to 0.98 of the
    /// content width while `Page 12` starts near 0.95, so a note long enough to be truncated
    /// drew its last characters over the page number on every page (BH-527).
    struct FooterLayout: Hashable {
        let runningHeaderMaxWidth: Double
        let noteX: Double
        let noteMaxWidth: Double
        let pageNumberX: Double
    }

    static func footerLayout(
        contentLeft: Double,
        contentWidth: Double,
        pageNumberWidth: Double,
        gap: Double = 8
    ) -> FooterLayout {
        let pageNumberX = contentLeft + contentWidth - pageNumberWidth
        let noteX = contentLeft + contentWidth * 0.62
        return FooterLayout(
            runningHeaderMaxWidth: contentWidth * 0.6,
            noteX: noteX,
            noteMaxWidth: max(0, pageNumberX - gap - noteX),
            pageNumberX: pageNumberX
        )
    }

    private mutating func drawFooter() {
        let baseline = options.margins.bottom * 0.5
        let number = "Page \(pageCount)"
        let layout = Self.footerLayout(
            contentLeft: contentLeft,
            contentWidth: contentWidth,
            pageNumberWidth: TextMeasure.width(number, font: body)
        )
        draw(number, at: layout.pageNumberX, baseline: baseline, font: body, gray: 0.45)
        if !runningHeader.isEmpty {
            draw(runningHeader, at: contentLeft, baseline: baseline, font: body,
                 maxWidth: layout.runningHeaderMaxWidth, gray: 0.45)
        }
        if let note = options.footerNote, layout.noteMaxWidth > 0 {
            draw(note, at: layout.noteX, baseline: baseline, font: body,
                 maxWidth: layout.noteMaxWidth, gray: 0.45)
        }
    }

    // MARK: - Text

    @discardableResult
    private mutating func draw(
        _ text: String,
        at x: Double,
        baseline: Double,
        font: CTFont,
        maxWidth: Double = .greatestFiniteMagnitude,
        gray: Double = 0,
        rightAligned: Bool = false
    ) -> Double {
        guard !text.isEmpty else { return 0 }
        // Core Text attribute keys, not AppKit's. This package draws with Core Graphics and
        // must not pull AppKit into the core layer.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: gray, alpha: 1)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        var width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > maxWidth, maxWidth.isFinite {
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: attributes)
            )
            if let truncated = CTLineCreateTruncatedLine(line, maxWidth, .end, token) {
                line = truncated
                width = CTLineGetTypographicBounds(line, nil, nil, nil)
            }
        }
        let origin = rightAligned ? x - width : x
        context.textPosition = CGPoint(x: origin, y: baseline)
        CTLineDraw(line, context)
        // Half a point of tolerance for the typographic bounds of a line Core Text truncated
        // exactly to its limit.
        let overrun = origin + width - (contentLeft + contentWidth)
        if overrun > 0.5 { rightMarginOverrun = max(rightMarginOverrun, overrun) }
        return width
    }

    private func rule(y: Double, gray: Double = 0.8, width lineWidth: Double = 0.5) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: gray, alpha: 1))
        context.setLineWidth(lineWidth)
        context.move(to: CGPoint(x: contentLeft, y: y))
        context.addLine(to: CGPoint(x: contentLeft + contentWidth, y: y))
        context.strokePath()
        context.restoreGState()
    }

    private func fill(rect: CGRect, gray: Double) {
        context.saveGState()
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(rect)
        context.restoreGState()
    }

    // MARK: - Cover

    /// The cover's label/value lines, in order.
    ///
    /// The cover carries every fact needed to reproduce the numbers below it: a takeoff sheet
    /// without its scale and its filter is a page of numbers nobody can check. A pure function of
    /// the metadata, separate from the drawing, so a test can assert what the title page says
    /// without decoding a compressed content stream.
    static func coverEntries(_ metadata: ExportMetadata) -> [(label: String, value: String)] {
        var entries: [(label: String, value: String)] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            entries.append((label, value))
        }
        add("Document", metadata.document.documentName)
        add("Revision", metadata.document.revision)
        // The date a person reads, the same one the ledger's CSV writes — not the timestamp the
        // machine formats carry (LT-19). `ExportDate.humanText` says why.
        add("Date", metadata.generatedAt.humanText)
        add("Scale", metadata.document.scaleDescription)
        // K-04: a takeoff holding values kept under an older scale says so on its cover.
        add("Scale notice", metadata.staleScaleNotice)
        add("Units", metadata.document.unitsDescription)
        add("Prepared by", metadata.document.preparedBy)
        // L-46: the cover is read by a person. Columns are named as the ledger titles them, and
        // the number locale and the contract and grammar versions — provenance a reader has no
        // use for — are in the document information instead (`provenanceKeywords`).
        add("Grouping", metadata.groupingColumnTitles.isEmpty
            ? "(none)" : metadata.groupingColumnTitles.joined(separator: " > "))
        add("Sort", metadata.printedSortDescription.isEmpty
            ? "(none)" : metadata.printedSortDescription.joined(separator: "; "))
        add("Filter", metadata.printedFilterDescription)
        add("Not applied", metadata.unappliedFilterRules.joined(separator: "; "))
        add("Rows", "\(metadata.rowCount) of \(metadata.totalRowCountBeforeFilter)")
        add("Notes", metadata.document.notes)
        return entries
    }

    /// `text` broken into lines no wider than `maxWidth` where Core Text would break it (between
    /// words; inside a word only when the word alone is wider), a new line at every line break
    /// the text holds. Empty paragraphs are dropped.
    static func wrapped(_ text: String, font: CTFont, maxWidth: Double) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        var lines: [String] = []
        for paragraph in text.components(separatedBy: .newlines) where !paragraph.isEmpty {
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let characters = paragraph as NSString
            var start = 0
            while start < attributed.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, maxWidth))
                let line = characters.substring(with: NSRange(location: start, length: min(count, attributed.length - start)))
                lines.append(line.trimmingCharacters(in: .whitespaces))
                start += count
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    mutating func drawCover(_ table: ExportTable) {
        beginPage()
        let metadata = table.metadata
        let heading = metadata.title.isEmpty ? "Quantity Ledger" : metadata.title

        // NL-QTY-11: the logo sits top right; the heading then stops short of it.
        var headingWidth = contentWidth
        if let data = options.logoImageData, let image = Self.decodeImage(data) {
            let box = PDFReportOptions.logoBox
            let scale = min(box.width / Double(max(1, image.width)), box.height / Double(max(1, image.height)), 1)
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            let rect = CGRect(
                x: contentLeft + contentWidth - size.width, y: contentTop - size.height,
                width: size.width, height: size.height
            )
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.restoreGState()
            drewLogo = true
            headingWidth = max(contentWidth * 0.4, contentWidth - size.width - 12)
        }
        cursorY -= options.titleFontSize
        // Ellipsised to the content width like every other cover line. The app titles the
        // report `<document name> — Quantity Ledger`, and a long drawing name ran the heading
        // off the page, "Quantity Ledger" tail and all (BH-138).
        draw(heading, at: contentLeft, baseline: cursorY, font: title, maxWidth: headingWidth)
        if drewLogo { cursorY = min(cursorY, contentTop - PDFReportOptions.logoBox.height) }
        cursorY -= 10
        rule(y: cursorY)
        cursorY -= options.bodyFontSize * 2.4

        if let project = metadata.document.projectName {
            draw(project, at: contentLeft, baseline: cursorY, font: subtitle)
            cursorY -= options.bodyFontSize * 2.2
        }
        let companyLines = (options.companyBlock ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !companyLines.isEmpty {
            for line in companyLines {
                draw(line, at: contentLeft, baseline: cursorY, font: body, maxWidth: contentWidth, gray: 0.25)
                cursorY -= options.rowHeight
            }
            drawnCompanyLines = companyLines
            cursorY -= options.rowHeight
        }

        let entries = Self.coverEntries(metadata)
        let labelWidth = 108.0
        for (label, value) in entries {
            if cursorY < contentBottom { endPage(); beginPage() }
            draw(label, at: contentLeft, baseline: cursorY, font: bold, maxWidth: labelWidth - 8)
            // Wrapped, not ellipsised: the K-04 scale notice is about 205 characters and only
            // about 95 fit beside the label on A4, so the cover cut off "they were not
            // recalculated" and the remedy, which every other format carries whole (S-070).
            for (number, line) in Self.wrapped(value, font: body, maxWidth: contentWidth - labelWidth).enumerated() {
                if number > 0 {
                    cursorY -= options.rowHeight
                    if cursorY < contentBottom { endPage(); beginPage() }
                }
                draw(line, at: contentLeft + labelWidth, baseline: cursorY, font: body,
                     maxWidth: contentWidth - labelWidth)
            }
            cursorY -= options.rowHeight + 3
        }

        // A formula column's declared aggregation semantics belong on the cover: two reports with
        // the same columns and different semantics are different reports (QUALITY_BAR A24).
        let formulaColumns = table.columns.filter { $0.aggregationSemantics != nil }
        if !formulaColumns.isEmpty {
            cursorY -= options.rowHeight
            draw("Formula columns", at: contentLeft, baseline: cursorY, font: bold)
            cursorY -= options.rowHeight + 3
            for column in formulaColumns {
                if cursorY < contentBottom { endPage(); beginPage() }
                draw(column.title, at: contentLeft, baseline: cursorY, font: body,
                     maxWidth: labelWidth - 8)
                let detail = "\(column.formulaCanonicalText ?? "")  [\(column.aggregationSemantics ?? "")]"
                draw(detail, at: contentLeft + labelWidth, baseline: cursorY, font: body,
                     maxWidth: contentWidth - labelWidth)
                cursorY -= options.rowHeight + 3
            }
        }
        endPage()
    }

    // MARK: - Table

    mutating func drawTableBand(
        _ band: PDFReportRenderer.Band,
        bandIndex: Int,
        bandCount: Int,
        widths: [Double],
        table: ExportTable,
        printedColumnCount: Int,
        lines: [PDFReportRenderer.Line]
    ) {
        guard !band.columns.isEmpty else { return }
        let usable = contentWidth
        let clamped = widths.map { min($0, usable) }
        var origins: [Double] = []
        var x = contentLeft
        for index in band.columns {
            origins.append(x)
            x += clamped[index]
        }
        // Counted over the columns the report prints, not over the ledger's whole column set:
        // the reader is being told where they are in this document (LT-18).
        let bandCaption = bandCount == 1
            ? nil
            : "Columns \(band.firstPrintedOrdinal)-\(band.lastPrintedOrdinal) of "
                + "\(printedColumnCount) (band \(bandIndex + 1) of \(bandCount))"
        runningHeader = table.metadata.title + (bandCaption.map { " — \($0)" } ?? "")
        // On every page of every band, not once: a loose sheet must explain its own marks.
        let legend = table.carriesProvenanceLabels ? Self.provenanceLegend : nil

        beginPage()
        drawColumnHeader(
            band: band, origins: origins, widths: clamped, table: table,
            caption: bandCaption, legend: legend
        )

        for line in lines {
            if cursorY < contentBottom {
                endPage()
                beginPage()
                drawColumnHeader(
                    band: band, origins: origins, widths: clamped, table: table,
                    caption: bandCaption, legend: legend
                )
            }
            switch line {
            case .groupHeading(let label, let depth, let rowCount):
                let indent = Double(depth) * 10
                fill(
                    rect: CGRect(
                        x: contentLeft, y: cursorY - 3.5,
                        width: contentWidth, height: options.rowHeight
                    ),
                    gray: 0.93
                )
                draw("\(label)  (\(rowCount))", at: contentLeft + 3 + indent,
                     baseline: cursorY, font: bold, maxWidth: contentWidth - 6 - indent)
                cursorY -= options.rowHeight
            case .row(let row):
                // The per-row mark of ADR-0012 rule 4, in the left margin so no column moves.
                // A measured row has no glyph; the legend on the page says exactly that.
                if legend != nil, let glyph = row.provenanceGlyph {
                    if options.recordsDrawnText { drawnMarks.append(glyph) }
                    draw(glyph, at: contentLeft - 3, baseline: cursorY, font: body,
                         gray: 0.25, rightAligned: true)
                }
                drawCells(
                    row.cells, band: band, origins: origins, widths: clamped,
                    table: table, font: body, record: true
                )
            case .subtotal(let label, _, let function, let cells):
                rule(y: cursorY + options.bodyFontSize + 1, gray: 0.6)
                drawCells(
                    cells, band: band, origins: origins, widths: clamped,
                    table: table, font: bold, record: true,
                    leadingLabel: band.columns.first == band.identityColumn
                        ? PDFReportRenderer.subtotalLabel(function: function, groupLabel: label)
                        : nil
                )
            case .grandTotal(let function, let cells):
                rule(y: cursorY + options.bodyFontSize + 1, gray: 0.2, width: 0.9)
                drawCells(
                    cells, band: band, origins: origins, widths: clamped,
                    table: table, font: bold, record: true,
                    leadingLabel: band.columns.first == band.identityColumn
                        ? PDFReportRenderer.grandTotalLabel(function: function)
                        : nil
                )
            }
        }
        endPage()
        runningHeader = ""
    }

    private mutating func drawColumnHeader(
        band: PDFReportRenderer.Band,
        origins: [Double],
        widths: [Double],
        table: ExportTable,
        caption: String?,
        legend: String? = nil
    ) {
        if let caption {
            draw(caption, at: contentLeft, baseline: cursorY, font: bold,
                 maxWidth: contentWidth, gray: 0.35)
            cursorY -= options.rowHeight + 2
        }
        if let legend {
            if options.recordsDrawnText { drawnMarks.append(legend) }
            draw(legend, at: contentLeft, baseline: cursorY, font: body,
                 maxWidth: contentWidth, gray: 0.35)
            cursorY -= options.rowHeight + 2
        }
        fill(
            rect: CGRect(
                x: contentLeft, y: cursorY - 3.5, width: contentWidth, height: options.rowHeight + 1
            ),
            gray: 0.12
        )
        for (slot, columnIndex) in band.columns.enumerated() {
            let column = table.columns[columnIndex]
            // A column whose rows do not share one unit names none: "Plan Length (ft)" used to
            // head a row printed in metres (T-042).
            let text = column.heading(sharesUnit: !mixedUnitColumns.contains(columnIndex))
            let width = widths[columnIndex] - options.columnPadding * 2
            if column.isNumeric {
                draw(text, at: origins[slot] + widths[columnIndex] - options.columnPadding,
                     baseline: cursorY, font: bold, maxWidth: width, gray: 1, rightAligned: true)
            } else {
                draw(text, at: origins[slot] + options.columnPadding, baseline: cursorY,
                     font: bold, maxWidth: width, gray: 1)
            }
        }
        cursorY -= options.rowHeight + 2
    }

    private mutating func drawCells(
        _ cells: [ExportCell],
        band: PDFReportRenderer.Band,
        origins: [Double],
        widths: [Double],
        table: ExportTable,
        font: CTFont,
        record: Bool,
        leadingLabel: String? = nil
    ) {
        for (slot, columnIndex) in band.columns.enumerated() {
            let column = table.columns[columnIndex]
            let cell = columnIndex < cells.count ? cells[columnIndex] : ExportCell.blank
            // `printedText` is `cell.text` for everything but a date, which the report humanises
            // (LT-19), and a number in a column of mixed units, which names its unit (T-042).
            // The recorded trace is what was drawn, or it would not be a trace.
            let cellText = cell.printedText(inMixedUnitColumn: mixedUnitColumns.contains(columnIndex))
            var text = cellText
            if slot == 0, let leadingLabel {
                // CR-61: the label names the line and is always drawn; the identity cell's own
                // aggregate, when the column has one, follows it.
                text = PDFReportRenderer.totalCellText(label: leadingLabel, cellText: text)
                if options.recordsDrawnText, record { drawnLabels.append(leadingLabel) }
            }
            if options.recordsDrawnText, record { drawnText.append(cellText) }
            guard !text.isEmpty else { continue }
            let width = widths[columnIndex] - options.columnPadding * 2
            // Numbers right-aligned; the decimal points line up and a reader can scan a column
            // for an order-of-magnitude mistake without reading a single digit.
            if column.isNumeric, !cell.isRefusal {
                draw(text, at: origins[slot] + widths[columnIndex] - options.columnPadding,
                     baseline: cursorY, font: font, maxWidth: width, rightAligned: true)
            } else {
                draw(text, at: origins[slot] + options.columnPadding, baseline: cursorY,
                     font: font, maxWidth: width, gray: cell.isRefusal ? 0.35 : 0)
            }
        }
        cursorY -= options.rowHeight
    }

    // MARK: - Audit appendix (ADR-0007 §3)

    /// Draws the audit trail as a paginated text table after the report body.
    ///
    /// One band only: the columns are scaled to fit the page width and a cell that still
    /// does not fit is end-truncated with an ellipsis — an audit row is a sentence, not
    /// a quantity, and splitting it across bands would read worse than trimming it.
    mutating func drawAuditAppendix(_ appendix: PDFReportAuditAppendix) {
        guard !appendix.columnTitles.isEmpty else { return }
        runningHeader = appendix.title

        // Natural widths from the widest cell, then scaled to the page.
        var widths = appendix.columnTitles.map {
            TextMeasure.width($0, font: bold) + options.columnPadding * 2
        }
        for row in appendix.rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = min(
                    max(widths[index], TextMeasure.width(cell, font: body) + options.columnPadding * 2),
                    options.maximumColumnWidth
                )
            }
        }
        widths = Self.fitAuditWidths(
            widths, into: contentWidth, minimum: options.minimumColumnWidth
        )
        var origins: [Double] = []
        var x = contentLeft
        for width in widths {
            origins.append(x)
            x += width
        }

        func drawHeader(withTitle: Bool) {
            if withTitle {
                cursorY -= options.bodyFontSize + 6
                draw(appendix.title, at: contentLeft, baseline: cursorY, font: subtitle,
                     maxWidth: contentWidth)
                cursorY -= options.rowHeight + 4
                if let caption = appendix.caption {
                    draw(caption, at: contentLeft, baseline: cursorY, font: body,
                         maxWidth: contentWidth, gray: 0.4)
                    cursorY -= options.rowHeight + 4
                }
            }
            fill(
                rect: CGRect(
                    x: contentLeft, y: cursorY - 3.5, width: contentWidth,
                    height: options.rowHeight + 1
                ),
                gray: 0.12
            )
            for (index, columnTitle) in appendix.columnTitles.enumerated() {
                draw(columnTitle, at: origins[index] + options.columnPadding, baseline: cursorY,
                     font: bold, maxWidth: widths[index] - options.columnPadding * 2, gray: 1)
            }
            cursorY -= options.rowHeight + 2
        }

        beginPage()
        drawHeader(withTitle: true)
        for row in appendix.rows {
            if cursorY < contentBottom {
                endPage()
                beginPage()
                drawHeader(withTitle: false)
            }
            for index in appendix.columnTitles.indices {
                let text = index < row.count ? row[index] : ""
                if options.recordsDrawnText { drawnText.append(text) }
                guard !text.isEmpty else { continue }
                draw(text, at: origins[index] + options.columnPadding, baseline: cursorY,
                     font: body, maxWidth: widths[index] - options.columnPadding * 2)
            }
            cursorY -= options.rowHeight
        }
        endPage()
        runningHeader = ""
    }

    /// Column widths that fit `available`, with no column below `minimum` when that is possible.
    ///
    /// Scaling to the page and then raising the narrow columns back to the minimum made the sum
    /// wider than the page: with the app's eight audit columns the Note column started 13-25 pt
    /// past the right margin, outside the header band (BH-529, BH-530). Here the columns held at
    /// the minimum are taken out first and only the remaining width is shared, in proportion,
    /// among the rest. When even the minimums do not fit, every column is scaled alike.
    static func fitAuditWidths(_ natural: [Double], into available: Double, minimum: Double) -> [Double] {
        let total = natural.reduce(0, +)
        guard total > available, total > 0, available > 0 else { return natural }
        guard minimum * Double(natural.count) < available else {
            return natural.map { _ in available / Double(natural.count) }
        }
        var pinned = Set<Int>()
        while true {
            let free = natural.indices.filter { !pinned.contains($0) }
            let budget = available - minimum * Double(pinned.count)
            let freeNatural = free.reduce(0.0) { $0 + natural[$1] }
            guard freeNatural > 0 else {
                return natural.indices.map { pinned.contains($0) ? minimum : 0 }
            }
            let factor = budget / freeNatural
            let tooNarrow = free.filter { natural[$0] * factor < minimum }
            if tooNarrow.isEmpty {
                return natural.indices.map { pinned.contains($0) ? minimum : natural[$0] * factor }
            }
            pinned.formUnion(tooNarrow)
        }
    }

    // MARK: - Appendix

    /// PNG or JPEG bytes as an image, through ImageIO's CoreGraphics providers (no AppKit).
    static func decodeImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return nil
    }

    // MARK: - Summary matrix (NL-QTY-09)

    /// The matrix's column bands: as many across-columns per page width as fit at the minimum
    /// column width, the row title and the Total column repeated on every band.
    static func matrixBands(columnCount: Int, usable: Double, titleWidth: Double, minimumWidth: Double) -> [Range<Int>] {
        guard columnCount > 0 else { return [0..<0] }
        let room = usable - titleWidth - minimumWidth // the Total column
        let perBand = max(1, Int(room / minimumWidth))
        return stride(from: 0, to: columnCount, by: perBand).map { $0..<min($0 + perBand, columnCount) }
    }

    /// One block per quantity column: heading, header row, a line per row group, Total line.
    /// Every string is the projection's own cell text.
    mutating func drawSummaryMatrix(_ matrix: ExportSummaryMatrix) {
        runningHeader = "Summary"
        let firstPage = pageCount + 1
        let titleWidth = min(
            contentWidth * 0.35,
            max(90, (matrix.printedRowTitles + [matrix.rowAxisTitle, ExportSummaryMatrix.totalTitle])
                .map { TextMeasure.width($0, font: bold) }.max() ?? 90) + options.columnPadding * 2
        )
        let minimum = max(options.minimumColumnWidth, 56)
        let bands = Self.matrixBands(
            columnCount: matrix.columnTitles.count, usable: contentWidth, titleWidth: titleWidth, minimumWidth: minimum
        )
        func record(_ text: String) { if options.recordsDrawnText { drawnMatrixText.append(text) } }
        for block in matrix.blocks {
            for band in bands {
                let slots = band.count + 1
                let width = min(options.maximumColumnWidth, (contentWidth - titleWidth) / Double(slots))
                func x(_ slot: Int) -> Double { contentLeft + titleWidth + Double(slot + 1) * width - options.columnPadding }
                func header() {
                    if !pageIsOpen || cursorY < contentBottom + options.rowHeight * 4 {
                        endPage(); beginPage()
                    }
                    cursorY -= options.bodyFontSize + 6
                    let caption = bands.count > 1
                        ? "\(block.heading) — \(matrix.rowAxisTitle) × \(matrix.columnAxisTitle) (columns \(band.lowerBound + 1)-\(band.upperBound) of \(matrix.columnTitles.count))"
                        : "\(block.heading) — \(matrix.rowAxisTitle) × \(matrix.columnAxisTitle)"
                    draw(caption, at: contentLeft, baseline: cursorY, font: subtitle, maxWidth: contentWidth)
                    record(caption)
                    cursorY -= options.rowHeight + 4
                    fill(rect: CGRect(x: contentLeft, y: cursorY - 3, width: contentWidth, height: options.rowHeight), gray: 0.92)
                    draw(matrix.rowAxisTitle, at: contentLeft + options.columnPadding, baseline: cursorY, font: bold,
                         maxWidth: titleWidth - options.columnPadding * 2)
                    record(matrix.rowAxisTitle)
                    for (slot, column) in band.enumerated() {
                        let text = matrix.printedColumnTitles[column]
                        draw(text, at: x(slot), baseline: cursorY, font: bold, maxWidth: width - options.columnPadding * 2, rightAligned: true)
                        record(text)
                    }
                    draw(ExportSummaryMatrix.totalTitle, at: x(band.count), baseline: cursorY, font: bold, rightAligned: true)
                    record(ExportSummaryMatrix.totalTitle)
                    cursorY -= options.rowHeight
                }
                header()
                func line(_ title: String, _ cells: [ExportCell], _ total: ExportCell, font: CTFont) {
                    if cursorY < contentBottom { header() }
                    draw(title, at: contentLeft + options.columnPadding, baseline: cursorY, font: font,
                         maxWidth: titleWidth - options.columnPadding * 2)
                    record(title)
                    for (slot, column) in band.enumerated() {
                        let text = cells[column].printedText
                        draw(text, at: x(slot), baseline: cursorY, font: font, maxWidth: width - options.columnPadding * 2, rightAligned: true)
                        record(text)
                    }
                    draw(total.printedText, at: x(band.count), baseline: cursorY, font: bold,
                         maxWidth: width - options.columnPadding * 2, rightAligned: true)
                    record(total.printedText)
                    cursorY -= options.rowHeight
                }
                for (index, title) in matrix.printedRowTitles.enumerated() {
                    line(title, block.cells[index], block.rowTotals[index], font: body)
                }
                rule(y: cursorY + options.rowHeight - 3)
                line(ExportSummaryMatrix.totalTitle, block.columnTotals, block.grandTotal, font: bold)
                cursorY -= options.rowHeight
            }
        }
        endPage()
        matrixPageCount = pageCount - firstPage + 1
        runningHeader = ""
    }

    mutating func drawAppendixPage(_ page: PDFReportAppendixPage) {
        runningHeader = "Appendix"
        beginPage()
        cursorY -= options.bodyFontSize + 6
        draw(page.title, at: contentLeft, baseline: cursorY, font: subtitle, maxWidth: contentWidth)
        cursorY -= options.rowHeight + 4
        if let caption = page.caption {
            draw(caption, at: contentLeft, baseline: cursorY, font: body,
                 maxWidth: contentWidth, gray: 0.4)
            cursorY -= options.rowHeight + 4
        }
        let available = CGRect(
            x: contentLeft,
            y: contentBottom,
            width: contentWidth,
            height: cursorY - contentBottom
        )
        let imageAspect = Double(page.image.width) / Double(max(1, page.image.height))
        var width = available.width
        var height = width / imageAspect
        if height > available.height {
            height = available.height
            width = height * imageAspect
        }
        let rect = CGRect(
            x: available.minX + (available.width - width) / 2,
            y: available.maxY - height,
            width: width,
            height: height
        )
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(page.image, in: rect)
        context.restoreGState()
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(rect)
        context.restoreGState()
        endPage()
        runningHeader = ""
    }
}
