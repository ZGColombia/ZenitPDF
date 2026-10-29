import Foundation
import ZPDFUIPresentation

/// How ``TableImportEngine`` found the column boundaries.
///
/// Kept on the proposal so the confirming surface can say *why* the columns sit where they
/// sit — "the table's own rule lines" is a stronger claim than "the text lines up", and the
/// user deciding whether to accept is entitled to know which one is being made.
public enum TableImportColumnSource: String, Hashable, Sendable, CaseIterable {
    /// Vertical rule lines drawn inside the region — the table's own grid.
    case ruleLines
    /// Clustered leading edges of the recognised text — alignment, not drawn structure.
    case textAlignment
}

/// One detected column: where it sits and what its header says.
public struct TableImportColumn: Hashable, Sendable {

    /// Zero-based position, left to right.
    public let index: Int
    /// The column's horizontal span in page space, region-clipped.
    public let minX: Double
    /// See ``minX``.
    public let maxX: Double
    /// The header cell's text, verbatim, when a header row was detected and the cell read.
    /// `nil` means no header — the confirming surface shows a positional name instead, and
    /// nothing downstream pretends the drawing named this column.
    public let headerText: String?

    /// Creates a column. Callers outside the engine exist only in tests.
    public init(index: Int, minX: Double, maxX: Double, headerText: String?) {
        self.index = index
        self.minX = minX
        self.maxX = maxX
        self.headerText = headerText
    }

    /// The name the column is presented and audited under: the header cell verbatim when
    /// the drawing provided one, a positional English name when it did not.
    public var title: String {
        if let headerText, !headerText.isEmpty { return headerText }
        return "Column \(index + 1)"
    }
}

/// One cell of one detected row: the recognised text, verbatim, or nothing.
///
/// A cell the OCR could not read **stays empty and stays flagged** (``isUnread``). It is
/// never filled from a neighbour, a header, or a guess — an invented cell value in a bid
/// is the silent-wrongness list wearing a spreadsheet's clothes.
public struct TableImportCell: Hashable, Sendable {

    /// The recognised text, verbatim. Empty when nothing was read inside the cell.
    public let text: String
    /// Union of the recognised lines' bounds inside the cell, when any were read.
    public let boundsInPageSpace: PDFRectValue?

    /// Creates a cell. Callers outside the engine exist only in tests.
    public init(text: String, boundsInPageSpace: PDFRectValue?) {
        self.text = text
        self.boundsInPageSpace = boundsInPageSpace
    }

    /// `true` when the OCR read nothing inside this cell. The flag the review surface
    /// renders, and the reason the cell is absent from the accepted row's derivation inputs.
    public var isUnread: Bool { text.isEmpty }
}

/// One detected row: its cells in column order.
public struct TableImportRow: Hashable, Sendable {

    /// One cell per detected column, in column order. Count always equals the column count.
    public let cells: [TableImportCell]
    /// Every recognised line of the row joined left to right, verbatim — including text
    /// that could not be assigned to a column, so nothing the OCR read is silently dropped.
    public let sourceText: String
    /// Union of the row's recognised line bounds.
    public let boundsInPageSpace: PDFRectValue?

    /// Creates a row. Callers outside the engine exist only in tests.
    public init(cells: [TableImportCell], sourceText: String, boundsInPageSpace: PDFRectValue?) {
        self.cells = cells
        self.sourceText = sourceText
        self.boundsInPageSpace = boundsInPageSpace
    }

    /// How many of the row's cells the OCR could not read.
    public var unreadCellCount: Int { cells.count(where: \.isUnread) }
}

/// A table read off the drawing, offered to the user. **It is never applied.**
///
/// This type is a proposal and only a proposal, on exactly the terms of ``ScaleProposal``:
/// nothing in this directory adds a row to the document, and no caller may treat an
/// unaccepted proposal as rows. Acceptance is explicit —
/// ``TableImportAcceptance/records(from:documentID:pageID:identifiers:timestamps:)`` — and
/// what it produces are `.read` rows under ADR-0012, distinguishable from measurements
/// forever after.
public struct TableImportProposal: Hashable, Sendable {

    /// The user-chosen region the table was read from, in page space.
    public let region: PDFRectValue
    /// The detected columns, left to right. Always at least two — a region that yields
    /// fewer is a ``TableImportRefusal``, never a one-column proposal.
    public let columns: [TableImportColumn]
    /// The header row, when the topmost row read as one. It never becomes a data row.
    public let headerRow: TableImportRow?
    /// The data rows, top to bottom.
    public let rows: [TableImportRow]
    /// How the column boundaries were found.
    public let columnSource: TableImportColumnSource
    /// Recognised lines inside the region that arrived without page-space bounds and so
    /// could not be placed in any cell. Carried, never dropped: the review surface lists
    /// them so the user knows what was read but not filed.
    public let unplacedTexts: [String]

    /// Creates a proposal. Callers outside the engine exist only in tests.
    public init(
        region: PDFRectValue,
        columns: [TableImportColumn],
        headerRow: TableImportRow?,
        rows: [TableImportRow],
        columnSource: TableImportColumnSource,
        unplacedTexts: [String]
    ) {
        self.region = region
        self.columns = columns
        self.headerRow = headerRow
        self.rows = rows
        self.columnSource = columnSource
        self.unplacedTexts = unplacedTexts
    }

    /// How many cells across all data rows the OCR could not read.
    public var unreadCellCount: Int {
        rows.reduce(0) { $0 + $1.unreadCellCount }
    }
}

/// Every reason the engine refuses to propose, as one typed error space.
///
/// A refusal is a result, not a failure — the same doctrine as `ScaleProposalEngine`
/// returning `nil` and `DocumentCommandError.noScale`: a region that does not read as a
/// table must say so and leave the user typing the schedule, and it must never fall back
/// to a confident one-column guess.
public enum TableImportRefusal: Error, Hashable, Sendable, CustomStringConvertible {

    /// No recognised text sits inside the region.
    case emptyRegion
    /// Text was recognised inside the document but every line inside the region arrived
    /// without page-space bounds, so nothing can be placed in a grid.
    case textWithoutPositions(lineCount: Int)
    /// Neither the rule lines nor the text alignment yields at least two columns. The
    /// counts say what was actually found, so the refusal can be shown with its reasons.
    case noColumnStructure(interiorRuleCount: Int, alignmentClusterCount: Int)
    /// Columns were found but no row of text sits under them (for example, a header
    /// with nothing beneath it).
    case noRows

    public var description: String {
        switch self {
        case .emptyRegion:
            "no recognised text inside the selected region"
        case .textWithoutPositions(let lineCount):
            "\(lineCount) recognised line(s) carry no page positions, so no grid can be built"
        case .noColumnStructure(let interiorRuleCount, let alignmentClusterCount):
            "no column structure: \(interiorRuleCount) interior rule line(s), "
                + "\(alignmentClusterCount) text alignment cluster(s) — two or more columns are required"
        case .noRows:
            "column structure was found but no row of text sits under it"
        }
    }
}
