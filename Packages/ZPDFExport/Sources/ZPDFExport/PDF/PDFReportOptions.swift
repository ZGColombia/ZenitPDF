import Foundation
import CoreGraphics

public struct PDFReportPageSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let a4 = PDFReportPageSize(width: 595.276, height: 841.89)
    public static let usLetter = PDFReportPageSize(width: 612, height: 792)

    public var landscape: PDFReportPageSize {
        PDFReportPageSize(width: max(width, height), height: min(width, height))
    }

    public var portrait: PDFReportPageSize {
        PDFReportPageSize(width: min(width, height), height: max(width, height))
    }
}

public struct PDFReportMargins: Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 42, left: Double = 36, bottom: Double = 42, right: Double = 36) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct PDFReportOptions: Hashable, Sendable {
    public var pageSize: PDFReportPageSize
    public var margins: PDFReportMargins
    public var includeCoverPage: Bool
    public var includeGroupHeadings: Bool
    public var includeGroupSubtotals: Bool
    public var includeGrandTotals: Bool
    public var fontName: String
    public var boldFontName: String
    public var titleFontSize: Double
    public var bodyFontSize: Double
    public var rowHeight: Double
    public var columnPadding: Double
    /// Footer line under the page number. The page number itself is always drawn.
    public var footerNote: String?
    /// Collect every table body string the renderer draws, in draw order. Off by default; the
    /// cross-format digit-for-digit test turns it on, because the only honest way to assert what
    /// a PDF says is to capture what was actually drawn.
    public var recordsDrawnText: Bool
    public var maximumColumnWidth: Double
    public var minimumColumnWidth: Double
    /// Print only the columns that have something in them, plus the identity columns
    /// (live-test finding LT-18). See ``PDFReportRenderer/printedColumns(table:options:)`` for
    /// what "something" means and why the totals count.
    ///
    /// On by default: a report that bands forty columns across six pages so that thirty of them
    /// can be blank is not a wide report, it is a wasted one. Off restores the old behaviour for
    /// a caller who has already narrowed the column set and wants exactly what it asked for.
    public var dropsEmptyColumns: Bool
    /// NL-QTY-11: the company logo, as PNG or JPEG bytes, drawn at the top right of the cover
    /// inside a 140 × 56 pt box with its aspect kept. Bytes rather than an image so the options
    /// stay a `Sendable` value a template can store; unreadable bytes draw nothing.
    public var logoImageData: Data?
    /// NL-QTY-11: the company block — name, address, contact — printed on the cover under the
    /// project name, one line per line of text.
    public var companyBlock: String?

    public init(
        pageSize: PDFReportPageSize = .a4,
        margins: PDFReportMargins = PDFReportMargins(),
        includeCoverPage: Bool = true,
        includeGroupHeadings: Bool = true,
        includeGroupSubtotals: Bool = true,
        includeGrandTotals: Bool = true,
        fontName: String = "Helvetica",
        boldFontName: String = "Helvetica-Bold",
        titleFontSize: Double = 22,
        bodyFontSize: Double = 8,
        rowHeight: Double = 13,
        columnPadding: Double = 6,
        footerNote: String? = nil,
        recordsDrawnText: Bool = false,
        maximumColumnWidth: Double = 160,
        minimumColumnWidth: Double = 28,
        dropsEmptyColumns: Bool = true
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.includeCoverPage = includeCoverPage
        self.includeGroupHeadings = includeGroupHeadings
        self.includeGroupSubtotals = includeGroupSubtotals
        self.includeGrandTotals = includeGrandTotals
        self.fontName = fontName
        self.boldFontName = boldFontName
        self.titleFontSize = titleFontSize
        self.bodyFontSize = bodyFontSize
        self.rowHeight = rowHeight
        self.columnPadding = columnPadding
        self.footerNote = footerNote
        self.recordsDrawnText = recordsDrawnText
        self.maximumColumnWidth = maximumColumnWidth
        self.minimumColumnWidth = minimumColumnWidth
        self.dropsEmptyColumns = dropsEmptyColumns
        self.logoImageData = nil
        self.companyBlock = nil
    }

    /// The largest box the cover logo is fitted into, in points.
    public static let logoBox = CGSize(width: 140, height: 56)
}

/// One page image for the optional appendix (spec 15.8: "page thumbnails optional").
///
/// The image is supplied by the caller with the markups already drawn on it. This package
/// deliberately does not render a PDF page: that would mean depending on PDFKit, and every
/// PDFKit call in Zenit PDF goes through `ZPDFEngineBarrier`, which belongs to the PDF layer and
/// not to the export layer. The caller owns the barrier; the appendix owns the layout.
///
/// Not `Sendable`, because `CGImage` is not.
public struct PDFReportAppendixPage {
    public var title: String
    public var caption: String?
    public var image: CGImage

    public init(title: String, caption: String? = nil, image: CGImage) {
        self.title = title
        self.caption = caption
        self.image = image
    }
}

/// The audit-trail appendix of ADR-0007 §3: "the audit trail is exportable as CSV and
/// included as an optional appendix in the PDF report".
///
/// A plain text table — the caller supplies finished strings, exactly as the History
/// pane rendered them, so the appendix can never disagree with the pane. This package
/// lays the rows out and paginates; it interprets nothing.
public struct PDFReportAuditAppendix: Hashable, Sendable {
    /// The appendix heading, for example "Audit Trail".
    public var title: String
    /// Optional context line under the heading.
    public var caption: String?
    /// Column titles, in order.
    public var columnTitles: [String]
    /// Rows of finished strings. Every row must have `columnTitles.count` cells; short
    /// rows render blank in the missing columns rather than shifting.
    public var rows: [[String]]

    public init(title: String, caption: String? = nil, columnTitles: [String], rows: [[String]]) {
        self.title = title
        self.caption = caption
        self.columnTitles = columnTitles
        self.rows = rows
    }
}

public struct PDFReportResult: Hashable, Sendable {
    public let pageCount: Int
    /// How many column bands the table was split into. `1` means it fitted.
    public let bandCount: Int
    /// Populated only when ``PDFReportOptions/recordsDrawnText`` is on.
    public let drawnText: [String]
    /// How many of the table's columns the report printed. Lower than
    /// `projection.table.columns.count` when ``PDFReportOptions/dropsEmptyColumns`` removed
    /// columns that were blank on every printed line (LT-18).
    public let printedColumnCount: Int
    /// The label of every subtotal and grand-total line the report drew — `Sum: Concrete`,
    /// `Count (all rows)` — in drawing order, so a test can prove each line was named (CR-61).
    /// Populated only when ``PDFReportOptions/recordsDrawnText`` is on.
    public let drawnLabels: [String]
    /// The provenance marks the report drew — the per-row glyph and the per-page legend
    /// (ADR-0012 rule 4) — in drawing order. Kept out of ``drawnText`` so that trace stays one
    /// entry per printed cell, the shape every digit-for-digit comparison slices it by; they
    /// used to be pushed into it between rows (BH-528). Populated only when
    /// ``PDFReportOptions/recordsDrawnText`` is on.
    public let drawnMarks: [String]
    /// How far, in points, the widest piece of text the report drew reaches past the right
    /// margin. `0` for a report that keeps inside its margins, which is every report: a cover
    /// title, a table cell or an audit column that ran off the page was clipped by the media
    /// box (BH-138, BH-529, BH-530).
    public let rightMarginOverrun: Double
    /// NL-QTY-11: whether the cover drew the logo, and the company-block lines it printed.
    public internal(set) var drewLogo = false
    public internal(set) var drawnCompanyLines: [String] = []
    /// NL-QTY-09: every string the summary-matrix pages drew, in order — kept apart from
    /// ``drawnText`` so that trace stays one entry per ledger cell. Populated only when
    /// ``PDFReportOptions/recordsDrawnText`` is on.
    public internal(set) var drawnMatrixText: [String] = []
    /// How many pages the summary matrix took.
    public internal(set) var matrixPageCount = 0

    init(
        pageCount: Int,
        bandCount: Int,
        drawnText: [String],
        printedColumnCount: Int,
        drawnLabels: [String],
        drawnMarks: [String] = [],
        rightMarginOverrun: Double = 0
    ) {
        self.pageCount = pageCount
        self.bandCount = bandCount
        self.drawnText = drawnText
        self.printedColumnCount = printedColumnCount
        self.drawnLabels = drawnLabels
        self.drawnMarks = drawnMarks
        self.rightMarginOverrun = rightMarginOverrun
    }
}

/// The cover logo's one question for a caller (NL-QTY-11): will the report be able to draw these
/// bytes? The same decoder the cover uses, so "accepted" and "drawn" cannot disagree.
public enum PDFReportLogo {
    public static func isReadable(_ data: Data) -> Bool { Painter.decodeImage(data) != nil }
}
